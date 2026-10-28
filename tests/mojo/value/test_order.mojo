from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from value.bigint import BigInt
from value.float_formats import F64
from value.order import compare, is_ord
from value.value import Value


def real(n: Int, d: Int) -> Value:
    return Value.real(BigInt(n), BigInt(d))


def test_bool() raises:
    assert_equal(compare(Value.bool(False), Value.bool(True)), -1)
    assert_equal(compare(Value.bool(True), Value.bool(False)), 1)
    assert_equal(compare(Value.bool(True), Value.bool(True)), 0)


def test_int_and_real() raises:
    assert_equal(compare(Value.int(-5), Value.int(3)), -1)
    assert_equal(compare(Value.int(3), Value.int(3)), 0)
    var big = Value.int(BigInt.parse("100000000000000000000"))
    assert_equal(compare(big, Value.int(5)), 1)
    assert_equal(compare(Value.int(-5), big), -1)
    assert_equal(compare(real(1, 2), real(1, 3)), 1)
    assert_equal(compare(Value.int(1), real(1, 2)), 1)
    assert_equal(compare(real(1, 2), Value.int(1)), -1)
    assert_equal(compare(real(4, 2 // 2), Value.int(4)), 0)
    assert_equal(compare(real(-7, 2), Value.int(-3)), -1)
    var pinf = real(1, 0)
    var ninf = real(-1, 0)
    assert_equal(compare(ninf, big), -1)
    assert_equal(compare(big, pinf), -1)
    assert_equal(compare(pinf, Value.int(0)), 1)
    assert_equal(compare(Value.int(0), ninf), 1)
    assert_equal(compare(pinf, pinf), 0)
    assert_equal(compare(ninf, pinf), -1)
    assert_equal(compare(pinf, ninf), 1)


def test_string_and_bytes() raises:
    assert_equal(compare(Value.string("a"), Value.string("b")), -1)
    assert_equal(compare(Value.string("ab"), Value.string("a")), 1)
    assert_equal(compare(Value.string(""), Value.string("")), 0)
    # U+FF5E is in the BMP, U+1F600 is not: UTF-16 would put the emoji first.
    assert_equal(compare(Value.string("～"), Value.string("\U0001F600")), -1)
    assert_equal(compare(Value.string("\U0001F600"), Value.string("～")), 1)
    assert_equal(compare(Value.bytes([1, 255]), Value.bytes([1, 2])), 1)
    assert_equal(compare(Value.bytes([1]), Value.bytes([1, 0])), -1)
    assert_equal(compare(Value.bytes([]), Value.bytes([])), 0)


def test_sequences() raises:
    var a = Value.list([Value.int(1), Value.int(2)])
    assert_equal(compare(a, Value.list([Value.int(1), Value.int(3)])), -1)
    assert_equal(compare(a, Value.list([Value.int(1)])), 1)
    assert_equal(compare(Value.list([Value.int(1)]), a), -1)
    assert_equal(compare(a, a.copy()), 0)
    assert_equal(compare(Value.list([]), a), -1)
    assert_equal(compare(Value.tuple([Value.int(1), Value.string("b")]), Value.tuple([Value.int(1), Value.string("a")])), 1)
    assert_equal(compare(Value.list([Value.list([Value.int(2)])]), Value.list([Value.list([Value.int(1), Value.int(9)])])), 1)


def test_raises() raises:
    var m = Value.map([Value.int(1)], [Value.int(1)])
    with assert_raises():
        _ = compare(m, m)
    with assert_raises():
        _ = compare(Value.float(F64, 0), Value.float(F64, 0))
    with assert_raises():
        _ = compare(Value.none(), Value.none())
    with assert_raises():
        _ = compare(Value.int(1), Value.string("1"))
    with assert_raises():
        _ = compare(Value.list([Value.int(1)]), Value.tuple([Value.int(1)]))
    with assert_raises():
        _ = compare(Value.list([m.copy()]), Value.list([m.copy()]))
    with assert_raises():
        _ = compare(Value.qerr(BigInt(1), BigInt(0)), Value.qerr(BigInt(1), BigInt(0)))


def test_is_ord() raises:
    assert_true(is_ord(Value.bool(True)))
    assert_true(is_ord(Value.int(1)))
    assert_true(is_ord(real(1, 2)))
    assert_true(is_ord(Value.string("")))
    assert_true(is_ord(Value.bytes([])))
    assert_true(is_ord(Value.list([])))
    assert_true(is_ord(Value.tuple([Value.int(1), Value.string("a")])))
    assert_false(is_ord(Value.float(F64, 0)))
    assert_false(is_ord(Value.list([Value.float(F64, 0)])))
    assert_false(is_ord(Value.map([], [])))
    assert_false(is_ord(Value.none()))
    assert_false(is_ord(Value.enum("p.E", "A")))
    assert_false(is_ord(Value.handle(1, "p.H")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
