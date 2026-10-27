from std.testing import assert_equal, assert_true, TestSuite
from std.time import perf_counter_ns

from mcheck.property import Property, Outcome, PASSED, FAILED
from mcheck.search import search
from mcheck.settings import Settings
from mcheck.source import Source


struct Together(Property):
    """Draws lo, x, hi in [0, 1000]; fails when x == hi and lo < x."""

    var lo: Int
    var x: Int
    var hi: Int

    def __init__(out self):
        self.lo = 0
        self.x = 0
        self.hi = 0

    def run(mut self, mut src: Source) raises -> Outcome:
        self.lo = src.draw_int(0, 1000)
        self.x = src.draw_int(0, 1000)
        self.hi = src.draw_int(0, 1000)
        return Outcome.single(0, FAILED if self.x == self.hi and self.lo < self.x else PASSED)


struct Spread(Property):
    """Fails when a - b == 7 over two ints in [0, 1000]."""

    var a: Int
    var b: Int

    def __init__(out self):
        self.a = 0
        self.b = 0

    def run(mut self, mut src: Source) raises -> Outcome:
        self.a = src.draw_int(0, 1000)
        self.b = src.draw_int(0, 1000)
        return Outcome.single(0, FAILED if self.a - self.b == 7 else PASSED)


struct Passing(Property):
    def __init__(out self):
        pass

    def run(mut self, mut src: Source) raises -> Outcome:
        var s = 0
        for _ in range(4):
            s += src.draw_int(0, 1000)
        return Outcome.single(0, PASSED)


def settings(seed: UInt64) -> Settings:
    var s = Settings()
    s.seed = seed
    s.max_examples = 1000
    s.max_shrink_steps = 3000
    return s^


def test_equal_choices_shrink_together() raises:
    var found = 0
    for seed in range(1, 8):
        var p = Together()
        var r = search(p, settings(UInt64(seed)))
        if not r.properties[0].failed:
            continue
        found += 1
        var src = Source(0)
        src.reset_replay(r.properties[0].choices.values)
        _ = p.run(src)
        assert_equal(p.lo, 0)
        assert_equal(p.x, 1)
        assert_equal(p.hi, 1)
    assert_true(found > 0)


def test_nearby_choices_shrink_together() raises:
    var found = 0
    for seed in range(1, 8):
        var p = Spread()
        var r = search(p, settings(UInt64(seed)))
        if not r.properties[0].failed:
            continue
        found += 1
        var src = Source(0)
        src.reset_replay(r.properties[0].choices.values)
        _ = p.run(src)
        assert_equal(p.a, 7)
        assert_equal(p.b, 0)
    assert_true(found > 0)


def test_passing_search_time() raises:
    var best = 1e18
    for _ in range(3):
        var p = Passing()
        var t0 = perf_counter_ns()
        var r = search(p, settings(1))
        best = min(best, Float64(perf_counter_ns() - t0) / 1e6)
        assert_equal(r.examples, 1000)
    print("passing 1000-example search:", best, "ms")
    assert_true(best < 500.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
