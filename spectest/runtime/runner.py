"""Running items: exhaustively, with Hypothesis, or once over a set (aggregates).

``collect_items(conf)`` lists a Conformance's items: one per judged clause of
every bound function and instantiation, the built-ins, the invariants of
models a function returns or modifies, and one stateful item per bound
interface and instantiation. ``Runner.run(item, item_id)`` runs one item and
returns its ClauseResults (one, or one per interface clause).

Modes: a function whose admitted input domain has at most the exhaustive
limit of values runs every input once, judging all its items in one pass that
the session caches. Otherwise each item runs its own Hypothesis search, after
judging the conformance's explicit examples and replaying the item's stored
counterexamples. A failure the search finds is then minimized further by
``spectest.shrink``, and so is the first input of each kind of spec error.
An aggregate is evaluated once.
"""

from __future__ import annotations

import hashlib
import re
import time
from collections.abc import Callable, Collection, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import hypothesis
from hypothesis import HealthCheck, Phase, Verbosity, given, settings
from hypothesis import errors as hyp_errors
from hypothesis import seed as hyp_seed

from spectest import ast, generate, shrink
from spectest import eval as ev
from spectest.runtime.binding import Conformance
from spectest.runtime.context import RuntimeContext, member_policy
from spectest.runtime.plans import (
    CallTimeout,
    ClauseFailure,
    Example,
    FunctionPlan,
    PlanItem,
    PlannedCalls,
    decl_label,
    skip_cause,
)
from spectest.runtime.report import AggregateSummary, ClauseResult, Counterexample
from spectest.runtime.store import CounterexampleStore
from spectest.values import SpecError

SUPPRESSED = [
    HealthCheck.too_slow,
    HealthCheck.filter_too_much,
    HealthCheck.data_too_large,
    HealthCheck.large_base_example,
]
PHASES = [Phase.explicit, Phase.reuse, Phase.generate, Phase.target, Phase.shrink]
SHOWN_EXAMPLES = 5
KEPT_SPEC_ERRORS = 20
SHRUNK_SPEC_ERRORS = 5
DEFAULT_AGGREGATE_SAMPLES = 10_000


@dataclass
class RunOptions:
    """Session-wide settings: the command-line options of the plugin.

    ``max_examples`` and ``exhaustive_limit`` override the Conformance's
    values when set; ``store`` is the counterexample store's root (None: no
    store).
    """

    seed: int = 0
    max_examples: int | None = None
    exhaustive_limit: int | None = None
    aggregate_samples: int = DEFAULT_AGGREGATE_SAMPLES
    timeout: float | None = None
    store: str | Path | None = None


def item_seed(base: int, item_id: str) -> int:
    """The Hypothesis seed of an item: the session seed mixed with a stable hash of its ID."""
    digest = hashlib.sha256(f"{base}:{item_id}".encode()).digest()
    return int.from_bytes(digest[:8], "big")


# ---------------------------------------------------------------------------
# Items


@dataclass
class Item:
    """One pytest item: a function item (``plan`` and ``key``) or an interface (``plan`` only)."""

    conf: Conformance
    name: str
    kind: str
    plan: Any
    key: str | None = None
    expected: frozenset[str] = frozenset()

    @property
    def plan_item(self) -> PlanItem:
        assert self.key is not None
        return self.plan.item(self.key)

    @property
    def expected_fail(self) -> bool:
        return bool(self.expected)


def expected_for(conf: Conformance, key: str) -> frozenset[str]:
    """The expect_fail entries naming a function item: its key, or for "<fn>:<Model>.<inv>"
    also the invariant's own ID."""
    out = {key} & conf.expect_fail
    if ":" in key:
        inv = key.split(":", 1)[1]
        out |= {inv} & conf.expect_fail
    return frozenset(out)


def collect_items(conf: Conformance) -> list[Item]:
    """Every item of a Conformance, in spec order: functions, then interfaces."""
    from spectest.runtime.stateful import InterfacePlan, interface_expected

    items: list[Item] = []
    spec = conf.spec
    for name, fn in spec.fns.items():
        if name not in conf.impls:
            continue
        for tenv in conf.instantiations(fn):
            plan = FunctionPlan(conf, fn, tenv)
            for it in plan.items:
                items.append(
                    Item(
                        conf,
                        plan.item_name(it),
                        it.kind,
                        plan,
                        it.key,
                        expected_for(conf, it.key),
                    )
                )
    for name, iface in spec.interfaces.items():
        if name not in conf.interfaces:
            continue
        for tenv in conf.instantiations(iface):
            plan = InterfacePlan(conf, iface, tenv)
            items.append(
                Item(
                    conf,
                    decl_label(name, tenv),
                    "interface",
                    plan,
                    None,
                    interface_expected(conf, iface),
                )
            )
    return items


# ---------------------------------------------------------------------------
# Tallies


@dataclass
class Tally:
    """Verdict counts, coverage, skips by cause, spec errors and failing inputs of one item.

    Coverage counts only the examples the item judged (pass or fail).
    """

    key: str
    counts: dict[str, int] = field(default_factory=dict)
    coverage: dict[str, int] = field(default_factory=dict)
    skips: dict[str, int] = field(default_factory=dict)
    spec_errors: dict[str, str] = field(default_factory=dict)
    spec_error_args: dict[str, dict[str, Any]] = field(default_factory=dict)
    failing: int = 0
    failing_args: list[dict[str, Any]] = field(default_factory=list)
    inconclusive_reason: str = ""

    @classmethod
    def for_item(cls, key: str, infos: Sequence[Any]) -> Tally:
        coverage = {f"{info.param}: {name}": 0 for info in infos for name in info.names}
        return cls(key, coverage=coverage)

    def add(self, ex: Example, plan: FunctionPlan) -> str:
        v = ex.verdicts.get(self.key, "skip")
        self.counts[v] = self.counts.get(v, 0) + 1
        if v in ("pass", "fail"):
            for param, name in ex.coverage.items():
                label = f"{param}: {name}"
                self.coverage[label] = self.coverage.get(label, 0) + 1
        if v == "skip":
            cause = skip_cause(ex, self.key)
            self.skips[cause] = self.skips.get(cause, 0) + 1
        elif v == "spec_error":
            msg = ex.notes.get(self.key, "spec error")
            if msg not in self.spec_errors and len(self.spec_errors) < KEPT_SPEC_ERRORS:
                inputs = ", ".join(f"{k} = {x}" for k, x in plan.format_inputs(ex.args).items())
                self.spec_errors[msg] = inputs or "(no inputs)"
                self.spec_error_args[msg] = dict(ex.args)
        elif v == "fail":
            self.failing += 1
            if len(self.failing_args) <= SHOWN_EXAMPLES:
                self.failing_args.append(dict(ex.args))
        elif v == "inconclusive" and not self.inconclusive_reason:
            self.inconclusive_reason = ex.notes.get(self.key, "")
        return v

    def spec_error_lines(self) -> list[str]:
        return [f"{msg}\nexample: {inputs}" for msg, inputs in self.spec_errors.items()]


_LITERALS = re.compile(
    r"""b?"(?:[^"\\]|\\.)*"|b?'(?:[^'\\]|\\.)*'|(?<![\w.:])-?\d+(?:\.\d+)?(?![\w:])"""
)


def error_signature(message: str) -> str:
    """A spec error's message without the values in it (quoted text, numbers), so the
    same error on two inputs has one signature; source positions are kept."""
    return _LITERALS.sub("_", message)


# ---------------------------------------------------------------------------
# The runner


@dataclass
class _Exhaustive:
    total: int
    tallies: dict[str, Tally]
    duration: float
    claimed: bool = False


class Runner:
    """Runs items for one session, caching exhaustive passes."""

    def __init__(self, options: RunOptions | None = None) -> None:
        self.options = options or RunOptions()
        self.store = (
            CounterexampleStore(self.options.store) if self.options.store is not None else None
        )
        self._exhaustive: dict[tuple[Any, ...], _Exhaustive | None] = {}

    # -- settings ----------------------------------------------------------------

    def max_examples(self, conf: Conformance) -> int:
        return self.options.max_examples or conf.max_examples

    def exhaustive_limit(self, conf: Conformance) -> int:
        limit = self.options.exhaustive_limit
        return conf.exhaustive_limit if limit is None else limit

    # -- dispatch ----------------------------------------------------------------

    def run(self, item: Item, item_id: str, reproduce: str = "") -> list[ClauseResult]:
        """Run one item: its ClauseResults (one per interface clause for an interface)."""
        if item.kind == "interface":
            from spectest.runtime.stateful import run_interface

            return run_interface(self, item, item_id, reproduce)
        plan: FunctionPlan = item.plan
        plan.timeout = self.options.timeout
        if item.kind == "aggregate":
            return [self.run_aggregate(item, item_id, reproduce)]
        try:
            run = self.exhaustive(plan)
        except SpecError as exc:
            return [self.errored(item, item_id, str(exc))]
        if run is not None:
            return [self.from_exhaustive(item, item_id, run, reproduce)]
        return [self.run_hypothesis(item, item_id, reproduce)]

    def base_result(self, item: Item, item_id: str, mode: str) -> ClauseResult:
        plan: FunctionPlan = item.plan
        it = item.plan_item
        return ClauseResult(
            item_id=item_id,
            clause_id=it.key,
            clause_text=clause_text(plan, it),
            kind=it.kind,
            decl=plan.decl_id,
            instantiation={k: str(v) for k, v in plan.tenv.items()},
            mode=mode,
            expected_fail=item.expected_fail,
        )

    def errored(self, item: Item, item_id: str, message: str) -> ClauseResult:
        result = self.base_result(item, item_id, "hypothesis")
        result.counts["spec_error"] = 1
        result.spec_errors = [message]
        return result

    # -- counterexamples -----------------------------------------------------------

    def counterexample(
        self, plan: FunctionPlan, key: str, args: dict[str, Any], reproduce: str
    ) -> tuple[Counterexample, Example]:
        """Replay failing inputs once with explanations and format the counterexample."""
        infos = generate.partitions(plan.fn, plan.spec, plan.tenv)
        ex = plan.run(args, [key], explain=True, coverage=infos)
        observation = ex.observation
        note = ex.notes.get(key, "")
        it = plan.item(key)
        if note and it.kind not in ("ensures", "relates", "type"):
            observation = f"{observation}\n{note}" if observation else note
        elif note:
            due = [line for line in note.split("\n") if line.startswith("note: ")]
            observation = "\n".join([observation, *due]) if observation else "\n".join(due)
        if ex.verdicts.get(key) != "fail":
            got = ex.verdicts.get(key, "skip")
            observation += f"\n(on replay this input gave {got}: the implementation is flaky)"
        cx = Counterexample(
            inputs=plan.format_inputs(args),
            observation=observation,
            partitions=dict(ex.coverage),
            explanation=ex.explanations.get(key, []),
            seed=self.options.seed,
            reproduce=reproduce,
        )
        return cx, ex

    # -- exhaustive ------------------------------------------------------------------

    def exhaustive(self, plan: FunctionPlan) -> _Exhaustive | None:
        """The session's exhaustive pass over a function's inputs, or None when too large."""
        limit = self.exhaustive_limit(plan.conf)
        cache_key = (id(plan.conf), plan.decl_id, decl_label("", plan.tenv), limit)
        if cache_key in self._exhaustive:
            return self._exhaustive[cache_key]
        found = generate.exhaustive_inputs(plan.fn, plan.spec, plan.tenv, limit)
        if found is None:
            self._exhaustive[cache_key] = None
            return None
        total, inputs = found
        infos = generate.partitions(plan.fn, plan.spec, plan.tenv)
        keys = plan.example_keys()
        tallies = {k: Tally.for_item(k, infos) for k in keys}
        started = time.perf_counter()
        for args in [*plan.explicit_examples(), *inputs]:
            ex = plan.run(args, keys, coverage=infos)
            for k in keys:
                tallies[k].add(ex, plan)
        run = _Exhaustive(total, tallies, time.perf_counter() - started)
        self._exhaustive[cache_key] = run
        return run

    def from_exhaustive(
        self, item: Item, item_id: str, run: _Exhaustive, reproduce: str
    ) -> ClauseResult:
        plan: FunctionPlan = item.plan
        assert item.key is not None
        tally = run.tallies[item.key]
        result = self.base_result(item, item_id, "exhaustive")
        result.counts = {**result.counts, **tally.counts}
        result.coverage = dict(tally.coverage)
        result.skips = dict(tally.skips)
        result.spec_errors = tally.spec_error_lines()
        result.failing_inputs = tally.failing
        result.duration = 0.0 if run.claimed else run.duration
        run.claimed = True
        if tally.failing_args:
            cx, _ = self.counterexample(plan, item.key, tally.failing_args[0], reproduce)
            result.counterexample = cx
            result.failing_examples = [plan.format_inputs(a) for a in tally.failing_args[1:]]
        return result

    # -- Hypothesis ----------------------------------------------------------------------

    def run_hypothesis(self, item: Item, item_id: str, reproduce: str) -> ClauseResult:
        plan: FunctionPlan = item.plan
        key = item.key
        assert key is not None
        spec = plan.spec
        started = time.perf_counter()
        result = self.base_result(item, item_id, "hypothesis")
        try:
            infos = generate.partitions(plan.fn, spec, plan.tenv)
            strategy = generate.args_strategy(plan.fn, spec, plan.tenv, plan.conf.sizes)
        except SpecError as exc:
            return self.errored(item, item_id, str(exc))
        tally = Tally.for_item(key, infos)
        types = dict(zip(plan.names, plan.types, strict=True))
        failing: dict[str, Any] | None = None
        notes: list[str] = []
        for args in plan.explicit_examples():
            ex = plan.run(args, [key], coverage=infos)
            if tally.add(ex, plan) == "fail":
                failing = args
                notes.append("an explicit example of the conformance (examples=)")
                break
        if failing is None and self.store is not None:
            for args in self.store.load(spec.hash, item_id, types, spec=spec):
                ex = plan.run(args, [key], coverage=infos)
                if tally.add(ex, plan) == "fail":
                    failing = self.minimize(plan, key, args, _fails(key))
                    result.replayed = True
                    notes.append(
                        "replayed from the counterexample store under .spectest/; "
                        "delete it to search afresh"
                    )
                    if failing != args:
                        self.save(spec.hash, item_id, failing, types, notes)
                    break
        given = set(tally.spec_error_args)
        if failing is None:
            failing, extra = self.search(plan, key, strategy, infos, tally, item_id)
            notes += extra
            if failing is not None:
                failing = self.minimize(plan, key, failing, _fails(key))
                self.save(spec.hash, item_id, failing, types, notes)
        if set(tally.spec_error_args) - given:
            self.shrink_spec_errors(plan, key, strategy, tally, item_id, given)
        result.counts = {**result.counts, **tally.counts}
        result.coverage = dict(tally.coverage)
        result.skips = dict(tally.skips)
        result.spec_errors = tally.spec_error_lines()
        if failing is not None:
            cx, _ = self.counterexample(plan, key, failing, reproduce)
            shown = [n for n in notes if not n.startswith("spec error:")]
            if shown:
                cx.observation += "".join(f"\n({n})" for n in shown)
            result.counterexample = cx
            result.failing_inputs = max(1, tally.failing)
        for note in notes:
            if note.startswith("spec error:"):
                result.spec_errors.append(note[len("spec error: ") :])
        result.duration = time.perf_counter() - started
        return result

    def save(
        self,
        spec_hash: str,
        item_id: str,
        args: dict[str, Any],
        types: dict[str, Any],
        notes: list[str],
    ) -> None:
        if self.store is None:
            return
        try:
            self.store.save(spec_hash, item_id, args, types)
        except (ValueError, OSError) as exc:
            notes.append(f"could not store the counterexample: {exc}")

    def minimize(
        self,
        plan: FunctionPlan,
        key: str,
        args: dict[str, Any],
        target: Callable[[Example], bool],
    ) -> dict[str, Any]:
        """Failing inputs after spectest.shrink's pass: simpler inputs on which the item
        still gives the same verdict (``target``)."""
        types = dict(zip(plan.names, plan.types, strict=True))
        defaults = {p.name for p in plan.fn.params if p.default is not None}
        return shrink.minimize(
            args, types, lambda trial: target(plan.run(trial, [key])), plan.spec, defaults=defaults
        )

    def shrink_spec_errors(
        self,
        plan: FunctionPlan,
        key: str,
        strategy: Any,
        tally: Tally,
        item_id: str,
        given: Collection[str] = (),
    ) -> None:
        """Report each kind of spec error (``error_signature``) once, on a shrunk input:
        the first kind is shrunk by a Hypothesis run that stops at it, as a failure is,
        and every kind by spectest.shrink's pass. Errors first met on an explicit or
        replayed example (``given``) are reported as they were."""
        kinds: dict[str, tuple[str, dict[str, Any]]] = {}
        for msg, args in tally.spec_error_args.items():
            kinds.setdefault(error_signature(msg), (msg, args))
        shrunk: dict[str, str] = {}
        searched = False
        for i, (signature, (msg, args)) in enumerate(kinds.items()):
            if i >= SHRUNK_SPEC_ERRORS or msg in given:
                shrunk.setdefault(msg, tally.spec_errors[msg])
                continue
            target = _errs(key, signature)
            if not searched:
                searched = True
                found, _ = self.search(plan, key, strategy, (), None, item_id, target=target)
                if found is not None:
                    args = found
            args = self.minimize(plan, key, args, target)
            ex = plan.run(args, [key])
            if not target(ex):
                shrunk.setdefault(msg, tally.spec_errors[msg])
                continue
            inputs = ", ".join(f"{k} = {x}" for k, x in plan.format_inputs(args).items())
            shrunk.setdefault(ex.notes.get(key, msg), inputs or "(no inputs)")
        tally.spec_errors = shrunk

    def search(
        self,
        plan: FunctionPlan,
        key: str,
        strategy: Any,
        infos: Sequence[Any],
        tally: Tally | None,
        item_id: str,
        *,
        target: Callable[[Example], bool] | None = None,
    ) -> tuple[dict[str, Any] | None, list[str]]:
        """One Hypothesis run: the shrunk failing inputs (or None) and notes.

        With ``target``, the run stops at (and shrinks) the first example that meets it
        instead of the first failure.
        """
        state: dict[str, Any] = {"failed": False, "last": None}
        stop = target or _fails(key)

        def check(args: dict[str, Any]) -> None:
            ex = plan.run(args, [key], coverage=infos)
            if tally is not None and not state["failed"]:
                tally.add(ex, plan)
            if ex.status in ("rejected", "skipped"):
                hypothesis.reject()
            if stop(ex):
                state["failed"] = True
                state["last"] = dict(args)
                raise ClauseFailure(key, ex.notes.get(key, "the clause is false"))

        test = given(strategy)(check)
        test = settings(
            max_examples=self.max_examples(plan.conf),
            deadline=None,
            database=None,
            suppress_health_check=SUPPRESSED,
            phases=PHASES,
            report_multiple_bugs=False,
            verbosity=Verbosity.quiet,
            print_blob=False,
        )(test)
        test = hyp_seed(item_seed(self.options.seed, item_id))(test)
        notes: list[str] = []
        try:
            test()
        except ClauseFailure:
            pass
        except hyp_errors.Unsatisfiable:
            if tally is not None:
                tally.counts["inconclusive"] = tally.counts.get("inconclusive", 0) + 1
            notes.append("no example satisfied requires")
        except hyp_errors.Flaky:
            notes.append("the failure did not reproduce: the implementation is flaky")
        except SpecError as exc:
            notes.append(f"spec error: {exc}")
            if tally is not None:
                tally.counts["spec_error"] = tally.counts.get("spec_error", 0) + 1
        return state["last"], notes

    # -- aggregates --------------------------------------------------------------------------

    def run_aggregate(self, item: Item, item_id: str, reproduce: str) -> ClauseResult:
        plan: FunctionPlan = item.plan
        clause = item.plan_item.clause
        assert clause is not None
        started = time.perf_counter()
        result = self.base_result(item, item_id, "exhaustive")
        evaluate = getattr(ev, "evaluate_aggregate", None)
        if evaluate is None:
            result.counts["spec_error"] = 1
            result.spec_errors = ["aggregate clauses need spectest.eval.evaluate_aggregate"]
            return result
        seed = item_seed(self.options.seed, item_id)
        policy = member_policy(
            self.exhaustive_limit(plan.conf), self.options.aggregate_samples, seed
        )
        planner = PlannedCalls(plan.conf, plan.spec, plan.tenv, self.options.timeout)
        ctx = RuntimeContext(plan.conf, plan.spec, planner=planner, members=policy)
        try:
            agg = evaluate(clause, plan.spec, ctx)
        except CallTimeout as exc:
            result.counts["inconclusive"] = 1
            result.spec_errors = []
            result.duration = time.perf_counter() - started
            result.counterexample = Counterexample(observation=str(exc), seed=self.options.seed)
            return result
        except SpecError as exc:
            result.counts["spec_error"] = 1
            result.spec_errors = [str(exc)]
            result.duration = time.perf_counter() - started
            return result
        verdict = "pass" if agg.holds else "fail"
        result.counts[verdict] = 1
        result.mode = "sampled" if agg.sampled else "exhaustive"
        result.aggregate = AggregateSummary(
            value=ev.format_value(agg.value),
            bound=ev.format_value(agg.bound),
            evaluated=agg.evaluated,
            skipped=agg.skipped,
            total=agg.total,
            sampled=agg.sampled,
            worst=[(ev.format_value(m), ev.format_value(t)) for m, t in agg.worst],
        )
        if not agg.holds:
            top = clause.expr.left if isinstance(clause.expr, ast.Binary) else clause.expr
            var = getattr(top, "var", "v")
            where = ev.source_text(top.iterable, plan.spec) if hasattr(top, "iterable") else "?"
            visited = agg.evaluated + agg.skipped
            how = f"a seeded sample of {visited} of" if agg.sampled else "every member of"
            kind = getattr(top, "kind", "aggregate")
            result.counterexample = Counterexample(
                inputs={var: f"{how} {where} ({agg.total} members)"},
                observation=(
                    f"{kind} = {ev.format_value(agg.value)}, against the bound "
                    f"{ev.format_value(agg.bound)}"
                ),
                seed=self.options.seed,
                reproduce=reproduce,
            )
        result.duration = time.perf_counter() - started
        return result


def _fails(key: str) -> Callable[[Example], bool]:
    return lambda ex: ex.verdicts.get(key) == "fail"


def _errs(key: str, signature: str) -> Callable[[Example], bool]:
    def target(ex: Example) -> bool:
        if ex.verdicts.get(key) != "spec_error":
            return False
        return error_signature(ex.notes.get(key, "spec error")) == signature

    return target


def clause_text(plan: FunctionPlan, it: PlanItem) -> str:
    """The quoted text of an item's clause; built-ins describe themselves."""
    if it.clause is not None:
        text = it.clause.text
        return f"{text} (on handles {plan.fn.name} returns or modifies)" if it.model else text
    if it.kind == "type":
        return f"built-in: the result of {plan.fn.name} reads as {plan.result_type}"
    if it.kind == "raises":
        return f"built-in: {plan.fn.name} raises only what a raises or may_raise admits"
    if it.kind == "frame":
        params = ", ".join(plan.handle_params)
        return f"built-in: {plan.fn.name} leaves {params} unchanged (no modifies clause)"
    return it.key


__all__ = [
    "DEFAULT_AGGREGATE_SAMPLES",
    "Item",
    "RunOptions",
    "Runner",
    "Tally",
    "clause_text",
    "collect_items",
    "error_signature",
    "expected_for",
    "item_seed",
]
