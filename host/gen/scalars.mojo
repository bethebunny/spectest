"""Scalar draws: integers, floats, strings and bytes, with v1's emphasis on edges."""

from std.memory import bitcast

from mcheck.source import Source, Many, MANY_LABEL
from numeric.bigint import BigInt
from numeric.formats import FloatFormat, F16, BF16, F32, F64
from wire.value import Value

from .sizes import Sizes


# Integers


def int_value(pattern: UInt64, width: Int, signed: Bool) -> Value:
    """The integer a `width`-bit two's-complement pattern denotes."""
    if signed:
        var bits = pattern
        if width < 64 and (pattern >> UInt64(width - 1)) & 1 == 1:
            bits = pattern | (~UInt64(0) << UInt64(width))
        return Value.int(Int(bitcast[DType.int64](bits)))
    if pattern <= UInt64(Int.MAX):
        return Value.int(Int(pattern))
    return Value.int(BigInt(pattern))


def _mask(width: Int) -> UInt64:
    return UInt64.MAX if width >= 64 else (UInt64(1) << UInt64(width)) - 1


def draw_fixed_pattern(mut src: Source, width: Int, signed: Bool) raises -> UInt64:
    """A `width`-bit pattern: small values, extremes, powers of two and their
    neighbours, then uniform over all patterns."""
    var mask = _mask(width)
    var r = Int(src.draw_below(100))
    if r < 15:
        var lo = -16
        var hi = 16
        if not signed:
            lo = 0
        elif width < 6:
            lo = -(1 << (width - 1))
            hi = (1 << (width - 1)) - 1
        var x = src.draw_int(lo, hi)
        return bitcast[DType.uint64](Int64(x)) & mask
    var top = UInt64(1) << UInt64(width - 1)
    if r < 30:
        var e = Int(src.draw_below(4))
        if signed:
            if e == 0:
                return top
            if e == 1:
                return top - 1
            if e == 2:
                return top + 1
            return top - 2
        if e == 0:
            return 0
        if e == 1:
            return mask
        if e == 2:
            return 1
        return mask - 1
    if r < 55 and width >= 3:
        var k = 1 + Int(src.draw_below(UInt64(width - 1)))
        var j = Int(src.draw_below(3))
        var p = UInt64(1) << UInt64(k)
        if j == 2 and signed:
            return (~p + 1) & mask
        if j == 0 and (not signed or k < width - 1):
            return p
        return p - 1
    return src.draw_bits(width)


def draw_int_value(mut src: Source, width: Int, signed: Bool) raises -> Value:
    return int_value(draw_fixed_pattern(src, width, signed), width, signed)


def _pow2(k: Int) -> BigInt:
    return BigInt(1) << k


def _huge_power(i: Int) -> Int:
    if i == 0:
        return 8
    if i == 1:
        return 16
    if i == 2:
        return 31
    if i == 3:
        return 32
    if i == 4:
        return 53
    if i == 5:
        return 63
    if i == 6:
        return 64
    if i == 7:
        return 100
    return 128


def draw_unbounded_int(mut src: Source) raises -> Value:
    """Mostly small integers, sometimes near big powers of two, sometimes wide."""
    var r = Int(src.draw_below(100))
    if r < 55:
        return Value.int(src.draw_int(-64, 64))
    if r < 70:
        return Value.int(src.draw_int(-1_000_000_000, 1_000_000_000))
    if r < 85:
        var negative = src.draw_bool()
        var k = _huge_power(Int(src.draw_below(9)))
        var d = Int(src.draw_below(3))
        var v = _pow2(k)
        if d == 1:
            v = v - BigInt(1)
        elif d == 2:
            v = v + BigInt(1)
        return Value.int(-v if negative else v^)
    var negative = src.draw_bool()
    var words = 1 + Int(src.draw_below(4))
    var v = BigInt()
    for _ in range(words):
        v = (v << 64) + BigInt(src.draw_bits(64))
    return Value.int(-v if negative else v^)


# Floats


def _simple_magnitude(i: Int) -> Float64:
    if i < 10:
        return Float64(i + 1)
    if i == 10:
        return 100.0
    if i == 11:
        return 1000.0
    if i == 12:
        return 0.5
    if i == 13:
        return 1.5
    return 0.25


def float64_bits_in(format: FloatFormat, x: Float64) -> UInt64:
    """The pattern of `x` rounded to `format`."""
    if format.id == F64.id:
        return bitcast[DType.uint64](x)
    if format.id == F32.id:
        return UInt64(bitcast[DType.uint32](Float32(x)))
    if format.id == F16.id:
        return UInt64(bitcast[DType.uint16](Float16(x)))
    return UInt64(bitcast[DType.uint16](BFloat16(x)))


comptime FLOAT_CLASSES = 7
"""zero, moderate, simple, normal, subnormal, inf, nan: the order is the order of
preference when shrinking."""


def draw_float_bits(mut src: Source, format: FloatFormat) raises -> UInt64:
    var cls = Int(src.draw_below(UInt64(FLOAT_CLASSES)))
    var fb = format.fraction_bits
    var bias = format.bias()
    var sign = UInt64(0)
    if cls != 2:
        sign = format.sign_mask() if src.draw_bool() else UInt64(0)
    if cls == 0:
        return sign
    if cls == 1:
        var e = min(20, bias // 2)
        var off = src.draw_int(-e, e - 1)
        var frac = src.draw_bits(fb)
        return sign | (UInt64(bias + off) << UInt64(fb)) | frac
    if cls == 2:
        var i = Int(src.draw_below(30))
        var x = _simple_magnitude(i // 2)
        if i % 2 == 1:
            x = -x
        return float64_bits_in(format, x)
    if cls == 3:
        var off = src.draw_int(1 - bias, bias)
        var frac = src.draw_bits(fb)
        return sign | (UInt64(bias + off) << UInt64(fb)) | frac
    if cls == 4:
        return sign | (src.draw_below(format.fraction_mask()) + 1)
    if cls == 5:
        return sign | format.exponent_mask()
    return sign | format.exponent_mask() | (src.draw_below(format.fraction_mask()) + 1)


# Sequences


struct Seq:
    """The loop over the elements of a collection: `while seq.more(src)`.

    A short sequence is a `Many`; a long one has a length drawn up front. Each element
    is one span either way.
    """

    var many: Many
    var long: Bool
    var n: Int
    var i: Int
    var open: Bool

    def __init__(out self, lo: Int, hi: Int):
        """A short sequence of `lo` to `hi` elements."""
        self.many = Many(lo, hi, Float64(hi) / 2.0 if hi > 0 else 0.0)
        self.long = False
        self.n = 0
        self.i = 0
        self.open = False

    def __init__(out self, n: Int, *, exactly: Bool):
        """A sequence of exactly `n` elements."""
        self.many = Many(0, 0, 0.0)
        self.long = True
        self.n = n
        self.i = 0
        self.open = False

    def more(mut self, mut src: Source) raises -> Bool:
        if not self.long:
            return self.many.more(src)
        if self.open:
            src.stop_span()
            self.open = False
        if self.i >= self.n:
            return False
        src.start_span(MANY_LABEL)
        self.open = True
        self.i += 1
        return True


def draw_is_long(mut src: Source, sizes: Sizes, depth: Int, short: Int, long: Int) raises -> Bool:
    """Whether a value at `depth` is long. Only top-level values can be, and no choice
    is drawn when long values are off."""
    if depth > 0 or not sizes.has_long(short, long):
        return False
    return src.draw_bool(sizes.long_share)


def draw_seq(
    mut src: Source, sizes: Sizes, depth: Int, short: Int, long: Int
) raises -> Seq:
    if draw_is_long(src, sizes, depth, short, long):
        var n = src.draw_int(sizes.long_lo(short), long)
        return Seq(n, exactly=True)
    return Seq(0, short)


# Strings


comptime INTERESTING = (
    "\u0000\t\n\r \u007f éßİ́Σمאก中"
    "あ​‍ ‮﻿�￿"
)
comptime INTERESTING_COUNT = 22


def _interesting(i: Int) -> Int:
    var k = 0
    for cp in INTERESTING.codepoints():
        if k == i:
            return Int(cp.to_u32())
        k += 1
    return 0x20


def _astral_edge(i: Int) -> Int:
    if i == 0:
        return 0x1F600
    if i == 1:
        return 0x10000
    if i == 2:
        return 0x10FFFF
    return 0x1D11E


def draw_code_point(mut src: Source) raises -> Int:
    """A Unicode scalar value: mostly ASCII, some interesting characters, the rest of
    the BMP and the astral planes. Never a surrogate."""
    var r = Int(src.draw_below(100))
    if r < 50:
        var i = Int(src.draw_below(95))
        return (i + 16) % 95 + 32
    if r < 70:
        return _interesting(Int(src.draw_below(UInt64(INTERESTING_COUNT))))
    if r < 90:
        var c = Int(src.draw_below(0x10000 - 0x800))
        return c + 0x800 if c >= 0xD800 else c
    if src.draw_bool(0.25):
        return _astral_edge(Int(src.draw_below(4)))
    return 0x10000 + Int(src.draw_below(0x100000))


def draw_string(mut src: Source, sizes: Sizes, depth: Int) raises -> Value:
    var seq = draw_seq(src, sizes, depth, sizes.max_text, sizes.long_text)
    var out = String()
    while seq.more(src):
        out += chr(draw_code_point(src))
    return Value.string(out^)


# Bytes


def _bad_utf8(i: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var b: List[Int]
    if i == 0:
        b = [0x80]
    elif i == 1:
        b = [0xC3]
    elif i == 2:
        b = [0xE2, 0x82]
    elif i == 3:
        b = [0xF0, 0x9F, 0x98]
    elif i == 4:
        b = [0xC0, 0x80]
    elif i == 5:
        b = [0xED, 0xA0, 0x80]
    elif i == 6:
        b = [0xF4, 0x90, 0x80, 0x80]
    else:
        b = [0xFF]
    for x in b:
        out.append(UInt8(x))
    return out^


def draw_bytes(mut src: Source, sizes: Sizes, depth: Int) raises -> Value:
    """Arbitrary bytes, UTF-8 encodings of text, or UTF-8 with one bad sequence."""
    var kind = Int(src.draw_below(100))
    var is_long = draw_is_long(src, sizes, depth, sizes.max_bytes, sizes.long_bytes)
    var limit = sizes.long_bytes if is_long else sizes.max_bytes
    var data = List[UInt8]()
    if kind < 60:
        var seq: Seq
        if is_long:
            seq = Seq(src.draw_int(sizes.long_lo(sizes.max_bytes), limit), exactly=True)
        else:
            seq = Seq(0, limit)
        while seq.more(src):
            data.append(UInt8(src.draw_bits(8)))
        return Value.bytes(data^)
    var seq = Seq(0, limit // 2) if not is_long else Seq(
        src.draw_int(sizes.long_lo(sizes.max_bytes) // 2, limit // 2), exactly=True
    )
    var text = String()
    while seq.more(src):
        text += chr(draw_code_point(src))
    for b in text.as_bytes():
        if len(data) >= limit:
            break
        data.append(b)
    while is_long and len(data) < sizes.long_lo(sizes.max_bytes):
        data.append(0x30)
    if kind >= 85:
        var bad = _bad_utf8(Int(src.draw_below(8)))
        var at = Int(src.draw_below(UInt64(len(data) + 1)))
        var spliced = List[UInt8]()
        for i in range(at):
            spliced.append(data[i])
        for b in bad:
            spliced.append(b)
        for i in range(at, len(data)):
            spliced.append(data[i])
        data = spliced^
    while len(data) > limit:
        _ = data.pop()
    return Value.bytes(data^)
