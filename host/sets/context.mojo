"""Sets of bit patterns up to 64 bits wide, and the context that owns their nodes."""

from std.os import abort
from std.builtin.sort import sort

from arena import ACCEPT, Arena, Id, Interrupted, REJECT
from arena.apply import complement, difference, intersection, union
from arena.arena import PauseStatePointer, never_pause
from arena.build import diagram, exactly_these, interval
from arena.compare import disjoint, subset
from arena.members import accepts, nth_narrow, rank_narrow
from bigint import BigUInt
from numeric.bigint import BigInt
from numeric.formats import FloatFormat

from .pattern import expand_pattern


def _bit(value: UInt64, bit: Int32) -> Bool:
    return bit < 64 and (value >> UInt64(bit)) & 1 == 1


@fieldwise_init
struct BitSet(Copyable, Equatable, TrivialRegisterPassable):
    """A set of `width`-bit patterns. Valid only with the `SetContext` that made it. Two
    sets of one context are equal exactly when their roots are."""

    var width: Int32
    var root: Id

    def __eq__(self, other: Self) -> Bool:
        return self.width == other.width and self.root == other.root


def _check_width(width: Int) raises:
    if width < 1 or width > 64:
        raise Error("set widths are 1 to 64 bits, not " + String(width))


struct SetContext(Movable):
    """Owns one arena. Nothing is freed until the context is dropped, so a context
    lives as long as one spec run."""

    var arena: Arena

    def __init__(out self):
        self.arena = Arena(never_pause, PauseStatePointer.unsafe_dangling())

    def _done(self, width: Int32, id: Id) -> BitSet:
        return BitSet(width, id)

    # Builders

    def empty(mut self, width: Int) -> BitSet:
        return BitSet(Int32(width), REJECT)

    def full(mut self, width: Int) -> BitSet:
        return BitSet(Int32(width), ACCEPT)

    def interval_inclusive(
        mut self, first: UInt64, last: UInt64, width: Int
    ) -> BitSet:
        """`[first, last]`, empty if `last < first`. Both must fit `width` bits."""
        if last < first:
            return self.empty(width)
        try:
            return BitSet(
                Int32(width), interval[_bit](self.arena, first, last, Int32(width))
            )
        except:
            abort("interval interrupted")

    def interval(mut self, lo: UInt64, hi: UInt64, width: Int) -> BitSet:
        """`[lo, hi)`, empty if `hi <= lo`. For a range that includes the width's
        highest pattern, use `interval_inclusive`."""
        if hi <= lo:
            return self.empty(width)
        return self.interval_inclusive(lo, hi - 1, width)

    def exactly(mut self, var values: List[UInt64], width: Int) -> BitSet:
        """The listed patterns, in any order, duplicates allowed."""
        sort(values)
        var distinct = List[UInt64]()
        for v in values:
            if not distinct or distinct[len(distinct) - 1] != v:
                distinct.append(v)
        try:
            return BitSet(
                Int32(width),
                exactly_these[_bit](self.arena, distinct, Int32(width)),
            )
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
            raise Error(
                "the pattern is "
                + String(bits.byte_length())
                + " bits, not "
                + String(width)
            )
        return self._diagram(bits, width)

    def int_range(
        mut self,
        width: Int,
        signed: Bool,
        lo: Optional[BigInt],
        hi: Optional[BigInt],
    ) -> BitSet:
        """Integers in `[lo, hi)` as two's-complement patterns; an absent bound is open,
        and bounds are clamped to the type."""
        var modulus = BigInt(negative=False, magnitude=BigUInt(1) << width)
        var type_lo = BigInt()
        var type_hi = modulus.copy()
        if signed:
            var half = BigInt(negative=False, magnitude=BigUInt(1) << (width - 1))
            type_lo = -half
            type_hi = half^
        var low = type_lo.copy()
        if lo:
            low = max(lo.value().copy(), type_lo)
        var high = type_hi.copy()
        if hi:
            high = min(hi.value().copy(), type_hi)
        if not (low < high):
            return self.empty(width)
        var last = high - BigInt(1)
        if low.negative and not last.negative:
            # Straddles zero: the non-negatives, then the negatives from the top.
            var upper = self.interval_inclusive(
                _u64(low + modulus), _u64(modulus - BigInt(1)), width
            )
            var lower = self.interval_inclusive(0, _u64(last), width)
            return self.union(lower, upper)
        if low.negative:
            return self.interval_inclusive(
                _u64(low + modulus), _u64(last + modulus), width
            )
        return self.interval_inclusive(_u64(low), _u64(last), width)

    def float_named(mut self, format: FloatFormat, name: StringSlice) raises -> BitSet:
        if name == "nan":
            return self.difference(
                self._float_glob(format, "?", "1", "?"),
                self._float_glob(format, "?", "1", "0"),
            )
        if name == "inf":
            return self._float_glob(format, "?", "1", "0")
        if name == "zero":
            return self._float_glob(format, "?", "0", "0")
        if name == "subnormal":
            return self.difference(
                self._float_glob(format, "?", "0", "?"),
                self._float_glob(format, "?", "0", "0"),
            )
        if name == "normal":
            var special = self.union(
                self._float_glob(format, "?", "0", "?"),
                self._float_glob(format, "?", "1", "?"),
            )
            return self.complement(special)
        if name == "finite":
            return self.complement(self._float_glob(format, "?", "1", "?"))
        if name == "positive":
            return self._float_glob(format, "0", "?", "?")
        if name == "negative":
            return self._float_glob(format, "1", "?", "?")
        raise Error("no float set named " + String(name))

    def _float_glob(
        mut self,
        format: FloatFormat,
        sign: String,
        exponent: String,
        fraction: String,
    ) -> BitSet:
        var bits = sign
        for _ in range(format.exponent_bits):
            bits += exponent
        for _ in range(format.fraction_bits):
            bits += fraction
        return self._diagram(bits, format.width())

    def float_magnitudes(
        mut self, format: FloatFormat, lo: UInt64, hi: UInt64, negative: Bool
    ) -> BitSet:
        """Patterns whose magnitude (the bits below the sign) is in `[lo, hi)`, with the
        sign bit set if `negative`."""
        if hi <= lo:
            return self.empty(format.width())
        var sign = format.sign_mask() if negative else UInt64(0)
        return self.interval_inclusive(lo | sign, (hi - 1) | sign, format.width())

    # Algebra

    def union(mut self, a: BitSet, b: BitSet) -> BitSet:
        try:
            return BitSet(a.width, union(self.arena, a.root, b.root))
        except:
            abort("union interrupted")

    def intersection(mut self, a: BitSet, b: BitSet) -> BitSet:
        try:
            return BitSet(a.width, intersection(self.arena, a.root, b.root))
        except:
            abort("intersection interrupted")

    def difference(mut self, a: BitSet, b: BitSet) -> BitSet:
        try:
            return BitSet(a.width, difference(self.arena, a.root, b.root))
        except:
            abort("difference interrupted")

    def complement(mut self, a: BitSet) -> BitSet:
        """The patterns of `a`'s width that `a` lacks."""
        try:
            return BitSet(a.width, complement(self.arena, a.root))
        except:
            abort("complement interrupted")

    # Queries

    def is_empty(self, a: BitSet) -> Bool:
        return a.root == REJECT

    def equal(self, a: BitSet, b: BitSet) -> Bool:
        return a.root == b.root

    def subset(mut self, a: BitSet, b: BitSet) -> Bool:
        try:
            return subset(self.arena, a.root, b.root)
        except:
            abort("subset interrupted")

    def disjoint(mut self, a: BitSet, b: BitSet) -> Bool:
        try:
            return disjoint(self.arena, a.root, b.root)
        except:
            abort("disjoint interrupted")

    def count(self, a: BitSet) -> BigUInt:
        return self.arena.count(a.root, a.width)

    def contains(self, a: BitSet, bits: UInt64) -> Bool:
        if a.width < 64 and (bits >> UInt64(a.width)) != 0:
            return False
        return accepts[_bit](self.arena, a.root, bits)

    def nth(self, a: BitSet, n: BigUInt) -> UInt64:
        """The `n`-th member in increasing order. `n` must be below `count(a)`; any
        other `n` gives 0."""
        var small = n.uint128_or_none()
        if not small or small.value() >= self.arena.count_narrow(a.root, a.width):
            return 0
        return UInt64(nth_narrow(self.arena, a.root, small.value()))

    def rank(self, a: BitSet, bits: UInt64) -> BigUInt:
        """How many members are below `bits`."""
        var value = UInt128(bits)
        if a.width < 64:
            value = value & ((UInt128(1) << UInt128(a.width)) - 1)
        return BigUInt(rank_narrow(self.arena, a.root, value, a.width))

    def members(self, a: BitSet, limit: Int) raises -> List[UInt64]:
        """Every member in increasing order; raises if there are more than `limit`."""
        var total = self.arena.count_narrow(a.root, a.width)
        if total > UInt128(limit):
            raise Error("the set has more than " + String(limit) + " members")
        var out = List[UInt64]()
        for i in range(Int(total)):
            out.append(UInt64(nth_narrow(self.arena, a.root, UInt128(i))))
        return out^


def _u64(value: BigInt) -> UInt64:
    return value.magnitude.uint64_or_none().value()
