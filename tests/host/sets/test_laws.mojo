"""Inverse nth and rank, and the laws of the algebra, checked against a model of plain
bool arrays on small widths."""

from std.testing import assert_equal, assert_true, TestSuite

from bigint import BigUInt
from sets import BitSet, SetContext

comptime W = 10
comptime N = 1 << W


struct Rng(Movable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return self.state >> 33


def _random_members(mut rng: Rng, density: Int) -> List[UInt64]:
    var out = List[UInt64]()
    for i in range(N):
        if Int(rng.next() % 100) < density:
            out.append(UInt64(i))
    return out^


def _random_set(mut c: SetContext, mut rng: Rng) -> BitSet:
    """A union of a few random intervals and a scatter of points."""
    var s = c.empty(W)
    for _ in range(Int(rng.next() % 4)):
        var a = rng.next() % UInt64(N)
        var b = rng.next() % UInt64(N)
        s = c.union(s, c.interval(min(a, b), max(a, b), W))
    s = c.union(s, c.exactly(_random_members(rng, 3), W))
    return s


def _model(c: SetContext, s: BitSet) -> List[Bool]:
    var out = List[Bool]()
    for i in range(N):
        out.append(c.contains(s, UInt64(i)))
    return out^


def _same(a: List[Bool], b: List[Bool]) -> Bool:
    for i in range(N):
        if a[i] != b[i]:
            return False
    return True


def test_nth_and_rank_are_inverses() raises:
    var c = SetContext()
    var rng = Rng(7)
    for _ in range(40):
        var s = _random_set(c, rng)
        var total = c.count(s).uint128_or_none().value()
        var previous: Optional[UInt64] = None
        var seen = 0
        for i in range(Int(total)):
            var member = c.nth(s, BigUInt(UInt64(i)))
            assert_true(c.contains(s, member))
            if previous:
                assert_true(previous.value() < member)
            previous = member
            assert_true(c.rank(s, member) == BigUInt(UInt64(i)))
            seen += 1
        assert_equal(UInt128(seen), total)
        # rank of any pattern counts the members below it.
        var below = 0
        for v in range(N):
            assert_true(c.rank(s, UInt64(v)) == BigUInt(UInt64(below)))
            if c.contains(s, UInt64(v)):
                below += 1


def test_members_match_nth() raises:
    var c = SetContext()
    var s = c.exactly([9, 1, 5], 4)
    var m = c.members(s, 3)
    assert_equal(len(m), 3)
    assert_equal(m[0], 1)
    assert_equal(m[1], 5)
    assert_equal(m[2], 9)
    assert_equal(len(c.members(c.empty(4), 0)), 0)


def test_algebra_against_model() raises:
    var c = SetContext()
    var rng = Rng(11)
    for _ in range(30):
        var a = _random_set(c, rng)
        var b = _random_set(c, rng)
        var ma = _model(c, a)
        var mb = _model(c, b)
        var un = List[Bool]()
        var inter = List[Bool]()
        var diff = List[Bool]()
        var comp = List[Bool]()
        var sub = True
        var disj = True
        for i in range(N):
            un.append(ma[i] or mb[i])
            inter.append(ma[i] and mb[i])
            diff.append(ma[i] and not mb[i])
            comp.append(not ma[i])
            if ma[i] and not mb[i]:
                sub = False
            if ma[i] and mb[i]:
                disj = False
        assert_true(_same(_model(c, c.union(a, b)), un))
        assert_true(_same(_model(c, c.intersection(a, b)), inter))
        assert_true(_same(_model(c, c.difference(a, b)), diff))
        assert_true(_same(_model(c, c.complement(a)), comp))
        assert_true(c.subset(a, b) == sub)
        assert_true(c.disjoint(a, b) == disj)
        assert_true(c.is_empty(c.intersection(a, b)) == disj)


def test_laws() raises:
    var c = SetContext()
    var rng = Rng(23)
    var none = c.empty(W)
    var all = c.full(W)
    for _ in range(30):
        var a = _random_set(c, rng)
        var b = _random_set(c, rng)
        var d = _random_set(c, rng)
        assert_true(c.equal(c.union(a, b), c.union(b, a)))
        assert_true(c.equal(c.intersection(a, b), c.intersection(b, a)))
        assert_true(c.equal(c.union(a, c.union(b, d)), c.union(c.union(a, b), d)))
        assert_true(
            c.equal(
                c.intersection(a, c.union(b, d)),
                c.union(c.intersection(a, b), c.intersection(a, d)),
            )
        )
        assert_true(c.equal(c.complement(c.complement(a)), a))
        assert_true(
            c.equal(
                c.complement(c.union(a, b)),
                c.intersection(c.complement(a), c.complement(b)),
            )
        )
        assert_true(c.equal(c.union(a, c.complement(a)), all))
        assert_true(c.is_empty(c.intersection(a, c.complement(a))))
        assert_true(c.equal(c.difference(a, b), c.intersection(a, c.complement(b))))
        assert_true(c.equal(c.union(a, none), a))
        assert_true(c.equal(c.intersection(a, all), a))
        assert_true(c.subset(c.intersection(a, b), a))
        assert_true(c.subset(a, c.union(a, b)))
        # |a| + |b| = |a or b| + |a and b|
        var left = c.count(a) + c.count(b)
        var right = c.count(c.union(a, b)) + c.count(c.intersection(a, b))
        assert_true(left == right)
        assert_true(c.count(c.complement(a)) + c.count(a) == BigUInt(UInt64(N)))


def test_wide_sets() raises:
    """Sets 64 bits wide, with nth and rank over the whole range."""
    var c = SetContext()
    var s = c.union(
        c.interval(5, 1000, 64),
        c.interval_inclusive(UInt64.MAX - 500, UInt64.MAX, 64),
    )
    assert_true(c.count(s) == BigUInt(995 + 501))
    assert_equal(c.nth(s, BigUInt(0)), 5)
    assert_equal(c.nth(s, BigUInt(994)), 999)
    assert_equal(c.nth(s, BigUInt(995)), UInt64.MAX - 500)
    assert_equal(c.nth(s, BigUInt(1495)), UInt64.MAX)
    assert_true(c.rank(s, UInt64.MAX) == BigUInt(1495))
    assert_true(c.rank(s, 5) == BigUInt(0))
    var all = c.full(64)
    assert_equal(c.nth(all, BigUInt(UInt64.MAX)), UInt64.MAX)
    assert_true(c.rank(all, UInt64.MAX) == BigUInt(UInt64.MAX))
    # Out of range nth gives 0.
    assert_equal(c.nth(s, BigUInt(1496)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
