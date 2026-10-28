from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from value.floats import *
from value.float_formats import F16, BF16, F32, F64
from value.literal import parse_number
from value.real import Real


def r(text: String) raises -> Real:
    return parse_number(text)


def neg(text: String) raises -> Real:
    return -parse_number(text)


def test_classification() raises:
    assert_true(is_nan(F64, 0x7FF8000000000000))
    assert_true(is_nan(F64, 0xFFF0000000000001))
    assert_false(is_nan(F64, 0x7FF0000000000000))
    assert_true(is_inf(F64, 0xFFF0000000000000))
    assert_true(is_zero(F64, 0x8000000000000000))
    assert_false(is_zero(F64, 1))
    assert_true(is_subnormal(F64, 1))
    assert_false(is_subnormal(F64, 0))
    assert_true(is_normal(F64, 0x0010000000000000))
    assert_false(is_normal(F64, 0x7FF0000000000000))
    assert_true(is_finite(F64, 0x7FEFFFFFFFFFFFFF))
    assert_false(is_finite(F64, 0x7FF0000000000000))
    assert_false(is_finite(F64, 0x7FF8000000000000))
    assert_true(signbit(F64, 0x8000000000000000))
    assert_false(signbit(F64, 0x7FF8000000000000))
    assert_true(is_normal(BF16, 0x3F80))
    assert_true(is_subnormal(F16, 0x03FF))
    assert_true(signbit(F32, 0x80000000))


def test_to_real() raises:
    assert_equal(to_real(F64, 0x3FF8000000000000), r("1.5"))
    assert_equal(to_real(F64, 0xBFF8000000000000), neg("1.5"))
    assert_equal(to_real(F64, 1), r("0x1p-1074"))
    assert_equal(to_real(F64, 0x7FEFFFFFFFFFFFFF), r("0x1.fffffffffffffp1023"))
    assert_equal(to_real(F64, 0x8000000000000000), Real())
    assert_equal(to_real(F16, 0x7BFF), r("65504"))
    assert_equal(to_real(F16, 1), r("0x1p-24"))
    assert_equal(to_real(BF16, 0x3F80), Real(1))
    assert_equal(to_real(F32, 0x3DCCCCCD), r("0x1.99999ap-4"))
    assert_equal(to_real(F64, 0x7FF0000000000000), Real.infinity())
    assert_equal(to_real(F32, 0xFF800000), Real.infinity(True))
    with assert_raises(contains="promoting a NaN"):
        _ = to_real(F64, 0x7FF8000000000000)
    with assert_raises(contains="promoting a NaN"):
        _ = to_real(F16, 0xFC01)


def test_round_basic() raises:
    assert_equal(round_to(F64, r("1.5")), 0x3FF8000000000000)
    assert_equal(round_to(F64, neg("1.5")), 0xBFF8000000000000)
    assert_equal(round_to(F64, r("0.1")), 0x3FB999999999999A)
    assert_equal(round_to(F32, r("0.1")), 0x3DCCCCCD)
    assert_equal(round_to(F16, r("0.1")), 0x2E66)
    assert_equal(round_to(BF16, r("0.1")), 0x3DCD)
    assert_equal(round_to(F64, Real.infinity()), 0x7FF0000000000000)
    assert_equal(round_to(F32, Real.infinity(True)), 0xFF800000)
    assert_equal(round_to(F64, Real()), 0)


def test_ties_to_even() raises:
    # 1 + 2**-53 is halfway between 1 and 1 + 2**-52: rounds to the even 1.
    assert_equal(round_to(F64, r("0x1.0000000000000_8p0")), 0x3FF0000000000000)
    # Above the tie, up.
    assert_equal(round_to(F64, r("0x1.0000000000000_81p0")), 0x3FF0000000000001)
    # 1 + 3 * 2**-53 is halfway between an odd and an even neighbour: the even one.
    assert_equal(round_to(F64, r("0x1.0000000000001_8p0")), 0x3FF0000000000002)
    assert_equal(round_to(F64, neg("0x1.0000000000001_8p0")), 0xBFF0000000000002)
    # f16: 2049 is halfway between 2048 and 2050.
    assert_equal(round_to(F16, r("2049")), 0x6800)
    assert_equal(round_to(F16, r("2051")), 0x6802)
    # A carry into the exponent.
    assert_equal(round_to(F16, r("2047.5")), 0x6800)
    assert_equal(round_to(BF16, r("0x1.ffp0")), 0x4000)


def test_overflow() raises:
    # Largest finite f64 and the halfway point above it.
    assert_equal(round_to(F64, r("0x1.fffffffffffffp1023")), 0x7FEFFFFFFFFFFFFF)
    assert_equal(round_to(F64, r("0x1.fffffffffffff_7ffp1023")), 0x7FEFFFFFFFFFFFFF)
    assert_equal(round_to(F64, r("0x1.fffffffffffff_8p1023")), 0x7FF0000000000000)
    assert_equal(round_to(F64, neg("0x1.fffffffffffff_8p1023")), 0xFFF0000000000000)
    assert_equal(round_to(F64, r("0x1p1024")), 0x7FF0000000000000)
    assert_equal(round_to(F64, r("1e400")), 0x7FF0000000000000)
    assert_equal(round_to(F16, r("65504")), 0x7BFF)
    assert_equal(round_to(F16, r("65519.99")), 0x7BFF)
    assert_equal(round_to(F16, r("65520")), 0x7C00)
    assert_equal(round_to(F16, neg("65520")), 0xFC00)
    assert_equal(round_to(F32, r("3.5e38")), 0x7F800000)


def test_subnormals() raises:
    var smallest = r("0x1p-1074")
    assert_equal(round_to(F64, smallest), 1)
    # Halfway between the largest subnormal and the smallest normal: even, the normal.
    assert_equal(round_to(F64, r("0x1.fffffffffffffp-1023")), 0x0010000000000000)
    assert_equal(round_to(F64, r("0x1.ffffffffffffe_fp-1023")), 0x000FFFFFFFFFFFFF)
    assert_equal(round_to(F64, r("0x1p-1022")), 0x0010000000000000)
    # Between subnormals 1 and 2: 1.5 * 2**-1074 ties to the even 2.
    assert_equal(round_to(F64, r("0x1.8p-1074")), 2)
    assert_equal(round_to(F64, r("0x1.4p-1074")), 1)
    assert_equal(round_to(F16, r("0x1p-24")), 1)
    assert_equal(round_to(F16, r("0x1.8p-24")), 2)
    assert_equal(round_to(F16, r("0x1.ffp-15")), 0x03FE)


def test_underflow_and_signed_zero() raises:
    # Exactly half the smallest subnormal: ties to even, which is zero.
    assert_equal(round_to(F64, r("0x1p-1075")), 0)
    assert_equal(round_to(F64, neg("0x1p-1075")), 0x8000000000000000)
    # Just above half: the smallest subnormal.
    assert_equal(round_to(F64, r("0x1.0000000000001p-1075")), 1)
    assert_equal(round_to(F64, neg("0x1.0000000000001p-1075")), 0x8000000000000001)
    # Far below.
    assert_equal(round_to(F64, r("1e-400")), 0)
    assert_equal(round_to(F64, neg("1e-400")), 0x8000000000000000)
    assert_equal(round_to(F32, neg("1e-60")), 0x80000000)
    assert_equal(round_to(F16, neg("0x1p-26")), 0x8000)
    assert_equal(round_to(F16, r("0x1p-26")), 0)
    assert_equal(round_to(F16, r("0x1p-25")), 0)
    assert_equal(round_to(F16, r("0x1.1p-25")), 1)
    # An exact zero is +0.
    assert_equal(round_to(F32, Real()), 0)


def test_exactly() raises:
    assert_equal(exactly(F64, r("1.5")).value(), 0x3FF8000000000000)
    assert_false(Bool(exactly(F64, r("0.1"))))
    assert_equal(exactly(F32, r("0.5")).value(), 0x3F000000)
    assert_equal(exactly(F64, Real()).value(), 0)
    assert_equal(exactly(F64, r("0x1p-1074")).value(), 1)
    assert_false(Bool(exactly(F64, r("0x1p-1075"))))
    assert_false(Bool(exactly(F64, r("0x1p1024"))))
    assert_equal(exactly(F64, r("0x1.fffffffffffffp1023")).value(), 0x7FEFFFFFFFFFFFFF)
    assert_equal(exactly(F64, Real.infinity()).value(), 0x7FF0000000000000)
    assert_equal(exactly(F64, Real.infinity(True)).value(), 0xFFF0000000000000)
    assert_equal(exactly(F16, neg("65504")).value(), 0xFBFF)
    assert_false(Bool(exactly(F16, r("65505"))))
    assert_equal(exactly(F16, neg("2048")).value(), 0xE800)
    assert_false(Bool(exactly(F16, r("2049"))))
    assert_false(Bool(exactly(F32, neg("1e-60"))))


def test_next_up_down() raises:
    # Zeros.
    assert_equal(next_up(F64, 0), 1)
    assert_equal(next_up(F64, 0x8000000000000000), 1)
    assert_equal(next_down(F64, 0), 0x8000000000000001)
    assert_equal(next_down(F64, 0x8000000000000000), 0x8000000000000001)
    # Infinities.
    assert_equal(next_up(F64, 0x7FF0000000000000), 0x7FF0000000000000)
    assert_equal(next_down(F64, 0x7FF0000000000000), 0x7FEFFFFFFFFFFFFF)
    assert_equal(next_up(F64, 0xFFF0000000000000), 0xFFEFFFFFFFFFFFFF)
    assert_equal(next_down(F64, 0xFFF0000000000000), 0xFFF0000000000000)
    # Extremes.
    assert_equal(next_up(F64, 0x7FEFFFFFFFFFFFFF), 0x7FF0000000000000)
    assert_equal(next_down(F64, 0xFFEFFFFFFFFFFFFF), 0xFFF0000000000000)
    assert_equal(next_up(F64, 0xFFEFFFFFFFFFFFFF), 0xFFEFFFFFFFFFFFFE)
    assert_equal(next_down(F64, 0x3FF0000000000000), 0x3FEFFFFFFFFFFFFF)
    assert_equal(next_up(F64, 0x000FFFFFFFFFFFFF), 0x0010000000000000)
    assert_equal(next_up(F64, 0x8000000000000001), 0x8000000000000000)
    assert_equal(next_down(F64, 1), 0)
    # A NaN stays.
    assert_equal(next_up(F64, 0x7FF8000000000001), 0x7FF8000000000001)
    assert_equal(next_down(F64, 0xFFF8000000000001), 0xFFF8000000000001)
    # Other formats.
    assert_equal(next_up(F16, 0x7BFF), 0x7C00)
    assert_equal(next_down(F16, 0x0000), 0x8001)
    assert_equal(next_up(BF16, 0xFF7F), 0xFF7E)
    assert_equal(next_up(F32, 0x3F800000), 0x3F800001)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
