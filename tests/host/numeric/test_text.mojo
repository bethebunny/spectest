from std.testing import assert_equal, TestSuite

from value.bigint import BigInt
from value.literal import parse_number
from value.real import Real
from value.number_text import approximate_decimal, exact_decimal, float_text


def q(n: String, d: String = "1") raises -> Real:
    return Real(BigInt.parse(n), BigInt.parse(d))


def test_float_text_f64() raises:
    assert_equal(float_text(4, 0x3FF0000000000000), "1.0")
    assert_equal(float_text(4, 0x3FB999999999999A), "0.1")
    assert_equal(float_text(4, 0xBFF8000000000000), "-1.5")
    assert_equal(float_text(4, 0x3EE4F8B588E368F1), "1e-05")
    assert_equal(float_text(4, 0x4341C37937E08000), "1e+16")
    assert_equal(float_text(4, 0x4341C37937E07FFF), "9999999999999998.0")
    assert_equal(float_text(4, 0x8000000000000000), "-0.0")
    assert_equal(float_text(4, 0), "0.0")
    assert_equal(float_text(4, 1), "5e-324")
    assert_equal(float_text(4, 0x7FEFFFFFFFFFFFFF), "1.7976931348623157e+308")
    assert_equal(float_text(4, 0x3FD5555555555555), "0.3333333333333333")


def test_float_text_special() raises:
    assert_equal(float_text(4, 0x7FF0000000000000), "inf")
    assert_equal(float_text(4, 0xFFF0000000000000), "-inf")
    assert_equal(float_text(4, 0x7FF8000000000000), "nan")
    assert_equal(float_text(4, 0x7FF8000000000001), "nan:0x7ff8000000000001")
    assert_equal(float_text(4, 0xFFF8000000000000), "nan:0xfff8000000000000")
    assert_equal(float_text(4, 0x7FF0000000000001), "nan:0x7ff0000000000001")
    assert_equal(float_text(3, 0x7FC00000), "nan")
    assert_equal(float_text(3, 0x7FC00001), "nan:0x7fc00001")
    assert_equal(float_text(1, 0x7E00), "nan")
    assert_equal(float_text(1, 0xFE01), "nan:0xfe01")
    assert_equal(float_text(2, 0x7FC0), "nan")
    assert_equal(float_text(2, 0x7F81), "nan:0x7f81")


def test_float_text_small_formats() raises:
    assert_equal(float_text(3, 0x3DCCCCCD), "0.1")
    assert_equal(float_text(3, 0x3F800000), "1.0")
    assert_equal(float_text(3, 1), "1e-45")
    assert_equal(float_text(3, 0x7F7FFFFF), "3.4028235e+38")
    assert_equal(float_text(1, 0x7BFF), "65500.0")
    assert_equal(float_text(1, 1), "6e-08")
    assert_equal(float_text(1, 0x3C00), "1.0")
    assert_equal(float_text(1, 0x2E66), "0.1")
    assert_equal(float_text(2, 0x3F80), "1.0")
    assert_equal(float_text(2, 0x3DCD), "0.1")
    assert_equal(float_text(2, 0x7F7F), "3.39e+38")
    assert_equal(float_text(2, 0x8001), "-9e-41")


def test_unknown_format() raises:
    var failed = False
    try:
        _ = float_text(0, 0)
    except:
        failed = True
    assert_equal(failed, True)


def real_text(r: Real) -> String:
    if r.is_inf():
        return "-inf" if r.numerator.negative else "inf"
    if r.is_zero():
        return "0"
    var sign = "-" if r.numerator.negative else ""
    var exact = exact_decimal(abs(r), limit=25)
    if exact is not None:
        return sign + exact.value()
    return "~" + sign + approximate_decimal(abs(r), digits=20)


def test_real_text() raises:
    assert_equal(real_text(Real()), "0")
    assert_equal(real_text(Real(42)), "42")
    assert_equal(real_text(Real(-42)), "-42")
    assert_equal(real_text(Real.infinity()), "inf")
    assert_equal(real_text(Real.infinity(True)), "-inf")
    assert_equal(real_text(q("5", "2")), "2.5")
    assert_equal(real_text(q("-5", "2")), "-2.5")
    assert_equal(real_text(q("1", "8")), "0.125")
    assert_equal(real_text(q("123", "1000000")), "0.000123")
    assert_equal(real_text(q("1", "1000000")), "0.000001")
    assert_equal(real_text(q("1", "100000")), "0.00001")
    assert_equal(real_text(q("7", "10000000000000000000000000")), "0.0000000000000000000000007")
    assert_equal(real_text(q("9999999999999999999999999")), "9999999999999999999999999")
    assert_equal(real_text(q("10000000000000000000000000")), "~1.0e+25")
    assert_equal(real_text(q("1", "3")), "~0.33333333333333333333")
    assert_equal(real_text(q("-2", "3")), "~-0.66666666666666666667")
    assert_equal(real_text(q("1", "1073741824")), "~9.3132257461547851562e-10")
    assert_equal(real_text(q("1000000000000000000000000000000")), "~1.0e+30")
    assert_equal(real_text(q("1", "1000000000000000000000000000000")), "~1.0e-30")
    assert_equal(real_text(q("12345678901234567890123456", "7")), "~1.7636684144620811272e+24")
    assert_equal(real_text(q("1", "3000000000")), "~3.3333333333333333333e-10")
    assert_equal(real_text(q("2000000000000000000000", "3")), "~6.6666666666666666667e+20")
    assert_equal(real_text(q("200000000000000000000", "3")), "~66666666666666666667")
    assert_equal(real_text(q("20000000000000000000", "3")), "~6666666666666666666.7")
    assert_equal(real_text(q("1", "1500000")), "~6.6666666666666666667e-7")
    assert_equal(real_text(q("1", "150000")), "~6.6666666666666666667e-6")
    assert_equal(real_text(q("33333333333333333333333", "100000000000000000000000000")), "~0.00033333333333333333333")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
