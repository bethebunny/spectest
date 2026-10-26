"""Correctly rounded functions cr.*: exhaustive over f16, sampled in bf16, f32 and f64.

The oracle is independent of cr's MPFR contexts: the 256-bit references of
spectest.prelude.mp, rounded with floats.round_to, plus IEEE 754's special
cases where a reference has no value (NaN, invalid operations, signed zeros).
"""

from __future__ import annotations

import math
import random
import struct
from collections.abc import Callable
from fractions import Fraction

import gmpy2
import pytest
from budget import budget, full
from hypothesis import given, settings
from hypothesis import strategies as st

from spectest.prelude import call, cr, floats, mp
from spectest.values import EvalError, FloatValue, QError

FUNCTIONS = cr.FUNCTIONS
MATH: dict[str, Callable[[float], float]] = {
    "sqrt": math.sqrt,
    "exp": math.exp,
    "log": math.log,
    "sin": math.sin,
    "cos": math.cos,
    "tan": math.tan,
    "atan": math.atan,
}


def f64(x: float) -> FloatValue:
    return FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


def f32(x: float) -> FloatValue:
    return floats.from_python_float(x, "f32")


def reference(name: str, x: FloatValue) -> FloatValue:
    """f(x) by the 256-bit reference and round_to, with IEEE 754's special cases."""
    fmt = x.fmt
    if floats.is_nan(x):
        return floats.nan(fmt)
    if floats.is_zero(x):
        if name in ("sin", "tan", "atan", "sqrt"):
            return x
        if name == "log":
            return floats.inf(fmt, negative=True)
    try:
        r = getattr(mp, name)(x)
    except EvalError as err:
        if "outside the reference range" in str(err) and name == "exp":
            return floats.inf(fmt) if not floats.signbit(x) else floats.zero(fmt)
        return floats.nan(fmt)
    return floats.round_to(r, fmt)


def mismatches(name: str, inputs: list[FloatValue]) -> list[str]:
    fn = getattr(cr, name)
    out = []
    for x in inputs:
        got, want = fn(x), reference(name, x)
        if got != want:
            out.append(f"cr.{name}({x!r}) = {got!r}, expected {want!r}")
    return out


@pytest.mark.parametrize("name", FUNCTIONS)
def test_exhaustive_f16(name: str) -> None:
    """Every f16 (every 31st bit pattern in the dev loop, which still meets every exponent)."""
    step = 1 if full() else 31
    assert mismatches(name, [FloatValue("f16", b) for b in range(0, 1 << 16, step)]) == []


@pytest.mark.parametrize("name", FUNCTIONS)
def test_every_fifth_bf16(name: str) -> None:
    """Every exponent and sign of bf16, with every fifth mantissa (every 55th bit pattern
    in the dev loop)."""
    step = 5 if full() else 55
    assert mismatches(name, [FloatValue("bf16", b) for b in range(0, 1 << 16, step)]) == []


def _sample(fmt: str, n: int, seed: int) -> list[FloatValue]:
    width = floats.fmt_info(fmt).width
    rng = random.Random(seed)
    return [FloatValue(fmt, rng.getrandbits(width)) for _ in range(n)]


def _near(fmt: str, center: float, n: int) -> list[FloatValue]:
    """n consecutive values on each side of a center value."""
    out, up, down = [], floats.from_python_float(center, fmt), floats.from_python_float(center, fmt)
    for _ in range(n):
        out += [up, down]
        up, down = floats.next_up(up), floats.next_down(down)
    return out


@pytest.mark.parametrize("name", FUNCTIONS)
def test_sampled_f32(name: str) -> None:
    inputs = _sample("f32", budget(4000, 400), 32) + _near("f32", 1.0, 64) + _near("f32", 0.0, 64)
    inputs += _near("f32", 88.72283935546875, 16) + _near("f32", -103.97, 16)
    assert mismatches(name, inputs) == []


@pytest.mark.parametrize("name", FUNCTIONS)
def test_sampled_f64(name: str) -> None:
    inputs = _sample("f64", budget(2000, 200), 64) + _near("f64", 1.0, 32) + _near("f64", 0.0, 32)
    assert mismatches(name, inputs) == []


HARD_F64: list[tuple[str, float, float | None]] = [
    ("cos", 1e22, 0.523214785395139),
    ("sin", 1e22, None),
    ("tan", 1e22, None),
    ("cos", 1.7976931348623157e308, None),
    ("sin", 2.0**1000, None),
    ("tan", 1.5707963267948966, None),
    ("cos", 1.5707963267948966, 6.123233995736766e-17),
    ("exp", 709.782712893384, 1.7976931348622732e308),
    ("exp", 709.7827128933841, math.inf),
    ("exp", -745.1332191019411, 5e-324),
    ("exp", -745.1332191019412, 0.0),
    ("exp", -708.4, None),
    ("exp", -740.0, None),
    ("exp", 1e-300, 1.0),
    ("exp", -1e-300, 1.0),
    ("log", 1 + 2.0**-52, 2.0**-52 - 2.0**-105),
    ("log", 1 - 2.0**-53, -(2.0**-53) - 2.0**-107),
    ("log", 5e-324, -744.4400719213812),
    ("log", 1.7976931348623157e308, 709.782712893384),
    ("sqrt", 5e-324, 2.2227587494850775e-162),
    ("sqrt", 2.0, 1.4142135623730951),
    ("atan", 1e300, 1.5707963267948966),
    ("atan", math.inf, 1.5707963267948966),
    ("atan", -math.inf, -1.5707963267948966),
    ("atan", 5e-324, 5e-324),
]


@pytest.mark.parametrize(("name", "x", "expected"), HARD_F64)
def test_hard_cases_f64(name: str, x: float, expected: float | None) -> None:
    got = getattr(cr, name)(f64(x))
    assert got == reference(name, f64(x))
    if expected is not None:
        assert got == f64(expected), (got, expected)
    try:
        y = MATH[name](x)
    except OverflowError:
        y = math.inf
    assert floats.qe(got, f64(y)).le(QError(1, 0)), (got, y)


def test_hard_cases_f32() -> None:
    big = f32(88.72283935546875)
    assert cr.exp(big) == floats.inf("f32")
    below = cr.exp(floats.next_down(big))
    assert below == reference("exp", floats.next_down(big))
    assert floats.is_finite(below) and floats.to_python_float(below) > 3.4e38
    assert cr.exp(f32(-103.97)) == floats.min_subnormal("f32")
    assert cr.exp(f32(-104.0)) == floats.zero("f32")
    assert cr.exp(f32(-103.0)) == reference("exp", f32(-103.0))
    assert floats.is_subnormal(cr.exp(f32(-103.0)))
    assert cr.cos(f32(1e30)) == reference("cos", f32(1e30))
    assert cr.log(floats.min_subnormal("f32")) == reference("log", floats.min_subnormal("f32"))


def test_round_to_nearest_even_subnormal_results() -> None:
    tiny = floats.min_subnormal("f16")
    assert cr.sin(tiny) == tiny and cr.tan(tiny) == tiny and cr.atan(tiny) == tiny
    assert cr.sin(floats.negate(tiny)) == floats.negate(tiny)
    assert cr.exp(floats.from_python_float(-17.0, "f16")) == FloatValue("f16", 0x0001)
    assert cr.exp(floats.from_python_float(-18.0, "f16")) == floats.zero("f16")


@pytest.mark.parametrize("fmt", ["f16", "bf16", "f32", "f64"])
def test_special_cases(fmt: str) -> None:
    nan, inf, ninf = floats.nan(fmt), floats.inf(fmt), floats.inf(fmt, negative=True)
    zero, nzero = floats.zero(fmt), floats.zero(fmt, negative=True)
    one = floats.from_python_float(1.0, fmt)
    minus_one = floats.from_python_float(-1.0, fmt)
    odd_nan = floats.nan(fmt, negative=True, payload=1)
    for name in FUNCTIONS:
        fn = getattr(cr, name)
        assert fn(odd_nan) == nan, name
        assert fn(nan) == nan, name
        assert fn(one).fmt == fmt
    for name in ("cos", "sin", "tan"):
        assert getattr(cr, name)(inf) == nan and getattr(cr, name)(ninf) == nan
    assert cr.sqrt(minus_one) == nan and cr.sqrt(ninf) == nan
    assert cr.sqrt(nzero) == nzero and cr.sqrt(zero) == zero and cr.sqrt(inf) == inf
    assert cr.log(zero) == ninf and cr.log(nzero) == ninf
    assert cr.log(minus_one) == nan and cr.log(ninf) == nan
    assert cr.log(inf) == inf and cr.log(one) == zero
    assert cr.exp(inf) == inf and cr.exp(ninf) == zero
    assert cr.exp(zero) == one and cr.exp(nzero) == one
    assert cr.exp(floats.max_finite(fmt)) == inf
    assert cr.exp(floats.min_finite(fmt)) == zero
    for name in ("sin", "tan", "atan"):
        assert getattr(cr, name)(nzero) == nzero and getattr(cr, name)(zero) == zero
    assert cr.cos(zero) == one and cr.cos(nzero) == one
    half_pi = floats.round_to(mp.pi() / 2, fmt)
    assert cr.atan(inf) == half_pi and cr.atan(ninf) == floats.negate(half_pi)


def test_non_floats_are_rejected() -> None:
    with pytest.raises(EvalError, match=r"cr.cos: expected a float, got 1"):
        cr.cos(1)
    with pytest.raises(EvalError, match="^cr.sqrt: "):
        call("cr.sqrt", (Fraction(1, 2),))


def test_independent_of_current_context() -> None:
    x = f64(0.5)
    expected = cr.exp(x)
    with gmpy2.context(precision=20, round=gmpy2.RoundToZero, emax=100, emin=-100):
        assert cr.exp(x) == expected
        assert cr.cos(f64(1e22)) == f64(0.523214785395139)
        assert gmpy2.get_context().precision == 20
    assert cr.context("f64").precision == 53
    assert cr.context("f16").emin == -23 and cr.context("f16").emax == 16


def test_contexts_match_gmpy2_ieee() -> None:
    for fmt, bits in (("f16", 16), ("f32", 32), ("f64", 64)):
        ctx, ieee = cr.context(fmt), gmpy2.ieee(bits)
        assert (ctx.precision, ctx.emin, ctx.emax) == (ieee.precision, ieee.emin, ieee.emax)
        assert ctx.subnormalize and ctx.round == gmpy2.RoundToNearest
    bf16 = cr.context("bf16")
    assert (bf16.precision, bf16.emin, bf16.emax) == (8, -132, 128)


@settings(max_examples=budget(300, 30), deadline=None)
@given(st.floats(min_value=-1e6, max_value=1e6, allow_nan=False))
def test_libm_is_within_one_step(x: float) -> None:
    v = f64(x)
    for name in ("sin", "cos", "atan", "exp", "tan"):
        y = MATH[name](x) if name != "exp" or x < 709 else math.inf
        assert floats.qe(f64(y), getattr(cr, name)(v)).le(QError(1, 0)), name
    if x > 0:
        assert floats.qe(f64(math.log(x)), cr.log(v)).le(QError(1, 0))
        assert cr.sqrt(v) == f64(math.sqrt(x))
