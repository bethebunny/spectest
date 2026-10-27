"""Exact conversions between bit patterns and reals, and IEEE 754 neighbours.

A pattern is a `UInt64` holding the format's bits, zero-extended.
"""

from bigint import BigUInt

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


def to_real(format: FloatFormat, bits: UInt64) raises -> Real:
    """The exact value; infinities map to the infinite reals."""
    if is_nan(format, bits):
        raise Error("promoting a NaN")
    var negative = signbit(format, bits)
    if is_inf(format, bits):
        return Real.infinity(negative)
    var m, q = significand_and_exponent(format, bits)
    return Real.dyadic(negative, BigUInt(m), q)


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
    var num = n << -q if q < 0 else n.copy()
    var den = d << q if q >= 0 else d.copy()
    return _encode(format, negative, rounded_quotient(num, den).limb(0), q)


def round_to(format: FloatFormat, r: Real) -> UInt64:
    """Rounds an extended real (see `round_ratio`); a zero result keeps the sign of `r`."""
    if r.is_inf():
        return format.exponent_mask() | (format.sign_mask() if r.numerator.negative else UInt64(0))
    return round_ratio(format, r.numerator.negative, r.numerator.magnitude, r.denominator.magnitude)


def exactly(format: FloatFormat, r: Real) -> Optional[UInt64]:
    """The pattern holding exactly `r`, if any (+0 for 0)."""
    if r.is_zero():
        return UInt64(0)
    var bits = round_to(format, r)
    try:
        return bits if to_real(format, bits) == r else None
    except:
        return None  # unreachable: rounding never gives a NaN


def converted(source: FloatFormat, target: FloatFormat, bits: UInt64) raises -> Optional[UInt64]:
    """The pattern in `target` of the value of `bits` in `source`, if `target` holds it
    exactly. A zero keeps its sign. Raises on a NaN."""
    if is_zero(source, bits):
        return target.sign_mask() if signbit(source, bits) else UInt64(0)
    return exactly(target, to_real(source, bits))


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
