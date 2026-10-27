"""Models built through `build`, observers, modifies, old, and relates with planned
calls."""

from __future__ import annotations

import pytest

import runimpls
from support import load

SPEC = """\
spec models

model runimpls.Box
  observe items: list<i32>
  observe size: int
  observe get(i: int): option<i32>
  build runimpls.make_box(items: list<i32>)
  invariant size_matches: size == len(items)

model runimpls.Counter
  observe value: i32
  build runimpls.make_counter(value: i32)

model runimpls.BadBox
  observe items: list<i32>
  observe size: int
  invariant size_matches: size == len(items)

fn runimpls.new_bad_box(n: u8) -> runimpls.BadBox
  ensures anything: true

fn runimpls.append(b: runimpls.Box, x: i32)
  modifies b
  ensures grew: b.items == old(b.items) + [x]

fn runimpls.append_to_both(a: runimpls.Box, b: runimpls.Box, x: i32)
  modifies a
  ensures grew: a.items == old(a.items) + [x]

fn runimpls.append_without_listing(b: runimpls.Box, x: i32)
  ensures nothing_promised: true

fn runimpls.sum_box(b: runimpls.Box) -> i64
  ensures total: result == sum(x in b.items: x)
  ensures first: len(b.items) > 0 implies b.get(0) == some(b.items[0])

fn runimpls.concat(a: runimpls.Box, b: runimpls.Box) -> runimpls.Box
  ensures joined: result.items == a.items + b.items

fn runimpls.concat_in_place(a: runimpls.Box, b: runimpls.Box) -> runimpls.Box
  ensures joined: result.items == old(a.items) + old(b.items)

fn runimpls.not_a_box(items: list<i32>) -> runimpls.Box
  ensures anything: true

fn runimpls.bump(c: runimpls.Counter)
  requires c.value < 1000000 and c.value > -1000000
  modifies c
  ensures plus_one: c.value == old(c.value) + 1

fn runimpls.bump_twice(c: runimpls.Counter)
  requires c.value < 1000000 and c.value > -1000000
  modifies c
  ensures plus_one: c.value == old(c.value) + 1

fn runimpls.new_counter(start: i32) -> runimpls.Counter
  ensures starts_at: result.value == start

fn runimpls.new_counter_off_by_one(start: i16) -> runimpls.Counter
  ensures starts_at: result.value == start

fn runimpls.count_up(c: runimpls.Counter, n: i16)
  requires c.value < 1000000 and c.value > -1000000
  modifies c
  ensures added: c.value == old(c.value) + n

fn runimpls.negate_asymmetric(x: i32) -> i32
  requires x >= -9 and x <= 9
  relates involution: runimpls.negate_asymmetric(runimpls.negate_asymmetric(x)) == x

fn runimpls.negate(x: i32) -> i32
  requires x > -1000000 and x < 1000000
  relates involution: runimpls.negate(runimpls.negate(x)) == x

fn runimpls.half(x: i32) -> i32
  requires x > -1000 and x < 1000
  may_raise ValueError when x % 2 != 0
  ensures halved: result * 2 == x
  relates odd_neighbour: runimpls.half(x + 1) * 2 == x + 1
  relates doubled: runimpls.half(2 * x) == x

fn runimpls.Box.get(self, i: int) -> option<i32>
  ensures in_range: 0 <= i and i < len(self.items) implies unwrap(result) == self.items[i]
  ensures out_of_range: (i < 0 or i >= len(self.items)) implies is_none(result)

fn runimpls.Box.size(self) -> int
  ensures length: result == len(self.items)

fn runimpls.Box.get_wrong(self, i: int) -> option<i32>
  ensures in_range: 0 <= i and i < len(self.items) implies unwrap(result) == self.items[i]

fn runimpls.counted(x: i32) -> i32
  relates twice: runimpls.counted(x) == runimpls.counted(x)
"""


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("models"), SPEC)
    yield loaded
    loaded.close()


def test_a_model_built_through_build_is_observed(spec):
    r = spec.run("runimpls.sum_box")
    assert r.passed_all(), r.data
    assert r.invalid == 0


def test_the_invariant_of_a_returned_model_is_an_item(spec):
    items = [i["clause_id"] for i in spec.items() if i["decl"] == "runimpls.concat"]
    assert "runimpls.concat:runimpls.Box.size_matches" in items
    r = spec.run("runimpls.concat")
    assert r.passed_all(), r.data
    assert r["runimpls.concat:runimpls.Box.size_matches"]["counts"]["pass"] == r.examples


def test_modifies_allows_the_listed_parameter_to_change(spec):
    r = spec.run("runimpls.append")
    assert r.passed_all(), r.data
    # modifies is an item of its function; so is the model's invariant on b.
    assert r["runimpls.append#1"]["kind"] == "modifies"
    assert r["runimpls.append#1"]["counts"]["pass"] == r.examples


def test_modifies_catches_a_mutated_parameter(spec):
    r = spec.run("runimpls.append_to_both")
    assert r.failed() == ["runimpls.append_to_both#1"]
    cx = r.cx("runimpls.append_to_both#1")
    assert r["runimpls.append_to_both#1"]["kind"] == "modifies"
    assert "runimpls.Box {" in cx["inputs"]["b"]
    assert r["runimpls.append_to_both#1"]["spec_errors"] == []
    assert cx["observation"].count("b before = runimpls.Box {") == 1
    assert cx["observation"].count("b after  = runimpls.Box {") == 1
    # Shrunk: a one-element or empty box and a small x.
    assert abs(int(cx["inputs"]["x"])) <= 20


def test_an_unlisted_mutation_fails_the_built_in_frame_clause(spec):
    r = spec.run("runimpls.append_without_listing")
    assert r.failed() == ["runimpls.append_without_listing#frame"]
    assert r["runimpls.append_without_listing#frame"]["kind"] == "frame"


def test_a_returned_alias_is_a_mutation_of_the_argument(spec):
    r = spec.run("runimpls.concat_in_place")
    assert "runimpls.concat_in_place#frame" in r.failed()
    # old(a.items) was taken before the call, so the ensures clause itself holds.
    assert "runimpls.concat_in_place.joined" not in r.failed()


def test_a_result_that_is_not_a_handle_fails_the_type_clause(spec):
    r = spec.run("runimpls.not_a_box")
    assert r.failed() == ["runimpls.not_a_box#type"]
    assert "expected runimpls.Box, got int 12" in r.cx("runimpls.not_a_box#type")["observation"]


def test_old_is_the_state_before_the_call(spec):
    assert spec.run("runimpls.bump").passed_all()
    r = spec.run("runimpls.bump_twice")
    assert r.failed() == ["runimpls.bump_twice.plus_one"]
    cx = r.cx("runimpls.bump_twice.plus_one")
    assert cx["inputs"]["c"].startswith("runimpls.Counter { value: ")
    before = int(cx["inputs"]["c"].split("value: ")[1].split(" ")[0])
    assert ["old(c.value) + 1", str(before + 1)] in cx["explanation"]
    assert ["c.value", str(before + 2)] in cx["explanation"]
    assert abs(before) <= 1


def test_old_with_a_scalar_argument(spec):
    assert spec.run("runimpls.count_up").passed_all()


def test_a_returned_model_is_observed_for_the_clauses(spec):
    assert spec.run("runimpls.new_counter").passed_all()
    r = spec.run("runimpls.new_counter_off_by_one")
    assert r.failed() == ["runimpls.new_counter_off_by_one.starts_at"]
    cx = r.cx("runimpls.new_counter_off_by_one.starts_at")
    assert cx["observation"].startswith("result = runimpls.Counter { value: ")
    start = int(cx["inputs"]["start"])
    assert ["result.value", str(start + 1)] in cx["explanation"]


def test_relates_with_planned_calls(spec):
    assert spec.run("runimpls.negate").passed_all()
    r = spec.run("runimpls.negate_asymmetric")
    assert r.failed() == ["runimpls.negate_asymmetric.involution"]
    cx = r.cx("runimpls.negate_asymmetric.involution")
    assert abs(int(cx["inputs"]["x"])) <= 9
    assert any("negate_asymmetric(" in e[0] for e in cx["explanation"])


def test_a_planned_call_that_raises_or_is_outside_requires_skips(spec):
    r = spec.run("runimpls.half")
    assert r.failed() == [] and r.spec_errors() == [], r.data
    odd = r["runimpls.half.odd_neighbour"]
    # The base call returns only for even x, so x + 1 is odd and the planned call raises.
    assert odd["counts"]["pass"] == 0
    assert odd["skips"]["planned call"] > 0
    assert sum(odd["skips"].values()) == odd["counts"]["skip"]
    doubled = r["runimpls.half.doubled"]
    # half(2 * x) is outside requires for |x| >= 500, and is judged below that.
    assert doubled["counts"]["pass"] > 0
    assert doubled["skips"]["planned call"] > 0


def test_identical_planned_calls_are_made_once(spec):
    runimpls.CALLS.clear()
    r = spec.run("runimpls.counted", max_examples=40)
    assert r.passed_all(), r.data
    # One call per example for the clauses, plus one planned call (the two are identical).
    assert len(runimpls.CALLS) == 2 * r.examples


def test_a_method_takes_its_receiver_first(spec):
    r = spec.run("runimpls.Box.get", max_examples=200)
    assert r.passed_all(), r.data
    assert r["runimpls.Box.get.in_range"]["counts"]["pass"] == 200
    assert r["runimpls.Box.get#frame"]["counts"]["pass"] == 200


def test_a_property_is_read_through_its_receiver(spec):
    r = spec.run("runimpls.Box.size", max_examples=50)
    assert r.passed_all(), r.data


def test_a_method_the_driver_cannot_resolve_is_a_spec_error(spec):
    r = spec.run("runimpls.Box.get_wrong", max_examples=100)
    assert r.failed() == []
    assert any("no attribute get_wrong" in e for e in r.spec_errors())


def test_a_model_invariant_is_judged_on_the_returned_handle(spec):
    r = spec.run("runimpls.new_bad_box", max_examples=300)
    clause = "runimpls.new_bad_box:runimpls.BadBox.size_matches"
    assert r.failed() == [clause]
    cx = r.cx(clause)
    assert int(cx["inputs"]["n"]) == 3
    assert cx["observation"] == "result = runimpls.BadBox { items: [0, 0, 0], size: 4 }"
    assert ["result", "runimpls.BadBox { items: [0, 0, 0], size: 4 }"] in cx["explanation"]
    assert ["len(items)", "3"] in cx["explanation"] or ["size", "4"] in cx["explanation"]
