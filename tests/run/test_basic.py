"""Plain functions: verdicts, requires, raises, may_raise, the built-in clauses."""

from __future__ import annotations

import pytest
from support import load

SPEC = """\
spec basic

fn runimpls.clamp(x: i16, lo: i16, hi: i16) -> i16
  requires lo <= hi
  ensures in_range: lo <= result and result <= hi
  ensures identity_inside: lo <= x and x <= hi implies result == x

fn runimpls.clamp_no_lower_bound(x: i16, lo: i16, hi: i16) -> i16
  requires lo <= hi
  ensures in_range: lo <= result and result <= hi

fn runimpls.clamp_identity_bug(x: i16, lo: i16, hi: i16) -> i16
  requires lo <= hi
  ensures in_range: lo <= result and result <= hi
  ensures identity_inside: lo <= x and x <= hi implies result == x

fn runimpls.ident_plus_one_from_five(x: i32) -> i32
  ensures same_value: result == x

fn runimpls.tag(x: i32) -> "small" | "large"
  ensures label: x < 10 implies result == "small"

fn runimpls.bad_tag(x: i32) -> "small" | "large"
  ensures label: x < 10 implies result == "small"

fn runimpls.first_or_none(xs: list<i32>) -> option<i32>
  ensures empty: len(xs) == 0 implies is_none(result)
  ensures head: len(xs) > 0 implies unwrap(result) == xs[0]

fn runimpls.pair_swap(p: (i32, string)) -> (string, i32)
  ensures swapped: result.0 == p.1 and result.1 == p.0
"""


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("basic"), SPEC)
    yield loaded
    loaded.close()


def test_a_correct_implementation_passes_every_clause(spec):
    r = spec.run("runimpls.clamp")
    assert r.passed_all(), r.data
    assert r.mode == "search"
    assert r.examples == 100
    assert set(r.clauses) == {
        "runimpls.clamp.in_range",
        "runimpls.clamp.identity_inside",
        "runimpls.clamp#type",
        "runimpls.clamp#raises",
    }
    for c in r.clauses.values():
        assert c["counts"]["pass"] > 0
        assert c["counterexample"] is None
        assert c["mode"] == "hypothesis"


def test_requires_filters_inputs(spec):
    r = spec.run("runimpls.clamp")
    # About half of the random bounds are the wrong way round.
    assert r.invalid > 0
    c = r["runimpls.clamp.in_range"]
    assert c["skips"]["requires"] == r.invalid
    assert c["counts"]["skip"] == r.invalid
    assert c["counts"]["pass"] == r.examples


def test_a_seeded_bug_fails_the_right_clause_with_a_shrunk_counterexample(spec):
    r = spec.run("runimpls.clamp_no_lower_bound")
    assert r.failed() == ["runimpls.clamp_no_lower_bound.in_range"]
    cx = r.cx("runimpls.clamp_no_lower_bound.in_range")
    inputs = {k: int(v) for k, v in cx["inputs"].items()}
    # Shrunk: lo and hi are as small as the failure allows.
    assert inputs["x"] < inputs["lo"] <= inputs["hi"]
    assert abs(inputs["lo"]) <= 2 and abs(inputs["x"]) <= 2
    assert cx["observation"] == f"result = {min(inputs['x'], inputs['hi'])}"
    assert cx["seed"] == 1
    assert "runimpls.clamp_no_lower_bound.in_range" in cx["reproduce"]
    assert ["lo <= result", "false"] in cx["explanation"] or cx["explanation"]


def test_a_conditional_bug_is_found_and_the_other_clauses_pass(spec):
    r = spec.run("runimpls.clamp_identity_bug")
    assert r.failed() == ["runimpls.clamp_identity_bug.identity_inside"]
    cx = r.cx("runimpls.clamp_identity_bug.identity_inside")
    x, lo, hi = (int(cx["inputs"][k]) for k in ("x", "lo", "hi"))
    assert lo < x == hi
    # Several choices must move together to shrink further, so only the size is bounded.
    assert abs(x) <= 100


def test_the_counterexample_is_minimal_for_a_threshold_bug(spec):
    r = spec.run("runimpls.ident_plus_one_from_five", max_examples=200)
    cx = r.cx("runimpls.ident_plus_one_from_five.same_value")
    assert 5 <= int(cx["inputs"]["x"]) <= 7
    assert cx["observation"].startswith("result = ")


def test_string_literal_unions(spec):
    assert spec.run("runimpls.tag").passed_all()
    r = spec.run("runimpls.bad_tag")
    # "medium" is not in the union: #type fails; ensures clauses skip those examples.
    assert r.failed() == ["runimpls.bad_tag#type"]
    assert "medium" in r.cx("runimpls.bad_tag#type")["observation"]
    assert r["runimpls.bad_tag.label"]["skips"]["wrong type"] > 0


def test_options_lists_and_tuples(spec):
    assert spec.run("runimpls.first_or_none").passed_all()
    assert spec.run("runimpls.pair_swap").passed_all()


def test_the_items_of_a_spec(spec):
    items = spec.items()
    by_id = {i["clause_id"]: i for i in items}
    assert "runimpls.clamp.in_range" in by_id
    item = dict(by_id["runimpls.clamp.in_range"])
    assert item.pop("file").endswith(".spec")
    assert item == {
        "decl": "runimpls.clamp",
        "clause_id": "runimpls.clamp.in_range",
        "kind": "ensures",
        "text": "ensures in_range: lo <= result and result <= hi",
        "line": 5,
        "tparams": [],
    }
    assert by_id["runimpls.clamp#type"]["kind"] == "type"
    assert by_id["runimpls.clamp#raises"]["kind"] == "raises"
    assert not any(i["kind"] == "requires" for i in items)
    # In source order.
    ids = [i["clause_id"] for i in items if i["decl"] == "runimpls.clamp"]
    assert ids[:2] == ["runimpls.clamp.in_range", "runimpls.clamp.identity_inside"]


def test_the_same_seed_gives_the_same_run(spec):
    a = spec.run("runimpls.clamp_no_lower_bound", seed=7)
    b = spec.run("runimpls.clamp_no_lower_bound", seed=7)
    assert a.cx("runimpls.clamp_no_lower_bound.in_range") == b.cx("runimpls.clamp_no_lower_bound.in_range")
    assert a["runimpls.clamp_no_lower_bound.in_range"]["counts"] == b["runimpls.clamp_no_lower_bound.in_range"]["counts"]
