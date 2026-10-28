from std.hash import default_hasher
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from value.bigint import BigInt
from value.equality import canonical_eq, same, hash_same
from value.float_formats import F32, F64
from value.value import Value


def same_hash(v: Value) -> UInt64:
    var h = default_hasher()
    hash_same(v, h)
    return h^.finish()


def two_maps() raises -> Tuple[Value, Value]:
    var a = Value.map(
        [Value.string("a"), Value.string("b")], [Value.int(1), Value.list([Value.int(2)])]
    )
    var b = Value.map(
        [Value.string("b"), Value.string("a")], [Value.list([Value.int(2)]), Value.int(1)]
    )
    return (a^, b^)


def test_canonical_scalars() raises:
    assert_true(canonical_eq(Value.bool(True), Value.bool(True)))
    assert_false(canonical_eq(Value.bool(True), Value.bool(False)))
    assert_true(canonical_eq(Value.string("x"), Value.string("x")))
    assert_false(canonical_eq(Value.string("x"), Value.string("y")))
    assert_true(canonical_eq(Value.bytes([1, 2]), Value.bytes([1, 2])))
    assert_false(canonical_eq(Value.bytes([1, 2]), Value.bytes([1])))
    assert_true(canonical_eq(Value.int(-3), Value.int(-3)))
    var big = Value.int(BigInt.parse("100000000000000000000"))
    assert_true(canonical_eq(big, Value.int(BigInt.parse("100000000000000000000"))))
    assert_false(canonical_eq(big, Value.int(1)))
    assert_false(canonical_eq(Value.int(1), Value.string("1")))
    assert_true(canonical_eq(Value.enum("p.E", "A"), Value.enum("p.E", "A")))
    assert_false(canonical_eq(Value.enum("p.E", "A"), Value.enum("p.E", "B")))
    assert_false(canonical_eq(Value.enum("p.E", "A"), Value.enum("p.F", "A")))


def test_canonical_real_and_qerr() raises:
    var half = Value.real(BigInt(1), BigInt(2))
    assert_true(canonical_eq(half, Value.real(BigInt(1), BigInt(2))))
    assert_false(canonical_eq(half, Value.real(BigInt(1), BigInt(3))))
    assert_true(canonical_eq(Value.real(BigInt(1), BigInt(0)), Value.real(BigInt(1), BigInt(0))))
    assert_false(canonical_eq(Value.real(BigInt(1), BigInt(0)), Value.real(BigInt(-1), BigInt(0))))
    assert_true(canonical_eq(Value.real(BigInt(3), BigInt(1)), Value.int(3)))
    assert_false(canonical_eq(half, Value.int(0)))
    assert_true(canonical_eq(Value.qerr(BigInt(3), BigInt(2)), Value.qerr(BigInt(3), BigInt(2))))
    assert_false(canonical_eq(Value.qerr(BigInt(3), BigInt(2)), Value.qerr(BigInt(3), BigInt(1))))


def test_canonical_compound() raises:
    assert_true(canonical_eq(Value.list([Value.int(1), Value.int(2)]), Value.list([Value.int(1), Value.int(2)])))
    assert_false(canonical_eq(Value.list([Value.int(1), Value.int(2)]), Value.list([Value.int(2), Value.int(1)])))
    assert_false(canonical_eq(Value.list([Value.int(1)]), Value.tuple([Value.int(1)])))
    assert_true(canonical_eq(Value.tuple([Value.int(1), Value.string("a")]), Value.tuple([Value.int(1), Value.string("a")])))
    assert_true(canonical_eq(Value.none(), Value.none()))
    assert_true(canonical_eq(Value.some(Value.int(1)), Value.some(Value.int(1))))
    assert_false(canonical_eq(Value.some(Value.int(1)), Value.none()))
    var pair = two_maps()
    assert_true(canonical_eq(pair[0], pair[1]))
    var other = Value.map([Value.string("a"), Value.string("b")], [Value.int(1), Value.list([Value.int(3)])])
    assert_false(canonical_eq(pair[0], other))
    assert_false(canonical_eq(pair[0], Value.map([Value.string("a")], [Value.int(1)])))
    var r1 = Value.record("p.R", ["x", "y"], [Value.int(1), Value.bool(True)])
    var r2 = Value.record("p.R", ["y", "x"], [Value.bool(True), Value.int(1)])
    assert_true(canonical_eq(r1, r2))
    assert_false(canonical_eq(r1, Value.record("p.S", ["x", "y"], [Value.int(1), Value.bool(True)])))
    assert_false(canonical_eq(r1, Value.record("p.R", ["x", "y"], [Value.int(2), Value.bool(True)])))


def test_canonical_raises() raises:
    var f = Value.float(F64, 0)
    with assert_raises():
        _ = canonical_eq(f, f)
    with assert_raises():
        _ = canonical_eq(Value.list([Value.int(1), f.copy()]), Value.list([Value.int(1), f.copy()]))
    with assert_raises():
        _ = canonical_eq(Value.list([Value.int(1)]), Value.list([f.copy()]))
    with assert_raises():
        _ = canonical_eq(Value.some(Value.handle(1, "p.H")), Value.none())
    with assert_raises():
        _ = canonical_eq(Value.error("p.E", [], "m"), Value.error("p.E", [], "m"))
    with assert_raises():
        _ = canonical_eq(Value.map([Value.int(1)], [f.copy()]), Value.map([Value.int(1)], [f.copy()]))


def test_same() raises:
    assert_true(same(Value.float(F64, 0), Value.float(F64, 0)))
    assert_false(same(Value.float(F64, 0), Value.float(F64, 0x8000000000000000)))
    assert_false(same(Value.float(F64, 0), Value.float(F32, 0)))
    var nan1 = Value.float(F64, 0x7FF8000000000001)
    var nan2 = Value.float(F64, 0x7FF8000000000002)
    assert_true(same(nan1, nan1.copy()))
    assert_false(same(nan1, nan2))
    assert_true(same(Value.handle(3, "p.H"), Value.handle(3, "p.H")))
    assert_false(same(Value.handle(3, "p.H"), Value.handle(4, "p.H")))
    assert_true(same(Value.error("p.E", ["p.B"], "m"), Value.error("p.E", ["p.B"], "m")))
    assert_false(same(Value.error("p.E", ["p.B"], "m"), Value.error("p.E", ["p.B"], "n")))
    assert_true(same(Value.list([nan1.copy()]), Value.list([nan1.copy()])))
    assert_false(same(Value.list([nan1.copy()]), Value.list([nan2.copy()])))
    assert_true(same(Value.string("a"), Value.string("a")))
    assert_false(same(Value.int(1), Value.bool(True)))
    assert_false(same(Value.int(3), Value.real(BigInt(3), BigInt(1))))
    var pair = two_maps()
    assert_true(same(pair[0], pair[1]))
    var fa = Value.map([Value.int(1), Value.int(2)], [nan1.copy(), nan2.copy()])
    var fb = Value.map([Value.int(2), Value.int(1)], [nan2.copy(), nan1.copy()])
    var fc = Value.map([Value.int(2), Value.int(1)], [nan1.copy(), nan2.copy()])
    assert_true(same(fa, fb))
    assert_false(same(fa, fc))
    var r1 = Value.record("p.R", ["x", "y"], [nan1.copy(), Value.int(1)])
    var r2 = Value.record("p.R", ["y", "x"], [Value.int(1), nan1.copy()])
    assert_true(same(r1, r2))
    assert_true(same(Value.some(nan1.copy()), Value.some(nan1.copy())))
    assert_false(same(Value.some(nan1.copy()), Value.none()))


def test_hashes() raises:
    var pair = two_maps()
    assert_equal(same_hash(pair[0]), same_hash(pair[1]))
    var r1 = Value.record("p.R", ["x", "y"], [Value.int(1), Value.bool(True)])
    var r2 = Value.record("p.R", ["y", "x"], [Value.bool(True), Value.int(1)])
    assert_equal(same_hash(r1), same_hash(r2))
    assert_true(same_hash(Value.float(F64, 0)) != same_hash(Value.float(F64, 0x8000000000000000)))
    assert_equal(same_hash(Value.float(F64, 5)), same_hash(Value.float(F64, 5)))
    assert_equal(same_hash(Value.handle(3, "p.H")), same_hash(Value.handle(3, "p.H")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
