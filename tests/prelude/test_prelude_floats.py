"""Floats: exact values, classification, neighbors, rounding, ulps and formatting."""

from __future__ import annotations

import itertools
import math
import struct
from fractions import Fraction

import gmpy2
import numpy as np
import pytest
from budget import full
from hypothesis import assume, example, given
from hypothesis import strategies as st

from spectest.prelude import floats
from spectest.types import FLOAT_FORMATS, FloatT
from spectest.values import (
    NEG_INF,
    POS_INF,
    EvalError,
    FloatValue,
    Handle,
    MapValue,
    RecordValue,
    Some,
)

FORMATS = list(FLOAT_FORMATS)
Q = Fraction


def p2(k: int) -> Fraction:
    return Fraction(2) ** k


def width(fmt: str) -> int:
    e, m = FLOAT_FORMATS[fmt]
    return 1 + e + m


def f64(x: float) -> FloatValue:
    return FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


def specials(fmt: str) -> list[FloatValue]:
    f = floats.fmt_info(fmt)
    pos = [0, 1, f.man_mask, 1 << f.man_bits, f.max_bits, f.inf_bits, f.inf_bits | f.quiet_bit]
    pos += [f.inf_bits | 1, (f.bias << f.man_bits), (f.bias << f.man_bits) | 1]
    return [FloatValue(fmt, b | s) for b in pos for s in (0, f.sign_mask)]


@st.composite
def float_values(draw: st.DrawFn, fmts: tuple[str, ...] = tuple(FORMATS)) -> FloatValue:
    fmt = draw(st.sampled_from(fmts))
    if draw(st.integers(0, 4)) == 0:
        return draw(st.sampled_from(specials(fmt)))
    return FloatValue(fmt, draw(st.integers(0, (1 << width(fmt)) - 1)))


def finite_values(fmts: tuple[str, ...] = tuple(FORMATS)) -> st.SearchStrategy[FloatValue]:
    return float_values(fmts).filter(floats.is_finite)


@st.composite
def dyadics(draw: st.DrawFn) -> Fraction:
    m = draw(st.integers(-(1 << 80), 1 << 80))
    e = draw(st.integers(-1200, 1100))
    return m * p2(e)


@st.composite
def rationals(draw: st.DrawFn) -> Fraction:
    n = draw(st.integers(-(1 << 70), 1 << 70))
    d = draw(st.integers(1, 1 << 70))
    return Fraction(n, d) * p2(draw(st.integers(-1100, 1100)))


def mpfr_round(r: Fraction, fmt: str) -> tuple[Fraction | object, bool]:
    """Oracle: MPFR rounding to an emulated IEEE format; (value, negative zero)."""
    e, m = FLOAT_FORMATS[fmt]
    p = m + 1
    bias = (1 << (e - 1)) - 1
    ctx = gmpy2.context(
        precision=p,
        emax=bias + 1,
        emin=2 - bias - m,
        subnormalize=True,
        round=gmpy2.RoundToNearest,
    )
    exact = gmpy2.mpfr(gmpy2.mpq(r.numerator, r.denominator), 200)
    y = ctx.plus(exact)
    if gmpy2.is_infinite(y):
        return (POS_INF if y > 0 else NEG_INF), False
    n, d = y.as_integer_ratio()
    return Fraction(int(n), int(d)), bool(y == 0 and gmpy2.is_signed(y))


# ---------------------------------------------------------------------------
# Exact values


@pytest.mark.parametrize(
    ("fmt", "bits", "value"),
    [
        ("f16", 0x3C00, Q(1)),
        ("f16", 0x0001, p2(-24)),
        ("f16", 0x03FF, 1023 * p2(-24)),
        ("f16", 0x0400, p2(-14)),
        ("f16", 0x7BFF, Q(65504)),
        ("f16", 0xFBFF, Q(-65504)),
        ("f16", 0x8000, Q(0)),
        ("f16", 0x3555, Q(1365, 4096)),
        ("bf16", 0x3F80, Q(1)),
        ("bf16", 0x0001, p2(-133)),
        ("bf16", 0x7F7F, (2 - p2(-7)) * p2(127)),
        ("f32", 0x3F800000, Q(1)),
        ("f32", 0x00000001, p2(-149)),
        ("f32", 0x7F7FFFFF, (2 - p2(-23)) * p2(127)),
        ("f32", 0x3DCCCCCD, Q(13421773, 2**27)),
        ("f64", 0x0000000000000001, p2(-1074)),
        ("f64", 0x7FEFFFFFFFFFFFFF, (2 - p2(-52)) * p2(1023)),
        ("f64", 0xBFF8000000000000, Q(-3, 2)),
    ],
)
def test_to_real_known(fmt: str, bits: int, value: Fraction) -> None:
    assert floats.to_real(FloatValue(fmt, bits)) == value


@pytest.mark.parametrize("fmt", FORMATS)
def test_to_real_infinities_and_nan(fmt: str) -> None:
    assert floats.to_real(floats.inf(fmt)) is POS_INF
    assert floats.to_real(floats.inf(fmt, negative=True)) is NEG_INF
    with pytest.raises(EvalError, match="NaN"):
        floats.to_real(floats.nan(fmt))
    with pytest.raises(EvalError, match="expected a float"):
        floats.to_real(1.5)  # type: ignore[arg-type]


@given(st.floats(allow_nan=False, allow_infinity=False))
def test_to_real_matches_python(x: float) -> None:
    assert floats.to_real(f64(x)) == Fraction(x)


@pytest.mark.parametrize(
    ("fmt", "dtype", "uint"), [("f16", np.float16, np.uint16), ("f32", np.float32, np.uint32)]
)
@given(data=st.data())
def test_to_real_matches_numpy(fmt: str, dtype: type, uint: type, data: st.DataObject) -> None:
    v = data.draw(finite_values((fmt,)))
    x = np.array(v.bits, dtype=uint).view(dtype)[()]
    assert floats.to_real(v) == Fraction(float(x))


# ---------------------------------------------------------------------------
# Classification


@pytest.mark.parametrize("fmt", FORMATS)
def test_classification_table(fmt: str) -> None:
    f = floats.fmt_info(fmt)
    rows = {
        "+0": (0, {"zero": True}),
        "-0": (f.sign_mask, {"zero": True, "sign": True}),
        "minsub": (1, {"sub": True}),
        "maxsub": (f.man_mask, {"sub": True}),
        "-minsub": (f.sign_mask | 1, {"sub": True, "sign": True}),
        "minnorm": (1 << f.man_bits, {"normal": True}),
        "max": (f.max_bits, {"normal": True}),
        "+inf": (f.inf_bits, {"inf": True}),
        "-inf": (f.inf_bits | f.sign_mask, {"inf": True, "sign": True}),
        "qnan": (f.inf_bits | f.quiet_bit, {"nan": True}),
        "snan": (f.inf_bits | 1, {"nan": True}),
        "-nan": (f.inf_bits | f.quiet_bit | f.sign_mask, {"nan": True, "sign": True}),
    }
    for name, (b, props) in rows.items():
        v = FloatValue(fmt, b)
        assert floats.is_nan(v) == props.get("nan", False), name
        assert floats.is_inf(v) == props.get("inf", False), name
        assert floats.is_zero(v) == props.get("zero", False), name
        assert floats.is_subnormal(v) == props.get("sub", False), name
        assert floats.is_normal(v) == props.get("normal", False), name
        assert floats.is_finite(v) == (not props.get("nan") and not props.get("inf")), name
        assert floats.signbit(v) == props.get("sign", False), name
        assert floats.bits(v) == b


@given(float_values())
def test_exactly_one_class(v: FloatValue) -> None:
    classes = [floats.is_nan, floats.is_inf, floats.is_zero, floats.is_subnormal, floats.is_normal]
    assert sum(c(v) for c in classes) == 1


@given(float_values(("f16", "f32", "f64")))
def test_classification_matches_numpy(v: FloatValue) -> None:
    x = floats.to_numpy(v)
    assert floats.is_nan(v) == bool(np.isnan(x))
    assert floats.is_inf(v) == bool(np.isinf(x))
    assert floats.is_finite(v) == bool(np.isfinite(x))
    assert floats.signbit(v) == bool(np.signbit(x))
    assert floats.is_zero(v) == bool(x == 0)
    tiny = np.finfo(type(x)).smallest_normal
    assert floats.is_subnormal(v) == bool(np.isfinite(x) and x != 0 and abs(x) < tiny)


def test_classification_rejects_non_floats() -> None:
    for fn in (floats.is_nan, floats.is_inf, floats.signbit, floats.bits, floats.next_up):
        with pytest.raises(EvalError, match=fn.__name__):
            fn(3)  # type: ignore[arg-type]


@pytest.mark.parametrize("fmt", FORMATS)
def test_constants(fmt: str) -> None:
    f = floats.fmt_info(fmt)
    top = (2 - p2(-f.man_bits)) * p2(f.emax)
    assert floats.to_real(floats.max_finite(fmt)) == top
    assert floats.to_real(floats.min_finite(fmt)) == -top
    assert floats.to_real(floats.min_subnormal(fmt)) == p2(f.emin - f.man_bits)
    assert floats.to_real(floats.min_normal(fmt)) == p2(f.emin)
    assert floats.signbit(floats.zero(fmt, negative=True))
    assert floats.is_nan(floats.nan(fmt, payload=5))
    assert floats.fmt_info(FloatT(fmt)) is f


def test_unknown_format() -> None:
    with pytest.raises(EvalError, match="unknown float format"):
        floats.fmt_info("f80")


def test_f16_and_bf16_constants() -> None:
    assert floats.to_real(floats.max_finite("f16")) == 65504
    assert floats.to_real(floats.max_finite("bf16")) == Fraction(
        "338953138925153547590470800371487866880"
    )


# ---------------------------------------------------------------------------
# Neighbors


def test_next_up_known() -> None:
    one16 = FloatValue("f16", 0x3C00)
    assert floats.to_real(floats.next_up(one16)) == Fraction("1.0009765625")
    assert floats.to_real(floats.next_down(one16)) == 1 - p2(-11)
    assert floats.next_up(FloatValue("bf16", 0x3F80)) == FloatValue("bf16", 0x3F81)
    assert floats.next_up(f64(1.0)) == f64(1.0000000000000002)


@pytest.mark.parametrize("fmt", FORMATS)
def test_next_up_edges(fmt: str) -> None:
    f = floats.fmt_info(fmt)
    s = f.sign_mask

    def v(b: int) -> FloatValue:
        return FloatValue(fmt, b)

    assert floats.next_up(v(s)) == v(1)
    assert floats.next_up(v(0)) == v(1)
    assert floats.next_down(v(0)) == v(s | 1)
    assert floats.next_down(v(s)) == v(s | 1)
    assert floats.next_up(v(s | 1)) == v(s)
    assert floats.next_down(v(1)) == v(0)
    assert floats.next_up(v(f.inf_bits)) == v(f.inf_bits)
    assert floats.next_up(v(s | f.inf_bits)) == v(s | f.max_bits)
    assert floats.next_down(v(s | f.inf_bits)) == v(s | f.inf_bits)
    assert floats.next_down(v(f.inf_bits)) == v(f.max_bits)
    assert floats.next_up(v(f.max_bits)) == v(f.inf_bits)
    assert floats.next_up(v(f.man_mask)) == v(1 << f.man_bits)
    for nan in (f.inf_bits | 1, f.inf_bits | f.quiet_bit | s):
        assert floats.is_nan(floats.next_up(v(nan)))
        assert floats.is_nan(floats.next_down(v(nan)))


@pytest.mark.slow
@pytest.mark.parametrize("fmt", ["f16", "bf16"])
def test_next_up_exhaustive(fmt: str) -> None:
    """Every non-NaN value's next_up is the next distinct real in the format."""
    values = [FloatValue(fmt, b) for b in range(1 << 16)]
    ordered = sorted(
        {floats.to_real(v) for v in values if not floats.is_nan(v)},
        key=lambda r: (r.sign * 2, 0) if r in (POS_INF, NEG_INF) else (0, r),
    )
    succ = dict(itertools.pairwise(ordered))
    pred = dict(zip(ordered[1:], ordered))
    for v in values:
        if floats.is_nan(v):
            continue
        r = floats.to_real(v)
        up = floats.to_real(floats.next_up(v))
        down = floats.to_real(floats.next_down(v))
        assert up == succ.get(r, POS_INF), v
        assert down == pred.get(r, NEG_INF), v


@given(st.floats())
def test_next_up_matches_math_nextafter(x: float) -> None:
    v = f64(x)
    up, down = floats.next_up(v), floats.next_down(v)
    if math.isnan(x):
        assert floats.is_nan(up) and floats.is_nan(down)
        return
    assert up == f64(math.nextafter(x, math.inf))
    assert down == f64(math.nextafter(x, -math.inf))


@given(float_values(("f16", "f32")))
def test_next_up_matches_numpy(v: FloatValue) -> None:
    assume(not floats.is_nan(v) and not floats.is_zero(v))
    x = floats.to_numpy(v)
    t = type(x)
    with np.errstate(over="ignore"):
        up, down = np.nextafter(x, t(np.inf)), np.nextafter(x, t(-np.inf))
    assert floats.next_up(v) == floats.from_numpy(up)
    assert floats.next_down(v) == floats.from_numpy(down)


@given(float_values())
def test_next_up_next_down_inverse(v: FloatValue) -> None:
    assume(not floats.is_nan(v))
    if v != floats.inf(v.fmt):
        back = floats.next_down(floats.next_up(v))
        assert floats.to_real(back) == floats.to_real(v)
        if not floats.is_zero(v):
            assert back == v
    if v != floats.inf(v.fmt, negative=True):
        back = floats.next_up(floats.next_down(v))
        assert floats.to_real(back) == floats.to_real(v)
        if not floats.is_zero(v):
            assert back == v


@given(float_values())
def test_negate_flips_sign_bit(v: FloatValue) -> None:
    n = floats.negate(v)
    assert n.fmt == v.fmt
    assert floats.signbit(n) != floats.signbit(v)
    assert floats.negate(n) == v


# ---------------------------------------------------------------------------
# Rounding


@pytest.mark.parametrize(
    ("fmt", "r", "bits"),
    [
        ("f16", 1 + p2(-11), 0x3C00),
        ("f16", 1 + 3 * p2(-11), 0x3C02),
        ("f16", 1 + p2(-11) + p2(-30), 0x3C01),
        ("f16", 1 + p2(-11) - p2(-30), 0x3C00),
        ("f16", -(1 + 3 * p2(-11)), 0xBC02),
        ("f16", Q(65519), 0x7BFF),
        ("f16", Q(65520), 0x7C00),
        ("f16", Q(-65520), 0xFC00),
        ("f16", Q(65520) - p2(-20), 0x7BFF),
        ("f16", p2(-25), 0x0000),
        ("f16", -p2(-25), 0x8000),
        ("f16", -p2(-40), 0x8000),
        ("f16", p2(-25) + p2(-40), 0x0001),
        ("f16", 3 * p2(-25), 0x0002),
        ("f16", 5 * p2(-25), 0x0002),
        ("f16", p2(-14) - p2(-25), 0x0400),
        ("f16", p2(-14) - p2(-24), 0x03FF),
        ("f16", Q(1, 3), 0x3555),
        ("f16", Q(0), 0x0000),
        ("bf16", 1 + p2(-8), 0x3F80),
        ("bf16", 1 + 3 * p2(-8), 0x3F82),
        ("bf16", Q(1, 3), 0x3EAB),
        ("bf16", p2(128), 0x7F80),
        ("bf16", p2(-134), 0x0000),
        ("bf16", 3 * p2(-134), 0x0002),
        ("f32", p2(128), 0x7F800000),
        ("f32", p2(128) - p2(104), 0x7F7FFFFF),
        ("f32", p2(128) - p2(103), 0x7F800000),
        ("f32", p2(128) - p2(103) - 1, 0x7F7FFFFF),
        ("f32", p2(-150), 0x00000000),
        ("f32", p2(-150) + p2(-200), 0x00000001),
        ("f32", Q(1, 10), 0x3DCCCCCD),
        ("f32", Q(16777217), 0x4B800000),
        ("f32", Q(16777219), 0x4B800002),
        ("f64", Q(1, 10), 0x3FB999999999999A),
        ("f64", p2(1024), 0x7FF0000000000000),
        ("f64", -p2(1024), 0xFFF0000000000000),
        ("f64", p2(-1075), 0x0000000000000000),
        ("f64", 3 * p2(-1075), 0x0000000000000002),
        ("f64", Q(2**53 + 1), 0x4340000000000000),
    ],
)
def test_round_known(fmt: str, r: Fraction, bits: int) -> None:
    assert floats.round_to(r, fmt) == FloatValue(fmt, bits)


@pytest.mark.parametrize("fmt", FORMATS)
def test_round_infinities_and_types(fmt: str) -> None:
    assert floats.round_to(POS_INF, fmt) == floats.inf(fmt)
    assert floats.round_to(NEG_INF, fmt) == floats.inf(fmt, negative=True)
    assert floats.round_to(1, FloatT(fmt)) == floats.round_to(Q(1), fmt)
    with pytest.raises(EvalError, match="expected a real"):
        floats.round_to(1.0, fmt)  # type: ignore[arg-type]
    with pytest.raises(EvalError, match="expected a real"):
        floats.round_to(True, fmt)


@given(float_values())
def test_round_of_real_is_identity(v: FloatValue) -> None:
    assume(not floats.is_nan(v))
    back = floats.round_to(floats.to_real(v), v.fmt)
    if floats.is_zero(v):
        assert back == floats.zero(v.fmt)
    else:
        assert floats.same(back, v)


@given(rationals())
@example(Fraction(1, 10))
@example(Fraction(2**1024 - 2**970))
@example(-Fraction(1, 10**400))
def test_round_f64_matches_python(r: Fraction) -> None:
    try:
        expected = float(r)
    except OverflowError:
        expected = math.inf if r > 0 else -math.inf
    assert floats.round_to(r, "f64") == f64(expected)


@given(st.floats(allow_nan=False))
def test_round_f32_f16_match_numpy(x: float) -> None:
    r = Fraction(x) if math.isfinite(x) else (POS_INF if x > 0 else NEG_INF)
    for fmt, dtype in (("f32", np.float32), ("f16", np.float16)):
        with np.errstate(over="ignore"):
            expected = floats.from_numpy(np.float64(x).astype(dtype))
        assert floats.convert(f64(x), fmt) == expected
        if x != 0:
            assert floats.round_to(r, fmt) == expected


@pytest.mark.parametrize("fmt", FORMATS)
@given(r=dyadics())
def test_round_matches_mpfr(fmt: str, r: Fraction) -> None:
    v = floats.round_to(r, fmt)
    value, negative_zero = mpfr_round(r, fmt)
    assert floats.to_real(v) == value
    if value == 0:
        assert floats.signbit(v) == negative_zero


@pytest.mark.parametrize("fmt", FORMATS)
@given(r=rationals())
def test_round_is_nearest_even(fmt: str, r: Fraction) -> None:
    v = floats.round_to(r, fmt)
    if floats.is_inf(v):
        f = floats.fmt_info(fmt)
        threshold = (2 - p2(-f.precision)) * p2(f.emax)
        assert abs(r) >= threshold
        return
    y = floats.to_real(v)
    for n in (floats.next_up(v), floats.next_down(v)):
        if floats.is_finite(n):
            dn = abs(floats.to_real(n) - r)
            assert abs(y - r) <= dn
            if abs(y - r) == dn:
                assert v.bits & 1 == 0 or floats.is_zero(v)


# ---------------------------------------------------------------------------
# ulp


@pytest.mark.parametrize(
    ("fmt", "r", "expected"),
    [
        ("f64", Q(1), p2(-52)),
        ("f64", Q(0), p2(-1074)),
        ("f64", p2(-1022), p2(-1074)),
        ("f64", p2(-1050), p2(-1074)),
        ("f64", Q(3, 2), p2(-52)),
        ("f64", Q(2), p2(-51)),
        ("f64", 1 - p2(-53), p2(-53)),
        ("f64", Q(-1), p2(-52)),
        ("f64", POS_INF, p2(971)),
        ("f64", NEG_INF, p2(971)),
        ("f64", p2(5000), p2(971)),
        ("f32", Q(1), p2(-23)),
        ("f32", Q(0), p2(-149)),
        ("f16", Q(1), p2(-10)),
        ("f16", Q(65504), Q(32)),
        ("f16", Q(0), p2(-24)),
        ("bf16", Q(1), p2(-7)),
        ("bf16", Q(0), p2(-133)),
    ],
)
def test_ulp_known(fmt: str, r: Fraction, expected: Fraction) -> None:
    assert floats.ulp(r, fmt) == expected


@given(st.floats(allow_nan=False, allow_infinity=False))
def test_ulp_matches_math_ulp(x: float) -> None:
    assert floats.ulp(Fraction(x), "f64") == Fraction(math.ulp(x))


@given(finite_values())
def test_ulp_is_gap_to_next_up(v: FloatValue) -> None:
    assume(not floats.signbit(v) and v != floats.max_finite(v.fmt))
    gap = floats.to_real(floats.next_up(v)) - floats.to_real(v)
    assert floats.ulp(floats.to_real(v), v.fmt) == gap


@pytest.mark.parametrize("fmt", FORMATS)
@given(r=rationals())
def test_correct_rounding_is_within_half_ulp(fmt: str, r: Fraction) -> None:
    v = floats.round_to(r, fmt)
    assume(floats.is_finite(v))
    assert abs(floats.to_real(v) - r) <= floats.ulp(r, fmt) / 2


# ---------------------------------------------------------------------------
# same and ieee_eq


def test_same() -> None:
    pz, nz, nan = f64(0.0), f64(-0.0), f64(math.nan)
    assert floats.same(pz, pz) and not floats.same(pz, nz)
    assert floats.same(nan, FloatValue("f64", nan.bits))
    assert not floats.same(nan, FloatValue("f64", nan.bits | 1))
    assert not floats.same(FloatValue("f32", 0x3F800000), f64(1.0))
    assert floats.same((pz, (nz,)), (pz, (nz,)))
    assert not floats.same((pz, nz), (pz, pz))
    assert not floats.same((pz,), (pz, pz))
    assert floats.same(None, None) and not floats.same(Some(1), None)
    assert floats.same(Some(nan), Some(nan)) and not floats.same(Some(pz), Some(nz))
    m1 = MapValue((("a", pz), ("b", nz)))
    m2 = MapValue((("b", nz), ("a", pz)))
    assert floats.same(m1, m2)
    assert not floats.same(m1, MapValue((("a", pz), ("b", pz))))
    assert not floats.same(m1, MapValue((("a", pz),)))
    assert not floats.same(m1, MapValue((("a", pz), ("c", nz))))
    r1 = RecordValue("P", (("x", pz), ("y", 1)))
    assert floats.same(r1, RecordValue("P", (("x", pz), ("y", 1))))
    assert not floats.same(r1, RecordValue("P", (("x", nz), ("y", 1))))
    assert not floats.same(r1, RecordValue("Q", (("x", pz), ("y", 1))))
    h1, h2 = Handle(object(), "M"), Handle(object(), "M")
    assert floats.same(h1, h1) and not floats.same(h1, h2)
    assert floats.same(1, Q(1)) and not floats.same(True, 1) and floats.same(False, False)
    assert not floats.same("a", b"a") and floats.same(b"a", b"a") and not floats.same("a", 1)
    assert floats.same(POS_INF, POS_INF) and not floats.same(POS_INF, NEG_INF)
    assert not floats.same(POS_INF, Q(1))
    with pytest.raises(EvalError, match="same"):
        floats.same(1.5, 1.5)


def test_ieee_eq() -> None:
    assert floats.ieee_eq(f64(0.0), f64(-0.0))
    assert not floats.ieee_eq(f64(math.nan), f64(math.nan))
    assert floats.ieee_eq(f64(1.0), f64(1.0))
    assert floats.ieee_eq(f64(math.inf), f64(math.inf))
    assert not floats.ieee_eq(f64(math.inf), f64(-math.inf))
    assert not floats.ieee_eq(f64(1.0), floats.next_up(f64(1.0)))
    with pytest.raises(EvalError, match="ieee_eq"):
        floats.ieee_eq(1, f64(1.0))  # type: ignore[arg-type]


@given(st.floats(), st.floats())
def test_ieee_eq_matches_python(x: float, y: float) -> None:
    assert floats.ieee_eq(f64(x), f64(y)) == (x == y)


# ---------------------------------------------------------------------------
# Formatting


@pytest.mark.parametrize(
    ("v", "text"),
    [
        (f64(1.5), "1.5"),
        (f64(-0.0), "-0.0"),
        (f64(0.0), "0.0"),
        (f64(math.inf), "inf"),
        (f64(-math.inf), "-inf"),
        (FloatValue("f64", 0x7FF8000000000000), "nan"),
        (FloatValue("f64", 0x7FF8000000000001), "nan:0x7ff8000000000001"),
        (FloatValue("f64", 0xFFF8000000000000), "nan:0xfff8000000000000"),
        (FloatValue("f32", 0x7FC00000), "nan"),
        (FloatValue("f32", 0x7F800001), "nan:0x7f800001"),
        (FloatValue("f16", 0x7E00), "nan"),
        (FloatValue("f16", 0x7C01), "nan:0x7c01"),
        (FloatValue("bf16", 0x7FC0), "nan"),
        (FloatValue("f32", 0x3DCCCCCD), "0.1"),
        (FloatValue("f32", 0x3E99999A), "0.3"),
        (FloatValue("f16", 0x2E66), "0.1"),
        (FloatValue("f16", 0x7BFF), "65500.0"),
        (FloatValue("f16", 0xFBFF), "-65500.0"),
        (FloatValue("f16", 0x0001), "6e-08"),
        (FloatValue("f16", 0x3555), "0.3333"),
        (FloatValue("f16", 0x3C01), "1.001"),
        (FloatValue("f32", 0x7F7FFFFF), "3.4028235e+38"),
        (FloatValue("f32", 0x4B800000), "16777216.0"),
        (FloatValue("f32", 0x00000001), "1e-45"),
        (FloatValue("bf16", 0x3F81), "1.01"),
        (FloatValue("bf16", 0x3F80), "1.0"),
        (FloatValue("bf16", 0x4120), "10.0"),
        (f64(1e16), "1e+16"),
        (f64(1e-5), "1e-05"),
        (f64(0.0001), "0.0001"),
    ],
)
def test_format_float_known(v: FloatValue, text: str) -> None:
    assert floats.format_float(v) == text


def test_float_value_repr() -> None:
    assert repr(FloatValue("f16", 0x3C00)) == "f16(1.0)"
    assert repr(FloatValue("f64", 0x7FF8000000000001)) == "f64(nan:0x7ff8000000000001)"


@given(st.floats(min_value=0, allow_nan=False, allow_infinity=False, exclude_min=True))
@example(1e16)
@example(1e-5)
@example(5e-324)
@example(1.7976931348623157e308)
@example(123456789012345680.0)
def test_shortest_digits_matches_python_repr(x: float) -> None:
    assert floats._render(*floats.shortest_digits(f64(x))) == repr(x)


@given(finite_values())
def test_format_float_round_trips(v: FloatValue) -> None:
    assume(not floats.is_zero(v))
    assert floats.round_to(Fraction(floats.format_float(v)), v.fmt) == v


def _numpy_digit_count(x: np.floating) -> int:
    mantissa = np.format_float_scientific(x, unique=True).split("e")[0]
    return len(mantissa.replace("-", "").replace(".", "").rstrip("0") or "0")


def _digit_count(v: FloatValue) -> int:
    digits, _ = floats.shortest_digits(v)
    return len(digits)


def test_format_f16_is_shortest_exhaustive() -> None:
    for b in range(0, 0x7C00, 3 if full() else 31):
        v = FloatValue("f16", b)
        if floats.is_zero(v):
            continue
        x = floats.to_numpy(v)
        assert _digit_count(v) == _numpy_digit_count(x), v


@given(finite_values(("f32",)))
def test_format_f32_is_shortest(v: FloatValue) -> None:
    assume(not floats.is_zero(v))
    assert _digit_count(v) == _numpy_digit_count(floats.to_numpy(v))


# ---------------------------------------------------------------------------
# Interop


def test_from_python_float() -> None:
    assert floats.from_python_float(1.5) == FloatValue("f64", 0x3FF8000000000000)
    assert floats.from_python_float(-0.0) == FloatValue("f64", 0x8000000000000000)
    payload = struct.unpack("<d", struct.pack("<Q", 0x7FF0000000000123))[0]
    assert floats.from_python_float(payload) == FloatValue("f64", 0x7FF0000000000123)
    assert floats.from_python_float(0.1, "f32") == FloatValue("f32", 0x3DCCCCCD)
    assert floats.from_python_float(0.5, "f16", exact=True) == FloatValue("f16", 0x3800)
    assert floats.from_python_float(-0.0, "f16") == FloatValue("f16", 0x8000)
    assert floats.from_python_float(1e300, "f32") == floats.inf("f32")
    assert floats.from_python_float(1, "f16") == FloatValue("f16", 0x3C00)
    assert floats.from_python_float(math.nan, "f16", exact=True) == FloatValue("f16", 0x7E00)
    with pytest.raises(ValueError, match="not exactly representable"):
        floats.from_python_float(0.1, "f32", exact=True)
    with pytest.raises(ValueError, match="not exactly representable"):
        floats.from_python_float(2**53 + 1, "f64", exact=True)
    with pytest.raises(TypeError):
        floats.from_python_float(True)
    with pytest.raises(TypeError):
        floats.from_python_float("1.0")  # type: ignore[arg-type]


def test_to_python_float() -> None:
    assert floats.to_python_float(FloatValue("f16", 0x3C01)) == 1.0009765625
    assert math.copysign(1, floats.to_python_float(FloatValue("f32", 0x80000000))) == -1
    assert floats.to_python_float(floats.inf("bf16", negative=True)) == -math.inf
    x = floats.to_python_float(FloatValue("f32", 0x7FC00001))
    assert struct.unpack("<Q", struct.pack("<d", x))[0] == 0x7FF8000020000000


@given(st.floats())
def test_python_float_round_trip(x: float) -> None:
    y = floats.to_python_float(floats.from_python_float(x))
    assert struct.pack("<d", x) == struct.pack("<d", y)


@given(float_values())
def test_to_python_float_is_exact(v: FloatValue) -> None:
    assume(not floats.is_nan(v))
    x = floats.to_python_float(v)
    assert floats.from_python_float(x, v.fmt, exact=True) == v


def test_numpy_scalars() -> None:
    assert floats.from_numpy(np.float16(1.0)) == FloatValue("f16", 0x3C00)
    assert floats.from_numpy(np.float32(0.1)) == FloatValue("f32", 0x3DCCCCCD)
    assert floats.from_numpy(np.float64(-0.0)) == FloatValue("f64", 0x8000000000000000)
    assert floats.from_numpy(np.array(2.0, dtype=np.float32)) == FloatValue("f32", 0x40000000)
    with pytest.raises(TypeError):
        floats.from_numpy(np.int32(1))
    with pytest.raises(TypeError):
        floats.from_numpy(np.zeros(2))
    x = floats.to_numpy(FloatValue("f32", 0x7F800001))
    assert isinstance(x, np.float32) and int(np.array(x).view(np.uint32)) == 0x7F800001


def test_numpy_round_trip_f16_exhaustive() -> None:
    for b in range(0, 1 << 16, 1 if full() else 17):
        assert floats.from_numpy(floats.to_numpy(FloatValue("f16", b))).bits == b


@given(float_values(("f32", "f64")))
def test_numpy_round_trip(v: FloatValue) -> None:
    assert floats.from_numpy(floats.to_numpy(v)) == v


def test_bf16_numpy_needs_ml_dtypes() -> None:
    try:
        import ml_dtypes  # noqa: F401
    except ImportError:
        with pytest.raises(TypeError, match="ml_dtypes"):
            floats.to_numpy(FloatValue("bf16", 0x3F80))
    else:
        v = FloatValue("bf16", 0x3F81)
        assert floats.from_numpy(floats.to_numpy(v)) == v


def test_bits_helpers() -> None:
    v = floats.from_bits("f32", 0x3F800000)
    assert v == FloatValue("f32", 0x3F800000) and floats.to_bits(v) == 0x3F800000
    assert floats.from_bits(FloatT("f16"), 1) == FloatValue("f16", 1)
    assert floats.decode(FloatValue("f16", 0xBC01)) == (1, 15, 1)
    with pytest.raises(ValueError):
        floats.from_bits("f16", 1 << 16)


@given(st.integers(0, (1 << 32) - 1))
def test_convert_f32_to_f64_matches_numpy(b: int) -> None:
    v = FloatValue("f32", b)
    expected = np.array(b, dtype=np.uint32).view(np.float32).astype(np.float64)
    assert floats.convert(v, "f64") == floats.from_numpy(expected)


@given(st.integers(0, (1 << 64) - 1))
def test_convert_f64_to_f32_matches_numpy(b: int) -> None:
    v = FloatValue("f64", b)
    with np.errstate(over="ignore"):
        expected = np.array(b, dtype=np.uint64).view(np.float64).astype(np.float32)
    assert floats.convert(v, "f32") == floats.from_numpy(expected)


def test_convert_keeps_signed_zero_and_quiets_nan() -> None:
    assert floats.convert(f64(-0.0), "bf16") == FloatValue("bf16", 0x8000)
    assert floats.convert(FloatValue("f64", 0x7FF0000000000001), "f16") == FloatValue("f16", 0x7E00)
    assert floats.convert(f64(1.0), "f64") == f64(1.0)
    assert floats.convert(f64(1e-30), "f16") == FloatValue("f16", 0)
