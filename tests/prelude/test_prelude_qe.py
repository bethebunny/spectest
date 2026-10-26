"""Quantized error: QError values, qe, steps, nans, and qerr equality in the prelude."""

from __future__ import annotations

import bisect
import dataclasses
import math
import struct
from fractions import Fraction
from functools import cache

import pytest
from budget import budget, full
from hypothesis import assume, given, settings
from hypothesis import strategies as st

from spectest.prelude import call, collections, floats
from spectest.types import FLOAT_FORMATS, FloatT
from spectest.values import NEG_INF, POS_INF, EvalError, FloatValue, QError

F16 = FloatT("f16")


def f16(x: float) -> FloatValue:
    return floats.from_python_float(x, "f16")


def f64(x: float) -> FloatValue:
    return floats.from_python_float(x, "f64")


def bits_of(fmt: str) -> st.SearchStrategy[FloatValue]:
    e, m = FLOAT_FORMATS[fmt]
    return st.integers(0, (1 << (1 + e + m)) - 1).map(lambda b: FloatValue(fmt, b))


any_float = st.sampled_from(list(FLOAT_FORMATS)).flatmap(bits_of)


# ---------------------------------------------------------------------------
# QError


def test_qerror_text() -> None:
    assert str(QError(3, 0)) == repr(QError(3, 0)) == "3"
    assert str(QError(0, 1)) == repr(QError(0, 1)) == "1nan"
    assert str(QError(3, 1)) == repr(QError(3, 1)) == "3 + 1nan"
    assert str(QError(0, 0)) == str(QError.ZERO) == "0"


def test_qerror_arithmetic_and_order() -> None:
    assert QError(1, 2) + QError(3, 4) == QError(4, 6)
    assert QError.ZERO + QError(2, 0) == QError(2, 0)
    assert QError(1, 0).le(QError(1, 0)) and QError(1, 0).le(QError(2, 1))
    assert not QError(2, 0).le(QError(1, 1)) and not QError(1, 1).le(QError(2, 0))
    assert QError(2, 0).max(QError(1, 3)) == QError(2, 3)
    with pytest.raises(TypeError):
        QError(1, 0) + 1  # type: ignore[operator]


@pytest.mark.parametrize("parts", [(-1, 0), (0, -1), (True, 0), (1.0, 0), (0, Fraction(1))])
def test_qerror_parts_are_whole_numbers(parts: tuple[object, object]) -> None:
    with pytest.raises(ValueError, match="must be an int >= 0"):
        QError(*parts)  # type: ignore[arg-type]


def test_qerror_is_frozen_and_hashable() -> None:
    q = QError(1, 2)
    with pytest.raises(dataclasses.FrozenInstanceError):
        q.steps = 3  # type: ignore[misc]
    assert {q: 1}[QError(1, 2)] == 1
    assert [f.name for f in dataclasses.fields(QError)] == ["steps", "nans"]


# ---------------------------------------------------------------------------
# qe: tables


def test_ordinal() -> None:
    assert floats.ordinal(f64(0.0)) == floats.ordinal(f64(-0.0)) == 0
    assert floats.ordinal(FloatValue("f16", 1)) == 1
    assert floats.ordinal(FloatValue("f16", 0x8001)) == -1
    assert floats.ordinal(floats.inf("f16")) == 0x7C00
    assert floats.ordinal(floats.inf("f16", negative=True)) == -0x7C00


@pytest.mark.parametrize(
    ("x", "y", "expected"),
    [
        (f64(1.0), floats.next_up(f64(1.0)), QError(1, 0)),
        (floats.next_down(f64(1.0)), floats.next_up(f64(1.0)), QError(2, 0)),
        (f64(1.0), f64(1.0), QError(0, 0)),
        (f16(0.5), f16(2.0), QError(2048, 0)),
        (f16(1.0), f16(2.0), QError(1024, 0)),
        (f16(-1.0), f16(1.0), QError(2 * 0x3C00, 0)),
        (f64(0.0), f64(-0.0), QError(0, 0)),
        (f16(0.0), FloatValue("f16", 1), QError(1, 0)),
        (f16(-0.0), FloatValue("f16", 1), QError(1, 0)),
        (FloatValue("f16", 0x8001), FloatValue("f16", 1), QError(2, 0)),
        (floats.max_finite("f16"), floats.inf("f16"), QError(1, 0)),
        (floats.min_finite("f32"), floats.inf("f32", negative=True), QError(1, 0)),
        (floats.inf("f16", negative=True), floats.inf("f16"), QError(2 * 0x7C00, 0)),
        (f16(0.0), floats.inf("f16"), QError(0x7C00, 0)),
        (floats.min_normal("f16"), floats.max_finite("f16"), QError(0x7BFF - 0x0400, 0)),
        (floats.nan("f16"), floats.nan("f16"), QError(0, 0)),
        (floats.nan("f64"), floats.nan("f64", negative=True, payload=5), QError(0, 0)),
        (floats.nan("f32"), f64(1.0), None),
        (floats.nan("f16"), f16(1.0), QError(0, 1)),
        (f16(1.0), floats.nan("f16", negative=True), QError(0, 1)),
        (floats.inf("bf16"), floats.nan("bf16"), QError(0, 1)),
        (FloatValue("f16", 0x7C01), f16(0.0), QError(0, 1)),
    ],
)
def test_qe_table(x: FloatValue, y: FloatValue, expected: QError | None) -> None:
    if expected is None:
        with pytest.raises(EvalError, match="qe: compares two values of one format"):
            floats.qe(x, y)
        return
    assert floats.qe(x, y) == expected
    assert floats.qe(y, x) == expected


def test_qe_rejects_non_floats() -> None:
    with pytest.raises(EvalError, match="qe: expected a float"):
        floats.qe(f64(1.0), 1)  # type: ignore[arg-type]
    with pytest.raises(EvalError, match="^qe: "):
        call("qe", (1, f64(1.0)))


# ---------------------------------------------------------------------------
# qe: properties


@given(any_float, st.data())
def test_qe_is_commutative_and_nan_aware(x: FloatValue, data: st.DataObject) -> None:
    y = data.draw(bits_of(x.fmt))
    e = floats.qe(x, y)
    assert e == floats.qe(y, x)
    assert (e.nans == 1) == (floats.is_nan(x) != floats.is_nan(y))
    assert e.nans in (0, 1)
    if floats.is_nan(x) or floats.is_nan(y):
        assert e.steps == 0
    else:
        assert (e.steps == 0) == (floats.to_real(x) == floats.to_real(y))


@given(any_float)
def test_qe_to_next_up_is_one(x: FloatValue) -> None:
    assume(not floats.is_nan(x) and x != floats.inf(x.fmt))
    assert floats.qe(x, floats.next_up(x)) == QError(1, 0)
    assert floats.qe(floats.next_down(floats.next_up(x)), floats.next_up(x)) == QError(1, 0)


@given(any_float, st.data())
def test_qe_is_the_ulp_distance_within_a_binade(x: FloatValue, data: st.DataObject) -> None:
    assume(floats.is_finite(x))
    f = floats.fmt_info(x.fmt)
    sign, exp, _ = floats.decode(x)
    man = data.draw(st.integers(0, f.man_mask))
    y = FloatValue(x.fmt, (sign << (f.width - 1)) | (exp << f.man_bits) | man)
    assume(not floats.is_zero(x) and not floats.is_zero(y))
    distance = abs(floats.to_real(x) - floats.to_real(y)) / floats.ulp(floats.to_real(x), x.fmt)
    assert floats.qe(x, y) == QError(int(distance), 0)
    assert distance.denominator == 1


@given(any_float, any_float)
def test_qe_adds_along_the_line(x: FloatValue, y: FloatValue) -> None:
    """For a <= b <= c (by value), qe(a, c) = qe(a, b) + qe(b, c)."""
    assume(not floats.is_nan(x) and not floats.is_nan(y))
    z = floats.convert(y, x.fmt)
    assume(not floats.is_nan(z))
    a, c = sorted((x, z), key=floats.ordinal)
    b = floats.next_up(a) if a != c else a
    assume(floats.ordinal(b) <= floats.ordinal(c))
    assert floats.qe(a, c) == floats.qe(a, b) + floats.qe(b, c)


def _key(v: FloatValue) -> tuple[int, Fraction]:
    r = floats.to_real(v)
    if r is POS_INF:
        return (1, Fraction(0))
    if r is NEG_INF:
        return (-1, Fraction(0))
    return (0, r)


def _f16_key(b: int) -> float | None:
    """The f16 value of a bit pattern, decoded by struct to an exact Python float (None for a
    NaN): it orders like the real it stands for, and both zeros are one value."""
    (x,) = struct.unpack("<e", b.to_bytes(2, "little"))
    return None if math.isnan(x) else x


@cache
def _f16_values() -> list[float]:
    """Every value of f16 once (both zeros as one), in numeric order."""
    return sorted({k for b in range(1 << 16) if (k := _f16_key(b)) is not None})


def test_f16_has_63489_distinct_values() -> None:
    assert len(_f16_values()) == 2 * 0x7C01 - 1


@settings(max_examples=budget(3000, 100), deadline=None)
@given(st.integers(0, 0xFFFF), st.integers(0, 0xFFFF))
def test_qe_counts_the_values_in_between_for_f16_pairs(a: int, b: int) -> None:
    """Against an independent count over the sorted distinct values of f16."""
    ka, kb = _f16_key(a), _f16_key(b)
    got = floats.qe(FloatValue("f16", a), FloatValue("f16", b))
    if ka is None or kb is None:
        assert got == QError(0, 0 if ka is None and kb is None else 1)
        return
    values = _f16_values()
    lo, hi = sorted((ka, kb))
    count = bisect.bisect_left(values, hi) - bisect.bisect_left(values, lo)
    assert got == QError(count, 0)


def test_qe_counts_values_exhaustively_near_zero() -> None:
    """Every pair among 256 bit patterns around both zeros, counted by enumeration (in the
    dev loop, the pairs among every fifth pattern)."""
    patterns = [*range(128), *range(0x8000, 0x8080)]
    values = sorted({_key(FloatValue("f16", b)) for b in patterns})
    chosen = patterns if full() else patterns[::5]
    for a in chosen:
        for b in chosen:
            lo, hi = sorted((_key(FloatValue("f16", a)), _key(FloatValue("f16", b))))
            count = bisect.bisect_left(values, hi) - bisect.bisect_left(values, lo)
            assert floats.qe(FloatValue("f16", a), FloatValue("f16", b)) == QError(count, 0)


# ---------------------------------------------------------------------------
# steps, nans, qe<T> and equality


def test_steps_and_nans() -> None:
    assert floats.steps(QError(3, 1)) == 3 and floats.nans(QError(3, 1)) == 1
    assert call("steps", (QError(2, 0),)) == 2 and call("nans", (QError.ZERO,)) == 0
    with pytest.raises(EvalError, match="steps: expected a qerr, got 3"):
        floats.steps(3)  # type: ignore[arg-type]
    with pytest.raises(EvalError, match="nans: expected a qerr"):
        call("nans", (f64(1.0),))


def test_qe_with_a_type_argument() -> None:
    one = f16(1.0)
    assert call("qe", (one, 1), type_args=(F16,)) == QError.ZERO
    assert call("qe", (one, Fraction(1, 2)), type_args=("f16",)) == QError(1024, 0)
    assert call("qe", (floats.max_finite("f16"), POS_INF), type_args=(F16,)) == QError(1, 0)
    assert call("qe", (2, 1), type_args=(F16,)) == QError(1024, 0)
    assert call("qe", (one, floats.nan("f16")), type_args=(F16,)) == QError(0, 1)
    with pytest.raises(EvalError, match=r"qe<f16>: 0\.1 is not exactly representable as f16"):
        call("qe", (one, Fraction(1, 10)), type_args=(F16,))
    with pytest.raises(EvalError, match="qe<f16>: compares f16 values, got a f64"):
        call("qe", (one, f64(1.0)), type_args=(F16,))
    with pytest.raises(EvalError, match="qe<f16>: expected a number or a f16"):
        call("qe", (one, "a"), type_args=(F16,))
    with pytest.raises(EvalError, match="qe<i32>: i32 is not a float format"):
        call("qe", (one, one), type_args=("i32",))


def test_qerr_equality_in_collections() -> None:
    assert floats.same(QError(1, 0), QError(1, 0))
    assert not floats.same(QError(1, 0), QError(1, 1))
    assert not floats.same(QError(0, 0), 0)
    assert not floats.same(0, QError(0, 0))
    assert floats.same((QError(1, 0), 2), (QError(1, 0), 2))
    assert collections.distinct((QError(1, 0), QError(0, 1)))
    assert not collections.distinct((QError(1, 0), QError(1, 0)))
    assert collections.index_of((QError(0, 0), QError(2, 0)), QError(2, 0)) == 1
    assert collections.eq((QError(1, 0),), (QError(1, 0),))
    with pytest.raises(EvalError, match="not ordered"):
        collections.sorted((QError(1, 0), QError(0, 1)))


def test_qe_agrees_with_math_nextafter() -> None:
    x = 1.0
    for k in range(1, 50):
        x = math.nextafter(x, math.inf)
        assert floats.qe(f64(1.0), f64(x)) == QError(k, 0)
