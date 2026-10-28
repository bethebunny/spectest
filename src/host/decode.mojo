"""Typed reading of values the driver returned, and preparing arguments.

The driver's wire objects are untyped. `decode` reads one against the type the spec
declares, as v1's binding did; a value that doesn't fit raises, and the runner charges
that to the `#type` clause."""

from spec import types as ty
from spec.types import Types
from value.fixed import int_max, int_min, low_mask
from value.float_formats import FloatFormat, format_by_id
from value.floats import converted, is_nan, signbit
from value.text import format_value
from value.value import Kind, Value

from .util import norm_name


def describe(v: Value) -> String:
    """A value for a mismatch message: its kind and, when short, its text."""
    try:
        var text = format_value(v)
        return String(v.kind, " ", text) if text.byte_length() <= 60 else String(v.kind)
    except:
        return String(v.kind)


def _mismatch(types: Types, t: Int, v: Value, path: String, extra: String = "") -> Error:
    var tail = String(" (", extra, ")") if extra else String()
    var at = String(" at ", path) if path else String()
    return Error(t"expected {types.text(t)}, got {describe(v)}{tail}{at}")


def _scalar(types: Types, v: Value, t: Int, path: String, kind: Kind) raises -> Value:
    if v.kind != kind:
        raise _mismatch(types, t, v, path)
    return v.copy()


def _float(types: Types, v: Value, t: Int, f: FloatFormat, path: String) raises -> Value:
    if v.kind != .FLOAT:
        raise _mismatch(types, t, v, path)
    var src = v.float_format()
    if src == f:
        return v.copy()
    var bits = v.float_bits()
    if not is_nan(src, bits):
        if case .Some(exact) = converted(src, f, bits):
            return Value.float(f, exact)
        raise _mismatch(types, t, v, path, String("not exact in ", f))
    # A NaN keeps its sign and payload when the narrower format can hold them.
    var payload = bits & src.fraction_mask()
    var sign = f.sign_mask() if signbit(src, bits) else UInt64(0)
    var drop = src.fraction_bits - f.fraction_bits
    if drop < 0:
        return Value.float(f, f.exponent_mask() | payload << UInt64(-drop) | sign)
    var kept = payload >> UInt64(drop)
    if payload & low_mask(drop) != 0 or kept == 0:
        raise _mismatch(types, t, v, path, "a NaN payload the format cannot hold")
    return Value.float(f, f.exponent_mask() | kept | sign)


def _record(types: Types, v: Value, t: Int, path: String) raises -> Value:
    """A record from `Record` or from a map with exactly the fields."""
    ref info = types.info(t)
    var values: List[Optional[Value]] = [None for _ in info.names]
    for key, value in v.pairs():
        if v.kind == .MAP and key.kind != .STRING:
            raise _mismatch(types, t, v, path, "a field name is not a string")
        ref name = key.text()
        var at = info.names.try_index(name)
        if at is None:
            raise _mismatch(types, t, v, path, String("no field ", name))
        values[at.value()] = _decode(value, info.args[at.value()], types, String(path, ".", name))
    for name, value in zip(info.names, values):
        if value is None:
            raise _mismatch(types, t, v, path, String("missing field ", name))
    return Value.record(info.name.copy(), info.names, [value.value().copy() for value in values])


def _decode(v: Value, t: Int, types: Types, path: String) raises -> Value:
    ref info = types.info(t)
    match info.kind:
        case .ANY | .TYPEVAR:
            return v.copy()
        case .UNIT:
            return Value.none()
        case .BOOL:
            return _scalar(types, v, t, path, .BOOL)
        case .INT:
            return _scalar(types, v, t, path, .INT)
        case .STRING:
            return _scalar(types, v, t, path, .STRING)
        case .BYTES:
            return _scalar(types, v, t, path, .BYTES)
        case .FIXED_INT:
            if v.kind != .INT:
                raise _mismatch(types, t, v, path)
            var low = int_min(info.bits, info.signed)
            var high = int_max(info.bits, info.signed)
            var n = v.as_bigint()
            if n < low or high < n:
                raise _mismatch(types, t, v, path, String("outside the ", types.text(t), " range ", low, "..", high))
            return v.copy()
        case .FLOAT:
            return _float(types, v, t, format_by_id(UInt8(info.bits)), path)
        case .LIST:
            if v.kind != .LIST and v.kind != .TUPLE:
                raise _mismatch(types, t, v, path)
            return Value.list([_decode(item, info.args[0], types, String(path, "[", i, "]")) for i, item in enumerate(v.items())])
        case .TUPLE:
            if (v.kind != .TUPLE and v.kind != .LIST) or v.count() != len(info.args):
                raise _mismatch(types, t, v, path)
            return Value.tuple([_decode(v.item(i), arg, types, String(path, ".", i)) for i, arg in enumerate(info.args)])
        case .MAP:
            if v.kind != .MAP:
                raise _mismatch(types, t, v, path)
            var keys: List[Value] = []
            var values: List[Value] = []
            for key, value in v.pairs():
                keys.append(_decode(key, info.args[0], types, path + "{key}"))
                values.append(_decode(value, info.args[1], types, path + "{value}"))
            return Value.map(keys^, values^)
        case .OPTION:
            if v.kind != .OPTION:
                return Value.some(_decode(v, info.args[0], types, path))
            if v.count() == 0:
                return Value.none()
            return Value.some(_decode(v.item(0), info.args[0], types, path))
        case .LITERAL | .ENUM:
            if v.kind != .STRING and v.kind != .ENUM:
                raise _mismatch(types, t, v, path)
            var member = v.text().copy()
            if info.kind == .LITERAL:
                if member not in info.names:
                    raise _mismatch(types, t, v, path, "not a member of the union")
                return Value.enum(String(), member^)
            if v.kind == .ENUM and v.name() != "" and norm_name(v.name()) != norm_name(info.name):
                raise _mismatch(types, t, v, path, String("an enum of ", v.name()))
            if member not in info.names:
                raise _mismatch(types, t, v, path, String(member, " is not a member"))
            return Value.enum(info.name.copy(), member^)
        case .RECORD:
            if v.kind != .RECORD and v.kind != .MAP:
                raise _mismatch(types, t, v, path)
            return _record(types, v, t, path)
        case .MODEL:
            if v.kind != .HANDLE:
                raise _mismatch(types, t, v, path)
            # A qualified model names a Python class; a handle of another class is not one.
            if "." in info.name and norm_name(v.name()) != norm_name(info.name):
                raise _mismatch(types, t, v, path, String("a handle of class ", v.name()))
            return v.copy()
        case _:
            raise Error(t"a result of type {types.text(t)} cannot be read")


def decode(value: Value, t: Int, types: Types) raises -> Value:
    """`value`, a wire value the driver returned, read as a value of type `t`.

    - `None` is an option's none, and a present option is wrapped;
    - records come from `Record` or from a map with exactly the fields;
    - enums and string-literal unions come from `Enum` or from strings;
    - fixed-width integers are range-checked;
    - a float of a wider format for an `f32`, `f16` or `bf16` result is accepted when
      exact in that format;
    - a handle's class is checked against its model when the model is qualified.

    Raises a message that says what was expected and where when the value doesn't fit.
    """
    return _decode(value, t, types, "")


def encode(value: Value, t: Int, types: Types) raises -> Value:
    """`value` checked to have the shape of an argument of type `t` (the wire form is the value)."""
    return _decode(value, t, types, "")
