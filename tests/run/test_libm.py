"""math.cos against a v2 spec modeled on examples/libm/libm.spec."""

from __future__ import annotations

import pytest
from support import load

SPEC = """\
spec libm

fn math.cos(x: f64) -> f64
  partition x
    nan       = f64.nan
    inf       = f64.inf
    zero      = f64.zero
    subnormal = f64.subnormal
    small     = f64.range(-0x1p-26, 0x1p-26) & f64.normal
    moderate  = f64.range(-0x1p20, 0x1p20) & f64.normal - small
    huge      = f64.normal - small - moderate
  ensures accurate: qe(result, cr.cos(x)) <= 1
  ensures bounded: is_finite(x) implies is_finite(result) and -1 <= result and result <= 1
  relates even: not is_nan(x) implies same(math.cos(-x), result)
  impl_defined nan_payload

fn runimpls.cos_shifted(x: f64) -> f64
  partition x
    nan       = f64.nan
    inf       = f64.inf
    zero      = f64.zero
    subnormal = f64.subnormal
    small     = f64.range(-0x1p-26, 0x1p-26) & f64.normal
    moderate  = f64.range(-0x1p20, 0x1p20) & f64.normal - small
    huge      = f64.normal - small - moderate
  ensures accurate: qe(result, cr.cos(x)) <= 1
  relates even: not is_nan(x) implies same(runimpls.cos_shifted(-x), result)

fn math.sqrt(x: f64) -> f64
  partition x
    nan       = f64.nan
    negative  = f64.negative - f64.nan - f64.zero
    zero      = f64.zero
    subnormal = f64.subnormal & f64.positive
    normal    = f64.normal & f64.positive
    inf       = f64.inf & f64.positive
  may_raise ValueError when not is_nan(x) and x < 0
  ensures correctly_rounded: qe(result, cr.sqrt(x)) == 0
  ensures signed_zero: is_zero(x) implies same(result, x)
"""


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("libm"), SPEC)
    yield loaded
    loaded.close()


def test_math_cos_is_accurate_but_raises_on_infinity(spec):
    r = spec.run("math.cos", max_examples=300)
    # The finding of examples/libm/FINDINGS.md: IEEE 754 cos(+-inf) is NaN, and
    # math.cos raises ValueError, which nothing admits.
    assert r.failed() == ["math.cos#raises"]
    cx = r.cx("math.cos#raises")
    assert cx["partitions"] == {"x": "inf"}
    assert cx["inputs"]["x"] in ("inf", "-inf")
    assert "raised builtins.ValueError: math domain error" in cx["observation"]
    assert not r.spec_errors()
    for clause in ("accurate", "bounded", "even"):
        c = r["math.cos." + clause]
        assert c["counts"]["pass"] > 100, c
        assert c["counts"]["fail"] == 0
    # Every class is drawn, whatever its size.
    cov = r["math.cos.accurate"]["coverage"]
    assert set(cov) == {f"x: {n}" for n in ("nan", "inf", "zero", "subnormal", "small", "moderate", "huge")}
    assert all(n > 0 for k, n in cov.items() if k != "x: inf")
    assert r["math.cos.accurate"]["skips"]["raised"] > 0
    assert r["math.cos.accurate"]["skips"]["raised"] == r["math.cos.bounded"]["skips"]["raised"]


def test_a_seeded_cos_bug_fails_accuracy_and_evenness(spec):
    r = spec.run("runimpls.cos_shifted", max_examples=300)
    assert "runimpls.cos_shifted.accurate" in r.failed()
    assert "runimpls.cos_shifted.even" in r.failed()
    cx = r.cx("runimpls.cos_shifted.accurate")
    assert cx["partitions"]["x"] in ("small", "moderate", "huge", "subnormal", "zero")
    assert cx["observation"].startswith("result = ")
    assert any(e[0] == "qe(result, cr.cos(x))" for e in cx["explanation"])
    assert not r.spec_errors()


def test_math_sqrt_may_raise_for_negative_numbers(spec):
    r = spec.run("math.sqrt", max_examples=300)
    assert r.passed_all(), r.data
    assert r["math.sqrt#raises"]["counts"]["pass"] == r.examples
    assert r["math.sqrt.correctly_rounded"]["skips"]["raised"] > 0
