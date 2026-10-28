from std.testing import assert_equal, assert_true, assert_false, TestSuite

from host.draw.classes import draw_in_classes
from host.draw.domain import domain_size, value_at
from mcheck.property import Property, Outcome, PASSED
from mcheck.search import enumerate_all
from mcheck.settings import Settings
from mcheck.source import Source
from partition.sets import SetContext, BitSet
from spec.types import Types
from value.bigint import BigInt
from value.float_formats import F64
from value.floats import is_nan, is_zero, is_normal
from value.value import Value


struct Visit(Property):
    """Visits `value_at` for each index and counts the values by a key."""

    var types: Types
    var t: Int
    var n: UInt64
    var counts: List[Int]
    var runs: Int

    def __init__(out self, var types: Types, t: Int, n: UInt64):
        self.types = types^
        self.t = t
        self.n = n
        self.counts = List[Int](length=Int(n), fill=0)
        self.runs = 0

    def run(mut self, mut src: Source) raises -> Outcome:
        var i = src.draw_below(self.n)
        var v = value_at(self.types, self.t, i)
        self.runs += 1
        self.counts[Int(key(v))] += 1
        return Outcome.single(0, PASSED)


def key(v: Value) -> UInt64:
    """A number that identifies a small-domain value among those of its type."""
    if v.kind == .Float:
        return v.float_bits()
    if v.kind == .Int:
        return UInt64(v.small_int().value() & 0xFFFF)
    var k = UInt64(0)
    for i in range(v.count()):
        var item = v.item(i)
        k = k * 256 + (UInt64(1) if item.kind != .Int and item.as_bool() else key(item))
    return k


def visit_all(var types: Types, t: Int) raises -> Visit:
    var n = domain_size(types, t).value()
    var p = Visit(types^, t, n)
    var r = enumerate_all(p, Int(n), Settings())
    assert_equal(r.examples, Int(n))
    return p^


def test_sizes() raises:
    var types = Types()
    assert_equal(domain_size(types, types.bool_()).value(), 2)
    assert_equal(domain_size(types, types.fixed(8, False)).value(), 256)
    assert_equal(domain_size(types, types.fixed(16, True)).value(), 65536)
    assert_equal(domain_size(types, types.float_(1)).value(), 65536)
    assert_equal(domain_size(types, types.float_(2)).value(), 65536)
    assert_false(domain_size(types, types.fixed(32, False)))
    assert_false(domain_size(types, types.float_(3)))
    assert_false(domain_size(types, types.string()))
    var bu = types.tuple_of([types.bool_(), types.fixed(8, False)])
    assert_equal(domain_size(types, bu).value(), 512)
    assert_false(domain_size(types, types.tuple_of([types.fixed(8, False), types.fixed(16, False)])))
    assert_equal(domain_size(types, types.option_of(types.bool_())).value(), 3)
    assert_equal(domain_size(types, types.enum_("m.E", ["A", "B", "C"])).value(), 3)
    assert_equal(domain_size(types, types.tuple_of(List[Int]())).value(), 1)


def test_u8_visited_once() raises:
    var types = Types()
    var t = types.fixed(8, False)
    var p = visit_all(types^, t)
    for c in p.counts:
        assert_equal(c, 1)


def test_i16_values() raises:
    var types = Types()
    var t = types.fixed(16, True)
    assert_equal(value_at(types, t, 0).small_int().value(), 0)
    assert_equal(value_at(types, t, 0x7FFF).small_int().value(), 32767)
    assert_equal(value_at(types, t, 0x8000).small_int().value(), -32768)
    assert_equal(value_at(types, t, 0xFFFF).small_int().value(), -1)


def test_f16_visited_once() raises:
    var types = Types()
    var t = types.float_(1)
    var p = visit_all(types^, t)
    for c in p.counts:
        assert_equal(c, 1)


def test_bf16_visited_once() raises:
    var types = Types()
    var t = types.float_(2)
    var p = visit_all(types^, t)
    for c in p.counts:
        assert_equal(c, 1)


def test_bool_u8_tuple_visited_once() raises:
    var types = Types()
    var t = types.tuple_of([types.bool_(), types.fixed(8, False)])
    var p = visit_all(types^, t)
    assert_equal(len(p.counts), 512)
    for c in p.counts:
        assert_equal(c, 1)


def test_option_and_out_of_range() raises:
    var types = Types()
    var t = types.option_of(types.bool_())
    assert_equal(value_at(types, t, 0).count(), 0)
    assert_equal(value_at(types, t, 2).item(0).as_bool(), True)
    var raised = False
    try:
        _ = value_at(types, t, 3)
    except:
        raised = True
    assert_true(raised)


def test_class_steering_is_even() raises:
    var types = Types()
    var t = types.float_(4)
    var ctx = SetContext()
    var classes = List[BitSet]()
    classes.append(ctx.float_named(F64, "nan"))
    classes.append(ctx.float_named(F64, "zero"))
    classes.append(ctx.float_named(F64, "normal"))
    var src = Source(2)
    var nans = 0
    var zeros = 0
    var normals = 0
    var neg_zeros = 0
    var distinct_nans = List[UInt64]()
    for _ in range(3000):
        src.reset_generate()
        var v = draw_in_classes(src, ctx, types, classes, t)
        assert_true(v.kind == .Float)
        var b = v.float_bits()
        if is_nan(F64, b):
            nans += 1
            if len(distinct_nans) < 5:
                distinct_nans.append(b)
        elif is_zero(F64, b):
            zeros += 1
            neg_zeros += 1 if b != 0 else 0
        elif is_normal(F64, b):
            normals += 1
    assert_equal(nans + zeros + normals, 3000)
    for c in [nans, zeros, normals]:
        assert_true(c > 850 and c < 1150)
    # -0 is as likely as +0.
    assert_true(neg_zeros > zeros * 2 // 5 and neg_zeros < zeros * 3 // 5)
    assert_true(len(distinct_nans) > 1)


def test_empty_classes_are_skipped() raises:
    var types = Types()
    var t = types.fixed(8, False)
    var ctx = SetContext()
    var classes = List[BitSet]()
    classes.append(ctx.empty(8))
    classes.append(ctx.interval(10, 13, 8))
    classes.append(ctx.empty(8))
    classes.append(ctx.exactly([200], 8))
    var src = Source(3)
    var seen: List[Int] = [0, 0, 0, 0]
    for _ in range(1000):
        src.reset_generate()
        var x = draw_in_classes(src, ctx, types, classes, t).small_int().value()
        if x == 200:
            seen[3] += 1
        else:
            assert_true(x >= 10 and x < 13)
            seen[1] += 1
    assert_true(seen[1] > 400 and seen[3] > 400)
    var none = List[BitSet]()
    none.append(ctx.empty(8))
    var raised = False
    try:
        _ = draw_in_classes(src, ctx, types, none, t)
    except:
        raised = True
    assert_true(raised)


def test_signed_and_bool_classes() raises:
    var types = Types()
    var ctx = SetContext()
    var i8 = types.fixed(8, True)
    var classes = List[BitSet]()
    classes.append(ctx.int_range(8, True, None, Optional(BigInt(0))))
    var src = Source(4)
    for _ in range(300):
        src.reset_generate()
        var x = draw_in_classes(src, ctx, types, classes, i8).small_int().value()
        assert_true(x < 0 and x >= -128)
    var b = List[BitSet]()
    b.append(ctx.exactly([1], 1))
    for _ in range(20):
        src.reset_generate()
        assert_true(draw_in_classes(src, ctx, types, b, types.bool_()).as_bool())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
