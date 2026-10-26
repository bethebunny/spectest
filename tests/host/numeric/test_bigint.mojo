from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from numeric.bigint import BigInt


def test_text() raises:
    assert_equal(String(BigInt(0)), "0")
    assert_equal(String(BigInt(-42)), "-42")
    assert_equal(String(BigInt(Int.MIN)), "-9223372036854775808")
    var big = BigInt.parse("123_456_789_012_345_678_901_234_567_890")
    assert_equal(String(big), "123456789012345678901234567890")
    assert_equal(String(BigInt.parse("-0x10000000000000000")), "-18446744073709551616")
    assert_equal(BigInt.parse("-0x10000000000000000").hex(), "-0x10000000000000000")
    assert_equal(BigInt(255).hex(), "0xff")
    assert_equal(BigInt(0).hex(), "0x0")
    with assert_raises():
        _ = BigInt.parse("12a")


def test_arithmetic() raises:
    var a = BigInt.parse("100000000000000000000")
    var b = BigInt(-7)
    assert_equal(String(a + b), "99999999999999999993")
    assert_equal(String(b - a), "-100000000000000000007")
    assert_equal(String(a * b), "-700000000000000000000")
    # Floored, as Python: -7 // 2 == -4, -7 % 2 == 1, 7 % -2 == -1.
    assert_equal(String(BigInt(-7) // BigInt(2)), "-4")
    assert_equal(String(BigInt(-7) % BigInt(2)), "1")
    assert_equal(String(BigInt(7) % BigInt(-2)), "-1")
    assert_equal(String(BigInt(7) // BigInt(-2)), "-4")
    assert_equal(String(BigInt(6) // BigInt(-2)), "-3")
    with assert_raises():
        _ = BigInt(1) // BigInt(0)


def test_order_and_identity() raises:
    assert_true(BigInt(-3) < BigInt(2))
    assert_true(BigInt(-3) < BigInt(-2))
    assert_false(BigInt(2) < BigInt(2))
    assert_true(-BigInt(0) == BigInt(0))
    assert_false((-BigInt(0)).negative)
    assert_equal(BigInt(-5).int64_or_none().value(), -5)
    assert_equal(BigInt(Int.MIN).int64_or_none().value(), Int64.MIN)
    assert_false(BigInt.parse("9223372036854775808").int64_or_none())
    assert_equal(BigInt(-8).bit_length(), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
