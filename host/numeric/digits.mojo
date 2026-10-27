"""Digits of integers: reading runs of them into a `BigUInt` and writing hex."""

from bigint import BigUInt

from numeric.decimal import pow10


def digit_value(c: Int, *, hex: Bool) -> Int:
    """The value of the ASCII digit `c` (hex digits only when `hex`), or -1."""
    if ord("0") <= c <= ord("9"):
        return c - ord("0")
    if hex and ord("a") <= c <= ord("f"):
        return c - ord("a") + 10
    if hex and ord("A") <= c <= ord("F"):
        return c - ord("A") + 10
    return -1


def magnitude_of_digits(digits: List[Int], *, base: Int) -> BigUInt:
    """Base 10 or 16, in chunks that fit a `UInt64` to keep big-number operations few."""
    var chunk = 19 if base == 10 else 15
    var result = BigUInt()
    for start in range(0, len(digits), chunk):
        var group = digits[start : min(start + chunk, len(digits))]
        var value = UInt64(0)
        for digit in group:
            value = value * UInt64(base) + UInt64(digit)
        if base == 10:
            result = result * pow10(len(group)) + BigUInt(value)
        else:
            result = (result << (4 * len(group))) + BigUInt(value)
    return result^


def hex_digits(value: UInt64, *, width: Int = 1) -> String:
    """Lowercase hexadecimal without a prefix, zero-padded to at least `width`."""
    var digits = hex(value, prefix="")
    return "0" * (width - digits.byte_length()) + digits
