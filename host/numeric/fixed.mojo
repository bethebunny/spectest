"""Fixed-width integers: the bounds of `iN` and `uN`, and two's-complement patterns.

A pattern is a `UInt64` holding a value's low `width` bits, for widths 1 to 64.
"""

from std.memory import bitcast

from numeric.bigint import BigInt


def int_min(width: Int, signed: Bool) -> BigInt:
    return -(BigInt(1) << (width - 1)) if signed else BigInt(0)


def int_max(width: Int, signed: Bool) -> BigInt:
    return (BigInt(1) << (width - 1 if signed else width)) - 1


def wrapped(x: BigInt, width: Int, *, signed: Bool) -> BigInt:
    """`x` modulo 2**width, in the range of `iN` or `uN`. Any width above 0."""
    var low = BigInt(negative=False, magnitude=x.magnitude.low_bits(width))
    if x.negative and low:
        low = (BigInt(1) << width) - low
    return low - (BigInt(1) << width) if signed and low.magnitude.bit(width - 1) else low^


def low_mask(width: Int) -> UInt64:
    """The low `width` bits set, for widths 0 to 64."""
    return UInt64.MAX if width >= 64 else (UInt64(1) << UInt64(width)) - 1


def pattern_of(x: BigInt, width: Int) -> UInt64:
    """`x` modulo 2**width, as a pattern."""
    var low = x.magnitude.limb(0)
    return (UInt64(0) - low if x.negative else low) & low_mask(width)


def signed_of(pattern: UInt64, width: Int) -> Int:
    """The pattern read as a signed `width`-bit integer."""
    var shift = UInt64(64 - width)
    return Int(bitcast[DType.int64](pattern << shift) >> Int64(shift))
