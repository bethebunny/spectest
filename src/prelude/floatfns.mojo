"""The float functions: classification, neighbours, `ulp`, `qe`, rounding, `real`."""

from std.math import clamp

from value import floats
from value.bigint import BigInt
from value.float_formats import FloatFormat
from value.real import Real
from value.value import Value

from prelude.util import fail, float_of, real_of, real_value


def classify(who: String, v: Value) raises -> Value:
    """The float predicate named `who` (`is_nan`, `signbit`, ...)."""
    var f = float_of(v, who)
    var bits = v.float_bits()
    match who:
        case "is_nan":
            return Value.bool(floats.is_nan(f, bits))
        case "is_inf":
            return Value.bool(floats.is_inf(f, bits))
        case "is_finite":
            return Value.bool(floats.is_finite(f, bits))
        case "is_zero":
            return Value.bool(floats.is_zero(f, bits))
        case "is_subnormal":
            return Value.bool(floats.is_subnormal(f, bits))
        case _:
            return Value.bool(floats.signbit(f, bits))


def bits(v: Value) raises -> Value:
    _ = float_of(v, "bits")
    return Value.int(BigInt(v.float_bits()))


def next_up(v: Value) raises -> Value:
    var f = float_of(v, "next_up")
    return Value.float(f, floats.next_up(f, v.float_bits()))


def next_down(v: Value) raises -> Value:
    var f = float_of(v, "next_down")
    return Value.float(f, floats.next_down(f, v.float_bits()))


def ulp(f: FloatFormat, x: Value) raises -> Value:
    """The spacing of the format in the binade of |x| (the top binade past the largest finite)."""
    var r = real_of(x, String("ulp<", f, ">"))
    var emin = 1 - f.bias()
    var e: Int
    if r.is_inf():
        e = f.bias()
    elif r.is_zero():
        e = emin
    else:
        e = clamp(floats.floor_log2(r.numerator.magnitude, r.denominator.magnitude), emin, f.bias())
    return real_value(Real.dyadic(False, 1, e - f.fraction_bits))


def _ordinal(f: FloatFormat, bits: UInt64) -> Int:
    var magnitude = Int(bits & ~f.sign_mask())
    return -magnitude if floats.signbit(f, bits) else magnitude


def _in_format(v: Value, f: FloatFormat) raises -> Value:
    var who = String("qe<", f, ">")
    if v.kind == .Float:
        if v.float_format() != f:
            raise fail(who, t"compares {f} values, got a {v.float_format()}")
        return v.copy()
    var r = real_of(v, who)
    if case .Some(bits) = floats.exactly(f, r):
        return Value.float(f, bits)
    raise fail(who, t"{r} is not exactly representable as {f}")


def qe(x: Value, y: Value, format: Optional[FloatFormat]) raises -> Value:
    """The quantized error: the values of the format in [min, max) (signed zeros are one value)."""
    var a = x.copy()
    var b = y.copy()
    if case .Some(f) = format:
        a = _in_format(x, f)
        b = _in_format(y, f)
    var fa = float_of(a, "qe")
    var fb = float_of(b, "qe")
    if fa != fb:
        raise fail("qe", t"compares two values of one format, got {fa} and {fb}")
    var a_nan = floats.is_nan(fa, a.float_bits())
    var b_nan = floats.is_nan(fa, b.float_bits())
    if a_nan or b_nan:
        return Value.qerr(BigInt(0), BigInt(0 if a_nan and b_nan else 1))
    var d = BigInt(_ordinal(fa, a.float_bits())) - BigInt(_ordinal(fa, b.float_bits()))
    return Value.qerr(abs(d), BigInt(0))


def qerr_part(who: String, v: Value, index: Int) raises -> Value:
    if v.kind != .Qerr:
        raise fail(who, t"expected a qerr, got {v}")
    return v.item(index)


def ieee_equal(a: Value, b: Value) raises -> Bool:
    """IEEE 754 equality of two floats of any formats: -0 equals +0, and a NaN equals nothing."""
    var fa = a.float_format()
    var fb = b.float_format()
    if floats.is_nan(fa, a.float_bits()) or floats.is_nan(fb, b.float_bits()):
        return False
    return floats.to_real(fa, a.float_bits()) == floats.to_real(fb, b.float_bits())


def ieee_eq(a: Value, b: Value) raises -> Value:
    _ = float_of(a, "ieee_eq")
    _ = float_of(b, "ieee_eq")
    return Value.bool(ieee_equal(a, b))


def real(x: Value) raises -> Value:
    return real_value(real_of(x, "real"))


def round_float(f: FloatFormat, x: Value) raises -> Value:
    var r = real_of(x, String("round<", f, ">"))
    return Value.float(f, floats.round_to(f, r))
