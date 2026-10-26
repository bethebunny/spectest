"""Stateful tests of interfaces: a Hypothesis RuleBasedStateMachine per instantiation.

A machine keeps the live handles of one step sequence. A rule per bound
constructor draws its arguments, calls it and adopts the new handle, while
fewer than the conformance's ``max_handles`` are live; a rule per method calls
it on a live handle, preferring the one used last, so a sequence builds deep
states instead of many fresh objects. Arguments whose declared type is an
integer are 0 to 4 in magnitude three times in four (sizes, counts, offsets).

Every call is judged like a function call (``ensures``, ``raises``,
``relates``, ``modifies`` or the frame rule, ``#type``, ``#raises``), and the
interface's invariants are checked on every live handle after every call. A
failing clause raises ClauseFailure so Hypothesis shrinks the sequence; then
``minimize`` deletes steps and lowers constructors' integer arguments, and
the step log ("d1 = Deque.bounded(n=2)", "d1.append(x=5)", ...) is the
counterexample. Failing step sequences go to the counterexample store and are
replayed first on the next run.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any

from hypothesis import Verbosity, settings
from hypothesis import errors as hyp_errors
from hypothesis import seed as hyp_seed
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, precondition, rule

from spectest import ast, generate
from spectest import eval as ev
from spectest.runtime import binding
from spectest.runtime.binding import Conformance
from spectest.runtime.context import RuntimeContext
from spectest.runtime.plans import (
    JUDGED_KINDS,
    CallJudge,
    CallTimeout,
    ClauseFailure,
    PlannedCalls,
    Snapshot,
    conditions_of,
    decl_label,
    explicit_examples,
    frame_verdict,
    invoke,
    show,
    show_handle,
    snapshot,
)
from spectest.runtime.report import ClauseResult, Counterexample
from spectest.runtime.store import is_default
from spectest.types import FixedIntT, IntT, ModelT, Type, substitute
from spectest.values import Handle, SkipClause, SpecError, Unrepresentable

STEP_COUNT = 30
MAX_HANDLES = 2
MAX_RUNS = 8
KEPT_SPEC_ERRORS = 20
SMALL_INTS = (0, 1, -1, 2, -2, 3, -3, 4, -4)
REPLAYED = "replayed from the counterexample store under .spectest/; delete it to search afresh"

# Below 3 (three times in four, and the choice to shrink to): an integer argument is small.
SMALL_SHARE = st.integers(0, 3)

# The handle a method runs on, as a position among the live handles by last use:
# 0 (the handle used last) at least half the time, and the simplest choice to shrink to.
_PICK = st.one_of(st.just(0), st.integers(0, 7))


@dataclass
class ClauseKey:
    """A tallied clause of an interface: a constructor or method clause, a built-in or an
    invariant."""

    key: str
    kind: str
    clause: ast.Clause | None
    owner: str


class CallablePlan:
    """A constructor or method of an interface under an instantiation."""

    def __init__(self, plan: InterfacePlan, decl: ast.CtorDecl | ast.MethodDecl) -> None:
        spec, conf, tenv = plan.spec, plan.conf, plan.tenv
        self.decl = decl
        self.is_ctor = isinstance(decl, ast.CtorDecl)
        self.decl_id = spec.decl_ids.get(decl, f"{plan.name}.{decl.name}")
        sig = spec.signature[decl]
        self.names = [p.name for p in decl.params]
        self.params = {p.name: p for p in decl.params}
        self.declared = list(sig.params)
        self.types = [substitute(t, tenv) for t in sig.params]
        self.result_type = substitute(sig.result, tenv)
        clauses = list(decl.clauses)
        self.requires = [c for c in clauses if c.kind == "requires"]
        self.raises = [c for c in clauses if c.kind == "raises"]
        self.may_raise = [c for c in clauses if c.kind == "may_raise"]
        self.modifies = [c for c in clauses if c.kind == "modifies"]
        self.modified = {n for c in self.modifies for n in c.names}
        self.with_olds = [c for c in clauses if c.kind == "ensures" and ev.old_calls(c.expr, spec)]
        self.keys = [
            ClauseKey(c.id, c.kind, c, self.decl_id) for c in clauses if c.kind in JUDGED_KINDS
        ]
        self.keys.append(ClauseKey(f"{self.decl_id}#type", "type", None, self.decl_id))
        self.keys.append(ClauseKey(f"{self.decl_id}#raises", "raises", None, self.decl_id))
        if not self.is_ctor and not self.modifies:
            self.keys.append(ClauseKey(f"{self.decl_id}#frame", "frame", None, self.decl_id))
        if self.is_ctor:
            self.fn: Callable[..., Any] | None = binding.constructor(conf, plan.name, decl.name)
        else:
            self.fn = binding.method(conf, plan.name, decl.name)
        self.returns_handle = (
            isinstance(self.result_type, ModelT)
            and self.result_type.is_interface
            and self.result_type.name == plan.name
        )
        self.infos: list[generate.PartitionInfo] = []
        self.small: dict[str, tuple[int, ...]] = {}
        self.strategy: st.SearchStrategy[dict[str, Any]] | None = None

    def prepare(
        self, spec: Any, tenv: dict[str, Type], sizes: Any = None, examples: Any = ()
    ) -> None:
        """Partitions, small integer values and the argument strategy (SpecError if broken);
        ``sizes`` bounds generated collections (the conformance's, by default Sizes()), and
        ``examples`` are explicit argument dicts, drawn about a quarter of the time."""
        self.infos = generate.partitions(self.decl, spec, tenv)
        self.small = {}
        for name, declared, t in zip(self.names, self.declared, self.types, strict=True):
            if not isinstance(declared, (IntT, FixedIntT)):
                continue
            admitted = generate.admitted_set(self.decl, name, spec, tenv)
            values = tuple(
                v
                for v in SMALL_INTS
                if (not isinstance(t, FixedIntT) or t.min <= v <= t.max)
                and (admitted is None or v in admitted)
            )
            if values:
                self.small[name] = values
        base = generate.args_strategy(self.decl, spec, tenv, sizes or generate.Sizes())
        self.strategy = _with_examples(_arguments(base, self.small), examples)

    @property
    def coverage_labels(self) -> list[str]:
        return [f"{info.param}: {name}" for info in self.infos for name in info.names]


def _arguments(
    base: st.SearchStrategy[dict[str, Any]], small: dict[str, tuple[int, ...]]
) -> st.SearchStrategy[dict[str, Any]]:
    """``base``, with each integer parameter in ``small`` replaced three times in four by one
    of its small values (shrinking toward the small value 0)."""
    if not small:
        return base
    picks = {name: st.sampled_from(values) for name, values in small.items()}

    @st.composite
    def arguments(draw: st.DrawFn) -> dict[str, Any]:
        chosen = {name: draw(s) for name, s in picks.items() if draw(SMALL_SHARE) < 3}
        args = dict(draw(base))
        args.update(chosen)
        return args

    return arguments()


def _with_examples(
    s: st.SearchStrategy[dict[str, Any]], examples: Sequence[dict[str, Any]]
) -> st.SearchStrategy[dict[str, Any]]:
    """``s``, or about a quarter of the time one of the explicit argument dicts, unchanged."""
    if not examples:
        return s
    explicit = st.sampled_from([dict(e) for e in examples])

    @st.composite
    def arguments(draw: st.DrawFn) -> dict[str, Any]:
        if draw(st.integers(0, 3)) == 3:
            return dict(draw(explicit))
        return draw(s)

    return arguments()


class InterfacePlan:
    """A bound interface under one instantiation: its callables and tallied clauses."""

    def __init__(self, conf: Conformance, iface: ast.InterfaceDecl, tenv: dict[str, Type]) -> None:
        self.conf = conf
        self.spec = spec = conf.spec
        self.iface = iface
        self.name = iface.name
        self.tenv = dict(tenv)
        self.label = decl_label(iface.name, self.tenv)
        tvars = list(spec.tparams.get(iface, {}))
        self.handle_type = ModelT(iface.name, tuple(self.tenv[n] for n in tvars), True)
        self.ctors = [
            CallablePlan(self, c)
            for c in iface.ctors
            if binding.constructor(conf, iface.name, c.name) is not None
        ]
        self.methods = [CallablePlan(self, m) for m in iface.methods]
        self.invariants = [c for c in iface.clauses if c.kind == "invariant"]
        self.keys: list[ClauseKey] = [k for cp in [*self.ctors, *self.methods] for k in cp.keys]
        self.keys += [ClauseKey(c.id, "invariant", c, self.name) for c in self.invariants]
        self.timeout: float | None = None
        self.prepared = False

    def __repr__(self) -> str:
        return f"<InterfacePlan {self.label}>"

    @property
    def prefix(self) -> str:
        return self.name[:1].lower() or "h"

    @property
    def steps(self) -> int:
        return getattr(self.conf, "steps", STEP_COUNT)

    @property
    def max_handles(self) -> int:
        return getattr(self.conf, "max_handles", MAX_HANDLES)

    def prepare(self) -> None:
        """Ready every callable's argument strategy; SpecError when one cannot be built."""
        if not self.prepared:
            sizes = getattr(self.conf, "sizes", None)
            for cp in [*self.ctors, *self.methods]:
                examples = explicit_examples(self.conf, cp.decl, self.tenv)
                cp.prepare(self.spec, self.tenv, sizes, examples)
            self.prepared = True

    def coverage_labels(self) -> dict[str, list[str]]:
        """The partition classes each tallied clause records coverage of."""
        out: dict[str, list[str]] = {}
        for cp in [*self.ctors, *self.methods]:
            for k in cp.keys:
                out[k.key] = cp.coverage_labels
        return out


def interface_expected(conf: Conformance, iface: ast.InterfaceDecl) -> frozenset[str]:
    """The expect_fail entries that belong to an interface (its own or its members' clauses)."""
    members = [iface.name, *(f"{iface.name}.{m.name}" for m in [*iface.ctors, *iface.methods])]
    out = set()
    for cid in conf.expect_fail:
        for prefix in members:
            if cid.startswith(prefix) and cid[len(prefix) : len(prefix) + 1] in (".", "#"):
                out.add(cid)
    return frozenset(out)


# ---------------------------------------------------------------------------
# Recording verdicts across steps and runs


@dataclass
class Step:
    """One executed rule: a constructor (``target`` None) or a method on the handle that the
    step ``target`` created."""

    sid: int
    cp: CallablePlan
    args: dict[str, Any]
    target: int | None


@dataclass
class _Failure:
    key: str
    message: str
    log: list[str]
    inputs: dict[str, str]
    observation: str
    explanation: list[tuple[str, str]]
    program: list[Step] = field(default_factory=list)


@dataclass
class Recorder:
    """Tallies per clause until the run's first failure, and of each clause only up to its own
    first failure (``done``: later runs still judge it, but no longer count it); the latest
    failure.

    ``coverage`` counts, per clause, the partition classes of the calls it judged (pass or
    fail).
    """

    plan: InterfacePlan
    counts: dict[str, dict[str, int]] = field(default_factory=dict)
    coverage: dict[str, dict[str, int]] = field(default_factory=dict)
    spec_errors: dict[str, dict[str, str]] = field(default_factory=dict)
    muted: set[str] = field(default_factory=set)
    done: set[str] = field(default_factory=set)
    failed: bool = False
    last: _Failure | None = None
    steps: int = 0

    def start(self, muted: set[str]) -> None:
        self.muted = set(muted)
        self.failed = False
        self.last = None

    def count(
        self,
        key: str,
        verdict: str,
        note: str = "",
        log: Sequence[str] = (),
        cover: dict[str, str] | None = None,
    ) -> None:
        if self.failed or key in self.muted or key in self.done:
            return
        by = self.counts.setdefault(key, {})
        by[verdict] = by.get(verdict, 0) + 1
        if verdict == "fail":
            self.done.add(key)
        if cover and verdict in ("pass", "fail"):
            seen = self.coverage.setdefault(key, {})
            for param, name in cover.items():
                label = f"{param}: {name}"
                seen[label] = seen.get(label, 0) + 1
        if verdict == "spec_error":
            errors = self.spec_errors.setdefault(key, {})
            if note not in errors and len(errors) < KEPT_SPEC_ERRORS:
                errors[note] = "; ".join(log) or "(no steps)"


# ---------------------------------------------------------------------------
# The machine


def _has_handles(machine: _Machine) -> bool:
    return bool(machine.live)


class _Machine(RuleBasedStateMachine):
    plan: InterfacePlan
    recorder: Recorder

    def __init__(self) -> None:
        super().__init__()
        self.live: list[tuple[str, Handle]] = []
        self.recent: list[Handle] = []
        self.handle_names: dict[int, str] = {}
        self.log: list[str] = []
        self.program: list[Step] = []
        self.creator: dict[int, int] = {}
        self.observed: dict[Any, Any] | None = None

    # -- helpers -------------------------------------------------------------------

    def name_of(self, h: Handle) -> str:
        return self.handle_names.get(h.id, repr(h))

    def adopt(self, h: Handle) -> str:
        name = f"{self.plan.prefix}{len(self.live) + 1}"
        self.handle_names[h.id] = name
        self.live.append((name, h))
        self.creator[h.id] = self.program[-1].sid
        self.touch(h)
        return name

    def touch(self, h: Handle) -> None:
        """Make h the most recently used handle."""
        self.recent = [h, *(x for x in self.recent if x is not h)]

    def choose(self, pick: int) -> Handle:
        return self.recent[pick % len(self.recent)]

    def record(self, cp: CallablePlan, args: dict[str, Any], h: Handle | None) -> None:
        target = self.creator.get(h.id) if h is not None else None
        self.program.append(Step(len(self.program), cp, dict(args), target))

    def known(self) -> list[Any]:
        return [h.obj for _, h in self.live]

    def pre_context(self, known: list[Any]) -> RuntimeContext:
        """The pre-state's context. Nothing runs between two steps, so the observations made
        after the last call still describe every handle (observers must not change them)."""
        ctx = RuntimeContext(self.plan.conf, self.plan.spec, known=known)
        if self.observed is not None:
            ctx.cache.update(self.observed)
        return ctx

    def prepare(
        self, cp: CallablePlan, args: dict[str, Any], self_handle: Handle | None
    ) -> tuple[dict[str, Any], dict[str, Any]] | None:
        """Concretized arguments and clause values, or None when the step does not apply."""
        spec, conf = self.plan.spec, self.plan.conf
        try:
            concrete = {
                n: binding.concretize_value(args[n], t, conf, spec)
                for n, t in zip(cp.names, cp.types, strict=True)
            }
            values = {
                n: ev.default_value(cp.params[n], spec) if is_default(v) else v
                for n, v in concrete.items()
            }
        except Unrepresentable:
            return None
        except SpecError as exc:
            for k in cp.keys:
                self.recorder.count(k.key, "spec_error", str(exc), self.log)
            return None
        if self_handle is not None:
            values["self"] = self_handle
        return concrete, values

    def call_text(self, cp: CallablePlan, args: dict[str, Any], receiver: str | None) -> str:
        spec = self.plan.spec
        shown = []
        for n, t in zip(cp.names, cp.types, strict=True):
            v = args[n]
            if is_default(v):
                continue
            shown.append(f"{n}={show(v, t, spec)}")
        head = f"{receiver}.{cp.decl.name}" if receiver else cp.decl_id
        return f"{head}({', '.join(shown)})"

    def classify(
        self, cp: CallablePlan, values: dict[str, Any], env: ev.Env, ctx: RuntimeContext
    ) -> dict[str, str]:
        """The partition class of each partitioned argument, on the pre-state."""
        out: dict[str, str] = {}
        for info in cp.infos:
            name: str | None = None
            if info.kind == "set":
                name = info.classify(values.get(info.param))
            else:
                for cls_name, expr in info.classes:
                    try:
                        if ev.evaluate(expr, env, self.plan.spec, ctx) is True:
                            name = cls_name
                            break
                    except (SpecError, SkipClause):
                        break
            if name is not None:
                out[info.param] = name
        return out

    def snapshot(self, cp: CallablePlan, h: Handle, ctx: RuntimeContext) -> dict[str, Snapshot]:
        """Every live handle's fields before a method call, and the digests the frame check
        compares: all of them, or all but the receiver's when the method modifies self."""
        plan = self.plan
        own = "self" in cp.modified
        checked = [(n, x) for n, x in self.live if not (own and x is h)]
        before = snapshot(checked, plan.conf, plan.spec, ctx, True)
        if own:
            try:
                values: dict[str, Any] | None = ctx.fields(h)
            except SpecError:
                values = None
            before[self.name_of(h)] = Snapshot(h, None, values, plan.spec)
        return before

    def inputs(
        self,
        cp: CallablePlan,
        values: dict[str, Any],
        receiver: tuple[str, Snapshot | None, str] | None,
    ) -> dict[str, str]:
        """A failing call's inputs for display: the receiver as it was before the call."""
        spec = self.plan.spec
        out: dict[str, str] = {}
        if receiver is not None:
            name, snap, fallback = receiver
            text = snap.text if snap is not None and snap.text else fallback
            out["self"] = f"{name} = {text}"
        out.update({n: show(values[n], t, spec) for n, t in zip(cp.names, cp.types, strict=True)})
        return out

    def judge_and_raise(
        self,
        cp: CallablePlan,
        judge: CallJudge,
        env: ev.Env,
        ctx: RuntimeContext,
        before: dict[str, Snapshot],
        self_name: str | None,
        inputs: Callable[[], dict[str, str]],
        cover: dict[str, str],
    ) -> None:
        failures: list[tuple[str, str, list[tuple[str, str]]]] = []
        for k in cp.keys:
            try:
                verdict, note, lines = self.verdict(cp, k, judge, env, ctx, before, self_name)
            except CallTimeout as exc:
                verdict, note, lines = "inconclusive", str(exc), []
            self.recorder.count(k.key, verdict, note, self.log, cover)
            if verdict == "fail" and k.key not in self.recorder.muted:
                failures.append((k.key, note, lines))
        if failures:
            key, note, lines = failures[0]
            self.fail(key, note, inputs(), judge.outcome_text(ctx), lines)

    def verdict(
        self,
        cp: CallablePlan,
        k: ClauseKey,
        judge: CallJudge,
        env: ev.Env,
        ctx: RuntimeContext,
        before: dict[str, Snapshot],
        self_name: str | None,
    ) -> tuple[str, str, list[tuple[str, str]]]:
        spec, conf = self.plan.spec, self.plan.conf
        if judge.convert_error is not None:
            return "spec_error", f"reading the result: {judge.convert_error}", []
        if k.kind == "type":
            return judge.type_verdict(ctx)
        if k.kind == "raises" and k.clause is None:
            return judge.unadmitted_verdict()
        if k.kind == "raises":
            assert k.clause is not None
            return judge.raises_verdict(k.clause)
        if k.kind in ("ensures", "relates"):
            assert k.clause is not None
            return judge.condition_verdict(k.clause, env, ctx)
        if k.kind in ("modifies", "frame"):
            if "self" in cp.modified:
                checked = [n for n in before if n != self_name]
                allowed = f"self ({self_name})"
            else:
                checked = list(before)
                allowed = "nothing"
            return frame_verdict(before, checked, allowed, conf, spec, ctx, True)
        return "skip", f"{k.kind} is not judged per call", []

    def fail(
        self,
        key: str,
        note: str,
        inputs: dict[str, str],
        observation: str,
        lines: list[tuple[str, str]],
    ) -> None:
        rec = self.recorder
        rec.failed = True
        rec.last = _Failure(
            key, note, list(self.log), inputs, observation, list(lines), list(self.program)
        )
        raise ClauseFailure(key, note, rec.last)

    def judge_invariants(self, ctx: RuntimeContext, judge: CallJudge) -> None:
        plan = self.plan
        for c in plan.invariants:
            try:
                verdict, note, lines = judge.invariant_verdict(c, self.live, ctx)
            except CallTimeout as exc:
                verdict, note, lines = "inconclusive", str(exc), []
            self.recorder.count(c.id, verdict, note, self.log)
            if verdict == "fail" and c.id not in self.recorder.muted:
                handles = {name: show_handle(h, ctx, plan.spec) for name, h in self.live}
                self.fail(c.id, note, handles, "after the last step", lines)

    def outcome_note(self, judge: CallJudge) -> str:
        if judge.raised:
            return " " + judge.raised_text()
        if judge.outcome.kind == "timeout":
            return f" {judge.outcome.exc}"
        if judge.type_error is not None:
            return f" returned {binding.describe(judge.outcome.value)}"
        return ""

    # -- steps ------------------------------------------------------------------------

    def construct(self, cp: CallablePlan, args: dict[str, Any]) -> None:
        self.step(cp, args, None)

    def call_method(self, cp: CallablePlan, h: Handle, args: dict[str, Any]) -> None:
        self.step(cp, args, h)

    def step(self, cp: CallablePlan, args: dict[str, Any], h: Handle | None) -> None:
        """Run one constructor (h None) or method call and judge it."""
        plan, rec = self.plan, self.recorder
        spec, conf = plan.spec, plan.conf
        rec.steps += 1
        self.record(cp, args, h)
        if h is not None:
            self.touch(h)
        prepared = self.prepare(cp, args, h)
        if prepared is None:
            return
        concrete, values = prepared
        known = self.known()
        pre = self.pre_context(known)
        env_pre = ev.Env(values=dict(values), tenv=plan.tenv)
        if not self.requires_hold(cp, env_pre, pre):
            self.observed = pre.cache
            return
        cover = self.classify(cp, values, env_pre, pre) if cp.infos else {}
        conditions = conditions_of([*cp.raises, *cp.may_raise], env_pre, spec, pre)
        olds = ev.snapshot_olds(cp.with_olds, env_pre, spec, pre) if cp.with_olds else {}
        self_name = self.name_of(h) if h is not None else None
        before: dict[str, Snapshot] = {}
        receiver: tuple[str, Snapshot | None, str] | None = None
        if h is not None and self_name is not None:
            before = self.snapshot(cp, h, pre)
            snap = before.get(self_name)
            fallback = "" if snap is not None and snap.text else show_handle(h, pre, spec)
            receiver = (self_name, snap, fallback)
        call = self.call_text(cp, args, self_name)
        try:
            pyargs, pykwargs = binding.call_arguments(
                cp.names, cp.types, [concrete[n] for n in cp.names], conf
            )
        except SpecError as exc:
            for k in cp.keys:
                rec.count(k.key, "spec_error", str(exc), self.log)
            self.observed = pre.cache
            return
        assert cp.fn is not None
        self.observed = None
        fn = cp.fn
        if h is None:
            outcome = invoke(fn, pyargs, pykwargs, plan.timeout)
        else:
            obj = h.obj
            outcome = invoke(lambda *a, **kw: fn(obj, *a, **kw), pyargs, pykwargs, plan.timeout)
        judge = CallJudge(
            conf,
            spec,
            raises=cp.raises,
            may_raise=cp.may_raise,
            conditions=conditions,
            outcome=outcome,
            result_type=cp.result_type,
            created_by=cp.decl_id,
            explain=True,
        )
        makes = cp.is_ctor or cp.returns_handle
        if makes and judge.returned_value and isinstance(judge.result, Handle):
            self.log.append(f"{self.adopt(judge.result)} = {call}")
        elif not cp.is_ctor and judge.returned_value and judge.result is not None:
            self.log.append(f"{call} -> {ev.format_value(judge.result, cp.result_type)}")
        else:
            self.log.append(f"{call}{self.outcome_note(judge)}")
        if outcome.kind == "timeout":
            for k in cp.keys:
                rec.count(k.key, "inconclusive", str(outcome.exc), self.log)
            return
        planner = PlannedCalls(conf, spec, plan.tenv, plan.timeout, known)
        post = RuntimeContext(conf, spec, known=known, planner=planner)
        env = ev.Env(values={**values, "result": judge.result}, olds=olds, tenv=plan.tenv)
        self.judge_and_raise(
            cp,
            judge,
            env,
            post,
            before,
            self_name,
            lambda: self.inputs(cp, values, receiver),
            cover,
        )
        self.judge_invariants(post, judge)
        if planner.calls == 0:
            self.observed = post.cache

    def requires_hold(self, cp: CallablePlan, env: ev.Env, ctx: RuntimeContext) -> bool:
        for c in cp.requires:
            try:
                ok = ev.holds(c, env, self.plan.spec, ctx)
            except (SpecError, SkipClause) as exc:
                for k in cp.keys:
                    self.recorder.count(k.key, "spec_error", f"{c.id}: {exc}", self.log)
                return False
            if not ok:
                for k in cp.keys:
                    self.recorder.count(k.key, "skip")
                return False
        return True


def build_machine(plan: InterfacePlan, recorder: Recorder) -> type[RuleBasedStateMachine]:
    """A RuleBasedStateMachine class for an interface plan, reporting to a recorder.

    Constructors run only while fewer than ``plan.max_handles`` handles are live
    (when the interface has methods to call instead); methods need a live handle.
    """
    plan.prepare()
    cap = plan.max_handles
    namespace: dict[str, Any] = {"plan": plan, "recorder": recorder}

    def room(machine: _Machine) -> bool:
        return len(machine.live) < cap

    for cp in plan.ctors:

        def make(self: _Machine, args: dict[str, Any], cp: CallablePlan = cp) -> None:
            self.step(cp, args, None)

        make.__name__ = f"new_{cp.decl.name}"
        made = rule(args=cp.strategy)(make)
        namespace[make.__name__] = precondition(room)(made) if plan.methods else made
    for cp in plan.methods:

        def call(
            self: _Machine, pick: int, args: dict[str, Any], cp: CallablePlan = cp
        ) -> None:
            self.step(cp, args, self.choose(pick))

        call.__name__ = f"call_{cp.decl.name}"
        namespace[call.__name__] = precondition(_has_handles)(
            rule(pick=_PICK, args=cp.strategy)(call)
        )
    return type(f"{plan.name}Machine", (_Machine,), namespace)


# ---------------------------------------------------------------------------
# Step programs: replaying, minimizing, storing


def _without(program: Sequence[Step], sid: int) -> list[Step]:
    """The program without one step and every step on a handle it created."""
    removed = {sid}
    out = []
    for step in program:
        if step.sid in removed or (step.target is not None and step.target in removed):
            removed.add(step.sid)
            continue
        out.append(step)
    return out


def _with_arg(program: Sequence[Step], sid: int, name: str, value: Any) -> list[Step]:
    """The program with one argument of one step replaced."""
    return [
        Step(s.sid, s.cp, {**s.args, name: value}, s.target) if s.sid == sid else s
        for s in program
    ]


def replay(
    machine: type[RuleBasedStateMachine], program: Sequence[Step], recorder: Recorder
) -> _Failure | None:
    """Run a step program outside Hypothesis, without tallying; the failure it ends in, if
    any (clauses in ``recorder.muted`` are judged but do not stop it)."""
    recorder.failed = True
    recorder.last = None
    m: Any = machine()
    made: dict[int, Handle] = {}
    for step in program:
        before = len(m.live)
        try:
            if step.target is None:
                m.step(step.cp, step.args, None)
            elif step.target in made:
                m.step(step.cp, step.args, made[step.target])
            else:
                return None
        except ClauseFailure:
            return recorder.last
        if len(m.live) > before:
            made[step.sid] = m.live[-1][1]
    return None


def shorten(
    machine: type[RuleBasedStateMachine], failure: _Failure, recorder: Recorder
) -> _Failure:
    """Delete steps (with the steps on handles they made) while the same clause still fails.

    Hypothesis refers to live handles by position, so it rarely deletes a
    constructor that later steps skip over; this pass does.
    """
    best = failure
    improved = True
    while improved:
        improved = False
        for step in reversed(best.program):
            found = replay(machine, _without(best.program, step.sid), recorder)
            if found is not None and found.key == failure.key:
                best, improved = found, True
                break
    return best


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _toward_zero(v: int) -> list[int]:
    """Smaller candidates for a nonzero integer: 0, half of it, and one step closer to 0."""
    half = v // 2 if v > 0 else -(-v // 2)
    step = v - 1 if v > 0 else v + 1
    return list(dict.fromkeys([0, half, step]))


def lower_arguments(
    machine: type[RuleBasedStateMachine], failure: _Failure, recorder: Recorder
) -> _Failure:
    """One smaller integer argument of a constructor, with the same clause still failing.

    A constructor's argument is often a size that later steps fill, as in
    ``bounded(n=12)`` followed by twelve appends: lowering it alone, or
    deleting one append alone, stops the failure. So besides the smaller value
    alone, the value one closer to 0 is tried together with deleting each one
    step on the handle the constructor made. Returns the first such failure,
    or ``failure`` itself when there is none.
    """
    program = failure.program
    for step in program:
        if step.target is not None:
            continue
        dependents = [s.sid for s in program if s.target == step.sid]
        for name, v in step.args.items():
            if not _is_int(v) or v == 0:
                continue
            for w in _toward_zero(v):
                lowered = _with_arg(program, step.sid, name, w)
                tries = [lowered]
                if abs(v - w) == 1:
                    tries += [_without(lowered, sid) for sid in dependents]
                for candidate in tries:
                    found = replay(machine, candidate, recorder)
                    if found is not None and found.key == failure.key:
                        return found
    return failure


def minimize(
    machine: type[RuleBasedStateMachine], failure: _Failure, recorder: Recorder
) -> _Failure:
    """Shorten a failing program, then lower constructor arguments and shorten again, until
    neither changes it."""
    best = shorten(machine, failure, recorder)
    while True:
        lowered = lower_arguments(machine, best, recorder)
        if lowered is best:
            return best
        best = shorten(machine, lowered, recorder)


def encode_program(program: Sequence[Step]) -> tuple[tuple[Any, ...], ...]:
    """A step program as a spec value for the counterexample store: one
    ``("new" | "call", name, target position or None, arguments)`` per step."""
    position = {step.sid: i for i, step in enumerate(program)}
    return tuple(
        (
            "new" if step.target is None else "call",
            step.cp.decl.name,
            None if step.target is None else position[step.target],
            dict(step.args),
        )
        for step in program
    )


def decode_program(plan: InterfacePlan, steps: Any) -> list[Step] | None:
    """The program of ``encode_program`` over this plan's callables, or None when it no
    longer fits them (an unbound constructor, a renamed method, other parameters)."""
    if not isinstance(steps, (tuple, list)):
        return None
    tables = {
        "new": {cp.decl.name: cp for cp in plan.ctors},
        "call": {cp.decl.name: cp for cp in plan.methods},
    }
    out: list[Step] = []
    for i, entry in enumerate(steps):
        if not (isinstance(entry, (tuple, list)) and len(entry) == 4):
            return None
        kind, name, target, args = entry
        cp = tables.get(kind, {}).get(name) if isinstance(kind, str) else None
        if cp is None or not isinstance(args, dict) or set(args) != set(cp.names):
            return None
        if kind == "call" and not (_is_int(target) and 0 <= target < i):
            return None
        out.append(Step(i, cp, dict(args), target if kind == "call" else None))
    return out


# ---------------------------------------------------------------------------
# Running an interface item


def run_interface(runner: Any, item: Any, item_id: str, reproduce: str) -> list[ClauseResult]:
    """Run an interface's state machine; one ClauseResult per tallied clause.

    Stored failing programs replay first. After a failure the search runs
    again with that clause muted (still judged, no longer stopping the run or
    counted), so every failing clause is found.
    """
    from hypothesis.stateful import run_state_machine_as_test

    from spectest.runtime.runner import PHASES, SUPPRESSED, item_seed

    plan: InterfacePlan = item.plan
    plan.timeout = runner.options.timeout
    started = time.perf_counter()
    recorder = Recorder(plan)
    failures: dict[str, _Failure] = {}
    replayed: set[str] = set()
    notes: dict[str, list[str]] = {}
    errors: list[str] = []
    state = (recorder, failures, replayed, notes, errors)
    try:
        machine = build_machine(plan, recorder)
    except SpecError as exc:
        errors.append(str(exc))
        return _results(runner, item, item_id, reproduce, *state, 0.0)
    store = getattr(runner, "store", None)
    spec_hash = plan.spec.hash
    if store is not None:
        for entry in store.load(spec_hash, item_id, spec=plan.spec):
            program = decode_program(plan, entry.get("steps"))
            if program is None:
                continue
            recorder.start(set(failures))
            found = replay(machine, program, recorder)
            if found is not None and found.key not in failures:
                failures[found.key] = found
                replayed.add(found.key)
    for attempt in range(MAX_RUNS):
        recorder.start(set(failures))
        machine = build_machine(plan, recorder)
        machine = hyp_seed(item_seed(runner.options.seed, item_id) + attempt)(machine)
        options = settings(
            max_examples=runner.max_examples(plan.conf),
            stateful_step_count=plan.steps,
            deadline=None,
            database=None,
            suppress_health_check=SUPPRESSED,
            phases=PHASES,
            report_multiple_bugs=False,
            verbosity=Verbosity.quiet,
            print_blob=False,
        )
        try:
            run_state_machine_as_test(machine, settings=options)
        except ClauseFailure:
            last = recorder.last
            if last is None or last.key in failures:
                break
            found = minimize(machine, last, recorder)
            failures[last.key] = found
            if store is not None:
                try:
                    store.save(
                        spec_hash,
                        item_id,
                        {"clause": found.key, "steps": encode_program(found.program)},
                    )
                except (ValueError, OSError) as exc:
                    notes[found.key] = [f"could not store the counterexample: {exc}"]
            continue
        except hyp_errors.Flaky:
            if recorder.last is not None and recorder.last.key not in failures:
                failures[recorder.last.key] = recorder.last
                continue
            errors.append("the state machine failed only some of the time: a flaky implementation")
        except hyp_errors.Unsatisfiable:
            errors.append("no step sequence could be run")
        except hyp_errors.InvalidDefinition as exc:
            errors.append(f"no step sequence could be run: {exc}")
        except SpecError as exc:
            errors.append(str(exc))
        break
    duration = time.perf_counter() - started
    return _results(runner, item, item_id, reproduce, *state, duration)


def _results(
    runner: Any,
    item: Any,
    item_id: str,
    reproduce: str,
    recorder: Recorder,
    failures: dict[str, _Failure],
    replayed: set[str],
    notes: dict[str, list[str]],
    errors: list[str],
    duration: float,
) -> list[ClauseResult]:
    """One ClauseResult per tallied clause, and one per expected clause the item never
    judges. A replayed clause's counts are its replay's: the search then mutes it."""
    plan: InterfacePlan = item.plan
    labels = plan.coverage_labels()
    instantiation = {n: str(t) for n, t in plan.tenv.items()}
    out: list[ClauseResult] = []
    for i, k in enumerate(plan.keys):
        counts = dict(recorder.counts.get(k.key, {}))
        coverage = dict.fromkeys(labels.get(k.key, []), 0)
        coverage.update(recorder.coverage.get(k.key, {}))
        result = ClauseResult(
            item_id=item_id,
            clause_id=k.key,
            clause_text=_text(k),
            kind=k.kind,
            decl=k.owner,
            instantiation=instantiation,
            mode="stateful",
            counts=counts,
            coverage=coverage,
            spec_errors=[
                f"{msg}\nsteps: {steps}"
                for msg, steps in recorder.spec_errors.get(k.key, {}).items()
            ],
            expected_fail=k.key in item.expected,
            duration=duration if i == 0 else 0.0,
        )
        if i == 0 and errors:
            result.spec_errors += errors
        failure = failures.get(k.key)
        if failure is not None:
            steps = "\n".join(f"{n}. {s}" for n, s in enumerate(failure.log, 1))
            message = "" if k.kind == "type" else f"\n{failure.message}"
            extra = [REPLAYED] if k.key in replayed else []
            shown = "".join(f"\n({note})" for note in [*extra, *notes.get(k.key, [])])
            result.counterexample = Counterexample(
                inputs=failure.inputs,
                observation=f"steps:\n{steps}\n{failure.observation}{message}{shown}",
                explanation=failure.explanation,
                seed=runner.options.seed,
                reproduce=reproduce,
            )
            result.failing_inputs = 1
            result.counts["fail"] = max(1, result.counts.get("fail", 0))
            result.replayed = k.key in replayed
        out.append(result)
    tallied = {k.key for k in plan.keys}
    for cid in sorted(item.expected - tallied):
        clause = plan.spec.clause_ids.get(cid)
        out.append(
            ClauseResult(
                item_id=item_id,
                clause_id=cid,
                clause_text=f"not judged by this item: {clause.text if clause else cid}",
                kind=clause.kind if clause else "",
                decl=plan.name,
                instantiation=instantiation,
                mode="stateful",
                expected_fail=True,
            )
        )
    return out


def _text(k: ClauseKey) -> str:
    if k.clause is not None:
        return k.clause.text
    if k.kind == "type":
        return f"built-in: the result of {k.owner} reads as its declared type"
    if k.kind == "raises":
        return f"built-in: {k.owner} raises only what a raises or may_raise admits"
    return f"built-in: {k.owner} leaves every live handle unchanged (no modifies clause)"


def interface_outcome(results: Sequence[ClauseResult], expected: frozenset[str]) -> str:
    """The item's outcome: failed, error, xfailed, xpassed, passed, inconclusive or skipped.

    ``expect_fail`` is strict per clause: when an expected clause never failed
    the item is an unexpected pass, even if other expected clauses failed.
    """
    failing = {r.clause_id for r in results if r.failed}
    if failing - expected:
        return "failed"
    if any(r.has_spec_errors for r in results):
        return "error"
    if expected - failing:
        return "xpassed"
    if failing:
        return "xfailed"
    if any(r.counts["pass"] for r in results):
        return "passed"
    if any(r.counts["inconclusive"] for r in results):
        return "inconclusive"
    return "skipped"


__all__ = [
    "MAX_HANDLES",
    "STEP_COUNT",
    "CallablePlan",
    "ClauseKey",
    "InterfacePlan",
    "Recorder",
    "Step",
    "build_machine",
    "decode_program",
    "encode_program",
    "interface_expected",
    "interface_outcome",
    "lower_arguments",
    "minimize",
    "replay",
    "run_interface",
    "shorten",
]
