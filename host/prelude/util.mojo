"""Shared helpers of the prelude functions: errors, and numbers as `Real`."""

from numeric.bigint import BigInt
from numeric.floats import to_real
from numeric.formats import FloatFormat, format_by_id
from numeric.real import Real
from wire.value import Value, Kind, INT, FLOAT, REAL, LIST, TUPLE


def fail(who: String, message: String) -> Error:
    """The error an evaluation raises: its message names the function."""
    return Error(who + ": " + message)


def describe(v: Value) -> String:
    """A short form of a value for error messages."""
    return String(v)


def want(v: Value, kind: Kind, who: String, what: String) raises:
    if v.kind != kind:
        raise fail(who, "expected " + what + ", got " + describe(v))


def int_of(v: Value, who: String) raises -> BigInt:
    if v.kind != INT:
        raise fail(who, "expected an integer, got " + describe(v))
    return v.as_bigint()


def float_of(v: Value, who: String) raises -> FloatFormat:
    """The format of a FLOAT value."""
    if v.kind != FLOAT:
        raise fail(who, "expected a float, got " + describe(v))
    return format_by_id(v.float_format_id())


def real_of(v: Value, who: String) raises -> Real:
    """An INT, REAL or FLOAT promoted to an extended real. A NaN raises."""
    if v.kind == INT:
        return Real(v.as_bigint())
    if v.kind == REAL:
        return Real(
            lowest_numerator=v.item(0).as_bigint(),
            lowest_denominator=v.item(1).as_bigint(),
        )
    if v.kind == FLOAT:
        var f = format_by_id(v.float_format_id())
        try:
            return to_real(f, v.float_bits())
        except:
            raise fail(who, "cannot promote a NaN (" + String(f) + " bits " + hex(v.float_bits()) + ")")
    raise fail(who, "expected a number, got " + describe(v))


def is_number(v: Value) -> Bool:
    return v.kind == INT or v.kind == REAL


def real_value(var r: Real) -> Value:
    return Value.real(r.numerator.copy(), r.denominator.copy())


def list_items(v: Value, who: String) raises -> List[Value]:
    if v.kind != LIST and v.kind != TUPLE:
        raise fail(who, "expected a list, got " + describe(v))
    var out = List[Value](capacity=v.count())
    for i in range(v.count()):
        out.append(v.item(i))
    return out^
