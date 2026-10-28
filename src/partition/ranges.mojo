"""Float ranges by numeric value, as sets of bit patterns."""

from std.os import abort

from value.float_formats import FloatFormat
from value.floats import exactly, round_to, to_real
from value.real import Real

from partition.sets import BitSet, SetContext


def _at_least(format: FloatFormat, r: Real) raises -> UInt64:
    """The smallest magnitude pattern whose value is >= r (the infinity's for +inf)."""
    var inf_mag = format.exponent_mask()
    var m = round_to(format, r)
    if m >= inf_mag:
        return inf_mag
    if to_real(format, m) >= r:
        return m
    # the nearest pattern lies below r, so its successor is the first at or above r
    return m + 1


def _above(format: FloatFormat, r: Real) raises -> UInt64:
    """The smallest magnitude pattern whose value is > r."""
    var mag = _at_least(format, r)
    if mag < format.exponent_mask() and to_real(format, mag) == r:
        return mag + 1
    return mag


def float_range(
    mut ctx: SetContext, format: FloatFormat, lo: Optional[Real], hi: Optional[Real]
) -> BitSet:
    """The non-NaN values v with lo <= v < hi by numeric value, so both zeros count as 0.
    An absent bound leaves that end open, including its infinity."""
    var top = format.exponent_mask() + 1
    var positive_lo = UInt64(0)
    var positive_hi = top
    var negative_lo = UInt64(0)
    var negative_hi = top
    try:
        if case .Some(bound) = lo:
            if bound.sign() > 0:
                positive_lo = _at_least(format, bound)
            negative_hi = _above(format, -bound) if bound.sign() <= 0 else 0
        if case .Some(bound) = hi:
            positive_hi = _at_least(format, bound) if bound.sign() > 0 else 0
            if bound.sign() <= 0:
                negative_lo = _above(format, -bound)
    except:
        abort("float_range: a bound is not a finite real")
    var sign = format.sign_mask()
    var positive = ctx.interval(positive_lo, positive_hi, format.width())
    var negative = ctx.interval(sign + negative_lo, sign + negative_hi, format.width())
    return ctx.union(positive, negative)


def float_equal(mut ctx: SetContext, format: FloatFormat, c: Real) raises -> BitSet:
    """The values numerically equal to c: both zeros for 0."""
    if c.is_zero():
        return ctx.float_named(format, "zero")
    var bits = exactly(format, c)
    return ctx.empty(format.width()) if bits is None else ctx.exactly([bits.value()], format.width())
