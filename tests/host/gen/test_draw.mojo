from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check.types import Types
from gen.sizes import Sizes
from gen.value import draw_value
from mcheck.source import Source
from numeric.bigint import BigInt
from numeric.floats import is_nan, is_inf, is_zero, is_subnormal, is_normal
from numeric.formats import format_by_id
from wire.value import Value, BOOL, INT, FLOAT, STRING, BYTES, LIST, TUPLE, MAP, OPTION, RECORD, ENUM

comptime N = 3000


def draw(mut src: Source, mut types: Types, t: Int, sizes: Sizes) raises -> Value:
    src.reset_generate()
    return draw_value(src, types, t, sizes, 0)


def test_bool() raises:
    var types = Types()
    var t = types.bool_()
    var src = Source(1)
    var sizes = Sizes()
    var yes = 0
    for _ in range(N):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == BOOL)
        yes += 1 if v.as_bool() else 0
    assert_true(yes > N // 3 and yes < 2 * N // 3)


def test_int_unbounded() raises:
    var types = Types()
    var t = types.int_()
    var src = Source(2)
    var sizes = Sizes()
    var zero = 0
    var one = 0
    var minus = 0
    var big = 0
    var small = 0
    for _ in range(N):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == INT)
        var s = v.small_int()
        if not s:
            big += 1
        else:
            small += 1
            zero += 1 if s.value() == 0 else 0
            one += 1 if s.value() == 1 else 0
            minus += 1 if s.value() == -1 else 0
    assert_true(zero > 0 and one > 0 and minus > 0)
    assert_true(big > N // 20)
    assert_true(small > N // 2)


def check_fixed(width: Int, signed: Bool, seed: UInt64) raises:
    var types = Types()
    var t = types.fixed(width, signed)
    var src = Source(seed)
    var sizes = Sizes()
    var lo = BigInt()
    var hi = (BigInt(1) << width) - BigInt(1)
    if signed:
        lo = -(BigInt(1) << (width - 1))
        hi = (BigInt(1) << (width - 1)) - BigInt(1)
    var saw_lo = False
    var saw_hi = False
    var saw_zero = False
    var saw_one = False
    for _ in range(N):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == INT)
        var x = v.as_bigint()
        assert_true(not (x < lo) and not (hi < x))
        saw_lo = saw_lo or x == lo
        saw_hi = saw_hi or x == hi
        saw_zero = saw_zero or x == BigInt()
        saw_one = saw_one or x == BigInt(1)
    assert_true(saw_lo and saw_hi and saw_zero and saw_one)


def test_fixed_ints() raises:
    check_fixed(8, False, 3)
    check_fixed(8, True, 4)
    check_fixed(16, True, 5)
    check_fixed(32, False, 6)
    check_fixed(32, True, 7)
    check_fixed(64, False, 8)
    check_fixed(64, True, 9)


def check_float(format_id: UInt8, seed: UInt64) raises:
    var types = Types()
    var t = types.float_(format_id)
    var f = format_by_id(format_id)
    var src = Source(seed)
    var sizes = Sizes()
    var zero = 0
    var neg_zero = 0
    var sub = 0
    var inf = 0
    var neg_inf = 0
    var nan = 0
    var normal = 0
    var one = 0
    for _ in range(400):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == FLOAT)
        assert_equal(Int(v.float_format_id()), Int(format_id))
        var b = v.float_bits()
        assert_true((b >> UInt64(f.width())) == 0 or f.width() == 64)
        zero += 1 if is_zero(f, b) else 0
        neg_zero += 1 if b == f.sign_mask() else 0
        sub += 1 if is_subnormal(f, b) else 0
        inf += 1 if is_inf(f, b) else 0
        neg_inf += 1 if b == (f.sign_mask() | f.exponent_mask()) else 0
        nan += 1 if is_nan(f, b) else 0
        normal += 1 if is_normal(f, b) else 0
    assert_true(zero > 0 and neg_zero > 0 and sub > 0 and inf > 0 and neg_inf > 0)
    assert_true(nan > 0 and normal > 100)


def test_floats() raises:
    check_float(1, 10)
    check_float(2, 11)
    check_float(3, 12)
    check_float(4, 13)


def test_strings() raises:
    var types = Types()
    var t = types.string()
    var src = Source(14)
    var sizes = Sizes()
    var astral = 0
    var long = 0
    var empty = 0
    for _ in range(N):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == STRING)
        var n = 0
        for cp in v.text().codepoints():
            var c = Int(cp.to_u32())
            assert_false(c >= 0xD800 and c < 0xE000)
            assert_true(c <= 0x10FFFF)
            astral += 1 if c >= 0x10000 else 0
            n += 1
        if n > 12:
            long += 1
            assert_true(n >= 25 and n <= 100)
        empty += 1 if n == 0 else 0
    assert_true(astral > 0)
    assert_true(empty > 0)
    assert_true(long > N // 32 and long < N // 8)


def test_bytes() raises:
    var types = Types()
    var t = types.bytes()
    var src = Source(15)
    var sizes = Sizes()
    var long = 0
    var high = 0
    for _ in range(N):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == BYTES)
        var n = len(v.data())
        if n > 16:
            long += 1
            assert_true(n >= 33 and n <= 100)
        for b in v.data():
            high += 1 if b >= 0x80 else 0
    assert_true(long > N // 32 and long < N // 8)
    assert_true(high > 0)


def test_lists_and_long_share() raises:
    var types = Types()
    var t = types.list_of(types.fixed(64, True))
    var src = Source(16)
    var sizes = Sizes()
    var long = 0
    var seen_max = 0
    for _ in range(4000):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == LIST)
        var n = v.count()
        if n > 8:
            long += 1
            assert_true(n >= 17 and n <= 100)
            var distinct = List[Value]()
            for i in range(n):
                var item = v.item(i)
                var found = False
                for d in distinct:
                    if d == item:
                        found = True
                if not found:
                    distinct.append(item^)
            assert_true(len(distinct) <= 17)
        seen_max = max(seen_max, n)
    # about 1 in 16: 250 of 4000
    assert_true(long > 150 and long < 375)
    assert_equal(seen_max, 100)


def test_long_off_and_custom_sizes() raises:
    var types = Types()
    var t = types.list_of(types.bool_())
    var src = Source(17)
    var sizes = Sizes()
    sizes.long_share = 0.0
    for _ in range(N):
        assert_true(draw(src, types, t, sizes).count() <= 8)
    var small = Sizes()
    small.max_list = 2
    small.long_share = 0.0
    var biggest = 0
    for _ in range(N):
        biggest = max(biggest, draw(src, types, t, small).count())
    assert_equal(biggest, 2)


def test_nested_lists_are_short() raises:
    var types = Types()
    var t = types.list_of(types.list_of(types.string()))
    var src = Source(18)
    var sizes = Sizes()
    for _ in range(1000):
        var v = draw(src, types, t, sizes)
        assert_true(v.count() <= 8)
        for i in range(v.count()):
            assert_true(v.item(i).count() <= 4)


def test_maps_have_distinct_keys() raises:
    var types = Types()
    var t = types.map_of(types.fixed(8, False), types.bool_())
    var src = Source(19)
    var sizes = Sizes()
    var biggest = 0
    for _ in range(N):
        var v = draw(src, types, t, sizes)
        assert_true(v.kind == MAP)
        biggest = max(biggest, v.count())
        for i in range(v.count()):
            for j in range(i):
                assert_true(v.item(2 * i) != v.item(2 * j))
    assert_true(biggest >= 5 and biggest <= 8)
    # A key type with two values leaves at most two entries.
    var tb = types.map_of(types.bool_(), types.int_())
    for _ in range(N):
        assert_true(draw(src, types, tb, sizes).count() <= 2)


def test_tuple_option_literal_enum_record() raises:
    var types = Types()
    var tup = types.tuple_of([types.bool_(), types.string(), types.fixed(8, False)])
    var opt = types.option_of(types.fixed(8, False))
    var lit = types.literal(["a", "b", "c"])
    var en = types.enum_("m.Color", ["Red", "Green"])
    var rec = types.record("m.P", ["x", "y"], [types.fixed(8, True), types.bool_()])
    var src = Source(20)
    var sizes = Sizes()
    var nones = 0
    var members: List[Int] = [0, 0, 0]
    var greens = 0
    for _ in range(N):
        var v = draw(src, types, tup, sizes)
        assert_true(v.kind == TUPLE and v.count() == 3)
        assert_true(v.item(0).kind == BOOL and v.item(1).kind == STRING and v.item(2).kind == INT)
        var o = draw(src, types, opt, sizes)
        assert_true(o.kind == OPTION)
        nones += 1 if o.count() == 0 else 0
        var l = draw(src, types, lit, sizes)
        assert_true(l.kind == ENUM and l.name() == "")
        var text = l.text()
        members[ord(text) - ord("a")] += 1
        var e = draw(src, types, en, sizes)
        assert_true(e.kind == ENUM and e.name() == "m.Color")
        greens += 1 if e.text() == "Green" else 0
        var r = draw(src, types, rec, sizes)
        assert_true(r.kind == RECORD and r.name() == "m.P" and r.count() == 2)
        assert_equal(r.item(0).text(), "x")
        assert_true(r.item(1).kind == INT)
        assert_equal(r.item(2).text(), "y")
        assert_true(r.item(3).kind == BOOL)
    assert_true(nones > 0 and nones < N // 2)
    for m in members:
        assert_true(m > N // 5)
    assert_true(greens > N // 3)


def test_unsupported_types_raise() raises:
    var types = Types()
    var src = Source(21)
    var sizes = Sizes()
    var raised = False
    try:
        _ = draw_value(src, types, types.real(), sizes, 0)
    except:
        raised = True
    assert_true(raised)


def test_spans_mark_values() raises:
    var types = Types()
    var t = types.list_of(types.fixed(8, False))
    var src = Source(22)
    var sizes = Sizes()
    sizes.long_share = 0.0
    for _ in range(50):
        var v = draw(src, types, t, sizes)
        # One span for the list, one per element (its flag and value), one per value.
        assert_true(len(src.rec.spans) >= 1 + v.count())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
