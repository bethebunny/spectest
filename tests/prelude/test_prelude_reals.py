"""Extended-real arithmetic, comparison, promotion and formatting."""

from __future__ import annotations

import math
import struct
from fractions import Fraction

import pytest
from hypothesis import given
from hypothesis import strategies as st

from spectest.prelude import reals
from spectest.values import NEG_INF, POS_INF, EvalError, FloatValue

Q = Fraction


def f64(x: float) -> FloatValue:
    return FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


finite = st.one_of(st.integers(-(10**30), 10**30), st.fractions(max_denominator=10**12))
extended = st.one_of(finite, st.sampled_from([POS_INF, NEG_INF]))


def test_promote() -> None:
    assert reals.promote(3) == 3 and isinstance(reals.promote(3), Fraction)
    assert reals.promote(Q(1, 3)) == Q(1, 3)
    assert reals.promote(POS_INF) is POS_INF
    assert reals.promote(f64(0.1)) == Fraction(0.1)
    assert reals.promote(f64(-0.0)) == 0
    assert reals.promote(f64(-math.inf)) is NEG_INF
    assert reals.promote(FloatValue("f16", 0x3C00)) == 1
    with pytest.raises(EvalError, match="real: cannot promote NaN"):
        reals.promote(f64(math.nan))
    with pytest.raises(EvalError, match="expected a number"):
        reals.promote(True)
    with pytest.raises(EvalError, match="expected a number"):
        reals.promote("1")


def test_integer_results_stay_integers() -> None:
    assert reals.add(2, 3) == 5 and type(reals.add(2, 3)) is int
    assert type(reals.sub(2, 3)) is int and reals.sub(2, 3) == -1
    assert type(reals.mul(2, 3)) is int and reals.mul(2, 3) == 6
    assert reals.truediv(6, 4) == Q(3, 2) and isinstance(reals.truediv(6, 3), Fraction)
    assert reals.floordiv(-7, 2) == -4 and type(reals.floordiv(-7, 2)) is int
    assert reals.mod(-7, 2) == 1 and reals.mod(7, -2) == -1


def test_mixed_and_float_operands() -> None:
    assert reals.add(1, Q(1, 2)) == Q(3, 2)
    assert reals.add(f64(0.5), f64(0.25)) == Q(3, 4)
    assert reals.mul(f64(0.1), 10) == Fraction(0.1) * 10
    assert reals.sub(f64(1.0), 1) == 0
    assert reals.floordiv(Q(7, 2), 1) == 3
    with pytest.raises(EvalError, match="NaN"):
        reals.add(f64(math.nan), 1)


def test_infinities() -> None:
    assert reals.add(POS_INF, 5) is POS_INF
    assert reals.add(-5, NEG_INF) is NEG_INF
    assert reals.add(POS_INF, POS_INF) is POS_INF
    assert reals.sub(POS_INF, NEG_INF) is POS_INF
    assert reals.sub(3, POS_INF) is NEG_INF
    assert reals.sub(3, NEG_INF) is POS_INF
    assert reals.mul(POS_INF, -2) is NEG_INF
    assert reals.mul(NEG_INF, NEG_INF) is POS_INF
    assert reals.truediv(POS_INF, -3) is NEG_INF
    assert reals.truediv(5, NEG_INF) == 0
    assert reals.neg(POS_INF) is NEG_INF
    assert reals.add(f64(math.inf), 1) is POS_INF


@pytest.mark.parametrize(
    ("op", "a", "b", "message"),
    [
        (reals.add, POS_INF, NEG_INF, r"\+: \+inf \+ -inf is undefined"),
        (reals.sub, POS_INF, POS_INF, "-: .* is undefined"),
        (reals.sub, NEG_INF, NEG_INF, "is undefined"),
        (reals.mul, 0, POS_INF, r"\*: .* is undefined"),
        (reals.mul, NEG_INF, Q(0), "is undefined"),
        (reals.truediv, 1, 0, "/: division by zero"),
        (reals.truediv, 0, 0, "division by zero"),
        (reals.truediv, POS_INF, 0, "division by zero"),
        (reals.truediv, POS_INF, NEG_INF, "is undefined"),
        (reals.floordiv, 1, 0, "//: division by zero"),
        (reals.floordiv, POS_INF, 2, "is undefined"),
        (reals.mod, 1, 0, "%: division by zero"),
        (reals.mod, Q(1, 2), 1, "%: expected integers"),
        (reals.mod, POS_INF, 1, "expected integers"),
        (reals.add, True, 1, "expected a number"),
        (reals.add, "1", 1, "expected a number"),
    ],
)
def test_undefined(op: object, a: object, b: object, message: str) -> None:
    with pytest.raises(EvalError, match=message):
        op(a, b)  # type: ignore[operator]


def test_neg() -> None:
    assert reals.neg(3) == -3
    assert reals.neg(Q(1, 2)) == Q(-1, 2)
    flipped = reals.neg(f64(0.0))
    assert flipped == f64(-0.0)
    assert reals.neg(f64(math.nan)).bits == f64(math.nan).bits | (1 << 63)


def test_compare() -> None:
    assert reals.lt(1, 2) and reals.le(2, 2) and reals.gt(3, 2) and reals.ge(2, 2)
    assert reals.eq(Q(4, 2), 2) and reals.ne(1, 2)
    assert reals.lt(NEG_INF, -(10**100)) and reals.gt(POS_INF, 10**100)
    assert reals.eq(POS_INF, POS_INF) and reals.lt(NEG_INF, POS_INF)
    assert not reals.lt(POS_INF, POS_INF)
    assert reals.le(-1, f64(-1.0))
    assert reals.eq(f64(0.0), f64(-0.0))
    assert reals.lt(f64(1.0), FloatValue("f16", 0x3C01))
    with pytest.raises(EvalError, match="<: cannot promote NaN"):
        reals.lt(f64(math.nan), 1)


@given(extended, extended)
def test_compare_is_a_total_order(a: object, b: object) -> None:
    c = reals.compare(a, b)
    assert c == -reals.compare(b, a)
    if c == 0:
        assert reals.eq(a, b)


@given(finite, finite)
def test_finite_arithmetic_matches_fractions(a: Fraction | int, b: Fraction | int) -> None:
    assert reals.add(a, b) == a + b
    assert reals.sub(a, b) == a - b
    assert reals.mul(a, b) == a * b
    if b != 0:
        assert reals.truediv(a, b) == Fraction(a) / b
        assert reals.floordiv(a, b) == a // b
    assert reals.compare(a, b) == (a > b) - (a < b)


@pytest.mark.parametrize(
    ("value", "text"),
    [
        (3, "3"),
        (Q(0), "0"),
        (Q(-1, 2), "-0.5"),
        (Q(1, 1024), "0.0009765625"),
        (Q(1, 3), "~0.33333333333333333333"),
        (Q(2, 3) * 10**30, "~6.6666666666666666667e+29"),
        (POS_INF, "inf"),
        (NEG_INF, "-inf"),
        (Q(10**40), "~1.0e+40"),
        (Q(1, 2**1074), "~4.9406564584124654418e-324"),
        (f64(1.5), "1.5"),
    ],
)
def test_format_real(value: object, text: str) -> None:
    assert reals.format_real(value) == text


@pytest.mark.slow
def test_format_real_huge() -> None:
    text = reals.format_real(Fraction(2) ** (1 << 20))
    assert text.startswith("~") and "e+315652" in text
