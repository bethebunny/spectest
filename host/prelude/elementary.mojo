"""`mp.*` (MPFR's 256-bit result, exactly) and `cr.*` (the correctly rounded result in
the argument's format, with IEEE 754's special cases)."""

from std.memory import bitcast

from numeric.floats import is_nan, round_to
from numeric.formats import FloatFormat, F16, F32, F64
from numeric.real import Real
from prelude.mpfr import ARGUMENT, RESULT, Mpfr
from prelude.util import fail, float_of, real_of, real_value
from wire.value import Value

comptime PRECISION = 256
comptime EXP_LIMIT = 1 << 18


def mp(function: String, x: Value) raises -> Value:
    var who = String("mp.", function)
    var r = real_of(x, who)
    var sign = r.sign()
    if function == "sqrt" and sign < 0:
        raise fail(who, t"argument must be non-negative, got {r}")
    if function == "log" and sign <= 0:
        raise fail(who, t"argument must be positive, got {r}")
    var m = Mpfr(precision=PRECISION, emin=-EXP_LIMIT, emax=EXP_LIMIT)
    m.set_real(ARGUMENT, r)
    if m.is_inf(ARGUMENT) and not r.is_inf():
        raise fail(who, t"argument {r} is outside the reference range")
    m.clear_flags()
    _ = m.apply(function)
    if m.is_nan(RESULT):
        raise fail(who, t"undefined at {r}")
    if m.overflowed() or m.underflowed() or (m.is_inf(RESULT) and not r.is_inf()):
        raise fail(who, t"result at {r} is outside the reference range")
    if m.is_inf(RESULT):
        return real_value(Real.infinity(m.negative(RESULT)))
    return real_value(m.to_real(RESULT))


def _to_double(f: FloatFormat, bits: UInt64) -> Float64:
    """Every format widens exactly into a double."""
    if f == F64:
        return bitcast[DType.float64](bits)
    if f == F32:
        return Float64(bitcast[DType.float32](UInt32(bits)))
    if f == F16:
        return Float64(bitcast[DType.float16](UInt16(bits)))
    return Float64(bitcast[DType.float32](UInt32(bits) << 16))


def cr(function: String, x: Value) raises -> Value:
    var who = String("cr.", function)
    var f = float_of(x, who)
    var bits = x.float_bits()
    if is_nan(f, bits):
        return Value.float(f, f.quiet_nan())
    var precision = f.fraction_bits + 1
    # The format's exponent range in MPFR's terms, eg. -1073 to 1024 for f64.
    var m = Mpfr(precision=precision, emin=3 - f.bias() - precision, emax=f.bias() + 1)
    m.set_double(ARGUMENT, _to_double(f, bits))
    m.subnormalize(m.apply(function))
    if m.is_nan(RESULT):
        return Value.float(f, f.quiet_nan())
    var sign = f.sign_mask() if m.negative(RESULT) else UInt64(0)
    if m.is_inf(RESULT):
        return Value.float(f, sign | f.exponent_mask())
    if m.is_zero(RESULT):
        return Value.float(f, sign)
    return Value.float(f, round_to(f, m.to_real(RESULT)))
