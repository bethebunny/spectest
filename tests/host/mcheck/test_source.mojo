from std.testing import assert_equal, assert_true, assert_raises, TestSuite

from mcheck.source import Source, Many, int_to_index, index_to_int
from std.tempfile import mkdtemp
from mcheck.store import store_save, store_load


def test_int_encoding_roundtrip() raises:
    var cases = List[Tuple[Int, Int]]()
    cases.append((-5, 5))
    cases.append((0, 10))
    cases.append((3, 9))
    cases.append((-9, -3))
    cases.append((-3, 100))
    cases.append((-100, 3))
    cases.append((-9223372036854775808, 9223372036854775807))
    for c in cases:
        var lo = c[0]
        var hi = c[1]
        var bound = UInt64(hi) - UInt64(lo)
        var probes = List[UInt64]()
        probes.append(0)
        probes.append(1)
        probes.append(2)
        probes.append(3)
        probes.append(bound // 2)
        probes.append(bound - 1)
        probes.append(bound)
        for p in probes:
            if p <= bound:
                var x = index_to_int(p, lo, hi)
                assert_true(lo <= x and x <= hi)
                assert_equal(int_to_index(x, lo, hi), p)


def test_int_encoding_order() raises:
    assert_equal(index_to_int(0, -10, 10), 0)
    assert_equal(index_to_int(1, -10, 10), 1)
    assert_equal(index_to_int(2, -10, 10), -1)
    assert_equal(index_to_int(0, 5, 9), 5)
    assert_equal(index_to_int(0, -9, -5), -5)


def test_draw_in_range_and_deterministic() raises:
    var a = Source(7)
    var b = Source(7)
    for _ in range(200):
        var x = a.draw_int(-50, 50)
        assert_true(-50 <= x and x <= 50)
        assert_equal(x, b.draw_int(-50, 50))


def test_replay() raises:
    var a = Source(3)
    var xs = List[Int]()
    for _ in range(20):
        xs.append(a.draw_int(-1000, 1000))
    var r = Source(99)
    r.reset_replay(a.rec.values)
    for i in range(20):
        assert_equal(r.draw_int(-1000, 1000), xs[i])
    with assert_raises():
        _ = r.draw_int(0, 1)
    assert_true(r.invalid)


def test_many_spans() raises:
    var s = Source(1)
    var m = Many(0, 10, 3.0)
    var n = 0
    while m.more(s):
        _ = s.draw_int(0, 5)
        n += 1
    assert_equal(len(s.rec.spans), n + 1 if n < 10 else n)


def test_store_roundtrip() raises:
    var s = Source(5)
    s.start_span(4)
    _ = s.draw_int(0, 100)
    _ = s.draw_bool()
    s.stop_span()
    var dir = mkdtemp()
    store_save(dir, "a key/with chars", s.rec)
    var loaded = store_load(dir, "a key/with chars")
    assert_true(Bool(loaded))
    var got = loaded.take()
    assert_equal(len(got.values), 2)
    assert_equal(got.values[0], s.rec.values[0])
    assert_equal(got.bounds[0], s.rec.bounds[0])
    assert_equal(len(got.spans), 1)
    assert_equal(got.spans[0].label, 4)
    assert_true(not Bool(store_load(dir, "missing")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
