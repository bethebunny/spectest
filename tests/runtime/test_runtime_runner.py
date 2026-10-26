"""The runner: items, Hypothesis and exhaustive modes, the store, tallies and aggregates."""

from __future__ import annotations

import textwrap

import pytest
from budget import full

from spectest import eval as ev
from spectest.lang import load_source
from spectest.runtime.binding import InterfaceBinding, ModelBinding, conformance
from spectest.runtime.report import render_failure
from spectest.runtime.runner import (
    Item,
    Runner,
    RunOptions,
    Tally,
    collect_items,
    expected_for,
    item_seed,
)
from spectest.runtime.store import CounterexampleStore
from spectest.types import FixedIntT

I64 = FixedIntT(64, True)


def spec_of(source: str):
    return load_source(textwrap.dedent(source).lstrip("\n"), "t.spec")


def items_by_name(conf) -> dict[str, Item]:
    return {it.name: it for it in collect_items(conf)}


def run_one(conf, name: str, runner: Runner | None = None, item_id: str | None = None):
    """The item's one result, by default at the conformance's budget (25 examples in the
    dev loop)."""
    item = items_by_name(conf)[name]
    runner = runner or Runner(RunOptions(max_examples=None if full() else 25))
    (result,) = runner.run(item, item_id or f"t.py::conf::{name}", f"repro {name}")
    return result


SIMPLE = """
spec t
error Neg
fn f(x: i64) -> i64
  partition x
    negative = i64.range(none, 0)
    small    = i64.range(0, 1000)
    large    = i64.range(1000, none)
  raises neg: Neg when x < 0
  ensures same: result == x
"""


class NegError(Exception):
    pass


def f_ok(x):
    if x < 0:
        raise NegError()
    return x


def f_bug(x):
    if x < 0:
        raise NegError()
    return x + 1 if x > 1000 else x


def simple(impl, **options):
    return conformance(spec_of(SIMPLE), impls={"f": impl}, errors={NegError: "Neg"}, **options)


def test_collect_items_names_and_kinds():
    source = """
    spec t
    error E
    model Frame
      observe n: i64
      invariant pos: n >= 0
    fn sort<T: Ord>(xs: list<T>) -> list<T>
      ensures ordered: is_sorted(result)
    fn drop(df: Frame) -> Frame
      ensures same: result.n == df.n
    interface Counter
      observe value: i64
      new zero() -> Counter
      method inc(self)
        modifies self
    """
    spec = spec_of(source)
    conf = conformance(
        spec,
        impls={"sort": sorted, "drop": lambda df: df},
        models={"Frame": ModelBinding(concretize=dict)},
        interfaces={"Counter": InterfaceBinding(constructors={"zero": dict})},
        instantiate=[{"T": "i64"}, {"T": "string"}],
        expect_fail={"sort.ordered", "Frame.pos"},
    )
    items = collect_items(conf)
    assert [it.name for it in items] == [
        "sort[T=i64].ordered",
        "sort[T=i64]#type",
        "sort[T=i64]#raises",
        "sort[T=string].ordered",
        "sort[T=string]#type",
        "sort[T=string]#raises",
        "drop.same",
        "drop#type",
        "drop#raises",
        "drop#frame",
        "drop:Frame.pos",
        "Counter",
    ]
    by = {it.name: it for it in items}
    assert by["sort[T=i64].ordered"].expected_fail
    assert not by["sort[T=i64]#type"].expected_fail
    assert by["drop:Frame.pos"].expected_fail
    assert by["Counter"].kind == "interface"
    assert expected_for(conf, "drop:Frame.pos") == {"Frame.pos"}


def test_item_seeds_are_stable_and_differ_by_item():
    assert item_seed(0, "a") == item_seed(0, "a")
    assert item_seed(0, "a") != item_seed(0, "b")
    assert item_seed(0, "a") != item_seed(1, "a")


def test_hypothesis_mode_passes_and_counts_coverage():
    result = run_one(simple(f_ok), "f.same")
    assert result.mode == "hypothesis"
    assert result.outcome == "passed"
    assert result.counts["pass"] > 0 and result.counts["fail"] == 0
    assert set(result.coverage) == {"x: negative", "x: small", "x: large"}
    assert result.clause_text == "ensures same: result == x"


def test_coverage_counts_only_judged_examples_and_skips_have_causes():
    same = run_one(simple(f_ok), "f.same")
    assert same.coverage["x: negative"] == 0
    assert same.coverage["x: small"] > 0 and same.coverage["x: large"] > 0
    assert same.counts["skip"] > 0
    assert same.skips == {"raised": same.counts["skip"]}
    neg = run_one(simple(f_ok), "f.neg")
    assert all(n > 0 for n in neg.coverage.values())
    assert sum(neg.coverage.values()) == neg.counts["pass"] + neg.counts["fail"]


def test_hypothesis_mode_minimizes_a_failure():
    result = run_one(simple(f_bug), "f.same")
    assert result.outcome == "failed"
    cx = result.counterexample
    assert cx is not None
    assert cx.inputs == {"x": "1001"}
    assert cx.observation == "result = 1002"
    assert cx.partitions == {"x": "large"}
    assert cx.explanation == [("result", "1002"), ("x", "1001")]
    assert cx.seed == 0
    assert cx.reproduce == "repro f.same"
    text = render_failure(result)
    assert "f.same (ensures) failed" in text
    assert "x = 1001" in text


def test_raises_item_fails_with_its_own_counterexample():
    result = run_one(simple(lambda x: x), "f.neg")
    assert result.outcome == "failed"
    assert result.counterexample.inputs == {"x": "-1"}
    assert "Neg was due (x < 0 holds), but the call returned" in result.counterexample.observation


def test_expected_failures_are_xfailed_and_strict():
    conf = simple(f_bug, expect_fail={"f.same"})
    assert run_one(conf, "f.same").outcome == "xfailed"
    conf = simple(f_ok, expect_fail={"f.same"})
    assert run_one(conf, "f.same").outcome == "xpassed"


def test_spec_errors_are_collected_without_stopping():
    source = """
    spec t
    fn g(xs: list<i64>) -> i64
      ensures first: result == xs[0]
    """
    conf = conformance(spec_of(source), impls={"g": lambda xs: xs[0] if xs else 0})
    result = run_one(conf, "g.first")
    assert result.outcome == "error"
    assert result.counts["pass"] > 0
    assert result.counts["spec_error"] > 0
    assert len(result.spec_errors) == 1
    assert "index 0 is out of range" in result.spec_errors[0]
    assert "example: xs = []" in result.spec_errors[0]


@pytest.mark.slow
def test_unsatisfiable_requires_is_inconclusive():
    source = """
    spec t
    fn g(x: i64, y: i64) -> i64
      requires x == y + 12345678
    """
    conf = conformance(spec_of(source), impls={"g": lambda x, y: x}, max_examples=20)
    result = run_one(conf, "g#type")
    assert result.counts["inconclusive"] >= 1 or result.counts["pass"] >= 1
    assert result.counts["skip"] > 0


def test_options_override_the_conformance():
    conf = simple(f_ok, max_examples=500)
    runner = Runner(RunOptions(max_examples=7, exhaustive_limit=3))
    assert runner.max_examples(conf) == 7
    assert runner.exhaustive_limit(conf) == 3
    assert Runner().max_examples(conf) == 500


SMALL = """
spec t
fn h(x: u8) -> u8
  ensures same: result == x
  ensures small: result < 200
"""


def test_exhaustive_mode_runs_every_input_once_for_all_items():
    calls = []

    def h(x):
        calls.append(x)
        return x if x != 7 else 8

    conf = conformance(spec_of(SMALL), impls={"h": h})
    runner = Runner()
    by = items_by_name(conf)
    (same,) = runner.run(by["h.same"], "t::h.same", "repro")
    (small,) = runner.run(by["h.small"], "t::h.small", "repro")
    (typ,) = runner.run(by["h#type"], "t::h#type", "repro")
    assert calls[:256] == list(range(256))
    assert calls[256:] == [7, 200]
    assert same.mode == small.mode == "exhaustive"
    assert same.counts["pass"] == 255 and same.counts["fail"] == 1
    assert same.failing_inputs == 1
    assert same.counterexample.inputs == {"x": "7"}
    assert small.counts["fail"] == 56 and small.failing_inputs == 56
    assert small.counterexample.inputs == {"x": "200"}
    assert small.failing_examples[:2] == [{"x": "201"}, {"x": "202"}]
    assert typ.outcome == "passed"
    text = render_failure(small)
    assert "failed on 56 of 256 inputs" in text
    assert "... and 50 more" in text


def test_exhaustive_limit_switches_to_hypothesis():
    conf = conformance(spec_of(SMALL), impls={"h": lambda x: x})
    runner = Runner(RunOptions(exhaustive_limit=100, max_examples=10))
    (result,) = runner.run(items_by_name(conf)["h.same"], "t::h.same")
    assert result.mode == "hypothesis"


def test_store_saves_and_replays_counterexamples(tmp_path):
    store = tmp_path / ".spectest"
    conf = simple(f_bug)
    runner = Runner(RunOptions(store=store))
    first = run_one(conf, "f.same", runner, "t.py::c::f.same")
    assert first.counterexample.inputs == {"x": "1001"}
    saved = CounterexampleStore(store).load(conf.spec.hash, "t.py::c::f.same")
    assert saved == [{"x": 1001}]
    again = run_one(conf, "f.same", Runner(RunOptions(store=store)), "t.py::c::f.same")
    assert again.outcome == "failed"
    assert again.counterexample.inputs == {"x": "1001"}
    assert "replayed from the counterexample store" in again.counterexample.observation
    assert "replayed" not in first.counterexample.observation
    assert again.replayed and not first.replayed
    assert again.counts == {
        "pass": 0,
        "fail": 1,
        "skip": 0,
        "spec_error": 0,
        "inconclusive": 0,
    }


def test_a_stored_example_that_passes_does_not_stop_the_search(tmp_path):
    store = CounterexampleStore(tmp_path)
    conf = simple(f_ok)
    store.save(conf.spec.hash, "t.py::c::f.same", {"x": 5})
    result = run_one(conf, "f.same", Runner(RunOptions(store=tmp_path)), "t.py::c::f.same")
    assert result.outcome == "passed"
    assert result.counts["pass"] > 1
    assert not result.replayed


def test_a_different_seed_still_finds_the_failure():
    result = run_one(simple(f_bug), "f.same", Runner(RunOptions(seed=12345)))
    assert result.counterexample.inputs == {"x": "1001"}
    assert result.counterexample.seed == 12345


def test_tally_counts_and_keeps_failing_inputs():
    conf = conformance(spec_of(SMALL), impls={"h": lambda x: 0})
    plan = items_by_name(conf)["h.same"].plan
    tally = Tally.for_item("h.same", [])
    for x in range(10):
        tally.add(plan.run({"x": x}), plan)
    assert tally.counts == {"pass": 1, "fail": 9}
    assert tally.failing == 9
    assert len(tally.failing_args) == 6


AGG = """
spec t
fn half(x: u8) -> u8
  aggregate total: sum(v in u8.all: half(v)) <= 20000
  aggregate exact: max(v in u8.all: if half(v) == v // 2 then 0 else 1) <= 0
fn wide(x: u32) -> u32
  aggregate small: all(v in u32.range(0, 1000000): wide(v) == v)
"""

needs_aggregates = pytest.mark.skipif(
    not hasattr(ev, "evaluate_aggregate"), reason="spectest.eval.evaluate_aggregate not landed"
)


@needs_aggregates
def test_aggregate_evaluated_over_every_member():
    calls = []

    def half(x):
        calls.append(x)
        return x // 2

    conf = conformance(spec_of(AGG), impls={"half": half})
    result = run_one(conf, "half.total")
    assert result.kind == "aggregate"
    assert result.mode == "exhaustive"
    assert result.outcome == "passed"
    agg = result.aggregate
    assert agg.value == str(sum(v // 2 for v in range(256)))
    assert agg.bound == "20000"
    assert agg.total == 256 and agg.evaluated == 256 and not agg.sampled


@needs_aggregates
def test_aggregate_failure_reports_the_worst_terms():
    conf = conformance(spec_of(AGG), impls={"half": lambda x: x // 2 if x != 9 else 0})
    result = run_one(conf, "half.exact")
    assert result.outcome == "failed"
    assert result.aggregate.value == "1"
    assert result.aggregate.worst[0] == ("9", "1")
    cx = result.counterexample
    assert cx.inputs == {"v": "every member of u8.all (256 members)"}
    assert cx.observation == "max = 1, against the bound 0"
    text = render_failure(result)
    assert "failed on" not in text
    assert "largest terms:\n  9: 1" in text


@needs_aggregates
def test_aggregate_over_a_large_set_is_sampled():
    calls = []

    def wide(x):
        calls.append(x)
        return x

    conf = conformance(spec_of(AGG), impls={"wide": wide})
    runner = Runner(RunOptions(aggregate_samples=500))
    result = run_one(conf, "wide.small", runner)
    assert result.mode == "sampled"
    assert result.aggregate.sampled
    assert result.aggregate.evaluated == 500
    assert result.aggregate.total == 1000000
    assert len(calls) == 500
    assert result.outcome == "passed"
    again = []
    conf2 = conformance(spec_of(AGG), impls={"wide": lambda x: again.append(x) or x})
    run_one(conf2, "wide.small", Runner(RunOptions(aggregate_samples=500)))
    assert again == calls


def test_aggregate_without_evaluator_support_is_a_spec_error(monkeypatch):
    source = """
    spec t
    fn half(x: u8) -> u8
      ensures r: result <= x
    """
    conf = conformance(spec_of(source), impls={"half": lambda x: x // 2})
    item = items_by_name(conf)["half.r"]
    monkeypatch.delattr(ev, "evaluate_aggregate", raising=False)
    result = Runner().run_aggregate(item, "t::half.r", "")
    assert result.outcome == "error"


def test_runs_are_reproducible():
    source = """
    spec t
    model Box
      observe v: i64
      invariant nonneg: v >= 0
    fn wrap(n: i64) -> Box
      ensures v: result.v == n
    """
    spec = spec_of(source)

    def once():
        conf = conformance(
            spec,
            impls={"wrap": lambda n: {"v": n}},
            models={"Box": ModelBinding(observers={"v": lambda o: o["v"]}, concretize=dict)},
        )
        return run_one(conf, "wrap:Box.nonneg", item_id="t.py::c::wrap:Box.nonneg")

    first, second = once(), once()
    assert first.counterexample.inputs == second.counterexample.inputs
    assert first.counts == second.counts
