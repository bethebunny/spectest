from std.testing import assert_equal, assert_true, assert_false, TestSuite

from numeric.bigint import BigInt
from sets import SetContext


def _big(text: StringSlice) raises -> Optional[BigInt]:
    return Optional[BigInt](BigInt.parse(text))


def test_interval() raises:
    var c = SetContext()
    var s = c.interval(10, 20, 8)
    assert_equal(c.count(s), UInt128(10))
    assert_false(c.contains(s, 9))
    assert_true(c.contains(s, 10))
    assert_true(c.contains(s, 19))
    assert_false(c.contains(s, 20))
    assert_true(c.is_empty(c.interval(5, 5, 8)))
    assert_true(c.is_empty(c.interval(6, 5, 8)))
    assert_equal(c.count(c.interval(0, 256, 8)), UInt128(256))
    assert_true(c.equal(c.interval(0, 256, 8), c.full(8)))


def test_interval_at_64() raises:
    var c = SetContext()
    var top = c.interval_inclusive(UInt64.MAX - 9, UInt64.MAX, 64)
    assert_equal(c.count(top), UInt128(10))
    assert_true(c.contains(top, UInt64.MAX))
    assert_false(c.contains(top, UInt64.MAX - 10))
    assert_equal(c.count(c.full(64)), UInt128(1) << 64)
    assert_equal(c.nth(top, 0), UInt64.MAX - 9)
    assert_equal(c.nth(top, 9), UInt64.MAX)


def test_exactly() raises:
    var c = SetContext()
    var s = c.exactly([7, 3, 200, 3], 8)
    assert_equal(c.count(s), UInt128(3))
    var members = c.members(s, 10)
    assert_equal(len(members), 3)
    assert_equal(members[0], 3)
    assert_equal(members[1], 7)
    assert_equal(members[2], 200)
    assert_true(c.is_empty(c.exactly([], 8)))


def test_members_limit() raises:
    var c = SetContext()
    var raised = False
    try:
        _ = c.members(c.full(8), 100)
    except:
        raised = True
    assert_true(raised)


def test_int_range_i8() raises:
    var c = SetContext()
    var all = c.int_range(8, True, _big("-128"), _big("128"))
    assert_true(c.equal(all, c.full(8)))
    var mid = c.int_range(8, True, _big("-5"), _big("5"))
    assert_equal(c.count(mid), UInt128(10))
    assert_true(c.contains(mid, 0xFB))
    assert_false(c.contains(mid, 0x05))
    assert_true(c.contains(mid, 0x04))
    assert_true(c.contains(mid, 0))
    assert_false(c.contains(mid, 0xFA))


def test_int_range_open_and_clamped() raises:
    var c = SetContext()
    var none = Optional[BigInt]()
    assert_true(c.equal(c.int_range(8, True, none, none), c.full(8)))
    var neg = c.int_range(8, True, none, _big("0"))
    assert_equal(c.count(neg), UInt128(128))
    assert_true(c.contains(neg, 0x80))
    assert_true(c.contains(neg, 0xFF))
    assert_false(c.contains(neg, 0))
    var pos = c.int_range(8, True, _big("0"), none)
    assert_equal(c.count(pos), UInt128(128))
    assert_true(c.contains(pos, 0))
    assert_true(c.contains(pos, 127))
    # Clamped to the type.
    assert_true(c.equal(c.int_range(8, True, _big("-1000"), _big("1000")), c.full(8)))
    assert_true(c.equal(c.int_range(8, False, _big("-1000"), _big("1000")), c.full(8)))
    assert_true(c.is_empty(c.int_range(8, False, none, _big("0"))))
    assert_true(c.is_empty(c.int_range(8, True, _big("5"), _big("5"))))
    assert_true(c.is_empty(c.int_range(8, True, _big("200"), none)))
    assert_true(c.is_empty(c.int_range(8, True, none, _big("-200"))))
    var u = c.int_range(8, False, _big("250"), none)
    assert_equal(c.count(u), UInt128(6))
    assert_true(c.contains(u, 255))


def test_int_range_u64() raises:
    var c = SetContext()
    var none = Optional[BigInt]()
    var near = c.int_range(64, False, _big("18446744073709551600"), _big("18446744073709551616"))
    assert_equal(c.count(near), UInt128(16))
    assert_true(c.contains(near, UInt64.MAX))
    assert_false(c.contains(near, UInt64.MAX - 16))
    var open = c.int_range(64, False, _big("18446744073709551615"), none)
    assert_equal(c.count(open), UInt128(1))
    assert_true(c.contains(open, UInt64.MAX))
    var s64 = c.int_range(64, True, _big("-3"), _big("2"))
    assert_equal(c.count(s64), UInt128(5))
    assert_true(c.contains(s64, UInt64.MAX - 2))
    assert_true(c.contains(s64, 1))
    assert_false(c.contains(s64, 2))
    var all = c.int_range(64, True, none, none)
    assert_true(c.equal(all, c.full(64)))
    var low = c.int_range(64, True, _big("-9223372036854775808"), _big("-9223372036854775807"))
    assert_equal(c.count(low), UInt128(1))
    assert_true(c.contains(low, UInt64(1) << 63))


def test_patterns() raises:
    var c = SetContext()
    # f16 nan | inf
    var ni = c.pattern("?111.11??.*.*", 16)
    var exp_all = c.pattern("?111.11??.????.????", 16)
    assert_true(c.equal(ni, exp_all))
    assert_equal(c.count(ni), UInt128(2 * 1024))
    assert_equal(c.count(c.pattern("1???.????", 8)), UInt128(128))
    assert_true(c.equal(c.pattern("1???.????", 8), c.interval(128, 256, 8)))
    assert_true(c.equal(c.pattern("1*.*", 8), c.interval(128, 256, 8)))
    assert_true(c.equal(c.pattern("101", 3), c.exactly([5], 3)))
    assert_equal(c.count(c.pattern("*1.0000", 8)), UInt128(8))
    var quiet = c.pattern("?111.1111.1111.1*.*.*.*.*.*.*.*.*.*.*.*.*", 64)
    assert_equal(c.count(quiet), UInt128(1) << 52)


def test_pattern_errors() raises:
    var c = SetContext()
    var message = String()
    try:
        _ = c.pattern("0000.0000", 64)
    except e:
        message = String(e)
    assert_true("8 bits, not 64" in message)
    for bad in ["xyz", "00.0000", "0000.000", "0|1", "1.2", "", "**", "11111"]:
        var raised = False
        try:
            _ = c.pattern(bad, 8)
        except:
            raised = True
        assert_true(raised, "pattern should be rejected: " + String(bad))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
