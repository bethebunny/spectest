"""The float functions: classification, neighbours, `ulp`, `qe`, rounding, `real`."""

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.floats import (
    exactly,
    is_finite as fl_is_finite,
    is_inf as fl_is_inf,
    is_nan as fl_is_nan,
    is_subnormal as fl_is_subnormal,
    is_zero as fl_is_zero,
    next_down as fl_next_down,
    next_up as fl_next_up,
    round_to,
    signbit as fl_signbit,
    to_real,
    _floor_log2,
)
from numeric.formats import FloatFormat
from numeric.real import Real
from prelude.util import fail, float_of, real_of, real_value
from wire.value import Value, FLOAT, QERR


def classify(who: String, v: Value) raises -> Value:
    """The float predicate named `who` (`is_nan`, `signbit`, ...)."""
    var f = float_of(v, who)
    var bits = v.float_bits()
    match who:
        case "is_nan":
            return Value.bool(fl_is_nan(f, bits))
        case "is_inf":
            return Value.bool(fl_is_inf(f, bits))
        case "is_finite":
            return Value.bool(fl_is_finite(f, bits))
        case "is_zero":
            return Value.bool(fl_is_zero(f, bits))
        case "is_subnormal":
            return Value.bool(fl_is_subnormal(f, bits))
        case _:
            return Value.bool(fl_signbit(f, bits))


def bits(v: Value) raises -> Value:
    _ = float_of(v, "bits")
    return Value.int(BigInt(v.float_bits()))


def next_up(v: Value) raises -> Value:
    var f = float_of(v, "next_up")
    return Value.float(f, fl_next_up(f, v.float_bits()))


def next_down(v: Value) raises -> Value:
    var f = float_of(v, "next_down")
    return Value.float(f, fl_next_down(f, v.float_bits()))


def _pow2(k: Int) -> Real:
    var one = BigUInt(UInt64(1))
    if k >= 0:
        return Real(lowest_numerator=BigInt(negative=False, magnitude=one << k), lowest_denominator=BigInt(1))
    return Real(lowest_numerator=BigInt(1), lowest_denominator=BigInt(negative=False, magnitude=one << (-k)))


def ulp(f: FloatFormat, x: Value) raises -> Value:
    """The spacing of the format in the binade of |x| (the top binade past the largest finite)."""
    var r = real_of(x, String("ulp<", f, ">"))
    var emin = 1 - f.bias()
    var emax = f.bias()
    var e: Int
    if r.is_inf():
        e = emax
    elif r.is_zero():
        e = emin
    else:
        e = _floor_log2(r.numerator.magnitude, r.denominator.magnitude)
        e = min(max(e, emin), emax)
    return real_value(_pow2(e - f.fraction_bits))


def _ordinal(f: FloatFormat, bits: UInt64) -> Int:
    var mag = Int(bits & ~f.sign_mask())
    return -mag if (bits & f.sign_mask()) != 0 else mag


def _in_format(v: Value, f: FloatFormat) raises -> Value:
    var who = String("qe<", f, ">")
    if v.kind == FLOAT:
        if v.float_format_id() != f.id:
            raise fail(who, t"compares {f} values, got a {float_of(v, who)}")
        return v.copy()
    var r = real_of(v, who)
    var exact = exactly(f, r)
    if exact is None:
        raise fail(who, t"{r} is not exactly representable as {f}")
    return Value.float(f, exact.value())


def qe(x_in: Value, y_in: Value, format: Optional[FloatFormat]) raises -> Value:
    """The quantized error: the values of the format in [min, max) (signed zeros are one value)."""
    var x = x_in.copy()
    var y = y_in.copy()
    if format is not None:
        x = _in_format(x, format.value())
        y = _in_format(y, format.value())
    var fx = float_of(x, "qe")
    var fy = float_of(y, "qe")
    if fx != fy:
        raise fail("qe", t"compares two values of one format, got {fx} and {fy}")
    var x_nan = fl_is_nan(fx, x.float_bits())
    var y_nan = fl_is_nan(fx, y.float_bits())
    if x_nan or y_nan:
        return Value.qerr(BigInt(0), BigInt(0 if (x_nan and y_nan) else 1))
    var d = BigInt(_ordinal(fx, x.float_bits())) - BigInt(_ordinal(fx, y.float_bits()))
    return Value.qerr(d.__abs__(), BigInt(0))


def qerr_part(who: String, v: Value, index: Int) raises -> Value:
    if v.kind != QERR:
        raise fail(who, t"expected a qerr, got {v}")
    return v.item(index)


def ieee_eq(a: Value, b: Value) raises -> Value:
    var fa = float_of(a, "ieee_eq")
    var fb = float_of(b, "ieee_eq")
    if fl_is_nan(fa, a.float_bits()) or fl_is_nan(fb, b.float_bits()):
        return Value.bool(False)
    return Value.bool(to_real(fa, a.float_bits()) == to_real(fb, b.float_bits()))


def real(x: Value) raises -> Value:
    return real_value(real_of(x, "real"))


def round_float(f: FloatFormat, x: Value) raises -> Value:
    var r = real_of(x, String("round<", f, ">"))
    return Value.float(f, round_to(f, r))
