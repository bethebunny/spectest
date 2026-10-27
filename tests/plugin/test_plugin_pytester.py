"""The pytest plugin, end to end in a scratch project: items, outcomes, reports."""

from __future__ import annotations

import json
import textwrap

import hypothesis.stateful
import pytest
from budget import full

import spectest.generate
import spectest.runtime.runner
import spectest.runtime.stateful
from spectest.pytest_plugin import package_versions, platform_facts
from spectest.runtime.report import load_reports

pytest_plugins = ["pytester"]

# In-process runs drop the modules they import; these stay loaded so that every
# run shares one copy of Hypothesis and of the runtime.
PRELOADED = (
    hypothesis.stateful,
    spectest.generate,
    spectest.runtime.runner,
    spectest.runtime.stateful,
)

SPEC = """
spec demo
error Neg

model Box
  observe v: i64
  invariant nonneg: v >= 0

fn ident(x: i64) -> i64
  partition x
    negative = i64.range(none, 0)
    rest     = i64.range(0, none)
  raises neg: Neg when x < 0
  ensures same: result == x

fn first<T: Eq>(xs: list<T>) -> T
  requires len(xs) > 0
  ensures head: result == xs[0]

fn bad(xs: list<i64>) -> i64
  ensures oops: result == xs[0]

fn wrap(n: i64) -> Box
  ensures v: result.v == n

fn tiny(x: u8) -> u8
  ensures same: result == x
"""

TEST = """
import spectest
from spectest import ModelBinding


class NegError(Exception):
    pass


def ident(x):
    if x < 0:
        raise NegError()
    # x + 1 stays an i64, so that ident.same is the only clause it breaks.
    return x + 1 if 1000 < x < 2**63 - 1 else x


box = ModelBinding(observers={"v": lambda o: o["v"]}, concretize=dict)

test_demo = spectest.conformance(
    "demo.spec",
    impls={
        "ident": ident,
        "first": lambda xs: xs[0],
        "wrap": lambda n: {"v": n},
        "tiny": lambda x: x,
    },
    errors={NegError: "Neg"},
    models={"Box": box},
    instantiate=[{"T": "i64"}, {"T": "string"}],
    expect_fail={"ident.same", "wrap:Box.nonneg"},
    max_examples=50,
)

test_errors = spectest.conformance(
    "demo.spec", impls={"bad": lambda xs: xs[0] if xs else 0}, max_examples=30
)

not_collected = test_demo
"""


@pytest.fixture(autouse=True)
def inner_budgets(request: pytest.FixtureRequest) -> None:
    """The scratch projects run their items under spectest's dev profile in the dev loop."""
    if "pytester" in request.fixturenames and not full():
        request.getfixturevalue("pytester").makeini("[pytest]\nspectest_profile = dev\n")


@pytest.fixture
def project(pytester: pytest.Pytester) -> pytest.Pytester:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(test_demo=TEST)
    return pytester


def test_items_are_named_after_clauses(project: pytest.Pytester) -> None:
    result = project.runpytest("--collect-only", "-q", "-p", "no:cacheprovider")
    ids = [ln for ln in result.outlines if "::" in ln]
    assert ids == [
        "test_demo.py::test_demo::ident.neg",
        "test_demo.py::test_demo::ident.same",
        "test_demo.py::test_demo::ident#type",
        "test_demo.py::test_demo::ident#raises",
        "test_demo.py::test_demo::first[T=i64].head",
        "test_demo.py::test_demo::first[T=i64]#type",
        "test_demo.py::test_demo::first[T=i64]#raises",
        "test_demo.py::test_demo::first[T=string].head",
        "test_demo.py::test_demo::first[T=string]#type",
        "test_demo.py::test_demo::first[T=string]#raises",
        "test_demo.py::test_demo::wrap.v",
        "test_demo.py::test_demo::wrap#type",
        "test_demo.py::test_demo::wrap#raises",
        "test_demo.py::test_demo::wrap:Box.nonneg",
        "test_demo.py::test_demo::tiny.same",
        "test_demo.py::test_demo::tiny#type",
        "test_demo.py::test_demo::tiny#raises",
        "test_demo.py::test_errors::bad.oops",
        "test_demo.py::test_errors::bad#type",
        "test_demo.py::test_errors::bad#raises",
    ]


@pytest.mark.slow
def test_outcomes_xfail_and_spec_errors(project: pytest.Pytester) -> None:
    result = project.runpytest("-v", "-rxs", "-p", "no:cacheprovider")
    outcomes = result.parseoutcomes()
    assert outcomes.get("xfailed") == 2
    assert "failed" not in outcomes
    assert outcomes.get("errors") == 1
    assert outcomes.get("passed") == 17
    result.stdout.fnmatch_lines(
        [
            "*test_demo.py::test_errors::bad.oops SPEC ERROR*",
            "*SPEC ERROR (the spec's or the binding's fault)*",
            "*index 0 is out of range*",
            "XFAIL test_demo.py::test_demo::ident.same - ident.same: x = 1001 -> result = 1002",
            "XFAIL test_demo.py::test_demo::wrap:Box.nonneg - wrap:Box.nonneg: n = -* -> *",
        ]
    )
    assert result.ret == 1


@pytest.mark.slow
def test_spectest_summary_section(project: pytest.Pytester) -> None:
    result = project.runpytest("-p", "no:cacheprovider")
    result.stdout.fnmatch_lines(
        [
            "*= spectest =*",
            "test_demo.py::test_demo (spec demo): 15 passed, 2 expected failures",
            "  expected failure ident.same: x = 1001 -> result = 1002",
            "  expected failure wrap:Box.nonneg: n = -* -> result = Box { v: -* }",
            "test_demo.py::test_errors (spec demo): 2 passed, 1 spec error",
            "  SPEC ERROR bad.oops: *index 0 is out of range*",
        ]
    )


def test_failures_show_the_counterexample_and_how_to_reproduce(
    pytester: pytest.Pytester,
) -> None:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(
        test_fail="""
        import spectest

        test_it = spectest.conformance(
            "demo.spec", impls={"ident": lambda x: x + 1 if x > 1000 else x}, max_examples=50
        )
        """
    )
    result = pytester.runpytest("-p", "no:cacheprovider", "-k", "same", "--spectest-seed=7")
    result.assert_outcomes(failed=1)
    result.stdout.fnmatch_lines(
        [
            "*ident.same (ensures) failed*",
            "*ensures same: result == x*",
            "*inputs:*",
            "*x = 1001*",
            "*observed:*",
            "*result = 1002*",
            "*seed: 7*",
            "*reproduce: uv run pytest 'test_fail.py::test_it::ident.same' --spectest-seed=7*",
        ]
    )
    assert (pytester.path / ".spectest" / "counterexamples").is_dir()
    again = pytester.runpytest("-p", "no:cacheprovider", "-k", "same", "--spectest-seed=7")
    again.assert_outcomes(failed=1)
    again.stdout.fnmatch_lines(["*x = 1001*"])


def test_strict_xfail_fails_when_nothing_fails(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(
        test_xpass="""
        import spectest

        test_it = spectest.conformance(
            "demo.spec", impls={"tiny": lambda x: x}, expect_fail={"tiny.same"}
        )
        """
    )
    result = pytester.runpytest("-p", "no:cacheprovider")
    result.assert_outcomes(failed=1, passed=2)
    result.stdout.fnmatch_lines(
        ["*[[]XPASS(strict)[]] expected to fail: tiny.same, but no example failed*"]
    )


@pytest.mark.slow
def test_report_files(project: pytest.Pytester) -> None:
    result = project.runpytest(
        "-p", "no:cacheprovider", "--spectest-report=out/report.md", "--spectest-json=out/r.json"
    )
    md = (project.path / "out" / "report.md").read_text()
    assert md.startswith("# spectest report: demo")
    assert "`test_demo.py::test_demo::ident.same`" in md
    assert "## Counterexamples" in md
    assert "**SPEC ERROR**" in md
    assert "## Coverage" in md
    assert "| Clause | x: negative | x: rest |" in md
    (report,) = load_reports((project.path / "out" / "r.json").read_text())
    assert report.spec_name == "demo"
    assert len(report.results) == 20
    data = json.loads((project.path / "out" / "r.json").read_text())
    assert data[0]["hypothesis_version"]
    result.stdout.fnmatch_lines(["report written to *report.md", "report written to *r.json"])


def test_an_explicit_file_that_does_not_match_python_files(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(
        explore_demo="""
        import spectest

        test_explore = spectest.conformance("demo.spec", impls={"tiny": lambda x: x})
        """
    )
    found = pytester.runpytest("-p", "no:cacheprovider", "explore_demo.py")
    found.assert_outcomes(passed=3)
    nothing = pytester.runpytest("-p", "no:cacheprovider")
    assert nothing.ret == pytest.ExitCode.NO_TESTS_COLLECTED


def test_conformance_errors_are_collection_errors(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(
        test_broken="""
        import spectest

        test_it = spectest.conformance("demo.spec", impls={"idnet": abs})
        """
    )
    result = pytester.runpytest("-p", "no:cacheprovider")
    assert result.ret == pytest.ExitCode.INTERRUPTED
    result.stdout.fnmatch_lines(
        ["*ConformanceError*", "*'idnet' is not a function of spec demo; did you mean 'ident'?*"]
    )


def test_options_reach_the_runner(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(
        test_opts="""
        import spectest

        calls = []

        def tiny(x):
            calls.append(x)
            return x

        test_it = spectest.conformance("demo.spec", impls={"tiny": tiny})

        def test_calls():
            pass
        """
    )
    result = pytester.runpytest(
        "-p",
        "no:cacheprovider",
        "--spectest-exhaustive-limit=10",
        "--spectest-max-examples=5",
        "-k",
        "tiny.same",
        "--spectest-json=r.json",
    )
    result.assert_outcomes(passed=1)
    (report,) = load_reports((pytester.path / "r.json").read_text())
    (r,) = report.results
    assert r.mode == "hypothesis"
    assert r.total <= 5


@pytest.mark.slow
def test_interface_items(pytester: pytest.Pytester) -> None:
    pytester.makefile(
        ".spec",
        counter="""
spec counter
interface Counter
  observe value: i64
  new zero() -> Counter
    ensures z: result.value == 0
  method inc(self)
    modifies self
    ensures up: self.value == old(self.value) + 1
""",
    )
    pytester.makepyfile(
        test_counter="""
        import spectest
        from spectest import InterfaceBinding

        class Counter:
            def __init__(self):
                self.value = 0
            def inc(self):
                self.value += 1 if self.value < 3 else 2

        test_counter = spectest.conformance(
            "counter.spec",
            interfaces={"Counter": InterfaceBinding(constructors={"zero": Counter})},
            max_examples=30,
        )
        """
    )
    result = pytester.runpytest("-p", "no:cacheprovider", "-v")
    result.assert_outcomes(failed=1)
    result.stdout.fnmatch_lines(
        [
            "*test_counter.py::test_counter::Counter FAILED*",
            "*Counter.inc.up (ensures) failed*",
            "*1. c1 = Counter.zero()*",
            "*5. c1.inc()*",
        ]
    )


@pytest.mark.slow
def test_the_reproduce_command_reproduces_the_counterexample(project: pytest.Pytester) -> None:
    def counterexample(*args: str) -> dict[str, str]:
        project.runpytest("-p", "no:cacheprovider", "--spectest-json=r.json", *args)
        (report,) = load_reports((project.path / "r.json").read_text())
        (r,) = [r for r in report.results if r.clause_id == "wrap:Box.nonneg"]
        (project.path / ".spectest").exists() and __import__("shutil").rmtree(
            project.path / ".spectest"
        )
        return r.counterexample.inputs

    whole = counterexample()
    verbose = counterexample("-v", "-rxs")
    alone = counterexample("test_demo.py::test_demo::wrap:Box.nonneg")
    assert whole == verbose == alone


def test_a_timeout_is_inconclusive(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(
        test_slow="""
        import time
        import spectest

        def tiny(x):
            time.sleep(0.5)
            return x

        test_it = spectest.conformance("demo.spec", impls={"tiny": tiny})
        """
    )
    result = pytester.runpytest(
        "-p",
        "no:cacheprovider",
        "-rs",
        "--spectest-timeout=0.01",
        "--spectest-exhaustive-limit=0",
        "--spectest-max-examples=3",
    )
    result.assert_outcomes(skipped=3)
    result.stdout.fnmatch_lines(["*inconclusive: *inconclusive*"])
    assert result.ret == pytest.ExitCode.OK


GENERIC_BUG = """
import spectest

test_it = spectest.conformance(
    "demo.spec",
    impls={"first": lambda xs: xs[-1]},
    instantiate=[{"T": "i64"}],
    expect_fail={"first.head"},
    max_examples=50,
)
test_plain = spectest.conformance(
    "demo.spec", impls={"first": lambda xs: xs[-1]}, instantiate=[{"T": "i64"}], max_examples=50
)
"""


@pytest.mark.slow
def test_every_printed_name_is_the_node_id_suffix(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", demo=textwrap.dedent(SPEC).lstrip())
    pytester.makepyfile(test_names=GENERIC_BUG)
    result = pytester.runpytest("-p", "no:cacheprovider", "-rx", "--spectest-json=r.json")
    result.assert_outcomes(failed=1, passed=4, xfailed=1)
    result.stdout.fnmatch_lines(
        [
            "first[[]T=i64[]].head (ensures) failed",
            "*reproduce: uv run pytest 'test_names.py::test_plain::first[[]T=i64[]].head'*",
            "*= spectest =*",
            "test_names.py::test_it (spec demo): 2 passed, 1 expected failure",
            "  expected failure first[[]T=i64[]].head: xs = *",
            "XFAIL test_names.py::test_it::first[[]T=i64[]].head - first[[]T=i64[]].head: xs = *",
        ]
    )
    assert "first.head[T=i64]" not in result.stdout.str()
    (report,) = load_reports((pytester.path / "r.json").read_text())
    assert all(r.item_id.endswith("::" + r.label) for r in report.results)
    again = pytester.runpytest(
        "-p", "no:cacheprovider", "test_names.py::test_plain::first[T=i64].head"
    )
    again.assert_outcomes(failed=1)


@pytest.mark.slow
def test_spectest_clause_selects_clauses_by_name_or_id(project: pytest.Pytester) -> None:
    project.makepyfile(test_more="def test_plain():\n    pass\n")
    result = project.runpytest(
        "-p", "no:cacheprovider", "-v", "--spectest-clause=ident#*", "--spectest-clause=tiny.same"
    )
    result.assert_outcomes(passed=4, deselected=17)
    result.stdout.fnmatch_lines(
        [
            "*::test_demo::ident#type PASSED*",
            "*::test_demo::ident#raises PASSED*",
            "*::test_demo::tiny.same PASSED*",
            "*test_more.py::test_plain PASSED*",
        ]
    )
    by_name = project.runpytest(
        "-p", "no:cacheprovider", "-q", "test_demo.py", "--spectest-clause=first[T=string]*,*:Box.*"
    )
    by_name.assert_outcomes(passed=3, xfailed=1, deselected=16)


COUNTER = """
spec counter
interface Counter
  observe value: i64
  new zero() -> Counter
    ensures z: result.value == 0
  method inc(self)
    modifies self
    ensures up: self.value == old(self.value) + 1
"""

COUNTER_TEST = """
import spectest
from spectest import InterfaceBinding

class Counter:
    def __init__(self):
        self.value = 0
    def inc(self):
        self.value += 1 if self.value < 3 else 2

test_counter = spectest.conformance(
    "counter.spec",
    interfaces={"Counter": InterfaceBinding(constructors={"zero": Counter})},
    max_examples=30,
)
"""


@pytest.mark.slow
def test_spectest_clause_on_interface_items(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", counter=COUNTER)
    pytester.makepyfile(test_counter=COUNTER_TEST)
    chosen = pytester.runpytest(
        "-p",
        "no:cacheprovider",
        "--spectest-clause=Counter[T=*]*,Counter.zero.z",
        "--spectest-json=r.json",
    )
    chosen.assert_outcomes(passed=1)
    (report,) = load_reports((pytester.path / "r.json").read_text())
    assert [r.clause_id for r in report.results] == ["Counter.zero.z"]
    failing = pytester.runpytest(
        "-p", "no:cacheprovider", "--spectest-clause=Counter.inc.up", "--spectest-json=r.json"
    )
    failing.assert_outcomes(failed=1)
    failing.stdout.fnmatch_lines(["*Counter.inc.up (ensures) failed*"])
    none = pytester.runpytest("-p", "no:cacheprovider", "--spectest-clause=nothing*")
    none.assert_outcomes(deselected=1)


@pytest.mark.slow
def test_interface_report_counts_pytest_items_and_names_clauses(pytester: pytest.Pytester) -> None:
    pytester.makefile(".spec", counter=COUNTER)
    pytester.makepyfile(test_counter=COUNTER_TEST)
    result = pytester.runpytest("-p", "no:cacheprovider", "--spectest-report=r.md")
    result.assert_outcomes(failed=1)
    md = (pytester.path / "r.md").read_text()
    lines = md.splitlines()
    (clauses,) = [ln for ln in lines if ln.startswith("- **Clause results:**")]
    assert "- **Items:** 1: 1 failed" in lines
    assert clauses.startswith("- **Clause results:** 7: ")
    assert "| `test_counter.py::test_counter::Counter` | `Counter.inc.up` |" in md
    assert "### `test_counter::Counter.inc.up`" in lines
    facts = platform_facts()
    assert f"- **Platform:** {facts['implementation']} {facts['python']}, " in md
    assert facts["machine"] in md


@pytest.mark.slow
def test_runxfail_reports_expected_failures_as_failures(project: pytest.Pytester) -> None:
    project.makepyfile(
        test_xpass="""
        import spectest

        test_it = spectest.conformance(
            "demo.spec", impls={"tiny": lambda x: x}, expect_fail={"tiny.same"}
        )
        """
    )
    result = project.runpytest("-p", "no:cacheprovider", "--runxfail", "-rf")
    result.assert_outcomes(failed=2, errors=1, passed=20)
    result.stdout.fnmatch_lines(
        [
            "*_ spectest test_demo::ident.same _*",
            "ident.same (ensures) failed",
            "  ensures same: result == x",
            "*x = 1001*",
            "*result = 1002*",
            "*reproduce: uv run pytest 'test_demo.py::test_demo::ident.same'*",
            "*= spectest =*",
            "test_demo.py::test_demo (spec demo): 15 passed, 2 failed",
            "test_xpass.py::test_it (spec demo): 3 passed",
        ]
    )
    assert "expected failure ident.same" not in result.stdout.str()


def test_package_versions_name_the_libraries_implementations_come_from() -> None:
    import functools
    import types
    from importlib import metadata

    def local(x):
        return x

    conf = types.SimpleNamespace(
        impls={"a": pytest.approx, "b": sorted, "c": local, "d": functools.partial(local, 1)},
        models={},
        interfaces={},
    )
    found = package_versions([conf])
    assert found["pytest"] == metadata.version("pytest")
    assert "builtins" not in found and "functools" not in found
    assert not any(name.startswith("test_") for name in found)
    assert "spectest" not in package_versions(
        [types.SimpleNamespace(impls={"f": package_versions}, models={}, interfaces={})]
    )


@pytest.mark.slow
def test_an_interface_item_is_strict_about_each_expected_clause(pytester: pytest.Pytester) -> None:
    """Two expected clauses, one of which never fails: pytest, the spectest summary and the
    report's header all count an unexpected pass, and the message names that clause."""
    pytester.makefile(".spec", counter=COUNTER)
    expect = 'max_examples=30,\n    expect_fail={"Counter.inc.up", "Counter.zero.z"},'
    pytester.makepyfile(test_counter=COUNTER_TEST.replace("max_examples=30,", expect))
    result = pytester.runpytest("-p", "no:cacheprovider", "--spectest-report=r.md")
    result.assert_outcomes(failed=1)
    result.stdout.fnmatch_lines(
        [
            "*[[]XPASS(strict)[]] expected to fail: Counter.zero.z, but no example failed*",
            "*test_counter.py::test_counter (spec counter): 1 unexpected pass*",
        ]
    )
    assert "expected to fail: Counter.inc.up" not in result.stdout.str()
    md = (pytester.path / "r.md").read_text()
    assert "- **Items:** 1: 1 unexpected pass" in md.splitlines()
