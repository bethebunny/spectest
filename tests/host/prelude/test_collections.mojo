from std.testing import assert_equal, assert_true, assert_false, TestSuite

from value.bigint import BigInt
from value.float_formats import F32, F64, FloatFormat
from prelude_testkit import (
    Lcg, bi, error_of, fl, int_list, rat, run, run_kw, samples,
)
from value.value import Value


def b(v: Value) -> Bool:
    return v.as_bool()


def ints_of(values: List[Int]) -> Value:
    var out = List[Value]()
    for v in values:
        out.append(Value.int(v))
    return Value.list(out^)


def strs(*values: String) -> Value:
    var out = List[Value]()
    for v in values:
        out.append(Value.string(v))
    return Value.list(out^)


def test_len() raises:
    assert_true(run("len", [int_list(1, 2, 3)]) == Value.int(3))
    assert_true(run("len", [Value.list([])]) == Value.int(0))
    assert_true(run("len", [Value.bytes([1, 2])]) == Value.int(2))
    assert_true(run("len", [Value.string("")]) == Value.int(0))
    # Unicode scalars, not bytes.
    assert_true(run("len", [Value.string("aé€")]) == Value.int(3))
    assert_true(run("len", [Value.string(chr(0x1F600) + "x")]) == Value.int(2))
    var m = Value.map([Value.int(1), Value.int(2)], [Value.string("a"), Value.string("b")])
    assert_true(run("len", [m^]) == Value.int(2))
    assert_true(error_of("len", [Value.int(3)]).startswith("len: "))


def test_keys_values() raises:
    var m = Value.map([Value.string("b"), Value.string("a")], [Value.int(1), Value.int(2)])
    assert_true(run("keys", [m.copy()]) == strs("b", "a"))
    assert_true(run("values", [m.copy()]) == int_list(1, 2))
    assert_true(run("keys", [Value.map([], [])]) == Value.list([]))
    assert_true(error_of("keys", [int_list(1)]).startswith("keys: "))
    assert_true(error_of("values", [int_list(1)]).startswith("values: "))


def test_range() raises:
    assert_true(run("range", [Value.int(0), Value.int(4)]) == int_list(0, 1, 2, 3))
    assert_true(run("range", [Value.int(-2), Value.int(1)]) == int_list(-2, -1, 0))
    assert_true(run("range", [Value.int(3), Value.int(3)]) == Value.list([]))
    assert_true(run("range", [Value.int(5), Value.int(2)]) == Value.list([]))
    var base = bi("100000000000000000000")
    var top = Value.int(base.as_bigint() + BigInt(2))
    var got = run("range", [base.copy(), top^])
    assert_true(run("len", [got.copy()]) == Value.int(2))
    assert_true(got.item(1) == Value.int(base.as_bigint() + BigInt(1)))
    assert_true(error_of("range", [Value.int(0), Value.int(10_000_001)]).startswith("range: "))
    assert_true(run("len", [run("range", [Value.int(0), Value.int(10_000)])]) == Value.int(10_000))
    assert_true(error_of("range", [Value.int(0), Value.string("x")]).startswith("range: "))


def test_sorted_values() raises:
    assert_true(run("sorted", [int_list(3, 1, 2, 1)]) == int_list(1, 1, 2, 3))
    assert_true(run("sorted", [Value.list([])]) == Value.list([]))
    assert_true(run("sorted", [strs("b", "a", "ab", "")]) == strs("", "a", "ab", "b"))
    assert_true(
        run("sorted", [Value.list([Value.bool(True), Value.bool(False)])])
        == Value.list([Value.bool(False), Value.bool(True)])
    )
    assert_true(
        run("sorted", [Value.list([Value.bytes([2]), Value.bytes([1, 5]), Value.bytes([1])])])
        == Value.list([Value.bytes([1]), Value.bytes([1, 5]), Value.bytes([2])])
    )
    # Ints and reals order together by value, tuples lexicographically.
    assert_true(
        run("sorted", [Value.list([Value.int(2), rat(3, 2), Value.int(-1), rat(1, 2)])])
        == Value.list([Value.int(-1), rat(1, 2), rat(3, 2), Value.int(2)])
    )
    var t1 = Value.tuple([Value.int(1), Value.string("b")])
    var t2 = Value.tuple([Value.int(1), Value.string("a")])
    var t3 = Value.tuple([Value.int(0), Value.string("z")])
    assert_true(
        run("sorted", [Value.list([t1.copy(), t2.copy(), t3.copy()])]) == Value.list([t3.copy(), t2.copy(), t1.copy()])
    )
    # Strings order by code point, which is the order of their UTF-8 bytes.
    assert_true(
        run("sorted", [strs(chr(0xFF61), chr(0x10000), "z", chr(0xE000))])
        == strs("z", chr(0xE000), chr(0xFF61), chr(0x10000))
    )


def test_unordered_values_raise() raises:
    assert_true(error_of("sorted", [Value.list([fl(F32, 0), fl(F32, 0)])]).startswith("sorted: "))
    assert_true(error_of("is_sorted", [Value.list([fl(F32, 0)])]).startswith("is_sorted: "))
    assert_true(error_of("sorted", [Value.list([Value.int(1), Value.string("a")])]).startswith("sorted: "))
    assert_true(error_of("sorted", [Value.int(1)]).startswith("sorted: "))
    assert_true(
        error_of("sorted", [Value.list([Value.tuple([fl(F32, 0)]), Value.tuple([fl(F32, 0)])])]).startswith("sorted: ")
    )


def test_sorted_is_stable() raises:
    # An int and a real of equal value are distinct values that order as equal.
    var xs = Value.list([rat(2, 1), Value.int(2), Value.int(1), rat(1, 1), Value.int(2), rat(2, 1)])
    var got = run("sorted", [xs^])
    var want = Value.list([Value.int(1), rat(1, 1), rat(2, 1), Value.int(2), Value.int(2), rat(2, 1)])
    # Equal-valued elements keep their input order: 1 before 1/1, and 2/1, 2, 2, 2/1.
    assert_true(got.item(0) == Value.int(1) and got.item(1) == rat(1, 1))
    assert_true(got.item(2) == rat(2, 1) and got.item(3) == Value.int(2))
    assert_true(got.item(4) == Value.int(2) and got.item(5) == rat(2, 1))


def test_sorted_random() raises:
    var rng = Lcg()
    for _ in range(samples(100, 3000)):
        var n = rng.below(40)
        var xs = List[Int]()
        for _k in range(n):
            xs.append(rng.below(15) - 5)
        var got = run("sorted", [ints_of(xs)])
        assert_true(b(run("is_sorted", [got.copy()])))
        assert_true(b(run("is_permutation", [got.copy(), ints_of(xs)])))
        assert_true(run("len", [got.copy()]) == Value.int(n))
    # A longer one crosses every merge width.
    var big = List[Int]()
    for k in range(1000):
        big.append((k * 7919) % 1009)
    var sorted_big = run("sorted", [ints_of(big)])
    assert_true(b(run("is_sorted", [sorted_big^])))


def test_is_sorted() raises:
    assert_true(b(run("is_sorted", [Value.list([])])))
    assert_true(b(run("is_sorted", [int_list(1)])))
    assert_true(b(run("is_sorted", [int_list(1, 1, 2)])))
    assert_false(b(run("is_sorted", [int_list(2, 1)])))
    assert_true(b(run("is_sorted", [strs("a", "b")])))
    assert_false(b(run("is_sorted", [strs("b", "a")])))


def test_is_permutation() raises:
    assert_true(b(run("is_permutation", [int_list(1, 2, 2), int_list(2, 1, 2)])))
    assert_false(b(run("is_permutation", [int_list(1, 2, 2), int_list(1, 1, 2)])))
    assert_false(b(run("is_permutation", [int_list(1), int_list(1, 1)])))
    assert_true(b(run("is_permutation", [Value.list([]), Value.list([])])))
    # Floats compare by bits.
    var pz = fl(F32, 0)
    var nz = fl(F32, 0x80000000)
    assert_false(b(run("is_permutation", [Value.list([pz.copy()]), Value.list([nz.copy()])])))
    var nan = fl(F32, 0x7FC00000)
    assert_true(b(run("is_permutation", [Value.list([nan.copy(), pz.copy()]), Value.list([pz.copy(), nan.copy()])])))


def test_is_permutation_of_rotations() raises:
    var rng = Lcg()
    for _ in range(samples(50, 1000)):
        var n = 1 + rng.below(30)
        var xs = List[Int]()
        for _k in range(n):
            xs.append(rng.below(6))
        var rotated = List[Int]()
        var shift = rng.below(n)
        for k in range(n):
            rotated.append(xs[(k + shift) % n])
        assert_true(b(run("is_permutation", [ints_of(xs), ints_of(rotated)])))
        xs[0] += 100
        assert_false(b(run("is_permutation", [ints_of(xs), ints_of(rotated)])))


def test_is_subsequence() raises:
    assert_true(b(run("is_subsequence", [Value.list([]), int_list(1, 2)])))
    assert_true(b(run("is_subsequence", [int_list(1, 3), int_list(1, 2, 3)])))
    assert_false(b(run("is_subsequence", [int_list(3, 1), int_list(1, 2, 3)])))
    assert_false(b(run("is_subsequence", [int_list(1, 1), int_list(1, 2)])))
    assert_true(b(run("is_subsequence", [int_list(1, 2, 3), int_list(1, 2, 3)])))
    assert_false(b(run("is_subsequence", [int_list(1), Value.list([])])))


def test_distinct() raises:
    assert_true(b(run("distinct", [Value.list([])])))
    assert_true(b(run("distinct", [int_list(1, 2, 3)])))
    assert_false(b(run("distinct", [int_list(1, 2, 1)])))
    assert_true(b(run("distinct", [Value.list([fl(F32, 0), fl(F32, 0x80000000)])])))
    assert_false(b(run("distinct", [Value.list([fl(F32, 0x7FC00000), fl(F32, 0x7FC00000)])])))
    var big = List[Int]()
    for k in range(2000):
        big.append(k)
    assert_true(b(run("distinct", [ints_of(big)])))
    big.append(77)
    assert_false(b(run("distinct", [ints_of(big)])))


def test_index_of() raises:
    assert_true(run("index_of", [int_list(5, 6, 7, 6), Value.int(6)]) == Value.int(1))
    assert_true(error_of("index_of", [int_list(5), Value.int(6)]).startswith("index_of: "))
    assert_true(run("index_of", [strs("a", "b"), Value.string("b")]) == Value.int(1))


def test_options() raises:
    var s = run("some", [Value.int(3)])
    assert_true(s == Value.some(Value.int(3)))
    assert_true(b(run("is_some", [s.copy()])))
    assert_false(b(run("is_none", [s.copy()])))
    assert_true(b(run("is_none", [Value.none()])))
    assert_false(b(run("is_some", [Value.none()])))
    assert_true(run("unwrap", [s.copy()]) == Value.int(3))
    assert_true(error_of("unwrap", [Value.none()]).startswith("unwrap: "))
    assert_true(error_of("is_some", [Value.int(1)]).startswith("is_some: "))
    assert_true(error_of("unwrap", [Value.int(1)]).startswith("unwrap: "))
    assert_true(run("unwrap", [run("some", [Value.none()])]) == Value.none())


def eq_with(a: Value, b: Value, float_mode: String = "", order: String = "") raises -> Bool:
    var names = List[String]()
    var kws = List[Value]()
    if float_mode:
        names.append("float")
        kws.append(Value.string(float_mode))
    if order:
        names.append("order")
        kws.append(Value.string(order))
    return run_kw("eq", [a.copy(), b.copy()], names, kws^).as_bool()


def test_eq_float_modes() raises:
    var pz = fl(F32, 0)
    var nz = fl(F32, 0x80000000)
    var n1 = fl(F32, 0x7FC00000)
    var n2 = fl(F32, 0x7FC00001)
    assert_true(eq_with(pz, pz))
    assert_false(eq_with(pz, nz))
    assert_false(eq_with(pz, nz, "bits"))
    assert_true(eq_with(pz, nz, "ieee"))
    assert_true(eq_with(n1, n1, "bits"))
    assert_false(eq_with(n1, n2, "bits"))
    assert_false(eq_with(n1, n1, "ieee"))
    assert_true(eq_with(n1, n2, "nan_any"))
    assert_false(eq_with(n1, pz, "nan_any"))
    assert_false(eq_with(pz, nz, "nan_any"))
    assert_false(eq_with(fl(F32, 0x3F800000), fl(F64, 0x3F800000), "ieee"))
    # The mode reaches into containers.
    assert_true(eq_with(Value.list([pz.copy()]), Value.list([nz.copy()]), "ieee"))
    assert_true(eq_with(Value.some(n1.copy()), Value.some(n2.copy()), "nan_any"))
    assert_false(eq_with(Value.tuple([n1.copy()]), Value.tuple([n1.copy()]), "ieee"))


def test_eq_order_ignore() raises:
    assert_false(eq_with(int_list(1, 2), int_list(2, 1)))
    assert_false(eq_with(int_list(1, 2), int_list(2, 1), order="exact"))
    assert_true(eq_with(int_list(1, 2), int_list(2, 1), order="ignore"))
    assert_false(eq_with(int_list(1, 2, 2), int_list(2, 1, 1), order="ignore"))
    assert_false(eq_with(int_list(1, 2), int_list(1, 2, 2), order="ignore"))
    # At every depth.
    var a = Value.list([int_list(1, 2), int_list(3)])
    var c = Value.list([int_list(3), int_list(2, 1)])
    assert_true(eq_with(a, c, order="ignore"))
    assert_false(eq_with(a, c))
    # Combined with a float mode.
    var pz = fl(F32, 0)
    var nz = fl(F32, 0x80000000)
    assert_true(eq_with(Value.list([pz.copy(), Value.int(1)]), Value.list([Value.int(1), nz.copy()]), "ieee", "ignore"))


def test_eq_structures() raises:
    var m1 = Value.map([Value.string("a"), Value.string("b")], [Value.int(1), Value.int(2)])
    var m2 = Value.map([Value.string("b"), Value.string("a")], [Value.int(2), Value.int(1)])
    var m3 = Value.map([Value.string("b"), Value.string("a")], [Value.int(2), Value.int(9)])
    assert_true(eq_with(m1, m2))
    assert_false(eq_with(m1, m3))
    assert_true(eq_with(Value.none(), Value.none()))
    assert_false(eq_with(Value.none(), Value.some(Value.int(1))))
    assert_true(eq_with(Value.some(Value.int(1)), Value.some(Value.int(1))))
    assert_false(eq_with(Value.int(1), Value.string("1")))
    assert_true(eq_with(Value.int(1), rat(1, 1)))
    assert_true(eq_with(Value.qerr(BigInt(1), BigInt(0)), Value.qerr(BigInt(1), BigInt(0))))
    assert_false(eq_with(Value.qerr(BigInt(1), BigInt(0)), Value.qerr(BigInt(1), BigInt(1))))
    assert_true(eq_with(Value.enum("p.E", "A"), Value.enum("p.E", "A")))
    assert_false(eq_with(Value.enum("p.E", "A"), Value.enum("p.E", "B")))
    var r1 = Value.record("p.R", ["x"], [Value.int(1)])
    var r2 = Value.record("p.R", ["x"], [Value.int(2)])
    assert_true(eq_with(r1, r1))
    assert_false(eq_with(r1, r2))


def test_eq_knobs_are_validated() raises:
    var err = String()
    try:
        _ = eq_with(Value.int(1), Value.int(1), "close")
    except e:
        err = String(e)
    assert_true(err.startswith("eq: "))
    err = String()
    try:
        _ = eq_with(Value.int(1), Value.int(1), order="sideways")
    except e:
        err = String(e)
    assert_true(err.startswith("eq: "))
    err = String()
    try:
        _ = run_kw("eq", [Value.int(1), Value.int(1)], ["tolerance"], [Value.int(1)])
    except e:
        err = String(e)
    assert_true(err.startswith("eq: "))
    # Handles can't be compared without observing them; the evaluator does that.
    err = String()
    try:
        _ = eq_with(Value.handle(1, "p.C"), Value.handle(1, "p.C"))
    except e:
        err = String(e)
    assert_true(err.startswith("eq: "))


def test_keywords_belong_to_eq() raises:
    var err = String()
    try:
        _ = run_kw("len", [int_list(1)], ["order"], [Value.string("exact")])
    except e:
        err = String(e)
    assert_true(err.startswith("len: "))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
