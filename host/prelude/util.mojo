"""Shared helpers of the prelude functions: errors, and numbers as `Real`."""

from numeric.bigint import BigInt
from numeric.floats import to_real
from numeric.formats import FloatFormat, format_by_id
from numeric.real import Real
from wire.value import Value, INT, FLOAT, REAL, LIST, TUPLE


def fail[Message: Writable](who: String, message: Message) -> Error:
    return Error(t"{who}: {message}")


def codepoint_count(s: String) -> Int:
    var n = 0
    for b in s.as_bytes():
        n += 1 if (Int(b) & 0xC0) != 0x80 else 0
    return n


def int_of(v: Value, who: String) raises -> BigInt:
    if v.kind != INT:
        raise fail(who, t"expected an integer, got {v}")
    return v.as_bigint()


def float_of(v: Value, who: String) raises -> FloatFormat:
    if v.kind != FLOAT:
        raise fail(who, t"expected a float, got {v}")
    return format_by_id(v.float_format_id())


def real_of(v: Value, who: String) raises -> Real:
    """An INT, REAL or FLOAT as an extended real. A NaN raises."""
    if v.kind == INT:
        return Real(v.as_bigint())
    if v.kind == REAL:
        return Real(lowest_numerator=v.item(0).as_bigint(), lowest_denominator=v.item(1).as_bigint())
    if v.kind == FLOAT:
        var f = format_by_id(v.float_format_id())
        try:
            return to_real(f, v.float_bits())
        except:
            raise fail(who, t"cannot promote a NaN ({f} bits {hex(v.float_bits())})")
    raise fail(who, t"expected a number, got {v}")


def real_value(var r: Real) -> Value:
    return Value.real(r.numerator.copy(), r.denominator.copy())


def list_items(v: Value, who: String) raises -> List[Value]:
    if v.kind != LIST and v.kind != TUPLE:
        raise fail(who, t"expected a list, got {v}")
    return [v.item(i) for i in range(v.count())]
