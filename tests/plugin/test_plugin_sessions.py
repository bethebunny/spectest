"""Session-level plugin options: the counterexample store's place, profiles, and runs split
over pytest-xdist workers (merged reports)."""

from __future__ import annotations

import json
import textwrap

import hypothesis.stateful
import pytest

import spectest.generate
import spectest.runtime.runner
import spectest.runtime.stateful
from spectest.pytest_plugin import DEV_EXAMPLES, STATE
from spectest.runtime.report import load_reports

pytest_plugins = ["pytester"]

# In-process runs drop the modules they import; these stay loaded (as in test_plugin_pytester).
PRELOADED = (
    hypothesis.stateful,
    spectest.generate,
    spectest.runtime.runner,
    spectest.runtime.stateful,
)

SPEC = """
spec tiny
fn bad(xs: list<i64>) -> i64
  requires len(xs) > 0
  ensures first: result == xs[0]
fn ok(x: i64) -> i64
  ensures same: result == x
"""

TEST = """
import spectest

test_tiny = spectest.conformance(
    "tiny.spec",
    impls={"bad": lambda xs: xs[-1], "ok": lambda x: x},
    expect_fail={"bad.first"},
    max_examples=200,
)
"""


@pytest.fixture
def project(pytester: pytest.Pytester) -> pytest.Pytester:
    pytester.makefile(".spec", tiny=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(test_tiny=TEST)
    return pytester


def results(project: pytest.Pytester, *args: str) -> dict[str, object]:
    project.runpytest(
        "-p",
        "no:cacheprovider",
        "--spectest-json=r.json",
        "-k",
        "first",
        "--spectest-max-examples=30",
        *args,
    )
    (report,) = load_reports((project.path / "r.json").read_text())
    return {r.clause_id: r for r in report.results}


def test_the_store_can_move_or_be_turned_off(pytester: pytest.Pytester) -> None:
    def state(*args: str) -> object:
        return pytester.parseconfigure(*args).stash[STATE]

    assert state().store == pytester.path / ".spectest"
    moved = state("--spectest-store=elsewhere")
    assert moved.store == pytester.path / "elsewhere"
    assert moved.runner.store.root == pytester.path / "elsewhere"
    off = state("--spectest-store=elsewhere", "--spectest-no-store")
    assert off.store is None and off.runner.store is None


@pytest.mark.slow
def test_profiles_choose_the_run_options_and_options_win(pytester: pytest.Pytester) -> None:
    def options(*args: str) -> object:
        return pytester.parseconfigure(*args).stash[STATE].runner.options

    ci = options()
    assert (ci.max_examples, ci.exhaustive_limit, ci.aggregate_samples) == (None, None, 10_000)
    dev = options("--spectest-profile=dev")
    assert (dev.max_examples, dev.exhaustive_limit, dev.aggregate_samples) == (
        DEV_EXAMPLES,
        4096,
        1000,
    )
    mixed = options("--spectest-profile=dev", "--spectest-max-examples=5")
    assert (mixed.max_examples, mixed.exhaustive_limit) == (5, 4096)
    pytester.makeini("[pytest]\nspectest_profile = dev\n")
    assert options().max_examples == DEV_EXAMPLES
    assert options("--spectest-profile=ci").max_examples is None
    pytester.makeini("[pytest]\nspectest_profile = quick\n")
    with pytest.raises(pytest.UsageError, match="the profiles are ci, dev"):
        options()


def test_a_dev_run_finds_an_easy_bug_and_stores_it_where_told(project: pytest.Pytester) -> None:
    dev = results(project, "--spectest-profile=dev", "--spectest-store=elsewhere")
    assert dev["bad.first"].failed
    assert dev["bad.first"].total <= DEV_EXAMPLES + 1
    assert list((project.path / "elsewhere" / "counterexamples").rglob("*.json"))
    assert not (project.path / ".spectest").exists()


@pytest.mark.slow
def test_an_xdist_run_writes_the_reports_of_a_serial_run(project: pytest.Pytester) -> None:
    pytest.importorskip("xdist")

    def run(*args: str) -> tuple[list[dict], list[str]]:
        result = project.runpytest_subprocess(
            "-p",
            "no:cacheprovider",
            "--spectest-no-store",
            "--spectest-max-examples=20",
            "--spectest-json=r.json",
            "-k",
            "first or same",
            *args,
        )
        result.assert_outcomes(passed=1, xfailed=1)
        data = json.loads((project.path / "r.json").read_text())
        for report in data:
            for r in report["results"]:
                r["duration"] = 0.0
        summary = [ln for ln in result.outlines if ln.startswith(("test_tiny.py::", "  expected"))]
        return data, summary

    serial, serial_summary = run()
    split, split_summary = run("-n", "2")
    assert split == serial
    assert split_summary == serial_summary
    assert len(serial_summary) == 2
