"""The plugin against the real host, when the extension module is built and can run."""

from __future__ import annotations

import importlib

import pytest

from conftest import make_test

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
    result.assert_outcomes(passed=1, failed=1)
    out = result.stdout.str()
    assert "realimpl.bad.same" in out
