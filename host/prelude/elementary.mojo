"""`mp.*` (MPFR's 256-bit result, exactly) and `cr.*` (the correctly rounded result in
the argument's format, with IEEE 754's special cases)."""

from std.memory import bitcast

from numeric.floats import round_to
from numeric.formats import FloatFormat, BF16, F16, F32, F64
from numeric.real import Real
from prelude.mpfr import Mpfr, SQRT, EXP, LOG, SIN, COS, TAN, ATAN
from prelude.util import describe, fail, float_of, real_of, real_value
from wire.value import Value, FLOAT

comptime PRECISION = 256
comptime EXP_LIMIT = 1 << 18


def _name(which: Int) -> String:
    if which == SQRT:
        return "sqrt"
    if which == EXP:
        return "exp"
    if which == LOG:
        return "log"
    if which == SIN:
        return "sin"
    if which == COS:
        return "cos"
    if which == TAN:
        return "tan"
    return "atan"


def mp(which: Int, x: Value) raises -> Value:
    var who = "mp." + _name(which)
    var r = real_of(x, who)
    var sign = r.sign()
    if which == SQRT and sign < 0:
        raise fail(who, "argument must be non-negative, got " + String(r))
    if which == LOG and sign <= 0:
        raise fail(who, "argument must be positive, got " + String(r))
    var m = Mpfr()
    m.set_range(-EXP_LIMIT, EXP_LIMIT)
    m.set_precision(0, PRECISION)
    m.set_precision(1, PRECISION)
    m.set_real(0, r)
    if m.is_inf(0) and not r.is_inf():
        raise fail(who, "argument " + String(r) + " is outside the reference range")
    m.clear_flags()
    _ = m.apply(which, 1, 0)
    if m.is_nan(1):
        raise fail(who, "undefined at " + String(r))
    if m.overflowed() or m.underflowed() or (m.is_inf(1) and not r.is_inf()):
        raise fail(who, "result at " + String(r) + " is outside the reference range")
    if m.is_inf(1):
        return real_value(Real.infinity(m.negative(1)))
    return real_value(m.to_real(1))


def _to_double(f: FloatFormat, bits: UInt64) -> Float64:
    """Every format widens exactly into a double."""
    if f == F64:
        return bitcast[DType.float64](bits)
    if f == F32:
        return Float64(bitcast[DType.float32](UInt32(bits)))
    if f == F16:
        return Float64(bitcast[DType.float16](UInt16(bits)))
    return Float64(bitcast[DType.float32](UInt32(bits) << 16))


def canonical_nan(f: FloatFormat) -> UInt64:
    return f.exponent_mask() | (UInt64(1) << UInt64(f.fraction_bits - 1))


def cr(which: Int, x: Value) raises -> Value:
    var who = "cr." + _name(which)
    var f = float_of(x, who)
    var bits = x.float_bits()
    var is_nan = (bits & f.exponent_mask()) == f.exponent_mask() and (bits & f.fraction_mask()) != 0
    if is_nan:
        return Value.float(f, canonical_nan(f))
    var prec = f.fraction_bits + 1
    var emin = 1 - f.bias()
    var m = Mpfr()
    m.set_range(emin - prec + 2, f.bias() + 1)
    m.set_precision(0, prec)
    m.set_precision(1, prec)
    m.set_double(0, _to_double(f, bits))
    var ternary = m.apply(which, 1, 0)
    m.subnormalize(1, ternary)
    if m.is_nan(1):
        return Value.float(f, canonical_nan(f))
    var sign = f.sign_mask() if m.negative(1) else UInt64(0)
    if m.is_inf(1):
        return Value.float(f, sign | f.exponent_mask())
    if m.is_zero(1):
        return Value.float(f, sign)
    return Value.float(f, round_to(f, m.to_real(1)))
