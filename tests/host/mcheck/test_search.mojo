from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.tempfile import mkdtemp

from mcheck.choices import Choices
from mcheck.property import Property, Outcome, PASSED, FAILED
from mcheck.search import search, enumerate_all
from mcheck.settings import Settings
from mcheck.shrink import shrink
from mcheck.source import Source, Many


struct IntAbove(Property):
    """Fails when x >= limit, x in [0, 10000]; records the draws."""

    var limit: Int
    var seen: List[Int]

    def __init__(out self, limit: Int):
        self.limit = limit
        self.seen = List[Int]()

    def run(mut self, mut src: Source) raises -> Outcome:
        var x = src.draw_int(0, 10000)
        self.seen.append(x)
        return Outcome.single(0, FAILED if x >= self.limit else PASSED)


struct ListSum(Property):
    var limit: Int
    var last: List[Int]

    def __init__(out self, limit: Int):
        self.limit = limit
        self.last = List[Int]()

    def run(mut self, mut src: Source) raises -> Outcome:
        self.last = List[Int]()
        var m = Many(0, 50, 5.0)
        var total = 0
        while m.more(src):
            var v = src.draw_int(0, 1000)
            self.last.append(v)
            total += v
        return Outcome.single(0, FAILED if total >= self.limit else PASSED)


struct ListLen(Property):
    var last: List[Int]

    def __init__(out self):
        self.last = List[Int]()

    def run(mut self, mut src: Source) raises -> Outcome:
        self.last = List[Int]()
        var m = Many(0, 50, 5.0)
        while m.more(src):
            self.last.append(src.draw_int(0, 1000))
        return Outcome.single(0, FAILED if len(self.last) >= 3 else PASSED)


struct TwoSided(Property):
    var x: Int

    def __init__(out self):
        self.x = 0

    def run(mut self, mut src: Source) raises -> Outcome:
        self.x = src.draw_int(-10000, 10000)
        var o = Outcome()
        o.add(1, FAILED if self.x > 500 else PASSED)
        o.add(2, FAILED if self.x < -500 else PASSED)
        return o^


struct Never(Property):
    def __init__(out self):
        pass

    def run(mut self, mut src: Source) raises -> Outcome:
        _ = src.draw_int(0, 10)
        return Outcome.single(0, PASSED)


struct Picky(Property):
    """Rejects 19 of 20 examples."""

    def __init__(out self):
        pass

    def run(mut self, mut src: Source) raises -> Outcome:
        if src.draw_below(20) != 0:
            src.reject()
        return Outcome.single(0, PASSED)


struct Trivial(Property):
    def __init__(out self):
        pass

    def run(mut self, mut src: Source) raises -> Outcome:
        _ = src.draw_bits(8)
        return Outcome.single(0, PASSED)


struct Mod7(Property):
    def __init__(out self):
        pass

    def run(mut self, mut src: Source) raises -> Outcome:
        var i = src.draw_below(65536)
        return Outcome.single(0, FAILED if i % 1000 == 7 else PASSED)


def settings(seed: UInt64 = 1, examples: Int = 100) -> Settings:
    var s = Settings()
    s.seed = seed
    s.max_examples = examples
    return s^


def test_determinism() raises:
    var a = IntAbove(100000)
    var b = IntAbove(100000)
    var c = IntAbove(100000)
    _ = search(a, settings(5, 50))
    _ = search(b, settings(5, 50))
    _ = search(c, settings(6, 50))
    assert_equal(len(a.seen), 50)
    var same = True
    var diff = False
    for i in range(50):
        if a.seen[i] != b.seen[i]:
            same = False
        if a.seen[i] != c.seen[i]:
            diff = True
    assert_true(same)
    assert_true(diff)


def test_int_shrinks_to_threshold() raises:
    var p = IntAbove(1000)
    var r = search(p, settings(1, 200))
    assert_equal(len(r.properties), 1)
    assert_true(r.properties[0].failed)
    var replay = Source(0)
    replay.reset_replay(r.properties[0].choices.values)
    assert_equal(replay.draw_int(0, 10000), 1000)


def test_list_sum_shrinks() raises:
    var p = ListSum(100)
    var r = search(p, settings(2, 300))
    assert_true(r.properties[0].failed)
    var src = Source(0)
    src.reset_replay(r.properties[0].choices.values)
    _ = p.run(src)
    assert_equal(len(p.last), 1)
    assert_equal(p.last[0], 100)


def test_list_length_shrinks() raises:
    var p = ListLen()
    var r = search(p, settings(3, 300))
    assert_true(r.properties[0].failed)
    var src = Source(0)
    src.reset_replay(r.properties[0].choices.values)
    _ = p.run(src)
    assert_equal(len(p.last), 3)
    for v in p.last:
        assert_equal(v, 0)


def test_two_properties() raises:
    var p = TwoSided()
    var r = search(p, settings(4, 300))
    assert_equal(len(r.properties), 2)
    for pr in r.properties:
        assert_true(pr.failed)
        var src = Source(0)
        src.reset_replay(pr.choices.values)
        _ = p.run(src)
        assert_equal(p.x, 501 if pr.id == 1 else -501)


def test_never_fails() raises:
    var p = Never()
    var r = search(p, settings(1, 100))
    assert_equal(r.examples, 100)
    assert_equal(r.invalid, 0)
    assert_equal(len(r.properties), 1)
    assert_false(r.properties[0].failed)
    assert_equal(r.properties[0].passes, 100)
    assert_equal(r.properties[0].fails, 0)
    assert_equal(r.properties[0].skips, 0)


def test_invalid_cap() raises:
    var p = Picky()
    var r = search(p, settings(1, 100))
    assert_true(r.invalid > 0)
    assert_true(r.examples < 100)
    assert_equal(r.examples + r.invalid, 1000)


def test_enumeration() raises:
    var p = Mod7()
    var r = enumerate_all(p, 65536, settings())
    assert_equal(r.examples, 65536)
    assert_true(r.properties[0].failed)
    assert_equal(r.properties[0].fails, 66)
    assert_equal(r.properties[0].choices.values[0], 7)


def test_enumeration_sample() raises:
    var s = settings()
    s.max_exhaustive = 1000
    var p = Mod7()
    var r = enumerate_all(p, 65536, s)
    assert_equal(r.examples, 1000)
    assert_true(r.properties[0].fails > 0)


def test_store_replayed_first() raises:
    var dir = mkdtemp()
    var s = settings(1, 200)
    s.store_dir = dir
    s.keys.append("k")
    var p = IntAbove(1000)
    var r = search(p, s)
    assert_true(r.properties[0].failed)
    var s2 = settings(999, 200)
    s2.store_dir = dir
    s2.keys.append("k")
    var q = IntAbove(1000)
    var r2 = search(q, s2)
    assert_equal(q.seen[0], 1000)
    assert_true(r2.properties[0].failed)


def test_speed() raises:
    var p = Trivial()
    var s = settings(1, 10000)
    var r = search(p, s)
    assert_equal(r.examples, 10000)
    print("10,000 trivial examples:", r.elapsed_ns // 1000, "us")
    assert_true(r.elapsed_ns < 500_000_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
