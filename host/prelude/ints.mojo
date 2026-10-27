"""Fixed-width integers and bytes: `wrap`, `fits`, `le_uint`, `bit_length`."""

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.formats import FloatFormat
from numeric.floats import exactly
from prelude.util import fail, int_of, real_of
from wire.value import Value, BYTES


def _bound(bits: Int) -> BigInt:
    return BigInt(1) << bits


def wrap(n: Value, bits: Int, signed: Bool) raises -> Value:
    """`n` reduced modulo 2**bits into the range of the type."""
    var x = int_of(n, "wrap")
    var m = x % _bound(bits)
    if signed and not (m < _bound(bits - 1)):
        m = m - _bound(bits)
    return Value.int(m^)


def fits_int(x: Value, bits: Int, signed: Bool) raises -> Value:
    var name = String("i" if signed else "u", bits)
    var lo = -_bound(bits - 1) if signed else BigInt(0)
    var hi = _bound(bits - 1 if signed else bits) - BigInt(1)
    var r = real_of(x, String("fits<", name, ">"))
    if r.is_inf() or r.denominator != BigInt(1):
        return Value.bool(False)
    return Value.bool(not (r.numerator < lo) and not (hi < r.numerator))


def fits_float(x: Value, f: FloatFormat) raises -> Value:
    var r = real_of(x, String("fits<", f, ">"))
    return Value.bool(Bool(exactly(f, r)))


def le_uint(b: Value) raises -> Value:
    if b.kind != BYTES:
        raise fail("le_uint", t"expected bytes, got {b}")
    ref data = b.data()
    var acc = BigUInt(UInt64(0))
    var i = len(data) - 1
    # seven bytes at a time keeps the big shifts few
    while i >= 0:
        var chunk = UInt64(0)
        var taken = 0
        while taken < 7 and i >= 0:
            chunk = (chunk << 8) | UInt64(data[i])
            i -= 1
            taken += 1
        acc = (acc << (8 * taken)) | BigUInt(chunk)
    return Value.int(BigInt(negative=False, magnitude=acc^))


def bit_length(n: Value) raises -> Value:
    return Value.int(int_of(n, "bit_length").bit_length())
