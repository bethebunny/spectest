"""Partitions and coverage, exhaustive runs, aggregates, the failure store, explicit
examples, defaults and generics."""

from __future__ import annotations

import time
from pathlib import Path

import pytest
from support import load

SPEC = """\
spec search

fn runimpls.ident(x: i32) -> i32
  partition x
    negative = i32.range(-2147483648, 0)
    zero      = {0}
    positive  = i32.range(1, 2147483648)
  ensures same_value: result == x

fn runimpls.first_or_none(xs: list<i32>) -> option<i32>
  partition xs
    empty  = len(xs) == 0
    single = len(xs) == 1
    many   = len(xs) > 1
  ensures head: len(xs) > 0 implies unwrap(result) == xs[0]

fn runimpls.f16_id(x: f16) -> f16
  ensures bits: same(result, x)
  aggregate no_error: sum(v in f16.finite: qe(runimpls.f16_id(v), v)) <= 0
  aggregate exact: all(v in f16.finite: same(runimpls.f16_id(v), v))

fn runimpls.f16_subnormal_to_zero(x: f16) -> f16
  ensures bits: same(result, x)
  aggregate no_error: sum(v in f16.finite: qe(runimpls.f16_subnormal_to_zero(v), v)) <= 0

fn runimpls.f32_id(x: f32) -> f32
  ensures bits: same(result, x)
  aggregate no_error: sum(v in f32.finite: qe(runimpls.f32_id(v), v)) <= 0

fn runimpls.half(x: i32) -> i32
  requires x > -1000 and x < 1000
  may_raise ValueError when x % 2 != 0
  ensures halved: result * 2 == x
  aggregate budget: sum(v in i32.range(0, 10): runimpls.half(v)) <= 100
  aggregate too_small: sum(v in i32.range(0, 10): runimpls.half(v)) <= 5
  aggregate widest: max(v in i32.range(0, 10): runimpls.half(v)) < 4
  aggregate none_negative: all(v in i32.range(0, 10): runimpls.half(v) >= 0)

fn runimpls.rare_bug(x: i32) -> i32
  ensures same_value: result == x

fn runimpls.ident_plus_one_from_five(x: i32) -> i32
  ensures same_value: result == x

fn runimpls.repeat(s: string, n: i32 = 2) -> string
  requires n >= 0 and n < 5
  ensures length: len(result) == len(s) * n

fn runimpls.repeat_bug(s: string, n: i32 = 2) -> string
  requires n >= 0 and n < 5
  ensures length: len(result) == len(s) * n

fn runimpls.ident_generic<T: Eq>(x: T) -> T
  ensures same_value: result == x

fn runimpls.ident_generic_bug<T: Eq>(x: T) -> T
  ensures same_value: result == x
"""


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("search"), SPEC)
    yield loaded
    loaded.close()


def test_coverage_counts_each_partition_class(spec):
    r = spec.run("runimpls.ident", max_examples=300)
    assert r.passed_all(), r.data
    c = r["runimpls.ident.same_value"]
    assert set(c["coverage"]) == {"x: negative", "x: zero", "x: positive"}
    assert sum(c["coverage"].values()) == c["counts"]["pass"] == r.examples == 300
    # Classes are drawn evenly, not by their size: zero is as likely as the others.
    for count in c["coverage"].values():
        assert 70 <= count <= 130


def test_predicate_classes_steer_generation(spec):
    r = spec.run("runimpls.first_or_none", max_examples=300)
    assert r.passed_all(), r.data
    cov = r["runimpls.first_or_none.head"]["coverage"]
    assert set(cov) == {"xs: empty", "xs: single", "xs: many"}
    assert all(n > 20 for n in cov.values()), cov


def test_the_partition_of_a_counterexample_is_named(spec):
    r = spec.run("runimpls.ident_plus_one_from_five", max_examples=100)
    assert r.cx("runimpls.ident_plus_one_from_five.same_value")["partitions"] == {}


def test_an_f16_function_runs_every_input(spec):
    r = spec.run("runimpls.f16_id")
    assert r.mode == "exhaustive"
    assert r.examples == 65536 and r.invalid == 0
    assert r.passed_all(), r.data
    assert r["runimpls.f16_id.bits"]["mode"] == "exhaustive"
    assert r["runimpls.f16_id.bits"]["counts"]["pass"] == 65536


def test_an_exhaustive_run_counts_every_failing_input(spec):
    r = spec.run("runimpls.f16_subnormal_to_zero")
    assert r.mode == "exhaustive"
    c = r["runimpls.f16_subnormal_to_zero.bits"]
    # The nonzero subnormals of f16: 1023 of each sign.
    assert c["counts"]["fail"] == 2046
    assert c["failing_inputs"] == 2046
    assert c["counts"]["pass"] == 65536 - 2046
    cx = r.cx("runimpls.f16_subnormal_to_zero.bits")
    # The smallest failing index: the first subnormal, in bit-pattern order.
    assert cx["inputs"]["x"] == "6e-08"
    assert "result = 0" in cx["observation"]


def test_the_search_is_exhaustive_only_within_the_limit(spec):
    r = spec.run("runimpls.f16_id", exhaustive_limit=1000, max_examples=50)
    assert r.mode == "search" and r.examples == 50
    assert r.passed_all()


def test_an_aggregate_over_a_whole_set(spec):
    r = spec.run("runimpls.f16_id")
    for name in ("no_error", "exact"):
        c = r["runimpls.f16_id." + name]
        assert c["kind"] == "aggregate"
        assert c["counts"]["pass"] == 1 and c["counts"]["fail"] == 0
        assert c["mode"] == "exhaustive"
        assert c["aggregate"]["total"] == 63488
        assert c["aggregate"]["evaluated"] == 63488 and c["aggregate"]["skipped"] == 0
        assert not c["aggregate"]["sampled"]


def test_a_failing_aggregate_shows_the_worst_terms(spec):
    r = spec.run("runimpls.f16_subnormal_to_zero")
    c = r["runimpls.f16_subnormal_to_zero.no_error"]
    assert c["counts"]["fail"] == 1
    agg = c["aggregate"]
    assert agg["total"] == 63488 and agg["evaluated"] == 63488
    assert agg["value"] != "0" and agg["bound"] == "0"
    assert len(agg["worst"]) == 5
    cx = c["counterexample"]
    assert cx["inputs"]["v"].startswith("every member of f16.finite (63488 members)")
    assert cx["observation"].startswith("sum = ")


def test_a_large_set_is_sampled(spec):
    r = spec.run("runimpls.f32_id", max_examples=20, aggregate_samples=1000)
    c = r["runimpls.f32_id.no_error"]
    assert c["counts"]["pass"] == 1
    assert c["mode"] == "sampled"
    assert c["aggregate"]["sampled"]
    assert c["aggregate"]["evaluated"] == 1000
    assert c["aggregate"]["total"] > 4_000_000_000


def test_aggregate_terms_that_raise_are_skipped_and_counted(spec):
    r = spec.run("runimpls.half", max_examples=20)
    budget = r["runimpls.half.budget"]
    assert budget["counts"]["pass"] == 1
    assert budget["aggregate"]["evaluated"] == 5 and budget["aggregate"]["skipped"] == 5
    assert budget["aggregate"]["value"] == "10"
    too_small = r["runimpls.half.too_small"]
    assert too_small["counts"]["fail"] == 1
    assert too_small["counterexample"]["observation"] == "sum = 10, against the bound 5"
    assert [w[0] for w in too_small["aggregate"]["worst"]] == ["8", "6", "4", "2"]
    widest = r["runimpls.half.widest"]
    assert widest["counts"]["fail"] == 1 and widest["aggregate"]["value"] == "4"
    assert widest["counts"]["pass"] == 0
    every = r["runimpls.half.none_negative"]
    assert every["counts"]["pass"] == 1


def test_a_failure_is_stored_and_replayed_first(spec, tmp_path):
    store = str(tmp_path / "store")
    first = spec.run("runimpls.rare_bug", seed=3, max_examples=5000, store=store)
    clause = "runimpls.rare_bug.same_value"
    assert first.failed() == [clause]
    assert first.mode == "search" and not first[clause]["replayed"]
    cx = first.cx(clause)
    assert int(cx["inputs"]["x"]) % 997 == 5
    assert list(Path(store).iterdir())
    # One example from another seed would not find a bug this rare; the store does.
    second = spec.run("runimpls.rare_bug", seed=99, max_examples=1, store=store)
    assert second.mode == "replay"
    assert second.failed() == [clause]
    assert second[clause]["replayed"]
    assert second.cx(clause)["inputs"] == cx["inputs"]
    # Without the store the same single example passes.
    third = spec.run("runimpls.rare_bug", seed=99, max_examples=1)
    assert third.passed_all() and third.mode == "search"


def test_the_store_keeps_each_instantiation_apart(spec, tmp_path):
    store = str(tmp_path / "store")
    clause = "runimpls.ident_generic_bug.same_value"
    first = spec.run("runimpls.ident_generic_bug", instantiation={"T": "i64"}, max_examples=3000, store=store)
    assert first.failed() == [clause]
    # The failure stored for i64 is not replayed for i32.
    other = spec.run("runimpls.ident_generic_bug", instantiation={"T": "i32"}, seed=99, max_examples=1, store=store)
    assert other.passed_all() and other.mode == "search"
    again = spec.run("runimpls.ident_generic_bug", instantiation={"T": "i64"}, seed=99, max_examples=1, store=store)
    assert again.mode == "replay"


def test_explicit_examples_are_judged_first_and_kept_as_given(spec):
    r = spec.run("runimpls.ident_plus_one_from_five", examples=[{"x": 9}], max_examples=1)
    cx = r.cx("runimpls.ident_plus_one_from_five.same_value")
    assert cx["inputs"] == {"x": "9"}
    assert cx["observation"] == "result = 10"
    r = spec.run("runimpls.ident", examples=[{"x": 2}], max_examples=5)
    assert r.passed_all()
    # The explicit example is judged besides the examples of the search.
    assert r["runimpls.ident.same_value"]["counts"]["pass"] == 6


def test_a_bad_explicit_example_is_a_spec_error(spec):
    r = spec.run("runimpls.ident_plus_one_from_five", examples=[{"y": 9}])
    assert r.spec_errors()
    assert "no value for x" in r.spec_errors()[0]


def test_a_parameter_default_is_filled_in_and_shown(spec):
    assert spec.run("runimpls.repeat", max_examples=200).passed_all()
    r = spec.run("runimpls.repeat_bug", max_examples=500)
    cx = r.cx("runimpls.repeat_bug.length")
    assert cx["inputs"]["n"] == "4"
    r = spec.run("runimpls.repeat", examples=[{"s": "ab"}])
    assert r.passed_all()


def test_a_generic_declaration_takes_its_type_arguments(spec):
    item = next(i for i in spec.items() if i["clause_id"] == "runimpls.ident_generic.same_value")
    assert item["tparams"] == ["T"]
    r = spec.run("runimpls.ident_generic", instantiation={"T": "i64"})
    assert r.passed_all()
    assert r["runimpls.ident_generic.same_value"]["instantiation"] == {"T": "i64"}
    r = spec.run("runimpls.ident_generic", instantiation={"T": "string"}, max_examples=30)
    assert r.passed_all()
    r = spec.run("runimpls.ident_generic_bug", instantiation={"T": "i8"}, max_examples=300)
    assert r.failed() == ["runimpls.ident_generic_bug.same_value"]
    assert r.cx("runimpls.ident_generic_bug.same_value")["inputs"] == {"x": "3"}
    with pytest.raises(Exception, match="needs a type for T"):
        spec.run("runimpls.ident_generic")


def test_an_unknown_declaration_is_an_error(spec):
    with pytest.raises(Exception, match="no declaration"):
        spec.run("runimpls.nothing")


def test_host_overhead_per_example(spec, capsys):
    """The cost of one example of a trivial function, driver call included."""
    spec.run("runimpls.ident", max_examples=200)
    n = 10_000
    started = time.perf_counter()
    r = spec.run("runimpls.ident", max_examples=n)
    elapsed = time.perf_counter() - started
    assert r.examples == n
    per_example = elapsed / n * 1e6
    with capsys.disabled():
        print(f"\nhost overhead: {per_example:.1f} us per example (target 50)")
    assert per_example < 500
