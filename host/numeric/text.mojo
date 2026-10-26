"""Text of numbers, as reports print them.

`float_text` writes the shortest decimal that reads back to the same value in its own
format, in the style of Python's float `repr`; `real_text` prints a real exactly when
that is short and otherwise approximately.
"""

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.decimal import decimal_digits, floor_log10, pow10
from numeric.floats import is_inf, is_nan, is_zero, round_ratio, signbit
from numeric.formats import FloatFormat, format_by_id
from numeric.real import Real


def _pad(count: Int) -> String:
    var out = String()
    for _ in range(count):
        out += "0"
    return out


def _try_digits(
    format: FloatFormat, target: UInt64, an: BigUInt, ad: BigUInt, k: Int, digits: Int
) -> Optional[BigUInt]:
    """An integer of at most `digits + 1` digits, scaled by a power of ten, that rounds
    to `target` and is nearest to `an / ad` among those that do."""
    var scale = k - digits + 1
    var p = pow10(scale if scale >= 0 else -scale)
    var qn: BigUInt
    var qd: BigUInt
    if scale >= 0:
        qn = an.copy()
        qd = ad * p
    else:
        qn = an * p
        qd = ad.copy()
    var lo = qn // qd
    var r2 = (qn % qd) << 1
    var hi = lo.plus(1)
    var lo_first = r2 < qd or (r2 == qd and not lo.bit(0))
    for pass_ in range(2):
        var c = lo.copy() if (pass_ == 0) == lo_first else hi.copy()
        var back: UInt64
        if scale >= 0:
            back = round_ratio(format, False, c * p, BigUInt(UInt64(1)))
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
    var field = Int((target & format.exponent_mask()) >> UInt64(format.fraction_bits))
    var m = target & format.fraction_mask()
    var q = 1 - format.bias() - format.fraction_bits
    if field != 0:
        m |= UInt64(1) << UInt64(format.fraction_bits)
        q = field - format.bias() - format.fraction_bits
    var an = BigUInt(m)
    var ad = BigUInt(UInt64(1))
    if q >= 0:
        an = an << q
    else:
        ad = ad << (-q)
    var k = floor_log10(an, ad)
    # Whether n digits suffice is monotone in n, and 17 always do.
    var lo = 1
    var hi = 17
    while lo < hi:
        var mid = (lo + hi) // 2
        if _try_digits(format, target, an, ad, k, mid):
            hi = mid
        else:
            lo = mid + 1
    var c = _try_digits(format, target, an, ad, k, lo).value().copy()
    var scale = k - lo + 1
    var text = decimal_digits(c)
    var e = scale + text.byte_length() - 1
    var end = text.byte_length()
    while end > 1 and Int(text.as_bytes()[end - 1]) == ord("0"):
        end -= 1
    return (String(text[byte=0:end]), e)


def _render(digits: String, e: Int) -> String:
    if -4 <= e < 16:
        if e >= 0:
            var whole = String(digits[byte = 0 : min(e + 1, digits.byte_length())])
            whole += _pad(e + 1 - whole.byte_length())
            var frac = String(digits[byte = e + 1 :]) if digits.byte_length() > e + 1 else String("0")
            return whole + "." + frac
        return "0." + _pad(-e - 1) + digits
    var out = String(digits[byte=0:1])
    if digits.byte_length() > 1:
        out += "." + String(digits[byte=1:])
    out += "e-" if e < 0 else "e+"
    var mag = String(-e if e < 0 else e)
    if mag.byte_length() < 2:
        mag = "0" + mag
    return out + mag


def _hex(bits: UInt64, width: Int) -> String:
    comptime DIGITS = "0123456789abcdef"
    var out = String("0x")
    for k in range(width - 1, -1, -1):
        out += String(DIGITS[byte=Int((bits >> UInt64(4 * k)) & 15)])
    return out


def float_text(format_id: UInt8, bits: UInt64) raises -> String:
    var format = format_by_id(format_id)
    var negative = signbit(format, bits)
    if is_nan(format, bits):
        if bits == format.exponent_mask() | (UInt64(1) << UInt64(format.fraction_bits - 1)):
            return "nan"
        return "nan:" + _hex(bits, format.width() // 4)
    if is_inf(format, bits):
        return "-inf" if negative else "inf"
    if is_zero(format, bits):
        return "-0.0" if negative else "0.0"
    var shortest = shortest_digits(format, bits)
    return ("-" if negative else "") + _render(shortest[0], shortest[1])


def _exact_decimal(a: Real, limit: Int) -> Optional[String]:
    """The terminating decimal of a positive finite real, if it has at most `limit`
    integer-and-fraction digits."""
    var d = a.denominator.magnitude.copy()
    var twos = 0
    var five = BigUInt(UInt64(5))
    while not d.bit(0):
        d = d >> 1
        twos += 1
    var fives = 0
    while d % five == BigUInt():
        d = d // five
        fives += 1
    var places = twos if twos > fives else fives
    if d != BigUInt(UInt64(1)) or places > limit:
        return None
    var scaled = a.numerator.magnitude * pow10(places) // a.denominator.magnitude
    if scaled >= pow10(limit):
        return None
    var text = decimal_digits(scaled)
    if places == 0:
        return text
    if text.byte_length() < places + 1:
        text = _pad(places + 1 - text.byte_length()) + text
    var cut = text.byte_length() - places
    var frac = String(text[byte=cut:])
    var end = frac.byte_length()
    while end > 0 and Int(frac.as_bytes()[end - 1]) == ord("0"):
        end -= 1
    return String(text[byte=0:cut]) + "." + String(frac[byte=0:end])


def _approximate(a: Real, digits: Int) -> String:
    var n = a.numerator.magnitude.copy()
    var d = a.denominator.magnitude.copy()
    var k = floor_log10(n, d)
    var shift = k - digits + 1
    if shift >= 0:
        d = d * pow10(shift)
    else:
        n = n * pow10(-shift)
    var rounded = n // d
    var twice = (n % d) << 1
    if d < twice or (twice == d and rounded.bit(0)):
        rounded = rounded.plus(1)
    if rounded >= pow10(digits):
        rounded = rounded // BigUInt(UInt64(10))
        k += 1
    var text = decimal_digits(rounded)
    if -5 <= k < digits:
        if k >= 0:
            var out = String(text[byte=0 : k + 1]) + "." + String(text[byte = k + 1 :])
            var end = out.byte_length()
            while Int(out.as_bytes()[end - 1]) == ord("0"):
                end -= 1
            if Int(out.as_bytes()[end - 1]) == ord("."):
                end -= 1
            return String(out[byte=0:end])
        var end = text.byte_length()
        while end > 1 and Int(text.as_bytes()[end - 1]) == ord("0"):
            end -= 1
        return "0." + _pad(-k - 1) + String(text[byte=0:end])
    var end = text.byte_length()
    while end > 1 and Int(text.as_bytes()[end - 1]) == ord("0"):
        end -= 1
    var frac = String(text[byte=1:end]) if end > 1 else String("0")
    return String(text[byte=0:1]) + "." + frac + "e" + ("-" if k < 0 else "+") + String(-k if k < 0 else k)


def real_text(r: Real) -> String:
    """Integers and terminating decimals of at most 25 digits print exactly; other
    values print as `~` and 20 significant digits. Infinities print as `inf` and
    `-inf`."""
    if r.is_inf():
        return "-inf" if r.numerator.negative else "inf"
    if r.is_zero():
        return "0"
    var sign = "-" if r.numerator.negative else ""
    var a = abs(r)
    var exact = _exact_decimal(a, 25)
    if exact:
        return sign + exact.value()
    return "~" + sign + _approximate(a, 20)
