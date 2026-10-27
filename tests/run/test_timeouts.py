"""A call past the driver's time limit leaves its example inconclusive, never failed."""

from __future__ import annotations

import pytest
from support import load
from test_stateful import PEEK, spec_text

from spectest.driver import Driver

SPEC = """\
spec timeouts

fn runimpls.stall_at_seven(x: u8) -> u8
  ensures same: result == x

fn runimpls.ident_u8(x: u8) -> u8
  ensures same: result == x
  relates stalls: runimpls.stall_at_seven(x) == x
"""

LIMIT = 0.2


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("timeouts"), SPEC, Driver(timeout=LIMIT))
    yield loaded
    loaded.close()


def test_an_example_that_times_out_judges_nothing(spec):
    r = spec.run("runimpls.stall_at_seven")
    assert r.failed() == [] and r.spec_errors() == [], r.data
    assert r.mode == "exhaustive"
    for clause in (
        "runimpls.stall_at_seven.same",
        "runimpls.stall_at_seven#type",
        "runimpls.stall_at_seven#raises",
    ):
        counts = r.counts(clause)
        assert counts["pass"] == 255
        assert counts["inconclusive"] == 1
        assert counts["skip"] == 0


def test_a_planned_call_that_times_out_makes_only_its_clause_inconclusive(spec):
    r = spec.run("runimpls.ident_u8")
    assert r.failed() == [] and r.spec_errors() == [], r.data
    assert r.counts("runimpls.ident_u8.stalls") == {
        "pass": 255,
        "fail": 0,
        "skip": 0,
        "spec_error": 0,
        "inconclusive": 1,
    }
    assert r.counts("runimpls.ident_u8.same")["inconclusive"] == 0
    assert r.counts("runimpls.ident_u8.same")["pass"] == 256


def test_a_step_that_times_out_ends_its_sequence(tmp_path):
    spec = load(
        tmp_path, spec_text("stateimpls.StallsOnPop", extra=PEEK), Driver(timeout=LIMIT)
    )
    try:
        r = spec.run(
            "stateimpls.StallsOnPop", instantiation={"T": "i64"}, max_examples=8
        )
    finally:
        spec.close()
    assert r.failed() == [] and r.spec_errors() == [], r.data
    assert r.counts("stateimpls.StallsOnPop.pop.value")["inconclusive"] > 0
    assert r.counts("stateimpls.StallsOnPop.append.items")["inconclusive"] == 0
