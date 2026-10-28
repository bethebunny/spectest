"""Sets of bit patterns up to 64 bits wide, and the context that owns their nodes."""

from std.collections import Set
from std.os import abort

from arena import ACCEPT, Arena, Id, Interrupted, REJECT
from arena.apply import complement, difference, intersection, union
from arena.arena import PauseStatePointer, never_pause
from arena.build import diagram, exactly_these, interval, narrow_bit
from arena.compare import disjoint, subset
from arena.members import accepts, bits_between, nth_narrow, rank_narrow
from arena.walk import Narrow, Walk
from value.bigint import BigInt
from value.fixed import int_max, int_min, low_mask, pattern_of
from value.float_formats import FloatFormat

from .pattern import expand_pattern

comptime Combine = def(mut Arena, Id, Id) thin raises Interrupted -> Id
comptime Relation = def(mut Arena, Id, Id) thin raises Interrupted -> Bool


@fieldwise_init
struct BitSet(Copyable, Equatable, TrivialRegisterPassable):
    """A set of `width`-bit patterns, valid only with the `SetContext` that made it."""

    var width: Int32
    var root: Id


def _check_width(width: Int) raises:
    if width < 1 or width > 64:
        raise Error(t"set widths are 1 to 64 bits, not {width}")


struct SetContext(Movable):
    """Owns the arena of its sets. Nothing is freed before the context is dropped.

    The arena never pauses, so its operations never raise `Interrupted`.
    """

    var arena: Arena

    def __init__(out self):
        self.arena = Arena(never_pause, PauseStatePointer.unsafe_dangling())

    def empty(self, width: Int) -> BitSet:
        return BitSet(Int32(width), REJECT)

    def full(self, width: Int) -> BitSet:
        return BitSet(Int32(width), ACCEPT)

    def interval_inclusive(
        mut self, first: UInt64, last: UInt64, width: Int
    ) -> BitSet:
        """`[first, last]`, empty if `last < first`."""
        if last < first:
            return self.empty(width)
        try:
            return BitSet(
                Int32(width),
                interval[narrow_bit](self.arena, UInt128(first), UInt128(last), Int32(width)),
            )
        except:
            abort("interval interrupted")

    def interval(mut self, lo: UInt64, hi: UInt64, width: Int) -> BitSet:
        """`[lo, hi)`, empty if `hi <= lo`."""
        if hi <= lo:
            return self.empty(width)
        return self.interval_inclusive(lo, hi - 1, width)

    def exactly(mut self, values: List[UInt64], width: Int) -> BitSet:
        var members = [UInt128(v) for v in Set(values)]
        sort(members)
        try:
            return BitSet(Int32(width), exactly_these[narrow_bit](self.arena, members, Int32(width)))
        except:
            abort("exactly interrupted")

    def _diagram(mut self, bits: String, width: Int) -> BitSet:
        try:
            return BitSet(Int32(width), diagram(self.arena, bits))
        except:
            abort("diagram interrupted")

    def pattern(mut self, text: StringSlice, width: Int) raises -> BitSet:
        _check_width(width)
        var bits = expand_pattern(text)
        if bits.byte_length() != width:
            raise Error(t"the pattern is {bits.byte_length()} bits, not {width}")
        return self._diagram(bits, width)

    def int_range(
        mut self,
        width: Int,
        signed: Bool,
        lo: Optional[BigInt],
        hi: Optional[BigInt],
    ) -> BitSet:
        """Integers in `[lo, hi)` as two's-complement patterns (absent bounds are open)."""
        var type_lo = int_min(width, signed)
        var type_hi = int_max(width, signed) + 1
        var low = type_lo.copy() if lo is None else max(lo.value().copy(), type_lo)
        var high = type_hi.copy() if hi is None else min(hi.value().copy(), type_hi)
        if low >= high:
            return self.empty(width)
        var last = high - 1
        if low.negative and not last.negative:
            # straddles zero: the non-negatives, then the negatives from the top
            var upper = self.interval_inclusive(pattern_of(low, width), low_mask(width), width)
            var lower = self.interval_inclusive(0, pattern_of(last, width), width)
            return self.union(lower, upper)
        return self.interval_inclusive(pattern_of(low, width), pattern_of(last, width), width)

    def float_named(mut self, format: FloatFormat, name: StringSlice) raises -> BitSet:
        match name:
            case "nan":
                var any_nan_or_inf = self._float_glob(format, "?", "1", "?")
                return self.difference(any_nan_or_inf, self._float_glob(format, "?", "1", "0"))
            case "inf":
                return self._float_glob(format, "?", "1", "0")
            case "zero":
                return self._float_glob(format, "?", "0", "0")
            case "subnormal":
                var zero_exponent = self._float_glob(format, "?", "0", "?")
                return self.difference(zero_exponent, self._float_glob(format, "?", "0", "0"))
            case "normal":
                var special = self.union(
                    self._float_glob(format, "?", "0", "?"),
                    self._float_glob(format, "?", "1", "?"),
                )
                return self.complement(special)
            case "finite":
                return self.complement(self._float_glob(format, "?", "1", "?"))
            case "positive":
                return self._float_glob(format, "0", "?", "?")
            case "negative":
                return self._float_glob(format, "1", "?", "?")
            case _:
                raise Error(t"no float set named {name}")

    def _float_glob(
        mut self,
        format: FloatFormat,
        sign: String,
        exponent: String,
        fraction: String,
    ) -> BitSet:
        var bits = sign + exponent * format.exponent_bits + fraction * format.fraction_bits
        return self._diagram(bits, format.width())

    def float_magnitudes(
        mut self, format: FloatFormat, lo: UInt64, hi: UInt64, negative: Bool
    ) -> BitSet:
        """Patterns with magnitude (the bits below the sign) in `[lo, hi)`."""
        if hi <= lo:
            return self.empty(format.width())
        var sign = format.sign_mask() if negative else UInt64(0)
        return self.interval_inclusive(lo | sign, (hi - 1) | sign, format.width())

    def _combined[op: Combine](mut self, a: BitSet, b: BitSet) -> BitSet:
        try:
            return BitSet(a.width, op(self.arena, a.root, b.root))
        except:
            abort("set operation interrupted")

    def _related[relation: Relation](mut self, a: BitSet, b: BitSet) -> Bool:
        try:
            return relation(self.arena, a.root, b.root)
        except:
            abort("set comparison interrupted")

    def union(mut self, a: BitSet, b: BitSet) -> BitSet:
        return self._combined[union](a, b)

    def intersection(mut self, a: BitSet, b: BitSet) -> BitSet:
        return self._combined[intersection](a, b)

    def difference(mut self, a: BitSet, b: BitSet) -> BitSet:
        return self._combined[difference](a, b)

    def complement(mut self, a: BitSet) -> BitSet:
        try:
            return BitSet(a.width, complement(self.arena, a.root))
        except:
            abort("complement interrupted")

    def is_empty(self, a: BitSet) -> Bool:
        return a.root == REJECT

    def equal(self, a: BitSet, b: BitSet) -> Bool:
        return a.root == b.root

    def subset(mut self, a: BitSet, b: BitSet) -> Bool:
        return self._related[subset](a, b)

    def disjoint(mut self, a: BitSet, b: BitSet) -> Bool:
        return self._related[disjoint](a, b)

    def count(self, a: BitSet) -> UInt128:
        return self.arena.count_narrow(a.root, a.width)

    def contains(self, a: BitSet, bits: UInt64) -> Bool:
        return bits <= low_mask(Int(a.width)) and accepts[narrow_bit](self.arena, a.root, UInt128(bits))

    def nth(self, a: BitSet, n: UInt64) -> UInt64:
        """The `n`-th member in increasing order (0 if `n` is not below `count(a)`)."""
        if UInt128(n) >= self.count(a):
            return 0
        return UInt64(nth_narrow(self.arena, a.root, UInt128(n)))

    def rank(self, a: BitSet, bits: UInt64) -> UInt128:
        """How many members are below `bits`, read as a `width`-bit pattern."""
        return rank_narrow(self.arena, a.root, bits_between(UInt128(bits), low=0, high=a.width), a.width)

    def members(self, a: BitSet, limit: Int) raises -> List[UInt64]:
        """Every member in increasing order; raises if there are more than `limit`."""
        if self.count(a) > UInt128(limit):
            raise Error(t"the set has more than {limit} members")
        var walk = Walk[Narrow](a.root, a.width)
        var members: List[UInt64] = []
        while case .Some(run) = walk.next_run(self.arena):
            var first = UInt64(run.first.value)
            members.extend([first + UInt64(k) for k in range(1 << Int(run.free))])
        return members^
