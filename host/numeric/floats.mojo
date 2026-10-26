"""Exact conversions between bit patterns and reals, and IEEE 754 neighbours.

A pattern is a `UInt64` holding the format's bits, zero-extended.
"""

from std.bit import count_trailing_zeros

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.formats import FloatFormat
from numeric.real import Real


# Classification


def is_nan(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.exponent_mask()) == format.exponent_mask() and (
        bits & format.fraction_mask()
    ) != 0


def is_inf(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.exponent_mask()) == format.exponent_mask() and (
        bits & format.fraction_mask()
    ) == 0


def is_zero(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & ~format.sign_mask()) == 0


def is_subnormal(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.exponent_mask()) == 0 and (bits & format.fraction_mask()) != 0


def is_normal(format: FloatFormat, bits: UInt64) -> Bool:
    var e = bits & format.exponent_mask()
    return e != 0 and e != format.exponent_mask()


def is_finite(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.exponent_mask()) != format.exponent_mask()


def signbit(format: FloatFormat, bits: UInt64) -> Bool:
    return (bits & format.sign_mask()) != 0


# Pattern to real


def to_real(format: FloatFormat, bits: UInt64) raises -> Real:
    """The exact value; infinities map to the infinite reals."""
    if is_nan(format, bits):
        raise Error("promoting a NaN")
    var negative = signbit(format, bits)
    if is_inf(format, bits):
        return Real.infinity(negative)
    var fraction = bits & format.fraction_mask()
    var field = Int((bits & format.exponent_mask()) >> UInt64(format.fraction_bits))
    var m: UInt64
    var q: Int
    if field == 0:
        m = fraction
        q = 1 - format.bias() - format.fraction_bits
    else:
        m = fraction | (UInt64(1) << UInt64(format.fraction_bits))
        q = field - format.bias() - format.fraction_bits
    if m == 0:
        return Real()
    # Make m odd, so the ratio is in lowest terms.
    var tz = Int(count_trailing_zeros(m))
    m >>= UInt64(tz)
    q += tz
    var numerator = BigUInt(m)
    var denominator = BigUInt(UInt64(1))
    if q >= 0:
        numerator = numerator << q
    else:
        denominator = denominator << (-q)
    return Real(
        lowest_numerator=BigInt(negative=negative, magnitude=numerator^),
        lowest_denominator=BigInt(negative=False, magnitude=denominator^),
    )


# Real to pattern


def _floor_log2(n: BigUInt, d: BigUInt) -> Int:
    """`floor(log2(n / d))` for positive n and d."""
    var e = n.bits() - d.bits()
    var ge: Bool
    if e >= 0:
        ge = d << e <= n
    else:
        ge = d <= n << (-e)
    return e if ge else e - 1


def _encode(format: FloatFormat, negative: Bool, m_in: UInt64, q_in: Int) -> UInt64:
    """The pattern of `±m * 2**q`, where m fits the significand at quantum q."""
    var sign_bits = format.sign_mask() if negative else UInt64(0)
    var m = m_in
    var q = q_in
    if m == 0:
        return sign_bits
    if (m >> UInt64(format.fraction_bits + 1)) != 0:
        m >>= 1
        q += 1
    if (m >> UInt64(format.fraction_bits)) != 0:
        var exp = q + format.fraction_bits + format.bias()
        if exp >= (1 << format.exponent_bits) - 1:
            return sign_bits | format.exponent_mask()
        return sign_bits | (UInt64(exp) << UInt64(format.fraction_bits)) | (
            m & format.fraction_mask()
        )
    return sign_bits | m


def round_ratio(
    format: FloatFormat, negative: Bool, n: BigUInt, d: BigUInt
) -> UInt64:
    """Round `±n / d` (d positive; need not be in lowest terms) to the format:
    nearest, ties to even, overflow to the infinity, gradual underflow. A zero
    result takes the sign."""
    if not n:
        return format.sign_mask() if negative else UInt64(0)
    var emin = 1 - format.bias()
    var e = _floor_log2(n, d)
    var q = (e if e > emin else emin) - format.fraction_bits
    var num = n.copy()
    var den = d.copy()
    if q >= 0:
        den = den << q
    else:
        num = num << (-q)
    var quotient = num // den
    var twice = (num % den) << 1
    if den < twice or (twice == den and quotient.bit(0)):
        quotient = quotient.plus(1)
    return _encode(format, negative, quotient.limb(0), q)


def round_to(format: FloatFormat, r: Real) -> UInt64:
    """Correct rounding of an extended real: half to even, overflow to the signed
    infinity, gradual underflow, a zero result keeping the sign of `r` (+0 for 0)."""
    if r.is_inf():
        return format.exponent_mask() | (
            format.sign_mask() if r.numerator.negative else UInt64(0)
        )
    return round_ratio(
        format,
        r.numerator.negative,
        r.numerator.magnitude,
        r.denominator.magnitude,
    )


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
