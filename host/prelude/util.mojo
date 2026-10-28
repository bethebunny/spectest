"""Shared helpers of the prelude functions: errors, and numbers as `Real`."""

from numeric.bigint import BigInt
from numeric.floats import is_nan, to_real
from numeric.formats import FloatFormat
from numeric.real import Real
from wire.value import Kind, Value


def fail(who: String, message: Some[Writable]) -> Error:
    return Error(t"{who}: {message}")


def int_of(v: Value, who: String) raises -> BigInt:
    if v.kind != .INT:
        raise fail(who, t"expected an integer, got {v}")
    return v.as_bigint()


def float_of(v: Value, who: String) raises -> FloatFormat:
    if v.kind != .FLOAT:
        raise fail(who, t"expected a float, got {v}")
    return v.float_format()


def real_of(v: Value, who: String) raises -> Real:
    """An INT, REAL or FLOAT as an extended real. A NaN raises."""
    match v.kind:
        case .INT | .REAL:
            return v.as_real()
        case .FLOAT:
            var f = v.float_format()
            if is_nan(f, v.float_bits()):
                raise fail(who, t"cannot promote a NaN ({f} bits {hex(v.float_bits())})")
            return to_real(f, v.float_bits())
        case _:
            raise fail(who, t"expected a number, got {v}")


def real_value(r: Real) -> Value:
    return Value.real(r.numerator.copy(), r.denominator.copy())


def list_items(v: Value, who: String) raises -> List[Value]:
    if v.kind not in [Kind.LIST, Kind.TUPLE]:
        raise fail(who, t"expected a list, got {v}")
    return v.items()
