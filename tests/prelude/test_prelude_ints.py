"""Fixed-width integers: wrap, fits, bounds and le_uint."""

from __future__ import annotations

import math
import struct
from fractions import Fraction

import pytest
from hypothesis import given
from hypothesis import strategies as st

from spectest.prelude import floats, ints
from spectest.types import INT_FORMATS, FixedIntT, FloatT, scalar_type
from spectest.values import NEG_INF, POS_INF, EvalError, FloatValue

I32 = FixedIntT(32, True)
U32 = FixedIntT(32, False)


def f64(x: float) -> FloatValue:
    return FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


@pytest.mark.parametrize(
    ("t", "n", "expected"),
    [
        ("i32", 2**31, -(2**31)),
        ("i32", 2**31 - 1, 2**31 - 1),
        ("i32", -(2**31) - 1, 2**31 - 1),
        ("u32", -1, 2**32 - 1),
        ("u32", 2**32, 0),
        ("i8", 255, -1),
        ("i8", 128, -128),
        ("u8", 256, 0),
        ("u8", -1, 255),
        ("i64", 2**63, -(2**63)),
        ("u64", -(2**64) - 5, 2**64 - 5),
        ("i16", 0, 0),
    ],
)
def test_wrap_known(t: str, n: int, expected: int) -> None:
    assert ints.wrap(n, t) == expected
    assert ints.wrap(n, scalar_type(t)) == expected  # type: ignore[arg-type]


@pytest.mark.parametrize("name", list(INT_FORMATS))
@given(n=st.integers(-(2**80), 2**80))
def test_wrap_properties(name: str, n: int) -> None:
    t = scalar_type(name)
    assert isinstance(t, FixedIntT)
    w = ints.wrap(n, t)
    assert t.min <= w <= t.max
    assert (w - n) % (1 << t.bits) == 0
    assert ints.fits(w, t)
    if t.min <= n <= t.max:
        assert w == n


def test_wrap_errors() -> None:
    with pytest.raises(EvalError, match="wrap<i32>: expected an integer"):
        ints.wrap(Fraction(1, 2), I32)
    with pytest.raises(EvalError, match="expected an integer"):
        ints.wrap(True, I32)
    with pytest.raises(EvalError, match="not a fixed-width integer type"):
        ints.wrap(1, FloatT("f32"))
    with pytest.raises(EvalError, match="not a fixed-width integer type"):
        ints.wrap(1, "int")


def test_bounds() -> None:
    assert ints.int_min("i8") == -128 and ints.int_max("i8") == 127
    assert ints.int_min(U32) == 0 and ints.int_max(U32) == 2**32 - 1
    assert ints.int_max("i64") == 2**63 - 1 and ints.int_min("i64") == -(2**63)
    with pytest.raises(EvalError):
        ints.int_max("f64")


def test_fits_integers() -> None:
    assert not ints.fits(2**31, I32)
    assert ints.fits(2**31 - 1, I32) and ints.fits(-(2**31), I32)
    assert not ints.fits(-(2**31) - 1, I32)
    assert not ints.fits(-1, "u8") and ints.fits(255, "u8") and not ints.fits(256, "u8")
    assert not ints.fits(Fraction(1, 2), I32)
    assert ints.fits(Fraction(6, 2), I32)
    assert not ints.fits(POS_INF, I32) and not ints.fits(NEG_INF, "u64")
    assert ints.fits(f64(3.0), I32) and not ints.fits(f64(3.5), I32)
    assert ints.fits(f64(-0.0), "u8")
    assert not ints.fits(f64(2.0**40), I32)
    with pytest.raises(EvalError, match="NaN"):
        ints.fits(f64(math.nan), I32)
    with pytest.raises(EvalError, match="expected a number"):
        ints.fits("3", I32)


def test_fits_floats() -> None:
    f16, f32 = FloatT("f16"), FloatT("f32")
    assert ints.fits(65504, f16) and not ints.fits(65505, f16)
    assert not ints.fits(65520, f16)
    assert ints.fits(POS_INF, f16) and ints.fits(NEG_INF, "f32")
    assert ints.fits(Fraction(1, 2**24), f16) and not ints.fits(Fraction(1, 2**25), f16)
    assert not ints.fits(Fraction(1, 3), f32)
    assert not ints.fits(f64(0.1), f32) and ints.fits(f64(1.5), f32)
    assert ints.fits(f64(-0.0), "f16")
    assert ints.fits(2**24, f32) and not ints.fits(2**24 + 1, f32)
    assert ints.fits(2**24 + 2, "f32")
    assert ints.fits(Fraction(2) ** 126 * 3, "bf16")
    assert not ints.fits(Fraction(2) ** 127 * 3, "bf16")


@given(st.floats(allow_nan=False))
def test_fits_f32_matches_round_trip(x: float) -> None:
    v = f64(x)
    narrowed = floats.convert(v, "f32")
    assert ints.fits(v, "f32") == (floats.to_real(narrowed) == floats.to_real(v))


@pytest.mark.parametrize(
    ("b", "expected"),
    [
        (b"", 0),
        (b"\x01", 1),
        (b"\x01\x00", 1),
        (b"\x00\x01", 256),
        (b"\xff\xff\xff\xff", 2**32 - 1),
        (b"\x78\x56\x34\x12", 0x12345678),
    ],
)
def test_le_uint(b: bytes, expected: int) -> None:
    assert ints.le_uint(b) == expected


def test_le_uint_matches_struct() -> None:
    for x in (0, 1, -1, 2**31 - 1, -(2**31), 123456789):
        assert ints.le_uint(struct.pack("<i", x)) == ints.wrap(x, U32)
    with pytest.raises(EvalError, match="le_uint: expected bytes"):
        ints.le_uint("abc")
