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
    """A set of `width`-bit patterns, valid only with the `SetContext` that made it."""

    var width: Int32
    var root: Id

    def __eq__(self, other: Self) -> Bool:
        return self.width == other.width and self.root == other.root


def _check_width(width: Int) raises:
    if width < 1 or width > 64:
        raise Error(t"set widths are 1 to 64 bits, not {width}")


struct SetContext(Movable):
    """Owns the arena of its sets. Nothing is freed before the context is dropped."""

    var arena: Arena

    def __init__(out self):
        self.arena = Arena(never_pause, PauseStatePointer.unsafe_dangling())

    def empty(mut self, width: Int) -> BitSet:
        return BitSet(Int32(width), REJECT)

    def full(mut self, width: Int) -> BitSet:
        return BitSet(Int32(width), ACCEPT)

    def interval_inclusive(
        mut self, first: UInt64, last: UInt64, width: Int
    ) -> BitSet:
        """`[first, last]`, empty if `last < first`."""
        if last < first:
            return self.empty(width)
        try:
            return BitSet(
                Int32(width), interval[_bit](self.arena, first, last, Int32(width))
            )
        except:
            abort("interval interrupted")

    def interval(mut self, lo: UInt64, hi: UInt64, width: Int) -> BitSet:
        """`[lo, hi)`, empty if `hi <= lo`."""
        if hi <= lo:
            return self.empty(width)
        return self.interval_inclusive(lo, hi - 1, width)

    def exactly(mut self, var values: List[UInt64], width: Int) -> BitSet:
        sort(values)
        var distinct = [v for i, v in enumerate(values) if i == 0 or values[i - 1] != v]
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
        var modulus = BigInt(negative=False, magnitude=BigUInt(1) << width)
        var type_lo = BigInt()
        var type_hi = modulus.copy()
        if signed:
            var half = BigInt(negative=False, magnitude=BigUInt(1) << (width - 1))
            type_lo = -half
            type_hi = half^
        var low = type_lo.copy() if lo is None else max(lo.value().copy(), type_lo)
        var high = type_hi.copy() if hi is None else min(hi.value().copy(), type_hi)
        if low >= high:
            return self.empty(width)
        var last = high - BigInt(1)
        if low.negative and not last.negative:
            # straddles zero: the non-negatives, then the negatives from the top
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
        try:
            return BitSet(a.width, complement(self.arena, a.root))
        except:
            abort("complement interrupted")

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
        """The `n`-th member in increasing order (0 if `n` is not below `count(a)`)."""
        var small = n.uint128_or_none()
        if small is None or small.value() >= self.arena.count_narrow(a.root, a.width):
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
            raise Error(t"the set has more than {limit} members")
        return [UInt64(nth_narrow(self.arena, a.root, UInt128(i))) for i in range(Int(total))]


def _u64(value: BigInt) -> UInt64:
    return value.magnitude.uint64_or_none().value()
