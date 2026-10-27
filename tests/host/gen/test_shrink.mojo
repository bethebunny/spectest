from std.memory import bitcast
from std.testing import assert_equal, assert_true, TestSuite
from std.time import perf_counter_ns

from check.types import Types
from gen.sizes import Sizes
from gen.value import draw_value
from mcheck.property import Property, Outcome, PASSED, FAILED
from mcheck.search import search
from mcheck.settings import Settings
from mcheck.source import Source
from wire.value import Value, INT, FLOAT


struct Drawn(Property):
    """Draws a value of one type and fails when `bad` holds of it."""

    var types: Types
    var t: Int
    var sizes: Sizes
    var kind: Int
    """0: a list with an element >= 10. 1: an f64 above 1.0."""
    var last: Value

    def __init__(out self, var types: Types, t: Int, kind: Int):
        self.types = types^
        self.t = t
        self.sizes = Sizes()
        self.kind = kind
        self.last = Value.none()

    def run(mut self, mut src: Source) raises -> Outcome:
        self.last = draw_value(src, self.types, self.t, self.sizes, 0)
        var bad = False
        if self.kind == 0:
            for i in range(self.last.count()):
                var x = self.last.item(i).small_int()
                if x and x.value() >= 10:
                    bad = True
        else:
            bad = bitcast[DType.float64](self.last.float_bits()) > 1.0
        return Outcome.single(0, FAILED if bad else PASSED)


def settings(seed: UInt64) -> Settings:
    var s = Settings()
    s.seed = seed
    s.max_examples = 300
    s.max_shrink_steps = 3000
    return s^


def test_list_shrinks_to_single_element() raises:
    for seed in range(1, 6):
        var types = Types()
        var t = types.list_of(types.fixed(32, True))
        var p = Drawn(types^, t, 0)
        var r = search(p, settings(UInt64(seed)))
        assert_true(r.properties[0].failed)
        var src = Source(0)
        src.reset_replay(r.properties[0].choices.values)
        _ = p.run(src)
        assert_equal(p.last.count(), 1)
        assert_equal(p.last.item(0).small_int().value(), 10)


def test_float_shrinks_to_just_above_one() raises:
    for seed in range(1, 6):
        var types = Types()
        var t = types.float_(4)
        var p = Drawn(types^, t, 1)
        var r = search(p, settings(UInt64(seed)))
        assert_true(r.properties[0].failed)
        var src = Source(0)
        src.reset_replay(r.properties[0].choices.values)
        _ = p.run(src)
        assert_equal(p.last.float_bits(), UInt64(0x3FF0000000000001))


def test_speed_of_list_of_pairs() raises:
    var types = Types()
    var t = types.list_of(types.tuple_of([types.fixed(32, True), types.string()]))
    var sizes = Sizes()
    var src = Source(1)
    var total = 0
    var ms = 1e18
    # The best of three runs, so a busy machine or a cold start doesn't decide it.
    for _ in range(3):
        total = 0
        var t0 = perf_counter_ns()
        for _ in range(10000):
            src.reset_generate()
            total += draw_value(src, types, t, sizes, 0).count()
        ms = min(ms, Float64(perf_counter_ns() - t0) / 1e6)
    print("10000 draws of list<(i32, string)>:", ms, "ms (", total, "elements )")
    assert_true(total > 0)
    # The aim is under 50 ms; the bound leaves room for a loaded machine.
    assert_true(ms < 100.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
