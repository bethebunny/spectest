from std.hash import hash
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from value.bigint import BigInt
from value.float_formats import F32, F64
from value.value import Value


def test_ints_are_canonical() raises:
    var small = Value.int(BigInt(-5))
    assert_true(small == Value.int(-5))
    assert_equal(small.small_int().value(), -5)
    var big = Value.int(BigInt.parse("100000000000000000000"))
    assert_false(big.small_int())
    assert_equal(String(big.as_bigint()), "100000000000000000000")
    assert_false(big == Value.int(0))


def test_structural_identity() raises:
    var a = Value.list([Value.int(1), Value.string("x"), Value.float(F64, 0x8000000000000000)])
    var b = a.copy()
    assert_true(a == b)
    assert_equal(hash(a), hash(b))
    assert_false(a == Value.list([Value.int(1), Value.string("x"), Value.float(F64, 0)]))
    assert_false(Value.float(F32, 0) == Value.float(F64, 0))
    assert_false(Value.list([]) == Value.tuple([]))
    var d = Dict[Value, Int]()
    d[a.copy()] = 7
    assert_equal(d[b], 7)


def test_compound() raises:
    var m = Value.map([Value.string("a"), Value.string("b")], [Value.int(1), Value.int(2)])
    assert_equal(m.count(), 2)
    assert_true(m.item(2) == Value.string("b"))
    with assert_raises():
        _ = Value.map([Value.int(1), Value.int(1)], [Value.int(1), Value.int(2)])
    assert_equal(Value.none().count(), 0)
    assert_true(Value.some(Value.int(3)).item(0) == Value.int(3))
    var r = Value.record("pkg.R", ["x", "y"], [Value.int(1), Value.bool(True)])
    assert_equal(r.name(), "pkg.R")
    assert_equal(r.count(), 2)
    var e = Value.enum("pkg.Color", "RED")
    assert_equal(e.text(), "RED")
    var err = Value.error("builtins.KeyError", ["builtins.LookupError", "builtins.Exception"], "'k'")
    assert_equal(err.item(0).text(), "builtins.LookupError")
    assert_equal(String(Value.int(3)), "int(3)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
