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
