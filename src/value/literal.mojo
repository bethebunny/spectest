"""Numeric literals, read exactly.

Decimal integers, decimals and exponents (`1.5`, `1e-3`, `2.5E+10`), hex integers
(`0xff`) and hex floats (`0x1p-26`, `0x1.8p3`); a single `_` may separate two digits.
"""

from value.biguint import pow10
from value.digits import digit_value, magnitude_of_digits
from value.real import Real


comptime _MAX_EXPONENT = 1_000_000
"""Larger exponents are refused: the exact value would not fit in memory."""


def _is_letter(bytes: Span[Byte, _], i: Int, letter: String) -> Bool:
    """Is `bytes[i]` the ASCII `letter`, in either case?"""
    return i < len(bytes) and Int(bytes[i]) | 0x20 == ord(letter)


def _is_hex(bytes: Span[Byte, _]) -> Bool:
    return len(bytes) >= 2 and Int(bytes[0]) == ord("0") and _is_letter(bytes, 1, "x")


def _scan_digits(bytes: Span[Byte, _], start: Int, *, hex: Bool, mut digits: List[Int]) -> Int:
    """Appends digits with single underscores between them to `digits`. Returns the
    index after them, or `start` when there is no digit there."""
    var i = start
    while i < len(bytes):
        var digit = digit_value(Int(bytes[i]), hex=hex)
        var separator = i > start and Int(bytes[i]) == ord("_") and i + 1 < len(bytes)
        if digit >= 0:
            digits.append(digit)
        elif not (separator and digit_value(Int(bytes[i + 1]), hex=hex) >= 0):
            break
        i += 1
    return i


def _exponent(bytes: Span[Byte, _], start: Int, text: StringSlice) raises -> Tuple[Int, Int]:
    """An optionally signed run of decimal digits at `start`; returns (value, end)."""
    var negative = start < len(bytes) and Int(bytes[start]) == ord("-")
    var signed = negative or (start < len(bytes) and Int(bytes[start]) == ord("+"))
    var begin = start + Int(signed)
    var i = begin
    var value = 0
    while i < len(bytes) and ord("0") <= Int(bytes[i]) <= ord("9"):
        value = value * 10 + Int(bytes[i]) - ord("0")
        if value > _MAX_EXPONENT:
            raise Error(t"exponent out of range: {text}")
        i += 1
    if i == begin:
        raise Error(t"not a number: {text}")
    return (-value if negative else value, i)


def is_integer_literal(text: StringSlice) -> Bool:
    """Is the text written as an integer: no fraction point and no exponent?"""
    var bytes = text.as_bytes()
    var hex = _is_hex(bytes)
    var exponent = ord("p") if hex else ord("e")
    var rest = bytes[2:] if hex else bytes
    return not any([Int(c) == ord(".") or Int(c) | 0x20 == exponent for c in rest])


def parse_number(text: StringSlice) raises -> Real:
    """The exact value of a numeric literal; raises on malformed text."""
    var bytes = text.as_bytes()
    var hex = _is_hex(bytes)
    var start = 2 if hex else 0
    var digits: List[Int] = []
    var i = _scan_digits(bytes, start, hex=hex, digits=digits)
    if i == start:
        raise Error(t"not a number: {text}")
    var fraction_digits = 0
    if i < len(bytes) and Int(bytes[i]) == ord("."):
        var whole_digits = len(digits)
        var end = _scan_digits(bytes, i + 1, hex=hex, digits=digits)
        if end == i + 1 and not hex:
            raise Error(t"not a number: {text}")
        fraction_digits = len(digits) - whole_digits
        i = end
    var exponent = 0
    if _is_letter(bytes, i, "p" if hex else "e"):
        exponent, i = _exponent(bytes, i + 1, text)
    if i != len(bytes):
        raise Error(t"not a number: {text}")
    var value = magnitude_of_digits(digits, base=16 if hex else 10)
    if hex:
        return Real.dyadic(False, value, exponent - 4 * fraction_digits)
    var scale = exponent - fraction_digits
    return Real.ratio(False, value * pow10(max(scale, 0)), pow10(max(-scale, 0)))
