"""Exact conversions between bit patterns and reals, and IEEE 754 neighbours.

A pattern is a `UInt64` holding the format's bits, zero-extended.
"""

from std.bit import count_trailing_zeros

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.decimal import rounded_quotient
from numeric.formats import FloatFormat
from numeric.real import Real


def is_nan(format: FloatFormat, bits: UInt64) -> Bool:
    return not is_finite(format, bits) and (bits & format.fraction_mask()) != 0


def is_inf(format: FloatFormat, bits: UInt64) -> Bool:
    return not is_finite(format, bits) and (bits & format.fraction_mask()) == 0


def is_zero(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & ~format.sign_mask()) == 0


def is_subnormal(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.exponent_mask()) == 0 and (bits & format.fraction_mask()) != 0


def is_normal(format: FloatFormat, bits: UInt64) -> Bool:
    var exponent = bits & format.exponent_mask()
    return exponent != 0 and exponent != format.exponent_mask()


def is_finite(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.exponent_mask()) != format.exponent_mask()


def signbit(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.sign_mask()) != 0


def significand_and_exponent(format: FloatFormat, bits: UInt64) -> Tuple[UInt64, Int]:
    """(m, q) with |x| = m * 2**q, for a finite pattern."""
    var field = Int((bits & format.exponent_mask()) >> UInt64(format.fraction_bits))
    var fraction = bits & format.fraction_mask()
    var q = max(field, 1) - format.bias() - format.fraction_bits
    return (fraction | UInt64(1) << UInt64(format.fraction_bits) if field != 0 else fraction, q)


def ratio_of_power_of_two(m: UInt64, q: Int) -> Tuple[BigUInt, BigUInt]:
    """`m * 2**q` as (numerator, denominator)."""
    if q >= 0:
        return (BigUInt(m) << q, BigUInt(UInt64(1)))
    return (BigUInt(m), BigUInt(UInt64(1)) << -q)


def to_real(format: FloatFormat, bits: UInt64) raises -> Real:
    """The exact value; infinities map to the infinite reals."""
    if is_nan(format, bits):
        raise Error("promoting a NaN")
    var negative = signbit(format, bits)
    if is_inf(format, bits):
        return Real.infinity(negative)
    var parts = significand_and_exponent(format, bits)
    if parts[0] == 0:
        return Real()
    # An odd significand puts the ratio in lowest terms.
    var trailing_zeros = Int(count_trailing_zeros(parts[0]))
    var ratio = ratio_of_power_of_two(parts[0] >> UInt64(trailing_zeros), parts[1] + trailing_zeros)
    return Real(
        lowest_numerator=BigInt(negative=negative, magnitude=ratio[0].copy()),
        lowest_denominator=BigInt(negative=False, magnitude=ratio[1].copy()),
    )


# Real to pattern


def _floor_log2(n: BigUInt, d: BigUInt) -> Int:
    """`floor(log2(n / d))` for positive n and d."""
    var e = n.bits() - d.bits()
    var at_least = d << e <= n if e >= 0 else d <= n << -e
    return e if at_least else e - 1


def _encode(format: FloatFormat, negative: Bool, var m: UInt64, var q: Int) -> UInt64:
    """The pattern of `±m * 2**q`, where m fits the significand at quantum q."""
    var sign_bits = format.sign_mask() if negative else UInt64(0)
    if m == 0:
        return sign_bits
    if (m >> UInt64(format.fraction_bits + 1)) != 0:
        m >>= 1
        q += 1
    if (m >> UInt64(format.fraction_bits)) == 0:
        return sign_bits | m
    var exponent = q + format.fraction_bits + format.bias()
    if exponent >= (1 << format.exponent_bits) - 1:
        return sign_bits | format.exponent_mask()
    return sign_bits | UInt64(exponent) << UInt64(format.fraction_bits) | m & format.fraction_mask()


def round_ratio(format: FloatFormat, negative: Bool, n: BigUInt, d: BigUInt) -> UInt64:
    """Rounds `±n / d` (d positive) to nearest, ties to even, overflowing to the
    infinity and underflowing gradually. A zero result keeps the sign."""
    if not n:
        return format.sign_mask() if negative else UInt64(0)
    var e = _floor_log2(n, d)
    var q = max(e, 1 - format.bias()) - format.fraction_bits
    var num = n.copy() << -q if q < 0 else n.copy()
    var den = d.copy() << q if q >= 0 else d.copy()
    return _encode(format, negative, rounded_quotient(num, den).limb(0), q)


def round_to(format: FloatFormat, r: Real) -> UInt64:
    """Rounds an extended real (see `round_ratio`); a zero result keeps the sign of `r`."""
    if r.is_inf():
        return format.exponent_mask() | (format.sign_mask() if r.numerator.negative else UInt64(0))
    return round_ratio(format, r.numerator.negative, r.numerator.magnitude, r.denominator.magnitude)


def exactly(format: FloatFormat, r: Real) -> Optional[UInt64]:
    """The pattern holding exactly `r`, if any (+0 for 0)."""
    var bits = round_to(format, r)
    if r.is_zero():
        return UInt64(0)
    try:
        if to_real(format, bits) == r:
            return bits
    except:
        pass
    return None


def next_up(format: FloatFormat, bits: UInt64) -> UInt64:
    """IEEE nextUp. A NaN and +inf are returned unchanged."""
    if is_nan(format, bits) or bits == format.exponent_mask():
        return bits
    if is_zero(format, bits):
        return 1
    return bits - 1 if signbit(format, bits) else bits + 1


def next_down(format: FloatFormat, bits: UInt64) -> UInt64:
    """IEEE nextDown. A NaN and -inf are returned unchanged."""
    if is_nan(format, bits):
        return bits
    return next_up(format, bits ^ format.sign_mask()) ^ format.sign_mask()
