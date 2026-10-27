"""raises, may_raise, #raises and #type."""

from __future__ import annotations

import pytest

from support import load

SPEC = """\
spec errors

fn runimpls.isqrt(x: i32) -> i32
  raises ValueError when x < 0
  ensures floor: result * result <= x and x < (result + 1) * (result + 1)

fn runimpls.isqrt_never_raises(x: i32) -> i32
  raises ValueError when x < 0
  ensures floor: result * result <= x

fn runimpls.isqrt_raises_too_much(x: i32) -> i32
  raises ValueError when x < 0
  ensures floor: result * result <= x

fn runimpls.isqrt_wrong_error(x: i32) -> i32
  raises ValueError when x < 0
  ensures floor: result * result <= x

fn runimpls.recip_or_zero(x: i32) -> i32
  may_raise ZeroDivisionError when x == 0
  ensures positive_for_small: 0 < x and x <= 1000 implies result > 0

fn runimpls.half(x: i32) -> i32
  requires x > -1000 and x < 1000
  ensures halved: result * 2 == x

fn runimpls.to_text(x: i32) -> i32
  ensures anything: result == x

fn runimpls.too_big_for_u8(x: u8) -> u8
  ensures anything: result >= x

fn runimpls.small_u8(x: i32) -> u8
  ensures low: result == x % 256

fn runimpls.negate(x: i32) -> i32
  ensures neg: result == 0 - x
  raises RuntimeError when x == 0
"""


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("errors"), SPEC)
    yield loaded
    loaded.close()


def test_raises_is_judged_both_ways(spec):
    r = spec.run("runimpls.isqrt")
    assert r.passed_all(), r.data
    assert r["runimpls.isqrt#1"]["kind"] == "raises"
    assert r.counts("runimpls.isqrt#1")["pass"] == r.examples
    # When a raise is due, the ensures clause does not apply.
    assert r["runimpls.isqrt.floor"]["skips"]["raised"] > 0


def test_a_missing_raise_fails_the_raises_clause(spec):
    r = spec.run("runimpls.isqrt_never_raises")
    # The raises clause fails where a raise was due; so does the ensures clause, which
    # meets an input the call should not have returned for, and says so.
    assert r.failed() == ["runimpls.isqrt_never_raises#1", "runimpls.isqrt_never_raises.floor"]
    cx = r.cx("runimpls.isqrt_never_raises#1")
    assert int(cx["inputs"]["x"]) == -1
    assert ["errors that must be raised (R)", "{builtins.ValueError}"] in cx["explanation"]
    assert ["raises builtins.ValueError when x < 0", "true"] in cx["explanation"]
    floor = r.cx("runimpls.isqrt_never_raises.floor")
    assert "note: runimpls.isqrt_never_raises#1 required builtins.ValueError on this input" in floor["observation"]


def test_an_unlisted_raise_fails_the_raises_clause(spec):
    r = spec.run("runimpls.isqrt_raises_too_much", max_examples=3000)
    failed = r.failed()
    assert failed == ["runimpls.isqrt_raises_too_much#1"]
    cx = r.cx(failed[0])
    assert int(cx["inputs"]["x"]) == 0
    assert "raised builtins.ValueError" in cx["observation"]
    assert "maps to builtins.ValueError" in cx["observation"]


def test_an_error_no_clause_admits_fails_the_built_in(spec):
    r = spec.run("runimpls.isqrt_wrong_error")
    assert "runimpls.isqrt_wrong_error#raises" in r.failed()
    cx = r.cx("runimpls.isqrt_wrong_error#raises")
    assert int(cx["inputs"]["x"]) == -1
    assert "builtins.KeyError" in cx["observation"]
    # The raises clause is also broken: ValueError was due and KeyError was raised.
    assert "runimpls.isqrt_wrong_error#1" in r.failed()


def test_may_raise_admits_the_raise(spec):
    r = spec.run("runimpls.recip_or_zero")
    assert r.passed_all(), r.data
    assert r["runimpls.recip_or_zero#raises"]["counts"]["pass"] == r.examples


def test_an_error_without_a_clause_fails_the_built_in(spec):
    # half raises ValueError for odd inputs, and nothing admits that.
    r = spec.run("runimpls.half")
    assert r.failed() == ["runimpls.half#raises"]
    cx = r.cx("runimpls.half#raises")
    assert int(cx["inputs"]["x"]) % 2 == 1 and abs(int(cx["inputs"]["x"])) == 1
    assert r["runimpls.half.halved"]["skips"]["raised"] > 0


def test_a_result_of_the_wrong_type_fails_the_type_clause(spec):
    r = spec.run("runimpls.to_text")
    assert r.failed() == ["runimpls.to_text#type"]
    cx = r.cx("runimpls.to_text#type")
    assert "expected i32, got string" in cx["observation"]
    assert r["runimpls.to_text.anything"]["skips"]["wrong type"] == r.examples


def test_a_value_out_of_range_fails_the_type_clause(spec):
    r = spec.run("runimpls.too_big_for_u8")
    assert r.failed() == ["runimpls.too_big_for_u8#type"]
    cx = r.cx("runimpls.too_big_for_u8#type")
    assert "outside the u8 range 0..255" in cx["observation"]
    assert int(cx["inputs"]["x"]) >= 6


def test_a_correct_narrow_result_passes(spec):
    r = spec.run("runimpls.small_u8")
    assert r.passed_all(), r.data


def test_an_unconditional_raise_clause_with_a_unused_error_condition(spec):
    # RuntimeError is declared for x == 0 but negate never raises: the clause fails there.
    r = spec.run("runimpls.negate")
    assert "runimpls.negate#2" in r.failed()
    assert int(r.cx("runimpls.negate#2")["inputs"]["x"]) == 0
