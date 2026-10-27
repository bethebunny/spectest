"""Typed reading of values the driver returned, and preparing arguments.

The driver's wire objects are untyped. `decode` reads one against the type the spec
declares, as v1's binding did; a value that doesn't fit raises, and the runner charges
that to the `#type` clause."""

from check import types as ty
from check.types import Types
from eval.coerce import int_max, int_min
from numeric.bigint import BigInt
from numeric.floats import exactly, is_nan, is_zero, round_to, signbit, to_real
from numeric.formats import FloatFormat, format_by_id
from .util import norm_name
from wire.format import format_value
from wire.value import Kind, Value


def describe(v: Value) -> String:
    """A value for a mismatch message: its kind and, when short, its text."""
    try:
        var text = format_value(v)
        return String(v.kind, " ", text) if text.byte_length() <= 60 else String(v.kind)
    except:
        return String(v.kind)


def _mismatch(types: Types, t: Int, v: Value, path: String, extra: String = "") -> Error:
    var at = String(" at ", path) if path else String()
    var tail = String(" (", extra, ")") if extra else String()
    return Error("expected ", types.text(t), ", got ", describe(v), tail, at)


def _float(
    types: Types, v: Value, t: Int, f: FloatFormat, path: String
) raises -> Value:
    if v.kind != .FLOAT:
        raise _mismatch(types, t, v, path)
    var src = format_by_id(v.float_format_id())
    if src == f:
        return v.copy()
    var bits = v.float_bits()
    if is_nan(src, bits):
        # A NaN keeps its sign and payload when the narrower format can hold them.
        var drop = src.fraction_bits - f.fraction_bits
        if drop < 0:
            return Value.float(
                f,
                (f.exponent_mask() | (bits & src.fraction_mask()) << UInt64(-drop))
                | (f.sign_mask() if signbit(src, bits) else UInt64(0)),
            )
        var payload = bits & src.fraction_mask()
        if payload & ((UInt64(1) << UInt64(drop)) - 1) != 0:
            raise _mismatch(types, t, v, path, "a NaN payload the format cannot hold")
        var kept = payload >> UInt64(drop)
        if kept == 0:
            raise _mismatch(types, t, v, path, "a NaN payload the format cannot hold")
        return Value.float(
            f,
            f.exponent_mask() | kept | (f.sign_mask() if signbit(src, bits) else UInt64(0)),
        )
    if is_zero(src, bits):
        return Value.float(f, f.sign_mask() if signbit(src, bits) else UInt64(0))
    var r = to_real(src, bits)
    if r.is_inf():
        return Value.float(f, round_to(f, r))
    var found = exactly(f, r)
    if not found:
        raise _mismatch(types, t, v, path, String("not exact in ", f))
    return Value.float(f, found.value())


def _record(
    types: Types, v: Value, t: Int, path: String, info_names: List[String], info_args: List[Int]
) raises -> Value:
    var values = [Value.none() for _ in info_names]
    var found = [False for _ in info_names]
    for i in range(v.count()):
        var key = v.item(2 * i)
        if v.kind == .MAP and key.kind != .STRING:
            raise _mismatch(types, t, v, path, "a field name is not a string")
        var name = key.text().copy()
        if name not in info_names:
            raise _mismatch(types, t, v, path, String("no field ", name))
        var at = info_names.index(name)
        values[at] = _decode(v.item(2 * i + 1), info_args[at], types, path + "." + name)
        found[at] = True
    for j, name in enumerate(info_names):
        if not found[j]:
            raise _mismatch(types, t, v, path, String("missing field ", name))
    return Value.record(types.info(t).name.copy(), info_names, values^)


def _decode(v: Value, t: Int, types: Types, path: String) raises -> Value:
    ref info = types.info(t)
    var k = info.kind
    if k == ty.ANY or k == ty.TYPEVAR:
        return v.copy()
    if k == ty.UNIT:
        return Value.none()
    if k == ty.BOOL or k == ty.INT or k == ty.STRING or k == ty.BYTES:
        var kind = Kind.BOOL if k == ty.BOOL else Kind.INT if k == ty.INT else Kind.STRING if k == ty.STRING else Kind.BYTES
        if v.kind != kind:
            raise _mismatch(types, t, v, path)
        return v.copy()
    if k == ty.FIXED_INT:
        if v.kind != .INT:
            raise _mismatch(types, t, v, path)
        var n = v.as_bigint()
        if n < int_min(info.bits, info.signed) or int_max(info.bits, info.signed) < n:
            raise _mismatch(
                types,
                t,
                v,
                path,
                String(
                    "outside the ", types.text(t), " range ",
                    int_min(info.bits, info.signed), "..", int_max(info.bits, info.signed),
                ),
            )
        return v.copy()
    if k == ty.FLOAT:
        return _float(types, v, t, format_by_id(UInt8(info.bits)), path)
    if k == ty.LIST:
        if v.kind != .LIST and v.kind != .TUPLE:
            raise _mismatch(types, t, v, path)
        var items = List[Value](capacity=v.count())
        for i in range(v.count()):
            items.append(_decode(v.item(i), info.args[0], types, String(path, "[", i, "]")))
        return Value.list(items^)
    if k == ty.TUPLE:
        if (v.kind != .TUPLE and v.kind != .LIST) or v.count() != len(info.args):
            raise _mismatch(types, t, v, path)
        var items = List[Value](capacity=v.count())
        for i in range(v.count()):
            items.append(_decode(v.item(i), info.args[i], types, String(path, ".", i)))
        return Value.tuple(items^)
    if k == ty.MAP:
        if v.kind != .MAP:
            raise _mismatch(types, t, v, path)
        var keys = List[Value]()
        var vals = List[Value]()
        for i in range(v.count()):
            keys.append(_decode(v.item(2 * i), info.args[0], types, path + "{key}"))
            vals.append(_decode(v.item(2 * i + 1), info.args[1], types, path + "{value}"))
        return Value.map(keys^, vals^)
    if k == ty.OPTION:
        if v.kind == .OPTION:
            if v.count() == 0:
                return Value.none()
            return Value.some(_decode(v.item(0), info.args[0], types, path))
        return Value.some(_decode(v, info.args[0], types, path))
    if k == ty.LITERAL or k == ty.ENUM:
        if v.kind != .STRING and v.kind != .ENUM:
            raise _mismatch(types, t, v, path)
        var member = v.text().copy()
        if k == ty.LITERAL:
            if member not in info.names:
                raise _mismatch(types, t, v, path, "not a member of the union")
            return Value.enum(String(), member^)
        if v.kind == .ENUM and v.name() != "" and norm_name(v.name()) != norm_name(info.name):
            raise _mismatch(types, t, v, path, String("an enum of ", v.name()))
        if member not in info.names:
            raise _mismatch(types, t, v, path, String(member, " is not a member"))
        return Value.enum(info.name.copy(), member^)
    if k == ty.RECORD:
        if v.kind != .RECORD and v.kind != .MAP:
            raise _mismatch(types, t, v, path)
        return _record(types, v, t, path, info.names, info.args)
    if k == ty.MODEL:
        if v.kind != .HANDLE:
            raise _mismatch(types, t, v, path)
        # A qualified model names a Python class; a handle of another class is not one.
        var cls = norm_name(v.name())
        if "." in info.name and cls != norm_name(info.name):
            raise _mismatch(types, t, v, path, String("a handle of class ", v.name()))
        return v.copy()
    raise Error(String("a result of type ", types.text(t), " cannot be read"))


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
