"""Text of numbers, as reports print them.

`float_text` writes the shortest decimal that reads back to the same value in its own
format, in the style of Python's float `repr`. `exact_decimal` and `approximate_decimal`
print reals.
"""

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.decimal import floor_log10, pow10, rounded_quotient, trailing_zeros
from numeric.digits import hex_digits
from numeric.floats import is_inf, is_nan, is_zero, round_ratio, signbit, significand_and_exponent
from numeric.formats import FloatFormat, format_by_id
from numeric.real import Real


def _digits(value: BigUInt) -> String:
    return String(BigInt(negative=False, magnitude=value.copy()))


def _decimal(whole: StringSlice, fraction: StringSlice) -> String:
    return String(whole, ".", fraction) if fraction else String(whole)


def _try_digits(
    format: FloatFormat, target: UInt64, value: Real, *, k: Int, digits: Int
) -> Optional[BigUInt]:
    """An integer of at most `digits + 1` digits, scaled by a power of ten, that rounds
    to `target` and is nearest to `value` among those that do. `k` is floor(log10(value))."""
    var scale = k - digits + 1
    # A candidate c stands for c * 10**scale, which is c * up / down.
    var up = pow10(max(scale, 0))
    var down = pow10(max(-scale, 0))
    var n = value.numerator.magnitude * down
    var d = value.denominator.magnitude * up
    var below = n // d
    var twice_rest = (n % d) << 1
    var nearer_below = twice_rest < d or (twice_rest == d and not below.bit(0))
    var above = below.plus(1)
    var candidates: List[BigUInt] = [below^, above^]
    if not nearer_below:
        candidates.reverse()
    for c in candidates:
        if round_ratio(format, False, c * up, down) == target:
            return c.copy()
    return None


def shortest_digits(format: FloatFormat, bits: UInt64) -> Tuple[String, Int]:
    """The shortest decimal that rounds back to the (finite, nonzero) value in its
    format, nearest to the value among the shortest. Returns (digits, e): the value
    of |x| reads d[0].d[1:] x 10**e, and digits has no trailing zeros."""
    var target = bits & ~format.sign_mask()
    var m, q = significand_and_exponent(format, target)
    var value = Real.dyadic(False, BigUInt(m), q)
    var k = floor_log10(value.numerator.magnitude, value.denominator.magnitude)
    # Whether n digits suffice is monotone in n, and 17 always do.
    var lo = 1
    var hi = 17
    while lo < hi:
        var mid = (lo + hi) // 2
        if _try_digits(format, target, value, k=k, digits=mid) is not None:
            hi = mid
        else:
            lo = mid + 1
    var text = _digits(_try_digits(format, target, value, k=k, digits=lo).value())
    return (String(text.rstrip("0")), k - lo + 1 + text.byte_length() - 1)


def _render(digits: String, e: Int) -> String:
    if -4 <= e < 16:
        if e < 0:
            return String("0.", "0" * (-e - 1), digits)
        var split = min(e + 1, digits.byte_length())
        var fraction = digits[byte=split:]
        var whole = String(digits[byte=:split]).ascii_ljust(e + 1, "0")
        return String(whole, ".", String(fraction) if fraction else "0")
    var exponent = String(abs(e)).ascii_rjust(2, "0")
    var fraction = digits[byte=1:]
    return String(digits[byte=:1], "." if fraction else "", fraction, "e-" if e < 0 else "e+", exponent)


def float_text(format_id: UInt8, bits: UInt64) raises -> String:
    var format = format_by_id(format_id)
    var negative = signbit(format, bits)
    if is_nan(format, bits):
        if bits == format.quiet_nan():
            return "nan"
        return String("nan:0x", hex_digits(bits, width=format.width() // 4))
    if is_inf(format, bits):
        return "-inf" if negative else "inf"
    if is_zero(format, bits):
        return "-0.0" if negative else "0.0"
    var digits, e = shortest_digits(format, bits)
    return String("-" if negative else "", _render(digits, e))


def exact_decimal(a: Real, *, limit: Int) -> Optional[String]:
    """The terminating decimal of a positive finite real, if it has at most `limit`
    integer-and-fraction digits."""
    var twos = trailing_zeros(a.denominator.magnitude)
    var rest = a.denominator.magnitude >> twos
    var fives = 0
    while not rest % 5:
        rest = rest // 5
        fives += 1
    var places = max(twos, fives)
    if rest != 1 or places > limit:
        return None
    var scaled = a.numerator.magnitude * pow10(places) // a.denominator.magnitude
    if scaled >= pow10(limit):
        return None
    var digits = _digits(scaled).ascii_rjust(places + 1, "0")
    var cut = digits.byte_length() - places
    return _decimal(digits[byte=:cut], digits[byte=cut:].rstrip("0"))


def approximate_decimal(a: Real, *, digits: Int) -> String:
    """`digits` significant digits of a positive finite real, rounded to nearest."""
    var k = floor_log10(a.numerator.magnitude, a.denominator.magnitude)
    var shift = k - digits + 1
    var rounded = rounded_quotient(
        a.numerator.magnitude * pow10(max(-shift, 0)), a.denominator.magnitude * pow10(max(shift, 0))
    )
    if rounded >= pow10(digits):
        rounded = rounded // 10
        k += 1
    var text = _digits(rounded)
    if -5 <= k < digits:
        if k >= 0:
            return _decimal(text[byte=: k + 1], text[byte = k + 1 :].rstrip("0"))
        return String("0.", "0" * (-k - 1), text.rstrip("0"))
    var fraction = text[byte=1:].rstrip("0")
    var mantissa_fraction = String(fraction) if fraction else "0"
    return String(text[byte=:1], ".", mantissa_fraction, "e", "-" if k < 0 else "+", abs(k))
