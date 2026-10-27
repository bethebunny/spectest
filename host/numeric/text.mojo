"""Text of numbers, as reports print them.

`float_text` writes the shortest decimal that reads back to the same value in its own
format, in the style of Python's float `repr`. `exact_decimal` and `approximate_decimal`
print reals.
"""

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.decimal import floor_log10, pow10, rounded_quotient
from numeric.digits import hex_digits
from numeric.floats import (
    is_inf,
    is_nan,
    is_zero,
    ratio_of_power_of_two,
    round_ratio,
    signbit,
    significand_and_exponent,
)
from numeric.formats import FloatFormat, format_by_id
from numeric.real import Real


def _digits(value: BigUInt) -> String:
    return String(BigInt(negative=False, magnitude=value.copy()))


def _decimal(whole: StringSlice, fraction: StringSlice) -> String:
    return String(whole, ".", fraction) if fraction.byte_length() > 0 else String(whole)


def _try_digits(
    format: FloatFormat, target: UInt64, an: BigUInt, ad: BigUInt, k: Int, digits: Int
) -> Optional[BigUInt]:
    """An integer of at most `digits + 1` digits, scaled by a power of ten, that rounds
    to `target` and is nearest to `an / ad` among those that do."""
    var scale = k - digits + 1
    var p = pow10(abs(scale))
    var qn = an.copy() if scale >= 0 else an * p
    var qd = ad * p if scale >= 0 else ad.copy()
    var lo = qn // qd
    var r2 = (qn % qd) << 1
    var hi = lo.plus(1)
    var lo_first = r2 < qd or (r2 == qd and not lo.bit(0))
    for pass_ in range(2):
        var c = lo.copy() if (pass_ == 0) == lo_first else hi.copy()
        var one = BigUInt(UInt64(1))
        var back: UInt64
        if scale >= 0:
            back = round_ratio(format, False, c * p, one)
        else:
            back = round_ratio(format, False, c, p)
        if back == target:
            return c^
    return None


def shortest_digits(format: FloatFormat, bits: UInt64) -> Tuple[String, Int]:
    """The shortest decimal that rounds back to the (finite, nonzero) value in its
    format, nearest to the value among the shortest. Returns (digits, e): the value
    of |x| reads d[0].d[1:] x 10**e, and digits has no trailing zeros."""
    var target = bits & ~format.sign_mask()
    var parts = significand_and_exponent(format, target)
    var ratio = ratio_of_power_of_two(parts[0], parts[1])
    var an = ratio[0].copy()
    var ad = ratio[1].copy()
    var k = floor_log10(an, ad)
    # Whether n digits suffice is monotone in n, and 17 always do.
    var lo = 1
    var hi = 17
    while lo < hi:
        var mid = (lo + hi) // 2
        if _try_digits(format, target, an, ad, k, mid) is not None:
            hi = mid
        else:
            lo = mid + 1
    var text = _digits(_try_digits(format, target, an, ad, k, lo).value())
    return (String(text.rstrip("0")), k - lo + 1 + text.byte_length() - 1)


def _render(digits: String, e: Int) -> String:
    if -4 <= e < 16:
        if e < 0:
            return String("0.", "0" * (-e - 1), digits)
        var split = min(e + 1, digits.byte_length())
        var whole = digits[byte=:split]
        var fraction = digits[byte=split:]
        var padding = "0" * (e + 1 - whole.byte_length())
        return String(whole, padding, ".", String(fraction) if fraction.byte_length() > 0 else "0")
    var exponent = String(abs(e))
    var fraction = digits[byte=1:]
    return String(
        digits[byte=:1],
        "." if fraction.byte_length() > 0 else "",
        fraction,
        "e-" if e < 0 else "e+",
        "0" * (2 - exponent.byte_length()),
        exponent,
    )


def float_text(format_id: UInt8, bits: UInt64) raises -> String:
    var format = format_by_id(format_id)
    var negative = signbit(format, bits)
    if is_nan(format, bits):
        var quiet = format.exponent_mask() | UInt64(1) << UInt64(format.fraction_bits - 1)
        if bits == quiet:
            return "nan"
        return String("nan:0x", hex_digits(bits, width=format.width() // 4))
    if is_inf(format, bits):
        return "-inf" if negative else "inf"
    if is_zero(format, bits):
        return "-0.0" if negative else "0.0"
    var shortest = shortest_digits(format, bits)
    return String("-" if negative else "", _render(shortest[0], shortest[1]))


def exact_decimal(a: Real, *, limit: Int) -> Optional[String]:
    """The terminating decimal of a positive finite real, if it has at most `limit`
    integer-and-fraction digits."""
    var rest = a.denominator.magnitude.copy()
    var twos = 0
    while not rest.bit(0):
        rest = rest >> 1
        twos += 1
    var fives = 0
    var five = BigUInt(UInt64(5))
    while rest % five == BigUInt():
        rest = rest // five
        fives += 1
    var places = max(twos, fives)
    if rest != BigUInt(UInt64(1)) or places > limit:
        return None
    var scaled = a.numerator.magnitude * pow10(places) // a.denominator.magnitude
    if scaled >= pow10(limit):
        return None
    var digits = _digits(scaled)
    digits = "0" * (places + 1 - digits.byte_length()) + digits
    var cut = digits.byte_length() - places
    return _decimal(digits[byte=:cut], digits[byte=cut:].rstrip("0"))


def approximate_decimal(a: Real, *, digits: Int) -> String:
    """`digits` significant digits of a positive finite real, rounded to nearest."""
    var n = a.numerator.magnitude.copy()
    var d = a.denominator.magnitude.copy()
    var k = floor_log10(n, d)
    var shift = k - digits + 1
    if shift >= 0:
        d = d * pow10(shift)
    else:
        n = n * pow10(-shift)
    var rounded = rounded_quotient(n, d)
    if rounded >= pow10(digits):
        rounded = rounded // BigUInt(UInt64(10))
        k += 1
    var text = _digits(rounded)
    if -5 <= k < digits:
        if k >= 0:
            return _decimal(text[byte=: k + 1], text[byte = k + 1 :].rstrip("0"))
        return String("0.", "0" * (-k - 1), text.rstrip("0"))
    var fraction = text[byte=1:].rstrip("0")
    var mantissa_fraction = String(fraction) if fraction.byte_length() > 0 else "0"
    return String(text[byte=:1], ".", mantissa_fraction, "e", "-" if k < 0 else "+", abs(k))
