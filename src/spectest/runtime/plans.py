"""Per-call plans: one example of a function call, judged for the function's items.

A ``FunctionPlan`` belongs to one bound function under one instantiation. It
lists the function's items (its judged clauses and the built-ins ``#type``,
``#raises``, ``#frame`` and the invariants of models it returns or modifies)
and runs one example: residual invariants and concretization of generated
models, defaults, ``requires``, the pre-state (``old`` snapshots, digests of
handle parameters, ``raises`` / ``may_raise`` conditions), the call (with an
optional timeout), the outcome and a verdict per requested item.
"""

from __future__ import annotations

import warnings
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, Literal

from spectest import ast
from spectest import eval as ev
from spectest.alarm import CallTimeout, alarm, can_time_out
from spectest.lang.spec import Spec
from spectest.runtime import binding
from spectest.runtime.binding import Conformance, TypeMismatch
from spectest.runtime.context import FieldsContext, RuntimeContext
from spectest.runtime.store import (
    canonical_json,
    encode_value,
    generate_module,
    is_default,
)
from spectest.types import (
    ListT,
    MapT,
    ModelT,
    OptionT,
    RecordT,
    TupleT,
    Type,
    UnitT,
    substitute,
)
from spectest.values import (
    BindingError,
    EvalError,
    Handle,
    MapValue,
    RecordValue,
    SkipClause,
    Some,
    SpecError,
    Unrepresentable,
)

Verdict = Literal["pass", "fail", "skip", "spec_error", "inconclusive"]
JUDGED_KINDS = ("ensures", "raises", "relates", "aggregate", "modifies")
EXPLAIN_LIMIT = 16


class ClauseFailure(AssertionError):
    """An item's clause failed on an example; raised inside Hypothesis so it shrinks."""

    def __init__(self, key: str, message: str, counterexample: Any = None) -> None:
        super().__init__(f"{key}: {message}")
        self.key = key
        self.message = message
        self.counterexample = counterexample


# ---------------------------------------------------------------------------
# Calling an implementation


@dataclass
class CallOutcome:
    """What one implementation call did: returned a value, raised, or timed out.

    ``warnings`` holds the warnings the call issued ("RuntimeWarning: invalid value
    encountered in cos"); they are recorded, never verdicts.
    """

    kind: Literal["returned", "raised", "timeout"]
    value: Any = None
    exc: BaseException | None = None
    warnings: list[str] = field(default_factory=list)


def invoke(
    fn: Callable[..., Any],
    args: Sequence[Any] = (),
    kwargs: dict[str, Any] | None = None,
    timeout: float | None = None,
) -> CallOutcome:
    """Call an implementation; exceptions are outcomes, a timeout is ``kind="timeout"``.

    Warnings the call issues are recorded on the outcome instead of shown; the
    active filters still apply, so ``-W error`` turns one into a raise.
    """
    with warnings.catch_warnings(record=True) as caught:
        outcome = _invoke(fn, args, kwargs or {}, timeout)
    outcome.warnings = list(dict.fromkeys(f"{w.category.__name__}: {w.message}" for w in caught))
    return outcome


def _invoke(
    fn: Callable[..., Any], args: Sequence[Any], kwargs: dict[str, Any], timeout: float | None
) -> CallOutcome:
    if not timeout or not can_time_out():
        try:
            return CallOutcome("returned", fn(*args, **kwargs))
        except Exception as exc:  # noqa: BLE001
            return CallOutcome("raised", exc=exc)
    try:
        with alarm(timeout):
            try:
                value = fn(*args, **kwargs)
            except Exception as exc:  # noqa: BLE001
                return CallOutcome("raised", exc=exc)
        return CallOutcome("returned", value)
    except CallTimeout as exc:
        return CallOutcome("timeout", exc=exc)


def describe_exception(exc: BaseException) -> str:
    text = str(exc)
    return f"{type(exc).__name__}: {text}" if text else type(exc).__name__


# ---------------------------------------------------------------------------
# Values: walking types, formatting


def handles_in(value: Any, t: Type) -> Iterator[tuple[Handle, ModelT]]:
    """Every model handle inside a value of type t, with its type."""
    if isinstance(t, ModelT):
        if isinstance(value, Handle):
            yield value, t
    elif isinstance(t, ListT) and isinstance(value, (tuple, list)):
        for x in value:
            yield from handles_in(x, t.elem)
    elif isinstance(t, TupleT) and isinstance(value, (tuple, list)):
        for x, et in zip(value, t.elems):
            yield from handles_in(x, et)
    elif isinstance(t, OptionT) and isinstance(value, Some):
        yield from handles_in(value.value, t.elem)
    elif isinstance(t, MapT) and isinstance(value, MapValue):
        for k, x in value.items:
            yield from handles_in(k, t.key)
            yield from handles_in(x, t.value)
    elif isinstance(t, RecordT) and isinstance(value, RecordValue):
        types = dict(t.fields)
        for k, x in value.fields:
            if k in types:
                yield from handles_in(x, types[k])


def _is_generated(value: Any) -> bool:
    gen = generate_module()
    cls = getattr(gen, "GeneratedModel", None) if gen is not None else None
    return cls is not None and isinstance(value, cls)


def generated_in(value: Any, t: Type) -> Iterator[Any]:
    """Every generated model value (not yet concretized) inside a value of type t."""
    if isinstance(t, ModelT):
        if _is_generated(value):
            yield value
    elif isinstance(t, ListT) and isinstance(value, (tuple, list)):
        for x in value:
            yield from generated_in(x, t.elem)
    elif isinstance(t, TupleT) and isinstance(value, (tuple, list)):
        for x, et in zip(value, t.elems):
            yield from generated_in(x, et)
    elif isinstance(t, OptionT) and isinstance(value, Some):
        yield from generated_in(value.value, t.elem)
    elif isinstance(t, MapT) and isinstance(value, MapValue):
        for k, x in value.items:
            yield from generated_in(k, t.key)
            yield from generated_in(x, t.value)
    elif isinstance(t, RecordT) and isinstance(value, RecordValue):
        types = dict(t.fields)
        for k, x in value.fields:
            if k in types:
                yield from generated_in(x, types[k])


def model_tenv(spec: Spec, model: str, targs: Sequence[Type]) -> dict[str, Type]:
    decl = spec.models.get(model) or spec.interfaces.get(model)
    names = list(spec.tparams.get(decl, {})) if decl is not None else []
    return dict(zip(names, targs))


def field_types(spec: Spec, model: str, targs: Sequence[Type]) -> dict[str, Type]:
    tenv = model_tenv(spec, model, targs)
    return {o.name: substitute(spec.signature[o].result, tenv) for o in spec.fields(model)}


def _record(model: str, values: dict[str, Any], types: dict[str, Type]) -> str:
    body = ", ".join(f"{k}: {ev.format_value(v, types.get(k))}" for k, v in values.items())
    return f"{model} {{ {body} }}" if body else f"{model} {{}}"


def show_generated(gm: Any, spec: Spec) -> str:
    try:
        types = field_types(spec, gm.model, gm.targs)
    except (KeyError, SpecError):
        types = {}
    return _record(gm.model, gm.fields, types)


def show_handle(h: Handle, ctx: Any, spec: Spec) -> str:
    """A handle as its observed fields: ``Frame { columns: ["a"], rows: [...], nrows: 1 }``."""
    try:
        values = ctx.fields(h)
        types = field_types(spec, h.model, h.targs)
    except (SpecError, KeyError) as exc:
        return f"<{h.model} #{h.id}> (fields not observable: {exc})"
    return _record(h.model, values, types)


def show(value: Any, t: Type | None, spec: Spec, ctx: Any = None) -> str:
    """A value for counterexamples: models by their fields, other values by format_value."""
    if _is_generated(value):
        return show_generated(value, spec)
    if isinstance(value, Handle) and ctx is not None:
        return show_handle(value, ctx, spec)
    return ev.format_value(value, t)


def inst_text(tenv: dict[str, Type]) -> str:
    """``T=i64`` or ``K=i64,V=string``: an instantiation inside an item name."""
    return ",".join(f"{k}={str(v).replace(' ', '')}" for k, v in tenv.items())


def decl_label(name: str, tenv: dict[str, Type]) -> str:
    return f"{name}[{inst_text(tenv)}]" if tenv else name


def memo_key(name: str, args: Sequence[Any]) -> str | None:
    """A key under which two planned calls are identical, or None when it cannot be built."""
    try:
        enc = encode_value(list(args), handle=lambda h: {"$handle": id(h.obj)})
    except (ValueError, TypeError):
        return None
    return name + canonical_json(enc)


# ---------------------------------------------------------------------------
# Explicit examples


def _has_model(t: Type) -> bool:
    if isinstance(t, ModelT):
        return not t.is_interface
    if isinstance(t, ListT | OptionT):
        return _has_model(t.elem)
    if isinstance(t, TupleT):
        return any(_has_model(e) for e in t.elems)
    return False


def from_example(value: Any, t: Type, conf: Conformance, spec: Spec) -> Any:
    """A value of an explicit example as a spec value of type t.

    A model value is a dict of the model's fields (fields that its invariants
    compute, such as ``nrows == len(rows)``, may be left out), which the
    binding's concretizer builds when the example runs. Other values are read
    as implementation values are (``binding.from_python``), or may already be
    spec values (a FloatValue for an exact float). BindingError says what does
    not fit.
    """
    gen = generate_module()
    if isinstance(t, ModelT) and not t.is_interface:
        if isinstance(value, gen.GeneratedModel) and value.model == t.name:
            return value
        if not isinstance(value, Mapping):
            raise BindingError(f"a {t} is given as a dict of its fields, not {binding.describe(value)}")
        types = field_types(spec, t.name, t.args)
        unknown = [str(k) for k in value if k not in types]
        if unknown:
            raise BindingError(f"{t.name} has no field {', '.join(unknown)}")
        fields = {k: from_example(x, types[k], conf, spec) for k, x in value.items()}
        try:
            fields = gen.computed_fields(gen.field_plans(t.name, spec), fields, missing_only=True)
        except KeyError as exc:
            raise BindingError(f"the {t.name} field {exc.args[0]} is missing") from None
        gm = gen.GeneratedModel(t.name, tuple(t.args), fields)
        if broken := gen.broken_invariants(gm, spec):
            raise BindingError(f"the {t.name} fields break {', '.join(broken)}")
        return gm
    if _has_model(t):
        if isinstance(t, ListT) and isinstance(value, list | tuple):
            return tuple(from_example(x, t.elem, conf, spec) for x in value)
        if isinstance(t, TupleT) and isinstance(value, list | tuple) and len(value) == len(t.elems):
            return tuple(from_example(x, et, conf, spec) for x, et in zip(value, t.elems))
        if isinstance(t, OptionT):
            if value is None:
                return None
            inner = value.value if isinstance(value, Some) else value
            return Some(from_example(inner, t.elem, conf, spec))
    try:
        return binding.from_python(value, t, conf)
    except TypeMismatch as exc:
        try:
            encode_value(value, t)
        except ValueError:
            raise BindingError(str(exc)) from None
        return value


def example_args(
    conf: Conformance, decl: ast.Callable_, tenv: dict[str, Type], raw: Any
) -> dict[str, Any]:
    """An explicit example (parameter name -> value) as spec values under one
    instantiation; a parameter left out (or DEFAULT) that has a default is DEFAULT."""
    spec = conf.spec
    gen = generate_module()
    name = spec.decl_ids.get(decl, decl.name)
    if not isinstance(raw, Mapping):
        raise BindingError(f"an example is a dict of parameter values, not {binding.describe(raw)}")
    params = list(decl.params)
    unknown = [str(k) for k in raw if k not in {p.name for p in params}]
    if unknown:
        raise BindingError(f"{name} has no parameter {', '.join(unknown)}")
    out: dict[str, Any] = {}
    for p, t in zip(params, spec.signature[decl].params, strict=True):
        if p.name not in raw or raw[p.name] is gen.DEFAULT:
            if p.default is None:
                raise BindingError(f"{p.name} is missing")
            out[p.name] = gen.DEFAULT
            continue
        try:
            out[p.name] = from_example(raw[p.name], substitute(t, tenv), conf, spec)
        except BindingError as exc:
            raise BindingError(f"{p.name} = {raw[p.name]!r}: {exc}") from None
    return out


def explicit_examples(
    conf: Conformance, decl: ast.Callable_, tenv: dict[str, Type]
) -> list[dict[str, Any]]:
    """The conformance's explicit examples of a function, constructor or method that fit
    an instantiation, as argument dicts (``conformance(examples=...)``)."""
    spec = conf.spec
    out: list[dict[str, Any]] = []
    for raw in getattr(conf, "examples", {}).get(spec.decl_ids.get(decl, decl.name), ()):
        try:
            out.append(example_args(conf, decl, tenv, raw))
        except BindingError:
            continue
    return out


def example_decl(spec: Spec, conf: Conformance, key: str) -> tuple[ast.Callable_, ast.Node] | None:
    """The function, or constructor or method of a bound interface, that an ``examples``
    key names, with the declaration whose instantiations apply."""
    if key in spec.fns and key in conf.impls:
        return spec.fns[key], spec.fns[key]
    iface_name, _, member = key.partition(".")
    iface = spec.interfaces.get(iface_name)
    if iface is None or iface_name not in conf.interfaces:
        return None
    for d in [*iface.ctors, *iface.methods]:
        if d.name == member:
            return d, iface
    return None


def example_problems(conf: Conformance) -> list[str]:
    """What is wrong with a conformance's explicit examples: each must name a bound
    function (or interface member) and fit at least one of its instantiations."""
    spec = conf.spec
    problems: list[str] = []
    for key, examples in conf.examples.items():
        found = example_decl(spec, conf, key) if isinstance(key, str) else None
        if found is None:
            problems.append(
                f"examples: {key!r} is not a bound function, or a constructor or method "
                "of a bound interface"
            )
            continue
        decl, owner = found
        if not isinstance(examples, list | tuple):
            problems.append(f"examples[{key!r}] must be a list of dicts, got {examples!r}")
            continue
        insts = conf.instantiations(owner) or [{}]
        for i, raw in enumerate(examples):
            errors: list[str] = []
            for tenv in insts:
                try:
                    example_args(conf, decl, tenv, raw)
                    break
                except BindingError as exc:
                    errors.append(str(exc))
            else:
                problems.append(f"examples[{key!r}][{i}]: {errors[0]}")
    return problems


# ---------------------------------------------------------------------------
# Items and examples


@dataclass(frozen=True)
class PlanItem:
    """One judged item of a function: a clause, a built-in, or a model invariant.

    ``key`` is what ``expect_fail`` names: the clause ID ("cos.accurate"),
    "cos#type", "cos#raises", "cos#frame" or "dropna:Frame.rectangular";
    ``suffix`` follows the declaration label in the item name.
    """

    key: str
    kind: str
    suffix: str
    clause: ast.Clause | None = None
    model: str | None = None


@dataclass
class Example:
    """One example's verdicts per item, with notes and (in explain mode) explanations."""

    args: dict[str, Any]
    status: Literal["judged", "rejected", "skipped", "error", "timeout"] = "judged"
    reason: str = ""
    verdicts: dict[str, Verdict] = field(default_factory=dict)
    notes: dict[str, str] = field(default_factory=dict)
    explanations: dict[str, list[tuple[str, str]]] = field(default_factory=dict)
    observation: str = ""
    coverage: dict[str, str] = field(default_factory=dict)
    values: dict[str, Any] = field(default_factory=dict)

    def all(self, keys: Iterable[str], verdict: Verdict, note: str = "") -> Example:
        for k in keys:
            self.verdicts[k] = verdict
            if note:
                self.notes[k] = note
        return self


def skip_cause(ex: Example, key: str) -> str:
    """Why an item skipped an example, as a key of ``report.SKIP_CAUSES``."""
    if ex.status == "skipped":
        return "requires"
    if ex.status == "rejected":
        return "unrepresentable" if ex.reason.startswith("unrepresentable") else "rejected"
    note = ex.notes.get(key, "")
    if note == "the call raised":
        return "raised"
    if note == "the result is not of its declared type":
        return "wrong type"
    if note.startswith(("raise due", "another error is due")):
        return "raise due"
    if note.startswith("planned call"):
        return "planned call"
    return "other"


class PlannedCalls:
    """Planned implementation calls of ``relates`` and ``aggregate`` clauses.

    A call checks the callee's ``requires`` on its (coerced) arguments, calls
    the implementation and reads its result; a false ``requires``, a raise or a
    result of the wrong type is a SkipClause. Identical calls are made once.
    """

    def __init__(
        self,
        conf: Conformance,
        spec: Spec,
        tenv: dict[str, Type],
        timeout: float | None = None,
        known: Iterable[Any] = (),
        memoize: bool = True,
    ) -> None:
        self.conf = conf
        self.spec = spec
        self.tenv = tenv
        self.timeout = timeout
        self.known = list(known)
        self.memoize = memoize
        self.memo: dict[str, Any] = {}
        self.calls = 0

    def __call__(self, name: str, args: tuple) -> Any:
        key = memo_key(name, args) if self.memoize else None
        if key is not None and key in self.memo:
            v = self.memo[key]
            if isinstance(v, SkipClause):
                raise SkipClause(str(v))
            return v
        try:
            v = self.call(name, args)
        except SkipClause as exc:
            if key is not None:
                self.memo[key] = exc
            raise
        if key is not None:
            self.memo[key] = v
        return v

    def call(self, name: str, args: tuple) -> Any:
        spec, conf = self.spec, self.conf
        fn = spec.fns.get(name)
        if fn is None:
            raise EvalError(f"{name} is not a function of spec {spec.name}")
        impl = conf.impls.get(name)
        if impl is None:
            raise BindingError(
                f"a planned call needs an implementation of {name}: bind it in impls"
            )
        tenv = {n: self.tenv[n] for n in spec.tparams.get(fn, {}) if n in self.tenv}
        sig = spec.signature[fn]
        ptypes = [substitute(t, tenv) for t in sig.params]
        rtype = substitute(sig.result, tenv)
        text = (
            f"{name}({', '.join(ev.format_value(a, t) for a, t in zip(args, ptypes, strict=True))})"
        )
        env = ev.Env(values=dict(zip((p.name for p in fn.params), args, strict=True)), tenv=tenv)
        ctx = RuntimeContext(conf, spec, known=self.known)
        for c in fn.clauses:
            if c.kind == "requires" and not ev.holds(c, env, spec, ctx):
                raise SkipClause(f"planned call {text} is outside {c.id}")
        pyargs = [binding.to_python(a, t, conf) for a, t in zip(args, ptypes, strict=True)]
        self.calls += 1
        outcome = invoke(impl, pyargs, {}, self.timeout)
        if outcome.kind == "timeout":
            raise CallTimeout(f"planned call {text} {outcome.exc}")
        if outcome.kind == "raised":
            assert outcome.exc is not None
            raise SkipClause(f"planned call {text} raised {describe_exception(outcome.exc)}")
        try:
            return binding.from_python(outcome.value, rtype, conf, created_by=name)
        except TypeMismatch as exc:
            raise SkipClause(f"planned call {text} returned a value that is not {rtype}: {exc}")


# ---------------------------------------------------------------------------
# The plan of one function


class FunctionPlan:
    """A bound function under one instantiation: its items, and how one example runs."""

    def __init__(
        self, conf: Conformance, fn: ast.FnDecl, tenv: dict[str, Type] | None = None
    ) -> None:
        self.conf = conf
        self.spec = spec = conf.spec
        self.fn = fn
        self.tenv = dict(tenv or {})
        self.impl = conf.impls[fn.name]
        self.timeout: float | None = None
        sig = spec.signature[fn]
        self.names = [p.name for p in fn.params]
        self.params = {p.name: p for p in fn.params}
        self.types = [substitute(t, self.tenv) for t in sig.params]
        self.type_of = dict(zip(self.names, self.types, strict=True))
        self.result_type = substitute(sig.result, self.tenv)
        self.decl_id = spec.decl_ids.get(fn, fn.name)
        self.label = decl_label(self.decl_id, self.tenv)
        self.clauses = list(fn.clauses)
        self.requires = [c for c in self.clauses if c.kind == "requires"]
        self.raises = [c for c in self.clauses if c.kind == "raises"]
        self.may_raise = [c for c in self.clauses if c.kind == "may_raise"]
        self.ensures = [c for c in self.clauses if c.kind == "ensures"]
        self.relates = [c for c in self.clauses if c.kind == "relates"]
        self.modifies = [c for c in self.clauses if c.kind == "modifies"]
        self.aggregates = [c for c in self.clauses if c.kind == "aggregate"]
        self.with_olds = {c for c in self.ensures if ev.old_calls(c.expr, spec)}
        self.handle_params = [
            n
            for n, t in zip(self.names, self.types, strict=True)
            if isinstance(t, ModelT) and not t.is_interface
        ]
        self.modified = {n for c in self.modifies for n in c.names}
        self.items = self._items()
        self._residuals: dict[str, list[ast.Clause]] = {}
        self._examples: list[dict[str, Any]] | None = None

    def __repr__(self) -> str:
        return f"<FunctionPlan {self.label}>"

    # -- items -------------------------------------------------------------------

    def _items(self) -> list[PlanItem]:
        prefix = self.decl_id
        out: list[PlanItem] = []
        for c in self.clauses:
            if c.kind in JUDGED_KINDS:
                suffix = c.id[len(prefix) :] if c.id.startswith(prefix) else f":{c.id}"
                out.append(PlanItem(c.id, c.kind, suffix, c))
        out.append(PlanItem(f"{prefix}#type", "type", "#type"))
        out.append(PlanItem(f"{prefix}#raises", "raises", "#raises"))
        if self.handle_params and not self.modifies:
            out.append(PlanItem(f"{prefix}#frame", "frame", "#frame"))
        for model in self.invariant_models():
            for c in self.spec.models[model].clauses:
                if c.kind == "invariant":
                    out.append(PlanItem(f"{prefix}:{c.id}", "invariant", f":{c.id}", c, model))
        return out

    def invariant_models(self) -> list[str]:
        """Models the function returns or modifies, whose invariants are judged on those handles."""
        found: list[str] = []

        def visit(t: Type) -> None:
            if isinstance(t, ModelT):
                if not t.is_interface and t.name in self.spec.models and t.name not in found:
                    found.append(t.name)
                for a in t.args:
                    visit(a)
            elif isinstance(t, (ListT, OptionT)):
                visit(t.elem)
            elif isinstance(t, TupleT):
                for e in t.elems:
                    visit(e)
            elif isinstance(t, MapT):
                visit(t.key)
                visit(t.value)
            elif isinstance(t, RecordT):
                for _, ft in t.fields:
                    visit(ft)

        visit(self.result_type)
        for n in self.names:
            if n in self.modified:
                visit(self.type_of[n])
        return found

    def item(self, key: str) -> PlanItem:
        for it in self.items:
            if it.key == key:
                return it
        raise KeyError(key)

    def item_name(self, it: PlanItem) -> str:
        return self.label + it.suffix

    def example_keys(self) -> list[str]:
        """Items judged per example (aggregates are judged once, over their set)."""
        return [it.key for it in self.items if it.kind != "aggregate"]

    # -- inputs ------------------------------------------------------------------

    def explicit_examples(self) -> list[dict[str, Any]]:
        """The conformance's explicit examples of this function that fit this
        instantiation, as argument dicts."""
        if self._examples is None:
            self._examples = explicit_examples(self.conf, self.fn, self.tenv)
        return self._examples

    def residuals(self, model: str) -> list[ast.Clause]:
        if model not in self._residuals:
            gen = generate_module()
            self._residuals[model] = list(gen.residual_invariants(model, self.spec))
        return self._residuals[model]

    def residuals_hold(self, args: dict[str, Any]) -> bool:
        """Do the generated models in the arguments satisfy the invariants generation does
        not enforce? EvalError when one cannot be evaluated."""
        ctx = FieldsContext(self.spec)
        for n, t in zip(self.names, self.types, strict=True):
            for gm in generated_in(args.get(n), t):
                clauses = self.residuals(gm.model)
                if not clauses:
                    continue
                h = Handle(gm, gm.model, targs=tuple(gm.targs))
                env = ev.Env(
                    values={"self": h},
                    fields=h,
                    tenv=model_tenv(self.spec, gm.model, gm.targs),
                )
                for c in clauses:
                    if not ev.holds(c, env, self.spec, ctx):
                        return False
        return True

    def format_inputs(self, args: dict[str, Any]) -> dict[str, str]:
        out: dict[str, str] = {}
        for n, t in zip(self.names, self.types, strict=True):
            if n not in args:
                continue
            v = args[n]
            if is_default(v):
                try:
                    out[n] = (
                        f"default ({ev.format_value(ev.default_value(self.params[n], self.spec), t)})"
                    )
                except SpecError:
                    out[n] = "default"
            else:
                out[n] = show(v, t, self.spec)
        return out

    # -- one example --------------------------------------------------------------

    def run(
        self,
        args: dict[str, Any],
        keys: Iterable[str] | None = None,
        *,
        explain: bool = False,
        coverage: Sequence[Any] = (),
    ) -> Example:
        """Run one example and judge the requested items (all but aggregates by default).

        ``coverage`` lists the PartitionInfo of the parameters whose class to record.
        """
        wanted = list(keys) if keys is not None else self.example_keys()
        return _Run(self, dict(args), wanted, explain, coverage).run()


Judged = tuple[Verdict, str, list[tuple[str, str]]]


class CallJudge:
    """The verdicts of one call's own clauses, from its pre-state and its outcome.

    ``conditions`` holds each raises / may_raise clause's condition on the
    pre-state (a bool, or the exception evaluating it raised). Each verdict
    method returns (verdict, note, explanation lines).
    """

    def __init__(
        self,
        conf: Conformance,
        spec: Spec,
        *,
        raises: Sequence[ast.Clause],
        may_raise: Sequence[ast.Clause],
        conditions: dict[ast.Clause, bool | BaseException],
        outcome: CallOutcome,
        result_type: Type,
        created_by: str | None = None,
        explain: bool = False,
    ) -> None:
        self.conf = conf
        self.spec = spec
        self.raises = list(raises)
        self.may_raise = list(may_raise)
        self.conditions = conditions
        self.outcome = outcome
        self.result_type = result_type
        self.explain = explain
        self.R = {c.error for c in self.raises if conditions.get(c) is True}
        self.M = {c.error for c in self.may_raise if conditions.get(c) is True}
        self.due = [c for c in self.raises if conditions.get(c) is True]
        self.result: Any = None
        self.type_error: TypeMismatch | None = None
        self.convert_error: SpecError | None = None
        self.error: str | None = None
        if outcome.kind == "returned":
            try:
                self.result = binding.from_python(
                    outcome.value, result_type, conf, created_by=created_by
                )
            except TypeMismatch as exc:
                self.type_error = exc
            except SpecError as exc:
                self.convert_error = exc
        elif outcome.exc is not None:
            self.error = binding.map_exception(outcome.exc, conf)

    @property
    def raised(self) -> bool:
        return self.outcome.kind == "raised"

    @property
    def returned_value(self) -> bool:
        return self.outcome.kind == "returned" and self.type_error is None

    @property
    def returned_while_due(self) -> list[ast.Clause]:
        """The raises clauses that were due on this input, when the call returned anyway."""
        return self.due if self.outcome.kind == "returned" else []

    def due_skip(self) -> Judged | None:
        """An item that cannot be evaluated where a raise was due is skipped, not a spec
        error: the input is one the clause's author expected never to return."""
        due = self.returned_while_due
        if not due:
            return None
        return "skip", f"raise due ({', '.join(c.id for c in due)})", []

    def due_notes(self) -> str:
        return "".join(
            f"\nnote: {c.id} required {c.error} on this input" for c in self.returned_while_due
        )

    def raised_text(self) -> str:
        assert self.outcome.exc is not None
        mapped = f" (maps to {self.error})" if self.error else " (no spec error maps it)"
        return f"raised {describe_exception(self.outcome.exc)}{mapped}"

    def outcome_text(self, ctx: Any = None) -> str:
        """What the call did, for counterexamples (with the warnings it issued)."""
        text = self._outcome_text(ctx)
        if self.outcome.warnings:
            text += "\n" + self.warned_text()
        return text

    def warned_text(self) -> str:
        return "warned: " + "; ".join(self.outcome.warnings) if self.outcome.warnings else ""

    @property
    def returned_unit(self) -> bool:
        return self.returned_value and isinstance(self.result_type, UnitT)

    def _outcome_text(self, ctx: Any) -> str:
        if self.raised:
            return self.raised_text()
        if self.outcome.kind == "timeout":
            return str(self.outcome.exc)
        if self.type_error is not None:
            return self.mismatch_text()
        if self.convert_error is not None:
            return f"the result could not be read: {self.convert_error}"
        return f"result = {show(self.result, self.result_type, self.spec, ctx)}"

    def mismatch_text(self) -> str:
        """``returned int 256, which is not u8 (outside the u8 range 0..255)``: the value
        once, then only what the mismatch adds to it."""
        err = self.type_error
        assert err is not None
        got = binding.describe(self.outcome.value)
        head = f"returned {got}, which is not {self.result_type}"
        plain = f"expected {self.result_type}, got {got}"
        if not err.path and err.message.startswith(plain):
            return head + err.message[len(plain) :]
        return f"{head}: {err}"

    def explain_clause(self, c: ast.Clause, env: ev.Env, ctx: Any) -> list[tuple[str, str]]:
        if not self.explain or c.expr is None:
            return []
        return ev.explain(c.expr, env, self.spec, ctx, limit=EXPLAIN_LIMIT)

    def type_verdict(self, ctx: Any = None) -> Judged:
        """``#type``: the result reads as its type, and (with ctx) every field of each model
        handle in it reads without an observer refusing the object (NotAValue)."""
        if self.raised:
            return "skip", "the call raised", []
        if self.type_error is not None:
            msg = f"the result is not {self.result_type}: {self.type_error}"
            return "fail", msg, [("result", binding.describe(self.outcome.value))]
        for h, t in handles_in(self.result, self.result_type) if ctx is not None else ():
            if t.is_interface:
                continue
            try:
                ctx.fields(h)
            except binding.ValueRefused as exc:
                return "fail", f"the result is not {self.result_type}: {exc}", []
            except SpecError as exc:
                return "spec_error", f"reading the result: {exc}", []
        return "pass", "", []

    def refused(self, exc: SpecError) -> str | None:
        """The skip note when an observer refused an object an implementation call returned
        (the result, which ``#type`` judges, or a planned call's), else None."""
        if not isinstance(exc, binding.ValueRefused) or exc.handle.created_by not in self.spec.fns:
            return None
        if any(h is exc.handle for h, _ in handles_in(self.result, self.result_type)):
            return "the result is not of its declared type"
        return f"planned call returned an object that is not a value: {exc}"

    def admitted_lines(self) -> list[tuple[str, str]]:
        lines = []
        for c in [*self.raises, *self.may_raise]:
            v = self.conditions.get(c)
            if isinstance(v, bool):
                shown = ev.format_value(v)
            else:
                shown = f"error: {v}" if v is not None else "?"
            lines.append((f"{c.kind} {c.error} when {_when(c, self.spec)}", shown))
        lines.append(("errors that must be raised (R)", _names(self.R)))
        lines.append(("errors that may be raised (M)", _names(self.M)))
        return lines

    def unadmitted_verdict(self) -> Judged:
        """``#raises``: an exception no raises or may_raise admits fails."""
        if not self.raised:
            return "pass", "", []
        err = self.error
        if err is None:
            assert self.outcome.exc is not None
            name = type(self.outcome.exc).__name__
            return (
                "fail",
                f"no spec error maps {name}, so no raises or may_raise admits it",
                self.admitted_lines(),
            )
        if err in self.R or err in self.M:
            return "pass", "", []
        if any(c.error == err for c in self.raises):
            return "pass", f"{err} is judged by its raises clause", []
        broken = [
            c
            for c in self.may_raise
            if c.error == err and isinstance(self.conditions.get(c), BaseException)
        ]
        if broken:
            return "spec_error", f"{broken[0].id}: {self.conditions[broken[0]]}", []
        return (
            "fail",
            f"no raises or may_raise admits {err} here",
            self.admitted_lines(),
        )

    def raises_verdict(self, c: ast.Clause) -> Judged:
        """``raises E when P``: due errors must be raised, and E only when due (or admitted)."""
        cond = self.conditions.get(c)
        if isinstance(cond, BaseException):
            return "spec_error", str(cond), []
        lines = self.admitted_lines()
        if self.raised:
            lines.append(("raised", self.raised_text()[len("raised ") :]))
        else:
            lines.append(("raised", "nothing (the call returned)"))
        when = _when(c, self.spec)
        if cond:
            if self.raised and self.error in self.R:
                return "pass", "", []
            did = self.raised_text() if self.raised else "returned"
            return "fail", f"{c.error} was due ({when} holds), but the call {did}", lines
        if self.R:
            return "skip", f"another error is due ({_names(self.R)})", []
        if self.raised and self.error == c.error and c.error not in self.M:
            return "fail", f"the call raised {c.error} although {when} is false", lines
        return "pass", "", []

    def condition_verdict(self, c: ast.Clause, env: ev.Env, ctx: Any) -> Judged:
        """ensures / relates: judged only when the call returned a value of its type."""
        if self.raised:
            return "skip", "the call raised", []
        if self.type_error is not None:
            return "skip", "the result is not of its declared type", []
        try:
            ok = ev.holds(c, env, self.spec, ctx)
        except SkipClause as exc:
            return "skip", str(exc), []
        except SpecError as exc:
            if note := self.refused(exc):
                return "skip", note, []
            return self.due_skip() or ("spec_error", str(exc), self.explain_clause(c, env, ctx))
        if ok:
            return "pass", "", []
        return "fail", f"{c.id} is false{self.due_notes()}", self.explain_clause(c, env, ctx)

    def invariant_verdict(
        self, c: ast.Clause, handles: Sequence[tuple[str, Handle]], ctx: Any
    ) -> Judged:
        """A model or interface invariant on each of the handles."""
        if not handles:
            return "skip", "no handle to check", []
        for where, h in handles:
            env = ev.Env(values={"self": h}, fields=h, tenv=model_tenv(self.spec, h.model, h.targs))
            try:
                ok = ev.holds(c, env, self.spec, ctx)
            except SkipClause as exc:
                return "skip", str(exc), []
            except SpecError as exc:
                if note := self.refused(exc):
                    return "skip", note, []
                skipped = self.due_skip()
                return skipped or ("spec_error", str(exc), self.explain_clause(c, env, ctx))
            if not ok:
                lines = [(where, show_handle(h, ctx, self.spec))] if self.explain else []
                lines += self.explain_clause(c, env, ctx)
                return "fail", f"{c.id} is false on {where}{self.due_notes()}", lines
        return "pass", "", []


@dataclass
class Snapshot:
    """A handle's digest before a call (or the error computing it), and its fields then."""

    handle: Handle
    digest: Any
    values: dict[str, Any] | None = None
    spec: Spec | None = None

    @property
    def text(self) -> str:
        if self.values is None or self.spec is None:
            return ""
        h = self.handle
        try:
            types = field_types(self.spec, h.model, h.targs)
        except (KeyError, SpecError):
            types = {}
        return _record(h.model, self.values, types)


def snapshot(
    handles: Sequence[tuple[str, Handle]], conf: Conformance, spec: Spec, ctx: Any, explain: bool
) -> dict[str, Snapshot]:
    """Digests of handles before a call; with ``explain``, their fields (through ctx) too."""
    out: dict[str, Snapshot] = {}
    for name, h in handles:
        try:
            d: Any = binding.digest(h, conf, spec)
        except SpecError as exc:
            d = exc
        values = None
        if explain:
            try:
                values = ctx.fields(h)
            except SpecError:
                values = None
        out[name] = Snapshot(h, d, values, spec)
    return out


def frame_verdict(
    before: dict[str, Snapshot],
    checked: Iterable[str],
    allowed: str,
    conf: Conformance,
    spec: Spec,
    ctx: Any,
    explain: bool,
) -> Judged:
    """Each checked handle must have the digest it had before the call."""
    changed: list[str] = []
    lines: list[tuple[str, str]] = []
    for name in checked:
        snap = before.get(name)
        if snap is None:
            continue
        if isinstance(snap.digest, BaseException):
            return "spec_error", f"digest of {name}: {snap.digest}", []
        try:
            after = binding.digest(snap.handle, conf, spec)
        except SpecError as exc:
            return "spec_error", f"digest of {name}: {exc}", []
        if after != snap.digest:
            changed.append(name)
            if explain:
                lines.append((f"{name} before", snap.text or "?"))
                lines.append((f"{name} after", show_handle(snap.handle, ctx, spec)))
    if changed:
        return (
            "fail",
            f"the call changed {', '.join(changed)}, but it may modify only {allowed}",
            lines,
        )
    return "pass", "", []


def conditions_of(
    clauses: Iterable[ast.Clause], env: ev.Env, spec: Spec, ctx: Any
) -> dict[ast.Clause, bool | BaseException]:
    """Each raises / may_raise condition on the pre-state."""
    out: dict[ast.Clause, bool | BaseException] = {}
    for c in clauses:
        try:
            out[c] = ev.holds(c, env, spec, ctx)
        except (SpecError, SkipClause) as exc:
            out[c] = exc
    return out


class _Run:
    """The state of one example while it runs."""

    def __init__(
        self,
        plan: FunctionPlan,
        args: dict[str, Any],
        keys: list[str],
        explain: bool,
        coverage: Sequence[Any],
    ) -> None:
        self.plan = plan
        self.spec = plan.spec
        self.conf = plan.conf
        self.keys = keys
        self.items = [plan.item(k) for k in keys]
        self.explain = explain
        self.coverage_infos = coverage
        self.ex = Example(args)

    def kinds(self) -> set[str]:
        return {it.kind for it in self.items}

    def set(self, key: str, judged: Judged) -> None:
        verdict, note, lines = judged
        self.ex.verdicts[key] = verdict
        if note:
            self.ex.notes[key] = note
        if lines and self.explain:
            self.ex.explanations[key] = list(lines)

    def run(self) -> Example:
        plan, ex = self.plan, self.ex
        try:
            if not plan.residuals_hold(ex.args):
                ex.status, ex.reason = "rejected", "a generated model breaks a model invariant"
                return ex.all(self.keys, "skip")
        except SpecError as exc:
            ex.status = "error"
            return ex.all(self.keys, "spec_error", f"checking a model invariant: {exc}")
        try:
            concrete = {
                n: binding.concretize_value(ex.args[n], t, self.conf, self.spec)
                for n, t in zip(plan.names, plan.types, strict=True)
            }
        except Unrepresentable as exc:
            ex.status, ex.reason = "rejected", f"unrepresentable: {exc}"
            return ex.all(self.keys, "skip")
        except SpecError as exc:
            ex.status = "error"
            return ex.all(self.keys, "spec_error", str(exc))
        try:
            values = {
                n: ev.default_value(plan.params[n], self.spec) if is_default(v) else v
                for n, v in concrete.items()
            }
        except SpecError as exc:
            ex.status = "error"
            return ex.all(self.keys, "spec_error", f"default value: {exc}")
        ex.values = values
        self.values = values
        inputs = [h for n in plan.names for h, _ in handles_in(values[n], plan.type_of[n])]
        self.inputs = [h.obj for h in inputs]
        pre = RuntimeContext(self.conf, self.spec, known=self.inputs)
        env_pre = ev.Env(values=dict(values), tenv=plan.tenv)
        for c in plan.requires:
            try:
                ok = ev.holds(c, env_pre, self.spec, pre)
            except (SpecError, SkipClause) as exc:
                ex.status = "error"
                return ex.all(self.keys, "spec_error", f"{c.id}: {exc}")
            if not ok:
                ex.status, ex.reason = "skipped", f"{c.id} is false"
                return ex.all(self.keys, "skip")
        self.record_coverage(env_pre, pre)
        kinds = self.kinds()
        ensures = [it.clause for it in self.items if it.clause in plan.with_olds]
        olds = ev.snapshot_olds(ensures, env_pre, self.spec, pre) if ensures else {}
        self.before: dict[str, Snapshot] = {}
        if kinds & {"frame", "modifies"} or self.explain:
            handles = [(n, values[n]) for n in plan.handle_params if isinstance(values[n], Handle)]
            self.before = snapshot(handles, self.conf, self.spec, pre, self.explain)
        conditions = {}
        if "raises" in kinds or (plan.raises and kinds & {"ensures", "relates", "invariant"}):
            conditions = conditions_of([*plan.raises, *plan.may_raise], env_pre, self.spec, pre)
        try:
            pyargs, pykwargs = binding.call_arguments(
                plan.names, plan.types, [concrete[n] for n in plan.names], self.conf
            )
        except SpecError as exc:
            ex.status = "error"
            return ex.all(self.keys, "spec_error", str(exc))
        outcome = invoke(plan.impl, pyargs, pykwargs, plan.timeout)
        if outcome.kind == "timeout":
            ex.status = "timeout"
            ex.observation = str(outcome.exc)
            return ex.all(self.keys, "inconclusive", str(outcome.exc))
        self.judge = CallJudge(
            self.conf,
            self.spec,
            raises=plan.raises,
            may_raise=plan.may_raise,
            conditions=conditions,
            outcome=outcome,
            result_type=plan.result_type,
            created_by=plan.fn.name,
            explain=self.explain,
        )
        self.post = RuntimeContext(
            self.conf,
            self.spec,
            known=self.inputs,
            planner=PlannedCalls(self.conf, self.spec, plan.tenv, plan.timeout, self.inputs),
        )
        self.env_post = ev.Env(
            values={**values, "result": self.judge.result}, olds=olds, tenv=plan.tenv
        )
        for it in self.items:
            try:
                self.set(it.key, self.verdict(it))
            except CallTimeout as exc:
                self.set(it.key, ("inconclusive", str(exc), []))
        if self.explain:
            ex.observation = self.observation()
        return ex

    def record_coverage(self, env: ev.Env, ctx: Any) -> None:
        for info in self.coverage_infos:
            v = self.values.get(info.param)
            name: str | None = None
            if info.kind == "set":
                name = info.classify(v)
            else:
                for cls_name, expr in info.classes:
                    try:
                        if ev.evaluate(expr, env, self.spec, ctx) is True:
                            name = cls_name
                            break
                    except (SpecError, SkipClause):
                        break
            if name is not None:
                self.ex.coverage[info.param] = name

    def observation(self) -> str:
        """The outcome, the state after the call of every handle the function may modify,
        and the before and after states of any other handle the call changed.

        A unit result is left out when a modified handle's state takes its place.
        """
        judge, plan = self.judge, self.plan
        afters: list[str] = []
        changes: list[str] = []
        for n, snap in self.before.items():
            after = show_handle(snap.handle, self.post, self.spec)
            changed = self.changed(snap, after)
            if n in plan.modified:
                afters.append(f"{n} after = {after}" + ("" if changed else " (unchanged)"))
            elif changed:
                changes += [f"{n} before = {snap.text}", f"{n} after  = {after}"]
        lines = [] if afters and judge.returned_unit else [judge._outcome_text(self.post)]
        lines += afters + changes
        lines[:0] = self.as_built()
        if judge.outcome.warnings:
            lines.append(judge.warned_text())
        return "\n".join(lines)

    def as_built(self) -> list[str]:
        """Inputs that a lossy binding built otherwise than generated, as they observed."""
        out: list[str] = []
        for n, snap in self.before.items():
            gm = self.ex.args.get(n)
            if _is_generated(gm) and snap.text and snap.text != show_generated(gm, self.spec):
                out.append(f"{n} as built = {snap.text}")
        return out

    def changed(self, snap: Snapshot, after: str) -> bool:
        """Did the call change a handle? By digest, or by its shown fields when the digest
        cannot be computed."""
        if not isinstance(snap.digest, BaseException):
            try:
                return binding.digest(snap.handle, self.conf, self.spec) != snap.digest
            except SpecError:
                pass
        return after != snap.text

    def verdict(self, it: PlanItem) -> Judged:
        judge, plan = self.judge, self.plan
        if judge.convert_error is not None:
            return "spec_error", f"reading the result: {judge.convert_error}", []
        kind, c = it.kind, it.clause
        if kind == "type":
            return judge.type_verdict(self.post)
        if kind == "raises" and c is None:
            return judge.unadmitted_verdict()
        if kind == "raises":
            assert c is not None
            return judge.raises_verdict(c)
        if kind in ("ensures", "relates"):
            assert c is not None
            return judge.condition_verdict(c, self.env_post, self.post)
        if kind in ("modifies", "frame"):
            checked = [n for n in plan.handle_params if n not in plan.modified]
            allowed = ", ".join(sorted(plan.modified)) or "nothing"
            return frame_verdict(
                self.before, checked, allowed, self.conf, self.spec, self.post, self.explain
            )
        if kind == "invariant":
            assert c is not None
            handles: list[tuple[str, Handle]] = []
            if judge.returned_value:
                handles += [
                    ("result", h)
                    for h, _ in handles_in(judge.result, plan.result_type)
                    if h.model == it.model
                ]
            for n in plan.names:
                if n in plan.modified:
                    handles += [
                        (n, h)
                        for h, _ in handles_in(self.values[n], plan.type_of[n])
                        if h.model == it.model
                    ]
            return judge.invariant_verdict(c, handles, self.post)
        return "skip", f"{kind} items are not judged per example", []


def _names(errors: set[str | None]) -> str:
    named = sorted(e for e in errors if e)
    return "{" + ", ".join(named) + "}"


def _when(c: ast.Clause, spec: Spec) -> str:
    return ev.source_text(c.expr, spec) if c.expr is not None else "true"


__all__ = [
    "JUDGED_KINDS",
    "CallJudge",
    "CallOutcome",
    "CallTimeout",
    "ClauseFailure",
    "Example",
    "FunctionPlan",
    "PlanItem",
    "PlannedCalls",
    "Snapshot",
    "Verdict",
    "can_time_out",
    "conditions_of",
    "decl_label",
    "describe_exception",
    "example_args",
    "example_decl",
    "example_problems",
    "explicit_examples",
    "field_types",
    "frame_verdict",
    "from_example",
    "generated_in",
    "handles_in",
    "inst_text",
    "invoke",
    "memo_key",
    "model_tenv",
    "show",
    "show_generated",
    "show_handle",
    "skip_cause",
    "snapshot",
]
