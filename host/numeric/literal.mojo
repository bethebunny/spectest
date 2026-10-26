"""Numeric literals, read exactly.

Decimal integers, decimals and exponents (`1.5`, `1e-3`, `2.5E+10`), hex integers
(`0xff`) and hex floats (`0x1p-26`, `0x1.8p3`); a single `_` may separate two digits.
"""

from bigint import BigUInt

from numeric.decimal import pow10
from numeric.real import Real


comptime _MAX_EXPONENT = 1_000_000
"""Larger exponents are refused: the exact value would not fit in memory."""


def _digit_value(c: Int, hex: Bool) -> Int:
    if ord("0") <= c <= ord("9"):
        return c - ord("0")
    if hex and ord("a") <= c <= ord("f"):
        return c - ord("a") + 10
    if hex and ord("A") <= c <= ord("F"):
        return c - ord("A") + 10
    return -1


def _scan_digits(
    bytes: Span[Byte, _], start: Int, hex: Bool, mut out: List[Int]
) -> Int:
    """Digits with single underscores between them, appended to `out`. Returns the
    index after them, or `start` when there is no digit there."""
    var i = start
    var n = len(bytes)
    if i >= n or _digit_value(Int(bytes[i]), hex) < 0:
        return start
    while i < n:
        var d = _digit_value(Int(bytes[i]), hex)
        if d >= 0:
            out.append(d)
            i += 1
        elif (
            Int(bytes[i]) == ord("_")
            and i + 1 < n
            and _digit_value(Int(bytes[i + 1]), hex) >= 0
        ):
            i += 1
        else:
            break
    return i


def _to_big(digits: List[Int], base: Int) -> BigUInt:
    var chunk = 19 if base == 10 else 15
    var result = BigUInt()
    var i = 0
    while i < len(digits):
        var stop = i + chunk
        if stop > len(digits):
            stop = len(digits)
        var value = UInt64(0)
        for k in range(i, stop):
            value = value * UInt64(base) + UInt64(digits[k])
        if base == 10:
            result = result * pow10(stop - i) + BigUInt(value)
        else:
            result = (result << (4 * (stop - i))) + BigUInt(value)
        i = stop
    return result^


def _exponent(bytes: Span[Byte, _], start: Int, text: StringSlice) raises -> Tuple[Int, Int]:
    """An optionally signed run of decimal digits at `start`; returns (value, end)."""
    var i = start
    var negative = False
    if i < len(bytes) and (Int(bytes[i]) == ord("+") or Int(bytes[i]) == ord("-")):
        negative = Int(bytes[i]) == ord("-")
        i += 1
    var begin = i
    var value = 0
    while i < len(bytes) and ord("0") <= Int(bytes[i]) <= ord("9"):
        value = value * 10 + (Int(bytes[i]) - ord("0"))
        if value > _MAX_EXPONENT:
            raise Error("exponent out of range: " + String(text))
        i += 1
    if i == begin:
        raise Error("not a number: " + String(text))
    return (-value if negative else value, i)


def _is_hex(bytes: Span[Byte, _]) -> Bool:
    return (
        len(bytes) >= 2
        and Int(bytes[0]) == ord("0")
        and (Int(bytes[1]) == ord("x") or Int(bytes[1]) == ord("X"))
    )


def is_integer_literal(text: StringSlice) -> Bool:
    """Is the text written as an integer: no fraction point and no exponent?"""
    var bytes = text.as_bytes()
    var hex = _is_hex(bytes)
    for i in range(2 if hex else 0, len(bytes)):
        var c = Int(bytes[i])
        if c == ord("."):
            return False
        if hex and (c == ord("p") or c == ord("P")):
            return False
        if not hex and (c == ord("e") or c == ord("E")):
            return False
    return True


def parse_number(text: StringSlice) raises -> Real:
    """The exact value of a numeric literal; raises on malformed text."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    var hex = _is_hex(bytes)
    var base = 16 if hex else 10
    var i = 2 if hex else 0
    var digits = List[Int]()
    var end = _scan_digits(bytes, i, hex, digits)
    if end == i:
        raise Error("not a number: " + String(text))
    i = end
    var fraction_digits = 0
    if i < n and Int(bytes[i]) == ord("."):
        var before = len(digits)
        end = _scan_digits(bytes, i + 1, hex, digits)
        if end == i + 1 and not hex:
            raise Error("not a number: " + String(text))
        fraction_digits = len(digits) - before
        i = end
    var exponent = 0
    if i < n and (
        (hex and (Int(bytes[i]) == ord("p") or Int(bytes[i]) == ord("P")))
        or (not hex and (Int(bytes[i]) == ord("e") or Int(bytes[i]) == ord("E")))
    ):
        var parsed = _exponent(bytes, i + 1, text)
        exponent = parsed[0]
        i = parsed[1]
    if i != n:
        raise Error("not a number: " + String(text))
    var value = _to_big(digits, base)
    var one = BigUInt(UInt64(1))
    if hex:
        var shift = exponent - 4 * fraction_digits
        if shift >= 0:
            return Real.ratio(False, value << shift, one^)
        return Real.ratio(False, value^, one << (-shift))
    var scale = exponent - fraction_digits
    if scale >= 0:
        return Real.ratio(False, value * pow10(scale), one^)
    return Real.ratio(False, value^, pow10(-scale))
