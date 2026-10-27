"""Float ranges by numeric value, as sets of bit patterns."""

from std.os import abort

from numeric.floats import exactly, round_to, to_real
from numeric.formats import FloatFormat
from numeric.real import Real
from sets import BitSet, SetContext


def _at_least(format: FloatFormat, r: Real) raises -> UInt64:
    """The smallest magnitude pattern whose value is >= r (r >= 0); the infinity's
    pattern stands for +inf."""
    var inf_mag = format.exponent_mask()
    var m = round_to(format, r)
    if m >= inf_mag:
        return inf_mag
    if to_real(format, m) >= r:
        return m
    # `m` is the nearest pattern and lies below r, so its successor is the first at or
    # above r.
    return m + 1


def _above(format: FloatFormat, r: Real) raises -> UInt64:
    """The smallest magnitude pattern whose value is > r (r >= 0)."""
    var mag = _at_least(format, r)
    if mag < format.exponent_mask() and to_real(format, mag) == r:
        return mag + 1
    return mag


def float_range(
    mut ctx: SetContext,
    format: FloatFormat,
    lo: Optional[Real],
    hi: Optional[Real],
) -> BitSet:
    """The non-NaN values v with lo <= v < hi by numeric value, so both zeros count as 0.
    An absent bound leaves that end open, including its infinity."""
    var zero = Real()
    var top = format.exponent_mask() + 1
    var sign = format.sign_mask()
    var width = format.width()
    var pos_lo = UInt64(0)
    var pos_hi = top
    var neg_lo = UInt64(0)
    var neg_hi = top
    try:
        if lo and lo.value() > zero:
            pos_lo = _at_least(format, lo.value())
        if hi:
            pos_hi = _at_least(format, hi.value()) if hi.value() > zero else 0
            if hi.value() <= zero:
                neg_lo = _above(format, -hi.value())
        if lo:
            neg_hi = _above(format, -lo.value()) if lo.value() <= zero else 0
    except:
        abort("float_range: a bound is not a finite real")
    var positive = ctx.interval(pos_lo, pos_hi, width)
    var negative = ctx.interval(sign + neg_lo, sign + neg_hi, width)
    return ctx.union(positive, negative)


def float_equal(mut ctx: SetContext, format: FloatFormat, c: Real) -> BitSet:
    """The values numerically equal to c: both zeros for 0."""
    if c.is_zero():
        try:
            return ctx.float_named(format, "zero")
        except:
            abort("float_equal: no zero set")
    var bits = exactly(format, c)
    if not bits:
        return ctx.empty(format.width())
    return ctx.exactly([bits.value()], format.width())
