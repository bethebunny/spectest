from std.testing import assert_equal, assert_true, TestSuite

from spec.types import Types
from host.draw.sizes import Sizes
from host.draw.value import draw_value
from mcheck.property import Property, Outcome, PASSED, FAILED
from mcheck.search import search
from mcheck.settings import Settings
from mcheck.source import Source
from value.value import Value


struct ListProp(Property):
    """Draws a list<i32>. kind 0: fails at 20 or more elements. 1: fails when it holds 7."""

    var types: Types
    var t: Int
    var sizes: Sizes
    var kind: Int
    var last: Value
    var first_fail_len: Int

    def __init__(out self, var types: Types, t: Int, kind: Int):
        self.types = types^
        self.t = t
        self.sizes = Sizes()
        self.kind = kind
        self.last = Value.none()
        self.first_fail_len = -1

    def run(mut self, mut src: Source) raises -> Outcome:
        self.last = draw_value(src, self.types, self.t, self.sizes, 0)
        var n = self.last.count()
        var bad = False
        if self.kind == 0:
            bad = n >= 20
        else:
            for i in range(n):
                var x = self.last.item(i).small_int()
                if x and x.value() == 7:
                    bad = True
        if bad and self.first_fail_len < 0:
            self.first_fail_len = n
        return Outcome.single(0, FAILED if bad else PASSED)


def settings(seed: UInt64) -> Settings:
    var s = Settings()
    s.seed = seed
    s.max_examples = 1000
    s.max_shrink_steps = 5000
    return s^


def test_long_list_shrinks_to_its_threshold() raises:
    var found = 0
    for seed in range(1, 6):
        var types = Types()
        var t = types.list_of(types.fixed(32, True))
        var p = ListProp(types^, t, 0)
        var r = search(p, settings(UInt64(seed)))
        if not r.properties[0].failed:
            continue
        found += 1
        var src = Source(0)
        src.reset_replay(r.properties[0].choices.values)
        _ = p.run(src)
        assert_equal(p.last.count(), 20)
    assert_true(found > 0)


def test_long_list_shrinks_to_one_element() raises:
    var found = 0
    var started_long = 0
    for seed in range(1, 12):
        var types = Types()
        var t = types.list_of(types.fixed(32, True))
        var p = ListProp(types^, t, 1)
        var r = search(p, settings(UInt64(seed)))
        if not r.properties[0].failed:
            continue
        found += 1
        if p.first_fail_len >= 17:
            started_long += 1
        var src = Source(0)
        src.reset_replay(r.properties[0].choices.values)
        _ = p.run(src)
        assert_equal(p.last.count(), 1)
        assert_equal(p.last.item(0).small_int().value(), 7)
    assert_true(found > 0)
    assert_true(started_long > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
