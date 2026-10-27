"""Shrinking in the runner: spec errors, and the stateful list argument."""

from __future__ import annotations

import re

import pytest

from support import load

SPEC = """\
spec shrinking

fn runimpls.ident(x: i32) -> i32
  ensures lookup: [10, 20, 30][x] > 0

fn runimpls.small_u8(x: u16) -> u8
  ensures two_errors: (if x > 0 then [10, 20, 30][x] else 100 // x) > 0

fn runimpls.first_or_none(xs: list<i32>) -> option<i32>
  ensures at_five: xs[5] > 0
"""


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("shrinking"), SPEC)
    yield loaded
    loaded.close()


def errors_of(r):
    out = []
    for e in r.spec_errors():
        message, example = e.split("\nexample: ")
        out.append((message, example))
    return out


def test_a_spec_error_is_reported_with_a_shrunk_input(spec):
    r = spec.run("runimpls.ident", max_examples=300)
    errs = errors_of(r)
    assert len(errs) == 1, r.spec_errors()
    message, example = errs[0]
    assert example == "x = -1", errs


def test_a_list_spec_error_shrinks_the_list(spec):
    r = spec.run("runimpls.first_or_none", max_examples=300)
    errs = errors_of(r)
    assert errs, r.data
    # Every list shorter than six raises the same index error, up to its numbers, so
    # the shrunk input is the empty list.
    assert [example for _, example in errs] == ["xs = []"], errs


def test_two_spec_error_messages_are_each_kept_and_shrunk(spec):
    r = spec.run("runimpls.small_u8", max_examples=300)
    errs = errors_of(r)
    examples = sorted(example for _, example in errs)
    assert examples == ["x = 0", "x = 3"], errs
    assert len({message for message, _ in errs}) == 2


def test_the_stateful_leaky_case_ends_with_short_list_arguments(tmp_path):
    from test_stateful import run, steps_of

    longest = 0
    for seed in range(1, 9):
        r = run(tmp_path, "Leaky", seed=seed, max_examples=300)
        assert r.failed() == ["stateimpls.Leaky.pop#2"]
        for step in steps_of(r.cx("stateimpls.Leaky.pop#2")):
            for lst in re.findall(r"\[([^\]]*)\]", step):
                longest = max(longest, len([e for e in lst.split(",") if e.strip()]))
    assert longest <= 3, longest
