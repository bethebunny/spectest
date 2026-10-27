"""Scalar draws: integers, floats, strings and bytes, with v1's emphasis on edges."""

from std.memory import bitcast

from eval.coerce import int_from_bits
from mcheck.source import Source, Many, MANY_LABEL, index_to_int
from numeric.bigint import BigInt
from numeric.formats import FloatFormat, F16, BF16, F32, F64
from wire.value import Value

from .sizes import Sizes


# Integers


def _mask(width: Int) -> UInt64:
    return UInt64.MAX if width >= 64 else (UInt64(1) << UInt64(width)) - 1


def _seg(u: UInt64, start: Int, log_length: Int, n: UInt128) -> UInt64:
    """Where `u` falls in the segment of 256ths [start, start + 2**log_length), scaled
    to [0, n). Monotone, so a smaller `u` never gives a larger index."""
    var off = UInt128(u) - (UInt128(start) << 56)
    return UInt64((off * n) >> UInt128(56 + log_length))


def draw_fixed_pattern(mut src: Source, width: Int, signed: Bool) raises -> UInt64:
    """A `width`-bit pattern from one choice.

    The choice, read as a fraction, picks small values, powers of two and their
    neighbours, the extremes, or a value uniform over all patterns, in that order.
    Within each, a smaller choice is a smaller magnitude."""
    var mask = _mask(width)
    var u = src.draw_bits(64)
    var seg = Int(u >> 56)
    var top = UInt64(1) << UInt64(width - 1)
    if seg < 32:
        var lo = -16
        var hi = 16
        if not signed:
            lo = 0
        elif width < 6:
            lo = -(1 << (width - 1))
            hi = (1 << (width - 1)) - 1
        var idx = _seg(u, 0, 5, UInt128(hi - lo + 1))
        return bitcast[DType.uint64](Int64(index_to_int(idx, lo, hi))) & mask
    if seg < 96:
        var k = 1 + Int(_seg(u, 32, 6, UInt128(width - 1)))
        var j = Int(u & 3)
        var p = UInt64(1) << UInt64(k)
        if j == 2 and signed:
            return (~p + 1) & mask
        if j == 0 and (not signed or k < width - 1):
            return p
        return p - 1
    if seg < 128:
        var e = Int(_seg(u, 96, 5, 4))
        return [top, top - 1, top + 1, top - 2][e] if signed else [0, mask, 1, mask - 1][e]
    var idx = _seg(u, 128, 7, UInt128(1) << UInt128(width))
    if signed:
        var lo = Int(bitcast[DType.int64](top << UInt64(64 - width))) >> (64 - width)
        var hi = -(lo + 1)
        return bitcast[DType.uint64](Int64(index_to_int(idx, lo, hi))) & mask
    return idx


def draw_int_value(mut src: Source, width: Int, signed: Bool) raises -> Value:
    return int_from_bits(draw_fixed_pattern(src, width, signed), width, signed)


def draw_unbounded_int(mut src: Source) raises -> Value:
    """Mostly small integers, sometimes near big powers of two, sometimes wide."""
    var r = Int(src.draw_below(100))
    if r < 55:
        return Value.int(src.draw_int(-64, 64))
    if r < 70:
        return Value.int(src.draw_int(-1_000_000_000, 1_000_000_000))
    var negative = src.draw_bool()
    var v: BigInt
    if r < 85:
        var k = [8, 16, 31, 32, 53, 63, 64, 100, 128][Int(src.draw_below(9))]
        v = (BigInt(1) << k) + BigInt([0, -1, 1][Int(src.draw_below(3))])
    else:
        v = BigInt()
        for _ in range(1 + Int(src.draw_below(4))):
            v = (v << 64) + BigInt(src.draw_bits(64))
    return Value.int(-v if negative else v^)


# Floats


def _simple_magnitude(i: Int) -> Float64:
    return [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 100.0, 1000.0, 0.5, 1.5, 0.25][i]


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
"""zero, moderate, simple, normal, subnormal, inf, nan (in order of preference when shrinking)."""


def draw_float_bits(mut src: Source, format: FloatFormat) raises -> UInt64:
    """A float pattern: a class uniformly, then a member of it.

    Every class draws the same four choices (class, sign, a, b) with the same meaning,
    so shrinking can move a failure to a lower class by lowering the class and raising b."""
    var cls = Int(src.draw_below(UInt64(FLOAT_CLASSES)))
    var fb = format.fraction_bits
    var bias = format.bias()
    var negative = src.draw_bool()
    var sign = format.sign_mask() if negative else UInt64(0)
    var a = src.draw_int(1 - bias, bias)
    var b = src.draw_bits(fb)
    if cls == 0:
        return sign
    if cls == 1:
        var e = min(20, bias // 2)
        return sign | (UInt64(bias + max(-e, min(e - 1, a))) << UInt64(fb)) | b
    if cls == 2:
        var x = _simple_magnitude(Int(b % 15))
        return float64_bits_in(format, -x if negative else x)
    if cls == 3:
        return sign | (UInt64(bias + a) << UInt64(fb)) | b
    if cls == 4:
        return sign | (b % format.fraction_mask() + 1)
    if cls == 5:
        return sign | format.exponent_mask()
    return sign | format.exponent_mask() | (b % format.fraction_mask() + 1)


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
        self.many = Many(lo, hi, Float64(hi) / 4.0 if hi > 0 else 0.0)
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


def draw_is_long(mut src: Source, sizes: Sizes, depth: Int, short: Int, *, long: Int) raises -> Bool:
    """Whether a value at `depth` is long (only top-level values can be). No choice is
    drawn when long values are off."""
    return depth == 0 and sizes.has_long(short, long=long) and src.draw_bool(sizes.long_share)


def _seq_of(mut src: Source, is_long: Bool, short: Int, long_lo: Int, long: Int) raises -> Seq:
    return Seq(src.draw_int(long_lo, long), exactly=True) if is_long else Seq(0, short)


def draw_seq(mut src: Source, sizes: Sizes, depth: Int, short: Int, *, long: Int) raises -> Seq:
    var is_long = draw_is_long(src, sizes, depth, short, long=long)
    return _seq_of(src, is_long, short, sizes.long_lo(short), long)


# Strings


comptime INTERESTING = (
    "\u0000\t\n\r \u007f éßİ́Σمאก中"
    "あ​‍ ‮﻿�￿"
)
comptime INTERESTING_COUNT = 22


def _interesting(i: Int) -> Int:
    for k, cp in enumerate(INTERESTING.codepoints()):
        if k == i:
            return Int(cp.to_u32())
    return 0x20


def draw_code_point(mut src: Source) raises -> Int:
    """A Unicode scalar value: half ASCII (one choice), the rest interesting
    characters, the BMP and the astral planes. Never a surrogate."""
    var r = Int(src.draw_below(190))
    if r < 95:
        return (r + 16) % 95 + 32
    if r < 133:
        return _interesting(Int(src.draw_below(UInt64(INTERESTING_COUNT))))
    if r < 171:
        var c = Int(src.draw_below(0x10000 - 0x800))
        return c + 0x800 if c >= 0xD800 else c
    if src.draw_bool(0.25):
        return [0x1F600, 0x10000, 0x10FFFF, 0x1D11E][Int(src.draw_below(4))]
    return 0x10000 + Int(src.draw_below(0x100000))


def append_utf8(mut out: List[UInt8], cp: Int):
    out.extend(chr(cp).as_bytes())


def draw_string(mut src: Source, sizes: Sizes, depth: Int) raises -> Value:
    var seq = draw_seq(src, sizes, depth, sizes.max_text, long=sizes.long_text)
    var out = List[UInt8]()
    while seq.more(src):
        append_utf8(out, draw_code_point(src))
    return Value.string(String(unsafe_from_utf8=Span(out)))


# Bytes


def _bad_utf8(i: Int) -> List[UInt8]:
    var sequences: List[List[Int]] = [
        [0x80], [0xC3], [0xE2, 0x82], [0xF0, 0x9F, 0x98], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xFF]
    ]
    return [UInt8(x) for x in sequences[i]]


def draw_bytes(mut src: Source, sizes: Sizes, depth: Int) raises -> Value:
    """Arbitrary bytes, UTF-8 encodings of text, or UTF-8 with one bad sequence."""
    var kind = Int(src.draw_below(100))
    var is_long = draw_is_long(src, sizes, depth, sizes.max_bytes, long=sizes.long_bytes)
    var limit = sizes.long_bytes if is_long else sizes.max_bytes
    var long_lo = sizes.long_lo(sizes.max_bytes)
    if kind < 60:
        var seq = _seq_of(src, is_long, limit, long_lo, limit)
        var data = List[UInt8]()
        while seq.more(src):
            data.append(UInt8(src.draw_bits(8)))
        return Value.bytes(data^)
    var seq = _seq_of(src, is_long, limit // 2, long_lo // 2, limit // 2)
    var text = List[UInt8]()
    while seq.more(src):
        append_utf8(text, draw_code_point(src))
    var data = List(text[: min(limit, len(text))])
    while is_long and len(data) < long_lo:
        data.append(0x30)
    if kind >= 85:
        var bad = _bad_utf8(Int(src.draw_below(8)))
        var at = Int(src.draw_below(UInt64(len(data) + 1)))
        var spliced = List(data[:at])
        spliced.extend(bad^)
        spliced.extend(data[at:])
        data = List(spliced[: min(limit, len(spliced))])
    return Value.bytes(data^)
