"""Bindings between a spec and Python implementations, and value conversion.

``conformance(...)`` builds a validated ``Conformance``: which functions,
models and interfaces are bound to what, how exceptions map to spec errors,
how scalars cross the boundary and which type instantiations run.
``to_python`` and ``from_python`` convert values by their declared type;
``concretize``, ``observe``, ``fields`` and ``digest`` work on model handles
through the bindings.
"""

from __future__ import annotations

import difflib
import enum
import operator
import os
import reprlib
import struct
import sys
from collections.abc import Callable, Hashable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from decimal import Decimal
from fractions import Fraction
from pathlib import Path
from typing import Any

from spectest import ast
from spectest.generate import DEFAULT_SIZES, Sizes
from spectest.lang import SpecLangError
from spectest.lang import load as _lang_load
from spectest.lang.spec import Spec
from spectest.prelude import floats
from spectest.runtime.store import (
    canonical_json,
    encode_value,
    generate_module,
    is_generated_model,
    is_qerror,
    qerr_type,
    qerror_class,
)
from spectest.types import (
    AnyT,
    BoolT,
    BytesT,
    EnumT,
    FixedIntT,
    FloatT,
    IntT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    RealT,
    RecordT,
    StringT,
    TupleT,
    Type,
    TypeVarT,
    UnitT,
    has_canonical_eq,
    has_total_order,
    substitute,
)
from spectest.values import (
    NEG_INF,
    POS_INF,
    BindingError,
    FloatValue,
    Handle,
    MapValue,
    NotAValue,
    RecordValue,
    Some,
    Unrepresentable,
    is_infinity,
)

SCALAR_MODES = ("python", "numpy")
NEVER_FAILS = ("requires", "may_raise", "unspecified", "impl_defined", "perf")
BUILTIN_CLAUSES = ("type", "raises")


@dataclass
class ModelBinding:
    """How a model's objects are observed and built.

    Each observer is called as ``f(obj, *args)``; observers not listed fall back
    to ``getattr(obj, name)`` (called when callable). An observer raises
    NotAValue for an object that is not a value of the model; ``accepts(obj)``
    returns False (or raises NotAValue) for one, and is asked about every object
    the implementation returns. ``concretize`` builds an object from the
    model's field values (as Python values) and may raise Unrepresentable; the
    object must observe as those fields, unless the binding is ``lossy`` (it
    cannot keep every field exactly, as pandas reads NaN as missing).
    ``digest`` summarizes an object for ``modifies`` checks (default: all
    fields); ``shares_memory`` answers the prelude's ``shares_memory(a, b)``.
    """

    observers: dict[str, Callable[..., Any]] = field(default_factory=dict)
    concretize: Callable[[dict[str, Any]], Any] | None = None
    digest: Callable[[Any], Hashable] | None = None
    shares_memory: Callable[[Any, Any], bool] | None = None
    accepts: Callable[[Any], bool] | None = None
    lossy: bool = False


@dataclass
class InterfaceBinding:
    """How an interface's objects are created, driven and observed.

    Constructors are called with the constructor's arguments; methods as
    ``f(obj, *args)``, falling back to ``getattr(obj, name)(*args)``; observers
    as for ModelBinding.
    """

    constructors: dict[str, Callable[..., Any]]
    methods: dict[str, Callable[..., Any]] | None = None
    observers: dict[str, Callable[..., Any]] | None = None
    digest: Callable[[Any], Hashable] | None = None


@dataclass(eq=False)
class Conformance:
    """A spec bound to implementations: what the pytest plugin collects and runs.

    ``instantiate`` lists the type instantiations (each a dict from type
    parameter name to Type); ``steps`` and ``max_handles`` bound each stateful
    step sequence of an interface (calls, and live handles before constructors
    stop); ``sizes`` bounds generated collections (``spectest.generate.Sizes``);
    ``examples`` maps a function (or ``Iface.member``) to explicit argument
    dicts, judged before the search; ``name`` is set by the plugin to the
    module-level name; ``path`` is the file that called ``conformance``.
    """

    spec: Spec
    impls: dict[str, Callable[..., Any]] = field(default_factory=dict)
    errors: dict[Any, str] = field(default_factory=dict)
    scalars: str = "python"
    instantiate: list[dict[str, Type]] = field(default_factory=list)
    models: dict[str, ModelBinding] = field(default_factory=dict)
    interfaces: dict[str, InterfaceBinding] = field(default_factory=dict)
    expect_fail: frozenset[str] = frozenset()
    max_examples: int = 100
    exhaustive_limit: int = 65536
    steps: int = 30
    max_handles: int = 2
    sizes: Sizes = DEFAULT_SIZES
    examples: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    name: str | None = None
    path: str | None = None

    def __repr__(self) -> str:
        bound = [*self.impls, *self.interfaces]
        label = f" {self.name}" if self.name else ""
        return f"<Conformance{label}: spec {self.spec.name}, bound {', '.join(bound) or 'nothing'}>"

    def instantiations(self, decl: ast.Node | str) -> list[dict[str, Type]]:
        """The instantiations a declaration runs with: [{}] when it is not generic.

        Each configured instantiation that names all of the declaration's type
        parameters contributes once (restricted to them); none may apply.
        """
        node = self.spec.decl(decl) if isinstance(decl, str) else decl
        if node is None:
            raise KeyError(decl)
        names = list(self.spec.tparams.get(node, {}))
        if not names:
            return [{}]
        out: list[dict[str, Type]] = []
        for inst in self.instantiate:
            if all(n in inst for n in names):
                sub = {n: inst[n] for n in names}
                if sub not in out:
                    out.append(sub)
        return out

    def is_expected_fail(self, clause_id: str) -> bool:
        return clause_id in self.expect_fail


class ConformanceError(ValueError):
    """A ``conformance(...)`` call does not fit its spec; ``problems`` lists every issue."""

    def __init__(self, spec_name: str, problems: Sequence[str]) -> None:
        self.problems = list(problems)
        lines = "\n".join(f"  - {p}" for p in self.problems)
        super().__init__(
            f"conformance for spec {spec_name}: {len(self.problems)} problem(s)\n{lines}"
        )


class TypeMismatch(Exception):
    """An implementation value cannot be read as its declared type: ``<fn>#type`` fails.

    ``path`` locates the offending part: ``[2]``, ``.0`` (tuple), ``.name`` (record), ``['k']`` (map).
    """

    def __init__(self, message: str, path: str = "") -> None:
        self.message = message
        self.path = path
        super().__init__(f"at {path}: {message}" if path else message)


class ValueRefused(BindingError):
    """An observer raised NotAValue: ``handle``'s object is not a value of its model.

    A BindingError like any other observer failure, except on a handle an
    implementation call returned (``created_by`` names a spec function), where
    the plans charge it to the implementation.
    """

    def __init__(self, message: str, handle: Handle) -> None:
        super().__init__(message)
        self.handle = handle


# ---------------------------------------------------------------------------
# Spec paths relative to the caller


_PACKAGE_DIR = Path(__file__).resolve().parent.parent


def _caller_file() -> Path | None:
    """The first calling file outside the spectest package (None for interactive code)."""
    frame = sys._getframe(1)
    while frame is not None:
        name = frame.f_code.co_filename
        if name.startswith("<"):
            return None
        p = Path(name).resolve()
        if not p.is_relative_to(_PACKAGE_DIR):
            return p
        frame = frame.f_back
    return None


def resolve_spec_path(path: str | os.PathLike[str], caller: Path | None = None) -> Path:
    """A spec path: absolute as given; relative to the caller's folder, then to the cwd."""
    p = Path(path)
    if p.is_absolute():
        return p
    candidates = []
    if caller is not None:
        candidates.append(caller.parent / p)
    candidates.append(Path.cwd() / p)
    for c in candidates:
        if c.is_file():
            return c.resolve()
    looked = ", ".join(str(c) for c in candidates)
    raise FileNotFoundError(f"cannot find spec file {str(path)!r} (looked for {looked})")


def load(path: str | os.PathLike[str]) -> Spec:
    """Load and check a spec file; a relative path resolves against the calling file's folder.

    Falls back to the working directory when the file is not next to the caller.
    Raises SpecSyntaxError or SpecCheckError on errors in the spec.
    """
    return _lang_load(resolve_spec_path(path, _caller_file()))


# ---------------------------------------------------------------------------
# conformance()


def _suggest(name: str, options: Iterable[str]) -> str:
    opts = sorted(options)
    close = difflib.get_close_matches(name, opts, n=1)
    hint = f"; did you mean {close[0]!r}?" if close else ""
    return hint + (f" ({', '.join(opts)})" if opts else " (there are none)")


def _children(t: Type) -> list[Type]:
    if isinstance(t, (ListT, OptionT)):
        return [t.elem]
    if isinstance(t, MapT):
        return [t.key, t.value]
    if isinstance(t, TupleT):
        return list(t.elems)
    if isinstance(t, RecordT):
        return [ft for _, ft in t.fields]
    if isinstance(t, ModelT):
        return list(t.args)
    return []


def _walk_types(t: Type) -> Iterable[Type]:
    yield t
    for child in _children(t):
        yield from _walk_types(child)


def _callables(spec: Spec) -> dict[str, ast.Node]:
    """Every callable by its clause-ID prefix: fns, "Iface.ctor", "Iface.method"."""
    out: dict[str, ast.Node] = dict(spec.fns)
    for iface in spec.interfaces.values():
        for c in [*iface.ctors, *iface.methods]:
            out[spec.decl_ids.get(c, f"{iface.name}.{c.name}")] = c
    return out


def _hint(name: str, known: Iterable[str]) -> str:
    close = difflib.get_close_matches(name, list(known), n=1)
    return f"; did you mean {close[0]!r}?" if close else ""


def _decl_types(spec: Spec, node: ast.Node) -> list[Type]:
    """Every parameter and result type of a declaration and of its members."""
    members = [node, *getattr(node, "ctors", []), *getattr(node, "methods", [])]
    members += getattr(node, "observers", [])
    out: list[Type] = []
    for m in members:
        sig = spec.signature.get(m)
        if sig is not None:
            out.extend([*sig.params, sig.result])
    return out


def _model_names(t: Type) -> set[str]:
    return {x.name for x in _walk_types(t) if isinstance(x, ModelT) and not x.is_interface}


def _runtime_items(spec: Spec, callables: Mapping[str, ast.Node]) -> list[str]:
    """Item IDs the runtime adds beyond clause IDs and #type / #raises: "<callable>#frame"
    (handle parameters or a method, and no modifies clause) and "<fn>:<Model>.<invariant>"
    (an invariant of a model the function returns or modifies)."""
    out: list[str] = []
    for prefix, node in callables.items():
        clauses = getattr(node, "clauses", [])
        modified = {n for c in clauses if c.kind == "modifies" for n in c.names}
        sig = spec.signature.get(node)
        if sig is None:
            continue
        handles = [t for t in sig.params if isinstance(t, ModelT) and not t.is_interface]
        if not modified and (handles or isinstance(node, ast.MethodDecl)):
            out.append(f"{prefix}#frame")
        if isinstance(node, ast.FnDecl):
            models = _model_names(sig.result)
            for p, t in zip(node.params, sig.params, strict=True):
                if p.name in modified:
                    models |= _model_names(t)
            for m in sorted(models):
                decl = spec.models.get(m)
                for c in getattr(decl, "clauses", []):
                    if c.kind == "invariant":
                        out.append(f"{prefix}:{c.id}")
    return out


def _runtime_item(spec: Spec, cid: str, callables: Mapping[str, ast.Node]) -> ast.Node | None:
    """The callable owning a runtime item ID ("<callable>#frame", "<fn>:<Model>.<inv>")."""
    if cid not in _runtime_items(spec, callables):
        return None
    prefix = cid.rpartition("#")[0] if cid.endswith("#frame") else cid.partition(":")[0]
    return callables.get(prefix)


def _is_count(x: Any, minimum: int) -> bool:
    return isinstance(x, int) and not isinstance(x, bool) and x >= minimum


class _Validator:
    """Checks the arguments of ``conformance`` against the spec, collecting every problem."""

    def __init__(self, spec: Spec) -> None:
        self.spec = spec
        self.problems: list[str] = []

    def add(self, message: str) -> None:
        self.problems.append(message)

    def names(self, what: str, given: Mapping[str, Any], known: Iterable[str], kind: str) -> None:
        known = list(known)
        for name, fn in given.items():
            if name not in known:
                self.add(f"{what}: {name!r} is not {kind}{_suggest(str(name), known)}")
            elif not callable(fn):
                self.add(f"{what}[{name!r}] is not callable: {fn!r}")

    def impls(self, impls: Mapping[str, Any]) -> None:
        self.names("impls", impls, self.spec.fns, f"a function of spec {self.spec.name}")

    def models(self, models: Mapping[str, Any]) -> None:
        spec = self.spec
        for name, b in models.items():
            if name not in spec.models:
                extra = " (it is an interface: bind it with interfaces=)"
                self.add(
                    f"models: {name!r} is not a model of spec {spec.name}"
                    f"{extra if name in spec.interfaces else ''}{_suggest(name, spec.models)}"
                )
            elif not isinstance(b, ModelBinding):
                self.add(f"models[{name!r}] must be a ModelBinding, got {b!r}")
            else:
                observers = [o.name for o in spec.models[name].observers]
                kind = f"an observer of {name}"
                self.names(f"models[{name!r}].observers", b.observers or {}, observers, kind)
                for attr in ("concretize", "digest", "shares_memory", "accepts"):
                    fn = getattr(b, attr)
                    if fn is not None and not callable(fn):
                        self.add(f"models[{name!r}].{attr} is not callable: {fn!r}")
                if not isinstance(b.lossy, bool):
                    self.add(f"models[{name!r}].lossy must be True or False, got {b.lossy!r}")

    def interfaces(self, interfaces: Mapping[str, Any]) -> None:
        spec = self.spec
        for name, b in interfaces.items():
            if name not in spec.interfaces:
                extra = " (it is a model: bind it with models=)"
                self.add(
                    f"interfaces: {name!r} is not an interface of spec {spec.name}"
                    f"{extra if name in spec.models else ''}{_suggest(name, spec.interfaces)}"
                )
                continue
            if not isinstance(b, InterfaceBinding):
                self.add(f"interfaces[{name!r}] must be an InterfaceBinding, got {b!r}")
                continue
            decl = spec.interfaces[name]
            if not b.constructors:
                self.add(f"interfaces[{name!r}] needs at least one constructor")
            for what, table, members in (
                ("constructors", b.constructors, decl.ctors),
                ("methods", b.methods, decl.methods),
                ("observers", b.observers, decl.observers),
            ):
                kind = f"a{'n' if what == 'observers' else ''} {what[:-1]} of {name}"
                self.names(
                    f"interfaces[{name!r}].{what}", table or {}, [m.name for m in members], kind
                )
            if b.digest is not None and not callable(b.digest):
                self.add(f"interfaces[{name!r}].digest is not callable: {b.digest!r}")

    def errors(self, errors: Mapping[Any, str]) -> None:
        for exc, err in errors.items():
            classes = exc if isinstance(exc, tuple) else (exc,)
            if not classes or not all(
                isinstance(c, type) and issubclass(c, BaseException) for c in classes
            ):
                self.add(f"errors: key {exc!r} is not an exception class (or a tuple of them)")
            if err not in self.spec.errors:
                self.add(
                    f"errors: {getattr(exc, '__name__', exc)} maps to {err!r}, which spec "
                    f"{self.spec.name} does not declare{_suggest(str(err), self.spec.errors)}"
                )

    def scalars(self, scalars: str, active: list[ast.Node]) -> None:
        if scalars not in SCALAR_MODES:
            self.add(f"scalars must be 'python' or 'numpy', got {scalars!r}")
            return
        if scalars != "numpy":
            return
        try:
            import numpy  # noqa: F401
        except ImportError:
            self.add("scalars='numpy' needs numpy, which is not installed")
        if _has_ml_dtypes():
            return
        for node in active:
            types = [x for t in _decl_types(self.spec, node) for x in _walk_types(t)]
            if any(isinstance(x, FloatT) and x.fmt == "bf16" for x in types):
                self.add(
                    f"{self.spec.decl_ids.get(node, '?')} uses bf16, which scalars='numpy' passes "
                    "as ml_dtypes.bfloat16: install ml_dtypes or use scalars='python'"
                )

    def instantiate(self, instantiate: Any) -> list[dict[str, Type]]:
        if instantiate is None:
            return []
        items = [instantiate] if isinstance(instantiate, Mapping) else instantiate
        if isinstance(items, (str, bytes)) or not isinstance(items, Iterable):
            self.add(f"instantiate must be a dict or a list of dicts, got {instantiate!r}")
            return []
        known = sorted({n for tv in self.spec.tparams.values() for n in tv})
        out: list[dict[str, Type]] = []
        for inst in items:
            if not isinstance(inst, Mapping):
                self.add(f"instantiate: expected a dict of type parameters, got {inst!r}")
                continue
            resolved: dict[str, Type] = {}
            for key, value in inst.items():
                if key not in known:
                    self.add(
                        f"instantiate: {key!r} is not a type parameter of any declaration"
                        f"{_suggest(str(key), known)}"
                    )
                elif (t := self.type_arg(key, value)) is not None:
                    resolved[key] = t
            out.append(resolved)
        return out

    def type_arg(self, key: str, value: Any) -> Type | None:
        if isinstance(value, Type):
            t = value
        elif isinstance(value, str):
            try:
                t = self.spec.resolve_type(value)
            except SpecLangError as e:
                self.add(f"instantiate: {key} = {value!r}: {'; '.join(e.messages)}")
                return None
        else:
            self.add(f"instantiate: {key} = {value!r} is neither a type name nor a Type")
            return None
        bad = [x for x in _walk_types(t) if isinstance(x, (TypeVarT, AnyT, RealT))]
        if bad:
            self.add(f"instantiate: {key} = {t} cannot be a parameter type ({bad[0]})")
            return None
        return t

    def bounds(self, active: list[ast.Node], insts: list[dict[str, Type]]) -> None:
        for node in active:
            tvars = self.spec.tparams.get(node, {})
            if not tvars:
                continue
            label = self.spec.decl_ids.get(node, getattr(node, "name", "?"))
            params = ", ".join(f"{n}: {v.bound}" if v.bound else n for n, v in tvars.items())
            applicable = [i for i in insts if all(n in i for n in tvars)]
            if not applicable:
                example = ", ".join(f"{n!r}: 'i64'" for n in tvars)
                self.add(
                    f"{label} is generic <{params}> but no instantiation names "
                    f"{', '.join(tvars)}: pass instantiate={{{example}}}"
                )
            for inst in applicable:
                for n, tv in tvars.items():
                    if tv.bound == "Ord" and not has_total_order(inst[n]):
                        need = "total order"
                    elif tv.bound == "Eq" and not has_canonical_eq(inst[n]):
                        need = "canonical equality"
                    else:
                        continue
                    self.add(
                        f"instantiate: {n} = {inst[n]} has no {need}, as {label}<{params}> needs"
                    )

    def concretizers(self, active: list[ast.Node], models: Mapping[str, ModelBinding]) -> None:
        for node in active:
            if not isinstance(node, ast.FnDecl):
                continue
            for p, t in zip(node.params, self.spec.signature[node].params):
                for x in _walk_types(t):
                    if isinstance(x, ModelT) and not x.is_interface:
                        b = models.get(x.name)
                        if not isinstance(b, ModelBinding) or b.concretize is None:
                            self.add(
                                f"{node.name} takes {p.name}: {t}, so models[{x.name!r}] needs a "
                                "ModelBinding with concretize="
                            )

    def expect_fail(
        self, expect: Iterable[Any], impls: Mapping[str, Any], interfaces: Mapping[str, Any]
    ) -> None:
        spec = self.spec
        callables = _callables(spec)
        for cid in sorted(expect, key=str):
            if not isinstance(cid, str):
                self.add(f"expect_fail: {cid!r} is not a clause ID")
                continue
            clause = spec.clause_ids.get(cid)
            prefix, sep, builtin = cid.rpartition("#")
            if clause is not None:
                if clause.kind in NEVER_FAILS:
                    self.add(f"expect_fail: {cid} is a {clause.kind} clause, which never fails")
                    continue
                owner = spec.owner.get(clause)
            elif sep and builtin in BUILTIN_CLAUSES and prefix in callables:
                owner = callables[prefix]
            elif (found := _runtime_item(spec, cid, callables)) is not None:
                owner = found
            else:
                known = [
                    *spec.clause_ids,
                    *(f"{c}#{b}" for c in callables for b in BUILTIN_CLAUSES),
                    *_runtime_items(spec, callables),
                ]
                self.add(
                    f"expect_fail: {cid!r} is not a clause ID of spec {spec.name}{_hint(cid, known)}"
                )
                continue
            if isinstance(owner, (ast.CtorDecl, ast.MethodDecl)):
                owner = spec.owner.get(owner)
            if isinstance(owner, ast.FnDecl) and owner.name not in impls:
                self.add(f"expect_fail: {cid} belongs to {owner.name}, which impls does not bind")
            elif isinstance(owner, ast.InterfaceDecl) and owner.name not in interfaces:
                self.add(
                    f"expect_fail: {cid} belongs to {owner.name}, which interfaces does not bind"
                )

    def limits(self, max_examples: Any, exhaustive_limit: Any) -> None:
        if not _is_count(max_examples, 1):
            self.add(f"max_examples must be a positive integer, got {max_examples!r}")
        if not _is_count(exhaustive_limit, 0):
            self.add(f"exhaustive_limit must be a non-negative integer, got {exhaustive_limit!r}")

    def stateful(self, steps: Any, max_handles: Any) -> None:
        if not _is_count(steps, 1):
            self.add(f"steps must be a positive integer, got {steps!r}")
        if not _is_count(max_handles, 1):
            self.add(f"max_handles must be a positive integer, got {max_handles!r}")


def conformance(
    spec: Spec | str | os.PathLike[str],
    *,
    impls: Mapping[str, Callable[..., Any]] | None = None,
    errors: Mapping[Any, str] | None = None,
    scalars: str = "python",
    instantiate: Mapping[str, Type | str] | Sequence[Mapping[str, Type | str]] | None = None,
    models: Mapping[str, ModelBinding] | None = None,
    interfaces: Mapping[str, InterfaceBinding] | None = None,
    expect_fail: Iterable[str] = (),
    max_examples: int = 100,
    exhaustive_limit: int = 65536,
    steps: int = 30,
    max_handles: int = 2,
    sizes: Sizes = DEFAULT_SIZES,
    examples: Mapping[str, Sequence[Mapping[str, Any]]] | None = None,
) -> Conformance:
    """Bind a spec (or a spec path, relative to the calling file) to implementations.

    ``examples`` maps a function, or a constructor or method of a bound
    interface ("Deque.push"), to explicit argument dicts that are judged before
    the search, like Hypothesis's ``@example``. A model-typed argument is a dict
    of the model's fields, which the model's concretizer builds. Everything is
    validated now; every problem is reported at once in a ConformanceError.
    """
    __tracebackhide__ = True
    caller = _caller_file()
    if not isinstance(spec, Spec):
        spec = _lang_load(resolve_spec_path(spec, caller))
    impls = dict(impls or {})
    errors = dict(errors or {})
    models = dict(models or {})
    interfaces = dict(interfaces or {})
    expect = frozenset([expect_fail] if isinstance(expect_fail, str) else expect_fail)
    active: list[ast.Node] = [spec.fns[n] for n in impls if n in spec.fns]
    active += [spec.interfaces[n] for n in interfaces if n in spec.interfaces]

    v = _Validator(spec)
    v.impls(impls)
    v.models(models)
    v.interfaces(interfaces)
    v.errors(errors)
    v.scalars(scalars, active)
    insts = v.instantiate(instantiate)
    v.bounds(active, insts)
    v.concretizers(active, models)
    v.expect_fail(expect, impls, interfaces)
    v.limits(max_examples, exhaustive_limit)
    v.stateful(steps, max_handles)
    if not isinstance(sizes, Sizes):
        v.add(f"sizes must be a spectest.generate.Sizes, got {sizes!r}")
    else:
        v.problems += [f"sizes: {p}" for p in sizes.problems()]
    if examples is not None and not isinstance(examples, Mapping):
        v.add(f"examples must map function names to lists of argument dicts, got {examples!r}")
        examples = None
    if v.problems:
        raise ConformanceError(spec.name, v.problems)
    conf = Conformance(
        spec=spec,
        impls=impls,
        errors=errors,
        scalars=scalars,
        instantiate=insts,
        models=models,
        interfaces=interfaces,
        expect_fail=expect,
        max_examples=max_examples,
        exhaustive_limit=exhaustive_limit,
        steps=steps,
        max_handles=max_handles,
        sizes=sizes,
        examples={k: _listed(x) for k, x in (examples or {}).items()},
        path=str(caller) if caller is not None else None,
    )
    if conf.examples:
        from spectest.runtime.plans import example_problems

        if problems := example_problems(conf):
            raise ConformanceError(spec.name, problems)
    return conf


def _listed(x: Any) -> Any:
    return list(x) if isinstance(x, list | tuple) else x


def _has_ml_dtypes() -> bool:
    try:
        import ml_dtypes  # noqa: F401
    except ImportError:
        return False
    return True


# ---------------------------------------------------------------------------
# Value conversion


_REPR = reprlib.Repr(maxstring=60, maxother=60, maxlist=6, maxtuple=6, maxdict=4, maxlevel=3)


def describe(obj: Any) -> str:
    """A short description of a Python object for messages: type name and a short repr."""
    return f"{type(obj).__name__} {_REPR.repr(obj)}"


def _numpy() -> Any:
    return sys.modules.get("numpy")


def _scalars(conf: Conformance | None) -> str:
    return conf.scalars if conf is not None else "python"


def _freeze(x: Any) -> Any:
    if isinstance(x, list):
        return tuple(_freeze(e) for e in x)
    if isinstance(x, dict):
        return tuple((k, _freeze(v)) for k, v in x.items())
    return x


def to_python(value: Any, t: Type, conf: Conformance | None = None) -> Any:
    """A spec value as the implementation receives it, by its declared type.

    Floats become Python floats (``scalars="python"``) or numpy scalars of their
    format (``"numpy"``), bit-exactly; lists become lists, maps dicts, records
    dicts, options None or the value, handles their object. BindingError when
    the value is not of type t.
    """

    def bad(why: str = "") -> BindingError:
        return BindingError(f"cannot pass {value!r} as {t}{': ' + why if why else ''}")

    if isinstance(t, BoolT):
        if not isinstance(value, bool):
            raise bad()
        return value
    if isinstance(t, (IntT, FixedIntT)):
        if isinstance(value, bool) or not isinstance(value, int):
            raise bad()
        if isinstance(t, FixedIntT) and not t.min <= value <= t.max:
            raise bad(f"outside {t.min}..{t.max}")
        return int(value)
    if isinstance(t, FloatT):
        if not isinstance(value, FloatValue) or value.fmt != t.fmt:
            raise bad()
        if _scalars(conf) == "numpy":
            try:
                return floats.to_numpy(value)
            except TypeError as e:
                raise bad(str(e)) from e
        wide = reformat(value, "f64") or floats.convert(value, "f64")
        return struct.unpack("<d", struct.pack("<Q", wide.bits))[0]
    if isinstance(t, RealT):
        if isinstance(value, Fraction):
            return value
        if is_infinity(value):
            return float("inf") if value.sign > 0 else float("-inf")
        raise bad()
    if (qt := qerr_type()) is not None and isinstance(t, qt):
        if not is_qerror(value):
            raise bad()
        return value
    if isinstance(t, StringT):
        if not isinstance(value, str):
            raise bad()
        return value
    if isinstance(t, BytesT):
        if not isinstance(value, (bytes, bytearray)):
            raise bad()
        return bytes(value)
    if isinstance(t, (LiteralT, EnumT)):
        members = t.values if isinstance(t, LiteralT) else t.members
        if not isinstance(value, str) or value not in members:
            raise bad()
        return value
    if isinstance(t, UnitT):
        if value is not None:
            raise bad()
        return None
    if isinstance(t, OptionT):
        if value is None:
            return None
        if not isinstance(value, Some):
            raise bad()
        return to_python(value.value, t.elem, conf)
    if isinstance(t, ListT):
        if not isinstance(value, (tuple, list)):
            raise bad()
        return [to_python(x, t.elem, conf) for x in value]
    if isinstance(t, TupleT):
        if not isinstance(value, (tuple, list)) or len(value) != len(t.elems):
            raise bad()
        return tuple(to_python(x, et, conf) for x, et in zip(value, t.elems))
    if isinstance(t, MapT):
        if not isinstance(value, MapValue):
            raise bad()
        out: dict[Any, Any] = {}
        for k, x in value.items:
            key = _freeze(to_python(k, t.key, conf))
            item = to_python(x, t.value, conf)
            try:
                out[key] = item
            except TypeError as e:
                raise bad(f"key {k!r} is not hashable in Python") from e
        return out
    if isinstance(t, RecordT):
        if not isinstance(value, RecordValue) or value.name != t.name:
            raise bad()
        ftypes = dict(t.fields)
        return {k: to_python(x, ftypes[k], conf) for k, x in value.fields if k in ftypes}
    if isinstance(t, ModelT):
        if isinstance(value, Handle):
            return value.obj
        if is_generated_model(value):
            raise bad("concretize the generated model first (concretize_value)")
        raise bad()
    raise BindingError(f"cannot convert {value!r} to Python: {t} is not a concrete value type")


def from_python(
    obj: Any, t: Type, conf: Conformance | None = None, *, created_by: str | None = None
) -> Any:
    """An implementation's value read as a spec value of type t.

    Raises TypeMismatch, with a precise message, when obj cannot be read as t.
    An object of model type becomes a new Handle (``created_by`` is recorded
    on it). BindingError when t is not a concrete type.
    """
    return _from(obj, t, conf, "", created_by)


def _from(obj: Any, t: Type, conf: Conformance | None, path: str, created_by: str | None) -> Any:
    np = _numpy()

    def mismatch(why: str = "") -> TypeMismatch:
        return TypeMismatch(
            f"expected {t}, got {describe(obj)}{' (' + why + ')' if why else ''}", path
        )

    if np is not None and isinstance(obj, np.ndarray) and obj.ndim == 0 and _is_scalar_type(t):
        obj = obj[()]

    if isinstance(t, BoolT):
        if isinstance(obj, bool):
            return obj
        if np is not None and isinstance(obj, np.bool_):
            return bool(obj)
        raise mismatch()
    if isinstance(t, (IntT, FixedIntT)):
        n = _as_int(obj, np)
        if n is None:
            raise mismatch()
        if isinstance(t, FixedIntT) and not t.min <= n <= t.max:
            raise mismatch(f"outside the {t} range {t.min}..{t.max}")
        return n
    if isinstance(t, FloatT):
        v = _as_float(obj, np)
        if v is None:
            raise mismatch()
        w = reformat(v, t.fmt)
        if w is not None:
            return w
        if floats.is_nan(v):
            return floats.convert(v, t.fmt)
        raise mismatch(f"not exactly representable as {t}")
    if isinstance(t, RealT):
        if isinstance(obj, bool):
            raise mismatch()
        if isinstance(obj, Fraction):
            return obj
        if is_infinity(obj):
            return obj
        n = _as_int(obj, np)
        if n is not None:
            return Fraction(n)
        v = _as_float(obj, np)
        if v is not None:
            if floats.is_nan(v):
                raise mismatch("NaN is not a real number")
            r = floats.to_real(v)
            return r if is_infinity(r) else Fraction(r)
        if isinstance(obj, Decimal):
            if obj.is_nan():
                raise mismatch("NaN is not a real number")
            if obj.is_infinite():
                return NEG_INF if obj.is_signed() else POS_INF
            return Fraction(obj)
        raise mismatch()
    if (qt := qerr_type()) is not None and isinstance(t, qt):
        if is_qerror(obj):
            return obj
        n = _as_int(obj, np)
        cls = qerror_class()
        if n is not None and n >= 0 and cls is not None:
            return cls(n, 0)
        raise mismatch()
    if isinstance(t, StringT):
        if isinstance(obj, str):
            return str(obj)
        raise mismatch()
    if isinstance(t, BytesT):
        if isinstance(obj, (bytes, bytearray, memoryview)):
            return bytes(obj)
        raise mismatch()
    if isinstance(t, (LiteralT, EnumT)):
        members = t.values if isinstance(t, LiteralT) else t.members
        s = obj
        if isinstance(obj, enum.Enum):
            s = obj.name if isinstance(t, EnumT) else obj.value
        if isinstance(s, str) and s in members:
            return str(s)
        options = ", ".join(f'"{m}"' for m in members)
        raise TypeMismatch(f"expected one of {options}, got {describe(obj)}", path)
    if isinstance(t, UnitT):
        if obj is None:
            return None
        raise TypeMismatch(f"expected no value (None), got {describe(obj)}", path)
    if isinstance(t, OptionT):
        if obj is None:
            return None
        return Some(_from(obj, t.elem, conf, path, created_by))
    if isinstance(t, ListT):
        if isinstance(obj, (list, tuple)) or (
            np is not None and isinstance(obj, np.ndarray) and obj.ndim >= 1
        ):
            return tuple(
                _from(x, t.elem, conf, f"{path}[{i}]", created_by) for i, x in enumerate(obj)
            )
        raise mismatch("a list, tuple or numpy array is accepted")
    if isinstance(t, TupleT):
        if not isinstance(obj, (tuple, list)):
            raise mismatch()
        if len(obj) != len(t.elems):
            raise mismatch(f"{len(obj)} elements instead of {len(t.elems)}")
        return tuple(
            _from(x, et, conf, f"{path}.{i}", created_by)
            for i, (x, et) in enumerate(zip(obj, t.elems))
        )
    if isinstance(t, MapT):
        if not isinstance(obj, Mapping):
            raise mismatch()
        return MapValue(
            tuple(
                (
                    _from(k, t.key, conf, f"{path}[key {k!r}]", created_by),
                    _from(x, t.value, conf, f"{path}[{k!r}]", created_by),
                )
                for k, x in obj.items()
            )
        )
    if isinstance(t, RecordT):
        names = [n for n, _ in t.fields]
        if isinstance(obj, Mapping):
            missing = [n for n in names if n not in obj]
            extra = [k for k in obj if k not in names]
            if missing or extra:
                parts = [f"missing {', '.join(map(repr, missing))}"] if missing else []
                parts += [f"unexpected {', '.join(map(repr, extra))}"] if extra else []
                raise mismatch("; ".join(parts))
            get = obj.__getitem__
        else:
            missing = [n for n in names if not hasattr(obj, n)]
            if missing:
                raise mismatch(f"no attribute {', '.join(map(repr, missing))}")

            def get(n: str) -> Any:
                return getattr(obj, n)

        return RecordValue(
            t.name,
            tuple((n, _from(get(n), ft, conf, f"{path}.{n}", created_by)) for n, ft in t.fields),
        )
    if isinstance(t, ModelT):
        if isinstance(obj, Handle):
            if obj.model != t.name:
                raise mismatch()
            return obj
        if obj is None:
            raise TypeMismatch(f"expected a {t} object, got None", path)
        why = refusal(obj, t.name, conf)
        if why is not None:
            what = type(obj).__name__
            raise TypeMismatch(f"the binding refuses this {what} as a {t}: {why}", path)
        return Handle(obj, t.name, created_by=created_by, targs=t.args)
    if isinstance(t, TypeVarT):
        raise BindingError(f"cannot read {describe(obj)}: type parameter {t} is not instantiated")
    raise BindingError(f"cannot read {describe(obj)} as {t}: not a concrete value type")


def refusal(obj: Any, model: str, conf: Conformance | None) -> str | None:
    """Why the model's ``accepts`` refuses an object, or None when it accepts it (or has none).

    ``accepts`` returning False or raising NotAValue refuses; any other exception
    is a BindingError.
    """
    fn = getattr(conf.models.get(model), "accepts", None) if conf is not None else None
    if fn is None:
        return None
    try:
        ok = fn(obj)
    except NotAValue as e:
        return str(e) or f"models[{model!r}].accepts refused it"
    except Exception as e:
        raise BindingError(f"accepts for model {model} raised {type(e).__name__}: {e}") from e
    return None if ok else f"models[{model!r}].accepts refused it"


def reformat(v: FloatValue, fmt: str) -> FloatValue | None:
    """v in another float format exactly, or None when it does not fit.

    A NaN keeps its sign, quiet bit and payload, shifted to the new mantissa
    width; it fits when no payload bit is lost.
    """
    if v.fmt == fmt:
        return v
    if floats.is_nan(v):
        src, dst = floats.fmt_info(v.fmt), floats.fmt_info(fmt)
        man = v.bits & src.man_mask
        shift = dst.man_bits - src.man_bits
        if shift < 0 and man & ((1 << -shift) - 1):
            return None
        payload = man << shift if shift >= 0 else man >> -shift
        sign = dst.sign_mask if v.bits & src.sign_mask else 0
        return FloatValue(fmt, sign | dst.inf_bits | payload)
    w = floats.convert(v, fmt)
    if floats.signbit(w) != floats.signbit(v) or floats.to_real(w) != floats.to_real(v):
        return None
    return w


def _is_scalar_type(t: Type) -> bool:
    return isinstance(t, (BoolT, IntT, FixedIntT, FloatT, RealT, StringT, BytesT))


def _as_int(obj: Any, np: Any) -> int | None:
    if isinstance(obj, bool) or (np is not None and isinstance(obj, np.bool_)):
        return None
    if isinstance(obj, int):
        return int(obj)
    if isinstance(obj, (float, Fraction, Decimal, complex, str, bytes)):
        return None
    if np is not None and isinstance(obj, (np.floating, np.complexfloating)):
        return None
    try:
        return operator.index(obj)
    except TypeError:
        return None


def _as_float(obj: Any, np: Any) -> FloatValue | None:
    if np is not None and isinstance(obj, np.generic):
        try:
            return floats.from_numpy(obj)
        except TypeError:
            return None
    if isinstance(obj, float):
        return floats.from_python_float(float(obj))
    return None


# ---------------------------------------------------------------------------
# Handles: building, observing, digests


def _binding(conf: Conformance, model: str) -> ModelBinding | InterfaceBinding | None:
    return conf.models.get(model) or conf.interfaces.get(model)


def _model_tenv(spec: Spec, model: str, targs: Sequence[Type]) -> dict[str, Type]:
    decl = spec.models.get(model) or spec.interfaces.get(model)
    tvars = list(spec.tparams.get(decl, {})) if decl is not None else []
    return dict(zip(tvars, targs))


def concretize(
    gm: Any, conf: Conformance, spec: Spec | None = None, *, created_by: str | None = None
) -> Handle:
    """Build the implementation object for a generated model value.

    Unrepresentable propagates (the example is skipped); any other failure is
    a BindingError naming the model. So is an object that ``accepts`` refuses,
    or (unless the binding is lossy) one whose fields do not read back as
    generated.
    """
    spec = spec or conf.spec
    binding = conf.models.get(gm.model)
    if binding is None or binding.concretize is None:
        raise BindingError(
            f"model {gm.model} has no concretize binding (models={{{gm.model!r}: ...}})"
        )
    try:
        observers = spec.fields(gm.model)
    except KeyError:
        raise BindingError(f"{gm.model} is not a model of spec {spec.name}") from None
    tenv = _model_tenv(spec, gm.model, gm.targs)
    types = {o.name: substitute(spec.signature[o].result, tenv) for o in observers}
    unknown = [k for k in gm.fields if k not in types]
    if unknown:
        raise BindingError(f"model {gm.model} has no field {', '.join(unknown)}")
    values = {k: concretize_value(v, types[k], conf, spec) for k, v in gm.fields.items()}
    py = {k: to_python(v, types[k], conf) for k, v in values.items()}
    try:
        obj = binding.concretize(py)
    except Unrepresentable:
        raise
    except Exception as e:
        raise BindingError(f"concretize for model {gm.model} raised {type(e).__name__}: {e}") from e
    if obj is None:
        raise BindingError(f"concretize for model {gm.model} returned None")
    why = refusal(obj, gm.model, conf)
    if why is not None:
        raise BindingError(f"concretize for model {gm.model} built an object it refuses: {why}")
    handle = Handle(obj, gm.model, created_by=created_by, targs=tuple(gm.targs))
    if not binding.lossy:
        check_round_trip(handle, values, types, conf, spec)
    return handle


def check_round_trip(
    handle: Handle,
    values: Mapping[str, Any],
    types: Mapping[str, Type],
    conf: Conformance,
    spec: Spec | None = None,
) -> None:
    """A concretized handle must observe as the field values it was built from.

    BindingError, showing both, when a field reads back differently (floats by
    bits, maps regardless of order, nested handles by their fields).
    """
    spec = spec or conf.spec
    observed = {n: observe(handle, n, (), conf, spec) for n in values}
    differ = [
        n
        for n in values
        if _state(values[n], conf, spec, set()) != _state(observed[n], conf, spec, set())
    ]
    if not differ:
        return
    from spectest.eval import format_value

    def show(fields: Mapping[str, Any]) -> str:
        body = ", ".join(f"{n}: {format_value(fields[n], types.get(n))}" for n in values)
        return f"{handle.model} {{ {body} }}"

    raise BindingError(
        f"concretize for model {handle.model} built an object that observes as "
        f"{show(observed)}, not as the generated {show(values)} (fields that differ: "
        f"{', '.join(differ)}); a binding that cannot keep every field exactly "
        "declares ModelBinding(lossy=True)"
    )


def _state(value: Any, conf: Conformance, spec: Spec, active: set[int]) -> str:
    """An exact, canonical text of a value, with each handle in it replaced by its fields."""

    def nested(h: Handle) -> Any:
        key = id(h.obj)
        if key in active:
            return {"$handle": h.model, "cycle": True}
        active.add(key)
        try:
            names = [o.name for o in spec.fields(h.model)]
            observed = {n: observe(h, n, (), conf, spec) for n in names}
            states = {n: _state(v, conf, spec, active) for n, v in observed.items()}
            return {"$handle": h.model, "fields": states}
        finally:
            active.discard(key)

    return canonical_json(encode_value(value, canonical=True, handle=nested))


def concretize_value(value: Any, t: Type, conf: Conformance, spec: Spec | None = None) -> Any:
    """The value with every generated model inside it (at any depth) concretized to a Handle."""
    if isinstance(t, ModelT) and is_generated_model(value):
        return concretize(value, conf, spec)
    if isinstance(t, ListT) and isinstance(value, (tuple, list)):
        return tuple(concretize_value(x, t.elem, conf, spec) for x in value)
    if isinstance(t, TupleT) and isinstance(value, (tuple, list)):
        return tuple(concretize_value(x, et, conf, spec) for x, et in zip(value, t.elems))
    if isinstance(t, OptionT) and isinstance(value, Some):
        return Some(concretize_value(value.value, t.elem, conf, spec))
    if isinstance(t, MapT) and isinstance(value, MapValue):
        return MapValue(
            tuple(
                (concretize_value(k, t.key, conf, spec), concretize_value(x, t.value, conf, spec))
                for k, x in value.items
            )
        )
    if isinstance(t, RecordT) and isinstance(value, RecordValue):
        ftypes = dict(t.fields)
        return RecordValue(
            value.name,
            tuple((k, concretize_value(x, ftypes[k], conf, spec)) for k, x in value.fields),
        )
    return value


def _observer_fn(conf: Conformance, model: str, name: str) -> Callable[..., Any] | None:
    binding = _binding(conf, model)
    table = getattr(binding, "observers", None) or {}
    return table.get(name)


def _fallback_observe(obj: Any, model: str, name: str, args: list[Any]) -> Any:
    try:
        attr = getattr(obj, name)
    except AttributeError:
        raise BindingError(
            f"observer {model}.{name} has no binding, and the {type(obj).__name__} object "
            f"has no attribute {name!r}"
        ) from None
    if args:
        return attr(*args)
    return attr() if callable(attr) else attr


def observe(
    handle: Handle, observer: str, args: Sequence[Any], conf: Conformance, spec: Spec | None = None
) -> Any:
    """Call an observer on a handle and read its result as the observer's declared type.

    Any failure (the observer raising, or returning a value of the wrong type)
    is a BindingError naming ``Model.observer``; NotAValue becomes ValueRefused.
    """
    spec = spec or conf.spec
    label = f"{handle.model}.{observer}"
    try:
        decl = spec.observers(handle.model)[observer]
    except KeyError:
        raise BindingError(f"{label} is not an observer of spec {spec.name}") from None
    sig = spec.signature[decl]
    tenv = _model_tenv(spec, handle.model, getattr(handle, "targs", ()))
    ptypes = [substitute(p, tenv) for p in sig.params]
    rtype = substitute(sig.result, tenv)
    if len(args) != len(ptypes):
        raise BindingError(f"observer {label} takes {len(ptypes)} argument(s), got {len(args)}")
    pyargs = [to_python(a, pt, conf) for a, pt in zip(args, ptypes)]
    fn = _observer_fn(conf, handle.model, observer)
    try:
        raw = (
            fn(handle.obj, *pyargs)
            if fn is not None
            else _fallback_observe(handle.obj, handle.model, observer, pyargs)
        )
    except BindingError:
        raise
    except NotAValue as e:
        raise ValueRefused(
            f"observer {label} says the object is not a {handle.model}: {e}", handle
        ) from e
    except Exception as e:
        raise BindingError(f"observer {label} raised {type(e).__name__}: {e}") from e
    try:
        return from_python(raw, rtype, conf, created_by=label)
    except TypeMismatch as e:
        raise BindingError(f"observer {label} returned a value that is not {rtype}: {e}") from e


def fields(handle: Handle, conf: Conformance, spec: Spec | None = None) -> dict[str, Any]:
    """Every zero-argument observer of the handle's model, in declaration order."""
    spec = spec or conf.spec
    try:
        names = [o.name for o in spec.fields(handle.model)]
    except KeyError:
        raise BindingError(f"{handle.model} is not a model of spec {spec.name}") from None
    return {n: observe(handle, n, (), conf, spec) for n in names}


def digest(handle: Handle, conf: Conformance, spec: Spec | None = None) -> Hashable:
    """A hashable summary of the handle's abstract state, for ``modifies``.

    The binding's ``digest`` when given; otherwise every field, encoded exactly
    (floats by bits, maps regardless of order).
    """
    return _digest(handle, conf, spec or conf.spec, set())


def _digest(handle: Handle, conf: Conformance, spec: Spec, active: set[int]) -> Hashable:
    binding = _binding(conf, handle.model)
    fn = getattr(binding, "digest", None)
    if fn is not None:
        try:
            d = fn(handle.obj)
            hash(d)
        except Exception as e:
            raise BindingError(f"digest for {handle.model} failed: {type(e).__name__}: {e}") from e
        return d
    key = id(handle.obj)
    if key in active:
        return ("cycle", handle.model)
    active.add(key)
    try:

        def nested(h: Handle) -> Any:
            return {"$handle": h.model, "digest": repr(_digest(h, conf, spec, active))}

        return tuple(
            (name, canonical_json(encode_value(v, canonical=True, handle=nested)))
            for name, v in fields(handle, conf, spec).items()
        )
    finally:
        active.discard(key)


def shares_memory(a: Handle, b: Handle, conf: Conformance) -> bool:
    """The binding's ``shares_memory`` for a's model; numpy arrays use np.shares_memory."""
    binding = conf.models.get(a.model)
    fn = getattr(binding, "shares_memory", None)
    np = _numpy()
    try:
        if fn is not None:
            return bool(fn(a.obj, b.obj))
        if np is not None and isinstance(a.obj, np.ndarray) and isinstance(b.obj, np.ndarray):
            return bool(np.shares_memory(a.obj, b.obj))
    except Exception as e:
        raise BindingError(f"shares_memory for {a.model} raised {type(e).__name__}: {e}") from e
    raise BindingError(f"model {a.model} has no shares_memory binding")


def map_exception(exc: BaseException, conf: Conformance) -> str | None:
    """The spec error an implementation exception stands for: the first matching mapping."""
    for cls, name in conf.errors.items():
        if isinstance(exc, cls):
            return name
    return None


# ---------------------------------------------------------------------------
# Calling implementations


def impl(conf: Conformance, name: str) -> Callable[..., Any] | None:
    """The implementation bound to a spec function, if any."""
    return conf.impls.get(name)


def constructor(conf: Conformance, iface: str, name: str) -> Callable[..., Any] | None:
    """The bound constructor of an interface, if any."""
    binding = conf.interfaces.get(iface)
    return binding.constructors.get(name) if binding is not None else None


def method(conf: Conformance, iface: str, name: str) -> Callable[..., Any]:
    """A callable ``f(obj, *args)`` for an interface method: the binding's, or ``obj.<name>``."""
    binding = conf.interfaces.get(iface)
    fn = (binding.methods or {}).get(name) if binding is not None else None
    if fn is not None:
        return fn

    def call(obj: Any, *args: Any) -> Any:
        try:
            bound = getattr(obj, name)
        except AttributeError:
            raise BindingError(
                f"method {iface}.{name} has no binding, and the {type(obj).__name__} object "
                f"has no attribute {name!r}"
            ) from None
        return bound(*args)

    return call


def call_arguments(
    names: Sequence[str], types: Sequence[Type], values: Sequence[Any], conf: Conformance
) -> tuple[list[Any], dict[str, Any]]:
    """Positional and keyword arguments for an implementation call.

    An argument equal to ``spectest.generate.DEFAULT`` is omitted; the
    arguments after it are passed by keyword (the spec's parameter names).
    """
    gen = generate_module()
    default = getattr(gen, "DEFAULT", None) if gen is not None else None
    args: list[Any] = []
    kwargs: dict[str, Any] = {}
    by_keyword = False
    for name, t, v in zip(names, types, values, strict=True):
        if default is not None and v is default:
            by_keyword = True
            continue
        py = to_python(v, t, conf)
        if by_keyword:
            kwargs[name] = py
        else:
            args.append(py)
    return args, kwargs


__all__ = [
    "BUILTIN_CLAUSES",
    "SCALAR_MODES",
    "Conformance",
    "ConformanceError",
    "InterfaceBinding",
    "ModelBinding",
    "TypeMismatch",
    "ValueRefused",
    "call_arguments",
    "concretize",
    "concretize_value",
    "conformance",
    "constructor",
    "describe",
    "digest",
    "fields",
    "from_python",
    "impl",
    "load",
    "map_exception",
    "method",
    "observe",
    "reformat",
    "resolve_spec_path",
    "shares_memory",
    "to_python",
]
