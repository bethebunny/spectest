"""MPFR references: known digits, independent series oracles, domains and contexts."""

from __future__ import annotations

import decimal
import math
import struct
from collections.abc import Callable
from fractions import Fraction

import gmpy2
import pytest
from hypothesis import assume, given
from hypothesis import strategies as st

from spectest.prelude import floats, mp
from spectest.values import NEG_INF, POS_INF, EvalError, FloatValue

TOL = Fraction(1, 2**250)


def f64(x: float) -> FloatValue:
    return FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


# The series sum exact rationals in gmpy2's mpq, which gives the same values as Fraction
# many times faster (the partial sums of atan(1/3) have numerators of 100,000 bits).


def exact(q: gmpy2.mpq) -> Fraction:
    return Fraction(int(q.numerator), int(q.denominator))


def series_sin(x: Fraction, terms: int = 80) -> Fraction:
    x = gmpy2.mpq(x)
    total, term = gmpy2.mpq(0), x
    for k in range(terms):
        total += term
        term = -term * x * x / ((2 * k + 2) * (2 * k + 3))
    return exact(total)


def series_cos(x: Fraction, terms: int = 80) -> Fraction:
    x = gmpy2.mpq(x)
    total, term = gmpy2.mpq(0), gmpy2.mpq(1)
    for k in range(terms):
        total += term
        term = -term * x * x / ((2 * k + 1) * (2 * k + 2))
    return exact(total)


def series_atan(x: Fraction, terms: int = 200) -> Fraction:
    x = gmpy2.mpq(x)
    total, power = gmpy2.mpq(0), x
    for k in range(terms):
        total += (-1) ** k * power / (2 * k + 1)
        power *= x * x
    return exact(total)


def series_exp(x: Fraction, terms: int = 120) -> Fraction:
    x = gmpy2.mpq(x)
    total, term = gmpy2.mpq(0), gmpy2.mpq(1)
    for k in range(terms):
        total += term
        term = term * x / (k + 1)
    return exact(total)


PI = 4 * (4 * series_atan(Fraction(1, 5)) - series_atan(Fraction(1, 239)))


def close(got: object, want: Fraction) -> bool:
    assert isinstance(got, Fraction)
    return abs(got - want) <= TOL * max(abs(want), Fraction(1))


def is_256_bit_dyadic(r: Fraction) -> bool:
    d = r.denominator
    if d & (d - 1):
        return False
    n = abs(r.numerator)
    if n == 0:
        return True
    return (n // (n & -n)).bit_length() <= mp.PRECISION


KNOWN_DIGITS = {
    "cos1": "0.540302305868139717400936607442976603732310420617922227670097",
    "sin1": "0.841470984807896506652502321630298999622563060798371065672751",
    "sqrt2": "1.414213562373095048801688724209698078569671875376948073176679",
    "e": "2.718281828459045235360287471352662497757247093699959574966967",
    "halfpi": "1.570796326794896619231321691639751442098584699687552910487472",
}


@pytest.mark.parametrize(
    ("value", "key"),
    [
        (lambda: mp.cos(1), "cos1"),
        (lambda: mp.sin(1), "sin1"),
        (lambda: mp.sqrt(2), "sqrt2"),
        (lambda: mp.exp(1), "e"),
        (lambda: mp.atan(POS_INF), "halfpi"),
    ],
)
def test_known_digits(value: Callable[[], object], key: str) -> None:
    got = value()
    want = Fraction(KNOWN_DIGITS[key])
    assert isinstance(got, Fraction)
    assert abs(got - want) < Fraction(1, 10**59)


@pytest.mark.parametrize("x", [Fraction(1), Fraction(1, 3), Fraction(-7, 4), Fraction(3, 1024)])
def test_trig_matches_series(x: Fraction) -> None:
    assert close(mp.sin(x), series_sin(round256(x)))
    assert close(mp.cos(x), series_cos(round256(x)))
    assert close(mp.tan(x), series_sin(round256(x)) / series_cos(round256(x)))


def round256(x: Fraction) -> Fraction:
    """x rounded to 256 significant bits, as mp converts its inputs."""
    if x == 0:
        return x
    sign = -1 if x < 0 else 1
    a = abs(x)
    e = floats.floor_log2(a) - mp.PRECISION + 1
    scaled = a / Fraction(2) ** e
    m = round(scaled)
    return sign * m * Fraction(2) ** e


@pytest.mark.parametrize("x", [Fraction(1, 2), Fraction(-1, 3), Fraction(1, 7)])
def test_atan_matches_series(x: Fraction) -> None:
    assert close(mp.atan(x), series_atan(round256(x)))


def test_atan_infinities_and_pi() -> None:
    assert close(mp.pi(), PI)
    assert mp.atan(POS_INF) == mp.pi() / 2
    assert mp.atan(NEG_INF) == -mp.pi() / 2
    assert mp.atan(f64(math.inf)) == mp.pi() / 2
    assert close(mp.atan(1), PI / 4)


@pytest.mark.parametrize("x", [Fraction(1), Fraction(-5, 2), Fraction(1, 1000), Fraction(40)])
def test_exp_matches_series(x: Fraction) -> None:
    assert close(mp.exp(x), series_exp(x, terms=250))


def test_log_and_sqrt_match_decimal() -> None:
    ctx = decimal.Context(prec=100)
    for x in (2, 10, 3, 12345):
        want = Fraction(str(ctx.ln(decimal.Decimal(x))))
        assert abs(mp.log(x) - want) < Fraction(1, 10**75)
        want = Fraction(str(ctx.sqrt(decimal.Decimal(x))))
        assert abs(mp.sqrt(x) - want) < Fraction(1, 10**74)


def test_exact_cases() -> None:
    assert mp.sqrt(4) == 2
    assert mp.sqrt(Fraction(1, 4)) == Fraction(1, 2)
    assert mp.sqrt(0) == 0
    assert mp.exp(0) == 1
    assert mp.log(1) == 0
    assert mp.sin(0) == 0
    assert mp.cos(0) == 1
    assert mp.atan(0) == 0
    assert mp.sqrt(FloatValue("f16", 0x4400)) == 2
    assert mp.sqrt(f64(-0.0)) == 0


def test_infinite_inputs() -> None:
    assert mp.exp(POS_INF) is POS_INF
    assert mp.exp(NEG_INF) == 0
    assert mp.log(POS_INF) is POS_INF
    assert mp.sqrt(POS_INF) is POS_INF
    assert mp.exp(f64(-math.inf)) == 0


@pytest.mark.parametrize(
    ("fn", "arg", "message"),
    [
        (mp.sqrt, -1, "mp.sqrt: argument must be non-negative"),
        (mp.sqrt, NEG_INF, "mp.sqrt"),
        (mp.log, 0, "mp.log: argument must be positive"),
        (mp.log, -1, "mp.log"),
        (mp.log, NEG_INF, "mp.log"),
        (mp.sin, POS_INF, "mp.sin: undefined"),
        (mp.cos, NEG_INF, "mp.cos: undefined"),
        (mp.tan, POS_INF, "mp.tan: undefined"),
        (mp.cos, f64(math.nan), "NaN"),
        (mp.exp, 10**6, "outside the reference range"),
        (mp.exp, -(10**6), "outside the reference range"),
        pytest.param(
            mp.sqrt, Fraction(2) ** (1 << 20), "outside the reference range", marks=pytest.mark.slow
        ),
        (mp.cos, "1", "expected a number"),
        (mp.cos, True, "expected a number"),
    ],
)
def test_domain_errors(fn: Callable[[object], object], arg: object, message: str) -> None:
    with pytest.raises(EvalError, match=message):
        fn(arg)


def test_extreme_but_representable() -> None:
    big = mp.exp(709)
    assert isinstance(big, Fraction) and big > Fraction(2) ** 1022
    tiny = mp.exp(-745)
    assert isinstance(tiny, Fraction) and 0 < tiny < Fraction(2) ** -1074
    assert floats.round_to(mp.exp(710), "f64") == floats.inf("f64")


def test_results_are_256_bit_dyadics() -> None:
    for value in (mp.cos(1), mp.exp(Fraction(1, 3)), mp.log(3), mp.atan(POS_INF), mp.sqrt(3)):
        assert isinstance(value, Fraction) and is_256_bit_dyadic(value)


def test_inputs_are_exact_up_to_256_bits() -> None:
    one = Fraction(1)
    assert mp.sin(one + Fraction(1, 2**255)) != mp.sin(one)
    assert mp.sin(one + Fraction(1, 2**256)) == mp.sin(one)


def test_independent_of_current_context() -> None:
    before = gmpy2.get_context()
    expected = mp.cos(1)
    with gmpy2.context(precision=20, round=gmpy2.RoundToZero, emax=100, emin=-100):
        assert mp.cos(1) == expected
        assert mp.exp(500) == mp.exp(500)
        assert gmpy2.get_context().precision == 20
    after = gmpy2.get_context()
    assert after.precision == before.precision
    assert after.round == before.round
    assert after.emax == before.emax


finite_f64 = st.floats(allow_nan=False, allow_infinity=False)


def ulps_off(y: FloatValue, r: Fraction) -> Fraction:
    """|y - r| in ulps of r's binade, for finite y."""
    return abs(floats.to_real(y) - r) / floats.ulp(r, y.fmt)


@given(st.floats(min_value=-1e6, max_value=1e6, allow_nan=False))
def test_trig_against_libm(x: float) -> None:
    v = f64(x)
    assert ulps_off(f64(math.cos(x)), mp.cos(v)) <= 1
    assert ulps_off(f64(math.sin(x)), mp.sin(v)) <= 1
    assert ulps_off(f64(math.atan(x)), mp.atan(v)) <= 1


@given(st.floats(min_value=-700, max_value=700, allow_nan=False))
def test_exp_against_libm(x: float) -> None:
    assert ulps_off(f64(math.exp(x)), mp.exp(f64(x))) <= 1


@given(finite_f64)
def test_sqrt_rounds_to_ieee_sqrt(x: float) -> None:
    assume(x > 0)
    assert floats.round_to(mp.sqrt(f64(x)), "f64") == f64(math.sqrt(x))


@given(st.floats(min_value=0, exclude_min=True, allow_infinity=False))
def test_log_against_libm(x: float) -> None:
    assert ulps_off(f64(math.log(x)), mp.log(f64(x))) <= 1
