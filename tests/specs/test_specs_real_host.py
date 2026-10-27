"""The plugin against the real host, when the extension module is built and can run."""

from __future__ import annotations

import importlib

import pytest
from fake_spec_host import make_test

pytest_plugins = ["pytester"]

ARGS = ("-p", "no:cacheprovider", "--spectest-no-store", "--spectest-max-examples=20")


def real_host():
    try:
        host = importlib.import_module("spectest._host")
    except ImportError:
        pytest.skip("spectest._host is not built")
    if not hasattr(host, "run"):
        pytest.skip("spectest._host has no run yet")
    return host


def test_a_spec_runs_through_the_real_host(pytester: pytest.Pytester) -> None:
    real_host()
    pytester.makefile(
        ".spec",
        realdemo="spec realdemo\n\nfn realimpl.ident(x: i64) -> i64\n  ensures same: result == x\n\n"
        "fn realimpl.bad(x: i64) -> i64\n  ensures same: result == x\n",
    )
    pytester.makepyfile(
        realimpl="def ident(x):\n    return x\n\n\ndef bad(x):\n    return x + 1\n"
    )
    make_test(pytester, 'test_real = spectest.check("realdemo.spec")\n')
    result = pytester.runpytest(*ARGS)
    # Each function has its clause, #type and #raises. `bad` fails its clause, and
    # #type too: at the largest i64, x + 1 is not an i64.
    result.assert_outcomes(passed=4, failed=2)
    out = result.stdout.str()
    assert "FAILED test_demo.py::test_real::realimpl.bad.same" in out
    assert "FAILED test_demo.py::test_real::realimpl.bad#type" in out
    assert "x = 9223372036854775807" in out


EXAMPLE_SPEC = """spec ex

fn exlib.ident(x: f64) -> f64
  ensures same: same(result, x)

fn exlib.narrow(x: f32) -> f32
  ensures same: same(result, x)

fn exlib.first(p: (i64, i64)) -> i64
  ensures same: result == p.0
"""
EXAMPLE_IMPL = """
def ident(x):
    return x


def narrow(x):
    return x


def first(p):
    return p[0]
"""


def example_project(pytester: pytest.Pytester, examples: str) -> pytest.RunResult:
    real_host()
    pytester.makefile(".spec", ex=EXAMPLE_SPEC)
    pytester.makepyfile(exlib=EXAMPLE_IMPL)
    make_test(pytester, f'test_ex = spectest.check("ex.spec", examples={examples})\n')
    return pytester.runpytest(*ARGS)


def test_float_and_tuple_examples_reach_the_host_as_wire_values(
    pytester: pytest.Pytester,
) -> None:
    result = example_project(
        pytester,
        '{"exlib.ident": [{"x": 0.5}], "exlib.narrow": [{"x": 0.5}], "exlib.first": [{"p": (1, 2)}]}',
    )
    result.assert_outcomes(passed=9)


def test_an_f32_example_that_is_not_representable_is_an_error(
    pytester: pytest.Pytester,
) -> None:
    result = example_project(pytester, '{"exlib.narrow": [{"x": 0.1}]}')
    result.assert_outcomes(passed=6, errors=3)
    result.stdout.fnmatch_lines(
        [
            "*test_demo.py::test_ex (spec ex): 6 passed, 3 spec errors",
            "*SPEC ERROR exlib.narrow.same: example x: 0.1 is not exactly representable as f32",
        ]
    )
