from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from numeric.bigint import BigInt
from numeric.literal import is_integer_literal, parse_number
from numeric.real import Real


def q(n: Int, d: Int = 1) raises -> Real:
    return Real(BigInt(n), BigInt(d))


def check(text: String, n: Int, d: Int = 1) raises:
    assert_equal(parse_number(text), q(n, d), "for " + text)


def test_decimal() raises:
    check("0", 0)
    check("42", 42)
    check("1_000_000", 1000000)
    check("007", 7)
    check("1.5", 3, 2)
    check("0.1", 1, 10)
    check("1e3", 1000)
    check("1E-3", 1, 1000)
    check("2.5e+2", 250)
    check("1.0", 1)
    check("1_0.2_5", 1025, 100)
    check("2.5E+10", 25000000000)
    check("1e0", 1)
    check("0e5", 0)
    assert_equal(String(parse_number("6.02e23")), "602000000000000000000000")
    assert_equal(
        String(parse_number("123456789012345678901234567890")),
        "123456789012345678901234567890",
    )


def test_hex() raises:
    check("0xff", 255)
    check("0XFF", 255)
    check("0xdead_beef", 0xDEADBEEF)
    check("0x1p-26", 1, 1 << 26)
    check("0x1p20", 1 << 20)
    check("0x1.8p3", 12)
    check("0x1.8p-1", 3, 4)
    check("0x1P+4", 16)
    check("0x1.8", 3, 2)
    check("0x10", 16)
    assert_equal(
        parse_number("0x1.fffffffffffffp1023"),
        Real(BigInt(1 << 53) - BigInt(1)) * Real(BigInt(1) << 971),
    )
    assert_equal(parse_number("0x0.0000000000001p-1022"), Real(BigInt(1), BigInt(1) << 1074))
    assert_equal(String(parse_number("0x10000000000000000")), "18446744073709551616")


def test_integer_flag() raises:
    assert_true(is_integer_literal("12"))
    assert_true(is_integer_literal("0x10"))
    assert_true(is_integer_literal("0xe"))
    assert_true(is_integer_literal("1_000"))
    assert_false(is_integer_literal("12.0"))
    assert_false(is_integer_literal("1e3"))
    assert_false(is_integer_literal("0x10p0"))
    assert_false(is_integer_literal("0x1.8"))
    assert_false(is_integer_literal("2.5E+10"))


def malformed(text: String) raises:
    var failed = False
    try:
        _ = parse_number(text)
    except:
        failed = True
    assert_true(failed, "should be malformed: " + text)


def test_malformed() raises:
    malformed("")
    malformed("-1")
    malformed("+1")
    malformed(" 1")
    malformed("1 ")
    malformed("abc")
    malformed("1.")
    malformed(".5")
    malformed("1e")
    malformed("1e+")
    malformed("1e3.5")
    malformed("1_")
    malformed("_1")
    malformed("1__0")
    malformed("1._5")
    malformed("1e_5")
    malformed("1e1_0")
    malformed("0x")
    malformed("0x.8p1")
    malformed("0xg")
    malformed("0x1p")
    malformed("0x1p+")
    malformed("0x1_")
    malformed("0x_1")
    malformed("0x1.8q3")
    malformed("1x")
    malformed("12abc")
    malformed("1e99999999999")
    malformed("0x1p99999999999")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
