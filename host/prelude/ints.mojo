"""Fixed-width integers and bytes: `wrap`, `fits`, `le_uint`, `bit_length`."""

from numeric.bigint import BigInt
from numeric.digits import magnitude_of_fields
from numeric.fixed import int_max, int_min, wrapped
from numeric.formats import FloatFormat
from numeric.floats import exactly
from prelude.util import fail, int_of, real_of
from wire.value import Value


def wrap(n: Value, bits: Int, signed: Bool) raises -> Value:
    """`n` reduced modulo 2**bits into the range of the type."""
    return Value.int(wrapped(int_of(n, "wrap"), bits, signed=signed))


def fits_int(x: Value, bits: Int, signed: Bool) raises -> Value:
    var r = real_of(x, String("fits<", "i" if signed else "u", bits, ">"))
    ref n = r.numerator
    return Value.bool(r.is_integer() and int_min(bits, signed) <= n and n <= int_max(bits, signed))


def fits_float(x: Value, f: FloatFormat) raises -> Value:
    var r = real_of(x, String("fits<", f, ">"))
    return Value.bool(Bool(exactly(f, r)))


def le_uint(b: Value) raises -> Value:
    if b.kind != .BYTES:
        raise fail("le_uint", t"expected bytes, got {b}")
    return Value.int(BigInt(negative=False, magnitude=magnitude_of_fields(b.data(), width=8)))


def bit_length(n: Value) raises -> Value:
    return Value.int(int_of(n, "bit_length").bit_length())
