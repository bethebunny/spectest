from std.testing import assert_equal, assert_true, TestSuite

from numeric.bigint import BigInt
from numeric.fixed import int_max, int_min, low_mask, pattern_of, signed_of, wrapped


def test_bounds() raises:
    assert_equal(int_min(8, True), BigInt(-128))
    assert_equal(int_max(8, True), BigInt(127))
    assert_equal(int_min(8, False), BigInt(0))
    assert_equal(int_max(8, False), BigInt(255))
    assert_equal(String(int_min(64, True)), "-9223372036854775808")
    assert_equal(String(int_max(64, False)), "18446744073709551615")
    assert_equal(String(int_max(128, False)), "340282366920938463463374607431768211455")


def test_wrapped() raises:
    assert_equal(wrapped(BigInt(-1), 8, signed=False), BigInt(255))
    assert_equal(wrapped(BigInt(-1), 8, signed=True), BigInt(-1))
    assert_equal(wrapped(BigInt(255), 8, signed=True), BigInt(-1))
    assert_equal(wrapped(BigInt(300), 8, signed=False), BigInt(44))
    assert_equal(wrapped(BigInt(-256), 8, signed=True), BigInt(0))
    assert_equal(wrapped(BigInt(128), 8, signed=True), BigInt(-128))
    assert_equal(wrapped(BigInt(1) << 100, 64, signed=False), BigInt(0))
    assert_equal(wrapped(-(BigInt(1) << 100) + 5, 64, signed=True), BigInt(5))


def test_patterns() raises:
    assert_equal(low_mask(0), 0)
    assert_equal(low_mask(5), 31)
    assert_equal(low_mask(64), UInt64.MAX)
    assert_equal(pattern_of(BigInt(-1), 8), 0xFF)
    assert_equal(pattern_of(BigInt(-128), 8), 0x80)
    assert_equal(pattern_of(BigInt(Int.MIN), 64), 0x8000000000000000)
    assert_equal(pattern_of(BigInt(UInt64.MAX), 64), UInt64.MAX)
    assert_equal(signed_of(0xFF, 8), -1)
    assert_equal(signed_of(0x7F, 8), 127)
    assert_equal(signed_of(0x8000000000000000, 64), Int.MIN)
    for x in [-128, -1, 0, 1, 127]:
        assert_equal(signed_of(pattern_of(BigInt(x), 8), 8), x)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
