from std.testing import assert_equal, assert_true, TestSuite
from std.time import perf_counter_ns

from value.float_formats import BF16, F16, F32, F64, FloatFormat
from sets import SetContext

comptime NAMES = ["nan", "inf", "zero", "subnormal", "normal", "finite", "positive", "negative"]


def _is_nan(f: FloatFormat, v: UInt64) -> Bool:
    return (v & f.exponent_mask()) == f.exponent_mask() and (v & f.fraction_mask()) != 0


def _is_inf(f: FloatFormat, v: UInt64) -> Bool:
    return (v & f.exponent_mask()) == f.exponent_mask() and (v & f.fraction_mask()) == 0


def _is_zero(f: FloatFormat, v: UInt64) -> Bool:
    return (v & f.exponent_mask()) == 0 and (v & f.fraction_mask()) == 0


def _is_subnormal(f: FloatFormat, v: UInt64) -> Bool:
    return (v & f.exponent_mask()) == 0 and (v & f.fraction_mask()) != 0


def _is_normal(f: FloatFormat, v: UInt64) -> Bool:
    var e = v & f.exponent_mask()
    return e != 0 and e != f.exponent_mask()


def test_f16_against_brute_force() raises:
    var c = SetContext()
    var f = F16
    var nan = c.float_named(f, "nan")
    var inf = c.float_named(f, "inf")
    var zero = c.float_named(f, "zero")
    var sub = c.float_named(f, "subnormal")
    var normal = c.float_named(f, "normal")
    var finite = c.float_named(f, "finite")
    var pos = c.float_named(f, "positive")
    var neg = c.float_named(f, "negative")
    var n0 = 0
    var n1 = 0
    var n2 = 0
    var n3 = 0
    var n4 = 0
    var wrong = 0
    for i in range(65536):
        var v = UInt64(i)
        if not (c.contains(nan, v) == _is_nan(f, v)):
            wrong += 1
        if not (c.contains(inf, v) == _is_inf(f, v)):
            wrong += 1
        if not (c.contains(zero, v) == _is_zero(f, v)):
            wrong += 1
        if not (c.contains(sub, v) == _is_subnormal(f, v)):
            wrong += 1
        if not (c.contains(normal, v) == _is_normal(f, v)):
            wrong += 1
        if not (c.contains(finite, v) == (not _is_nan(f, v) and not _is_inf(f, v))):
            wrong += 1
        if not (c.contains(pos, v) == ((v & f.sign_mask()) == 0)):
            wrong += 1
        if not (c.contains(neg, v) == ((v & f.sign_mask()) != 0)):
            wrong += 1
        if _is_nan(f, v):
            n0 += 1
        if _is_inf(f, v):
            n1 += 1
        if _is_zero(f, v):
            n2 += 1
        if _is_subnormal(f, v):
            n3 += 1
        if _is_normal(f, v):
            n4 += 1
    assert_equal(wrong, 0)
    assert_equal(c.count(nan), UInt128(n0))
    assert_equal(c.count(inf), UInt128(n1))
    assert_equal(c.count(zero), UInt128(n2))
    assert_equal(c.count(sub), UInt128(n3))
    assert_equal(c.count(normal), UInt128(n4))
    assert_equal(n0, 2046)
    assert_equal(n4, 2 * 30 * 1024)


def _check_partition(mut c: SetContext, f: FloatFormat) raises:
    var w = f.width()
    var classes = [
        c.float_named(f, "nan"),
        c.float_named(f, "inf"),
        c.float_named(f, "zero"),
        c.float_named(f, "subnormal"),
        c.float_named(f, "normal"),
    ]
    var total = c.empty(w)
    for i in range(len(classes)):
        for j in range(i + 1, len(classes)):
            assert_true(c.disjoint(classes[i], classes[j]))
        total = c.union(total, classes[i])
    assert_true(c.equal(total, c.full(w)))
    var pos = c.float_named(f, "positive")
    var neg = c.float_named(f, "negative")
    assert_true(c.disjoint(pos, neg))
    assert_true(c.equal(c.union(pos, neg), c.full(w)))
    var finite = c.float_named(f, "finite")
    var expect = c.union(
        c.union(classes[2], classes[3]), classes[4]
    )
    assert_true(c.equal(finite, expect))


def test_partitions_every_format() raises:
    var c = SetContext()
    _check_partition(c, F16)
    _check_partition(c, BF16)
    _check_partition(c, F32)
    _check_partition(c, F64)


def test_counts() raises:
    var c = SetContext()
    assert_equal(c.count(c.float_named(F64, "normal")), UInt128(18428729675200069632))
    assert_equal(c.count(c.float_named(F64, "nan")), UInt128(2) * ((UInt128(1) << 52) - 1))
    assert_equal(c.count(c.float_named(F64, "inf")), UInt128(2))
    assert_equal(c.count(c.float_named(F32, "normal")), UInt128(2) * 254 * (UInt128(1) << 23))
    assert_equal(c.count(c.float_named(BF16, "normal")), UInt128(2) * 254 * 128)
    assert_equal(c.count(c.float_named(F64, "positive")), UInt128(1) << 63)


def test_unknown_name() raises:
    var c = SetContext()
    var raised = False
    try:
        _ = c.float_named(F16, "bogus")
    except:
        raised = True
    assert_true(raised)


def test_magnitudes() raises:
    var c = SetContext()
    var one = UInt64(0x3C00)
    var s = c.float_magnitudes(F16, 0, one, False)
    assert_equal(c.count(s), UInt128(one))
    assert_true(c.contains(s, 0))
    assert_true(c.contains(s, one - 1))
    assert_false_(c.contains(s, one))
    assert_false_(c.contains(s, 0x8000))
    var n = c.float_magnitudes(F16, 5, 10, True)
    assert_equal(c.count(n), UInt128(5))
    assert_true(c.contains(n, 0x8005))
    assert_true(c.contains(n, 0x8009))
    assert_false_(c.contains(n, 0x800A))
    assert_false_(c.contains(n, 5))
    assert_true(c.is_empty(c.float_magnitudes(F16, 5, 5, False)))
    # The whole magnitude range of f64, with the sign set.
    var top = c.float_magnitudes(F64, 0, UInt64(1) << 63, True)
    assert_true(c.equal(top, c.float_named(F64, "negative")))


def assert_false_(b: Bool) raises:
    assert_true(not b)


def test_speed_of_named_sets() raises:
    var c = SetContext()
    var start = perf_counter_ns()
    var made = 0
    for f in [F16, BF16, F32, F64]:
        for name in materialize[NAMES]():
            _ = c.float_named(f, name)
            made += 1
    var elapsed = perf_counter_ns() - start
    print("built", made, "named sets in", Float64(elapsed) / 1e6, "ms")
    assert_true(elapsed < 5_000_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
