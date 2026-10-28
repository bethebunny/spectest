from std.memory import bitcast
from std.os import getenv
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from partition.ranges import float_equal, float_range
from partition.sets import SetContext
from value.float_formats import BF16, F16, F32, F64, FloatFormat
from value.floats import round_to, to_real
from value.real import Real


def _some(r: Real) -> Optional[Real]:
    return Optional[Real](r.copy())


def _f16_value(bits: Int) -> Float64:
    return Float64(bitcast[DType.float16](UInt16(bits)))


def test_f16_matches_brute_force() raises:
    var c = SetContext()
    var values = List[Float64]()
    for b in range(1 << 16):
        values.append(_f16_value(b))
    # Pattern bounds at zeros, subnormal edges, one, the ends of the finite range.
    var patterns: List[UInt64] = [
        0x0000, 0x8000, 0x0001, 0x8001, 0x03FF, 0x0400, 0x3C00, 0xBC00, 0x7BFF, 0xFBFF,
        0x3555, 0xC555,
    ]
    if getenv("SPECTEST_STRENGTH") == "full":
        for b in range(1, 0x7C00, 1021):
            patterns.append(UInt64(b))
            patterns.append(UInt64(b) | 0x8000)
    var reals = List[Real]()
    var floats = List[Float64]()
    for p in patterns:
        reals.append(to_real(F16, p))
        floats.append(_f16_value(Int(p)))
    # Midpoints between neighbours are not f16 values.
    var near: List[UInt64] = [0x03FF, 0x3C00, 0x7BFE, 0x8001]
    for a in near:
        reals.append((to_real(F16, a) + to_real(F16, a + 1)) / Real(2))
        floats.append((_f16_value(Int(a)) + _f16_value(Int(a) + 1)) / 2.0)
    reals.append((to_real(F16, 0x0001) / Real(2)))
    floats.append(_f16_value(1) / 2.0)
    var n = len(reals)
    var checked = 0
    for i in range(n + 1):
        for j in range(n + 1):
            var lo: Optional[Real] = None
            var hi: Optional[Real] = None
            if i < n:
                lo = _some(reals[i])
            if j < n:
                hi = _some(reals[j])
            var s = float_range(c, F16, lo, hi)
            var want = List[UInt64]()
            for b in range(1 << 16):
                var v = values[b]
                if v != v:
                    continue
                if i < n and v < floats[i]:
                    continue
                if j < n and v >= floats[j]:
                    continue
                want.append(UInt64(b))
            assert_true(c.equal(s, c.exactly(want, 16)))
            checked += 1
    assert_equal(checked, (n + 1) * (n + 1))


def _exercise(format: FloatFormat) raises:
    var c = SetContext()
    var w = format.width()
    var inf_mag = format.exponent_mask()
    var sign = format.sign_mask()
    var nans = c.count(c.difference(c.full(w), c.float_named(format, "finite")))
    var infs = UInt128(2)
    var nan_count = nans - infs
    var total = UInt128(1) << UInt128(w)
    # No bounds: every non-NaN value.
    assert_equal(c.count(float_range(c, format, None, None)), total - nan_count)
    # Open ends include their infinity, and no NaN.
    var up = float_range(c, format, _some(Real(0)), None)
    assert_true(c.contains(up, inf_mag))
    assert_false(c.contains(up, inf_mag | sign))
    assert_true(c.contains(up, 0))
    assert_true(c.contains(up, sign))
    assert_equal(c.count(up), UInt128(inf_mag) + 2)
    var down = float_range(c, format, None, _some(Real(0)))
    assert_true(c.contains(down, inf_mag | sign))
    assert_false(c.contains(down, inf_mag))
    assert_false(c.contains(down, 0))
    assert_false(c.contains(down, sign))
    assert_equal(c.count(down), UInt128(inf_mag))
    # Edges of the subnormal and normal ranges.
    var edges: List[UInt64] = [
        1, format.fraction_mask(), format.fraction_mask() + 1, inf_mag - 1
    ]
    for m in edges:
        var v = to_real(format, m)
        # [0, v): both zeros and magnitudes below m.
        assert_equal(c.count(float_range(c, format, _some(Real(0)), _some(v))), UInt128(m) + 1)
        # [-v, 0): negative magnitudes 1..m.
        assert_equal(c.count(float_range(c, format, _some(-v), _some(Real(0)))), UInt128(m))
        # [v, none): from m up to and including +inf.
        assert_equal(c.count(float_range(c, format, _some(v), None)), UInt128(inf_mag - m) + 1)
        # (none, -v): the negatives of magnitude above m, down to -inf.
        assert_equal(c.count(float_range(c, format, None, _some(-v))), UInt128(inf_mag - m))
        # [-v, v) is every value between, both zeros once each.
        assert_equal(c.count(float_range(c, format, _some(-v), _some(v))), UInt128(2 * m) + 1)
        assert_true(c.contains(float_range(c, format, _some(-v), _some(v)), sign | m))
        assert_false(c.contains(float_range(c, format, _some(-v), _some(v)), m))
    # An empty range, and an inverted one.
    assert_true(c.is_empty(float_range(c, format, _some(Real(1)), _some(Real(1)))))
    assert_true(c.is_empty(float_range(c, format, _some(Real(2)), _some(Real(1)))))
    # Between two values: [a, b) holds b - a patterns.
    var a = to_real(format, 3)
    var b = to_real(format, inf_mag - 1)
    assert_equal(c.count(float_range(c, format, _some(a), _some(b))), UInt128(inf_mag - 4))
    # A bound that is no value: 1/10 lies between two patterns.
    var tenth = Real(1) / Real(10)
    var m = round_to(format, tenth)
    var below = float_range(c, format, None, _some(tenth))
    var lower: UInt64
    if to_real(format, m) < tenth:
        lower = m
    else:
        lower = m - 1
    assert_true(c.contains(below, sign | 0))
    assert_true(c.contains(below, lower))
    assert_false(c.contains(below, lower + 1))
    assert_true(c.contains(below, sign | (lower + 1)))


def test_every_format() raises:
    _exercise(F16)
    _exercise(BF16)
    _exercise(F32)
    _exercise(F64)


def test_float_equal() raises:
    var c = SetContext()
    assert_equal(c.count(float_equal(c, F64, Real(0))), UInt128(2))
    assert_true(c.contains(float_equal(c, F64, Real(0)), 0))
    assert_true(c.contains(float_equal(c, F64, Real(0)), 1 << 63))
    var one = float_equal(c, F32, Real(1))
    assert_equal(c.count(one), UInt128(1))
    assert_true(c.contains(one, 0x3F800000))
    var neg = float_equal(c, F32, Real(-2))
    assert_true(c.contains(neg, 0xC0000000))
    assert_true(c.is_empty(float_equal(c, F32, Real(1) / Real(10))))
    assert_true(c.is_empty(float_equal(c, F16, Real(1 << 20))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
