"""Digits of integers: reading runs of them into a `BigUInt` and writing hex."""

from std.math import ceildiv

from bigint import BigUInt, Limbs

from value.biguint import pow10


def digit_value(c: Int, *, hex: Bool) -> Int:
    """The value of the ASCII digit `c` (hex digits only when `hex`), or -1."""
    if ord("0") <= c <= ord("9"):
        return c - ord("0")
    if hex and ord("a") <= c <= ord("f"):
        return c - ord("a") + 10
    if hex and ord("A") <= c <= ord("F"):
        return c - ord("A") + 10
    return -1


def magnitude_of_fields[
    T: Intable & ImplicitlyCopyable & Deinitable
](fields: Span[T, _], *, width: Int) -> BigUInt:
    """The number whose `width`-bit fields, least significant first, are `fields`.
    `width` divides 64."""
    var per_limb = 64 // width
    var limbs = Limbs(length=ceildiv(len(fields), per_limb), fill=0)
    for i, field in enumerate(fields):
        limbs.unsafe_get(i // per_limb) |= UInt64(Int(field)) << UInt64(width * (i % per_limb))
    return BigUInt(limbs=limbs^)


def magnitude_of_digits(digits: List[Int], *, base: Int) -> BigUInt:
    """Base 10 or 16, most significant digit first."""
    if base == 16:
        return magnitude_of_fields([digit for digit in reversed(digits)], width=4)
    # 19 digits fit a UInt64, which keeps the big-number operations few.
    var result = BigUInt()
    for start in range(0, len(digits), 19):
        var group = digits[start : min(start + 19, len(digits))]
        var value = UInt64(0)
        for digit in group:
            value = value * 10 + UInt64(digit)
        result = result * pow10(len(group)) + BigUInt(value)
    return result^


def hex_digits(value: UInt64, *, width: Int = 1) -> String:
    """Lowercase hexadecimal without a prefix, zero-padded to at least `width`."""
    return hex(value, prefix="").ascii_rjust(width, "0")
