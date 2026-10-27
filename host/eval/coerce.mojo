"""Values made exact for the types of the parameters they are passed to, and the bit
patterns of fixed-width values."""

from check import types as ty
from numeric.bigint import BigInt
from numeric.fixed import int_max, int_min, pattern_of, signed_of
from numeric.floats import exactly, is_nan, is_zero, round_to, signbit, to_real
from numeric.formats import FloatFormat, format_by_id
from numeric.real import Real
from wire.value import Value

from .numbers import real_of, show, to_real_kind


def needs_exact(types: ty.Types, t: Int) -> Bool:
    """Do values of type t hold fixed-width integers or floats?"""
    var k = types.kind(t)
    if k == ty.FIXED_INT or k == ty.FLOAT:
        return True
    if k == ty.LIST or k == ty.OPTION or k == ty.MAP or k == ty.TUPLE or k == ty.RECORD:
        return any([needs_exact(types, a) for a in types.info(t).args])
    return False


def _to_int(v: Value, width: Int, signed: Bool, what: String) raises -> Value:
    var type_name = String("i" if signed else "u", width)
    var n: BigInt
    if v.kind == .INT:
        n = v.as_bigint()
    elif v.kind == .REAL and v.item(1).as_bigint() == BigInt(1):
        n = v.item(0).as_bigint()
    else:
        raise Error(t"{what}: expected an integer for {type_name}, got {show(v)}")
    if n < int_min(width, signed) or int_max(width, signed) < n:
        raise Error(t"{what}: {n} is out of range for {type_name}")
    return Value.int(n^)


def _inexact(what: String, v: Value, f: FloatFormat) -> Error:
    return Error(t"{what}: {show(v)} is not exactly representable as {f}")


def _to_float(v: Value, f: FloatFormat, what: String) raises -> Value:
    var r: Real
    if v.kind == .FLOAT:
        var src = format_by_id(v.float_format_id())
        if src == f:
            return v.copy()
        var bits = v.float_bits()
        if is_nan(src, bits):
            raise _inexact(what, v, f)
        if is_zero(src, bits):
            return Value.float(f, f.sign_mask() if signbit(src, bits) else UInt64(0))
        r = to_real(src, bits)
    elif v.kind == .INT or v.kind == .REAL:
        r = real_of(v)
    else:
        raise Error(t"{what}: expected a number for {f}, got {show(v)}")
    if r.is_inf():
        return Value.float(f, round_to(f, r))
    var found = exactly(f, r)
    if found is None:
        raise _inexact(what, v, f)
    return Value.float(f, found.value())


def coerce_arg(types: ty.Types, v: Value, t: Int, what: String) raises -> Value:
    """`v` as an argument of type `t`: fixed-width ints in range, floats exact."""
    if not needs_exact(types, t):
        return v.copy()
    ref info = types.info(t)
    var k = info.kind
    if k == ty.FIXED_INT:
        return _to_int(v, info.bits, info.signed, what)
    if k == ty.FLOAT:
        return _to_float(v, format_by_id(UInt8(info.bits)), what)
    if k == ty.LIST and v.kind == .LIST:
        return Value.list([coerce_arg(types, v.item(i), info.args[0], what) for i in range(v.count())])
    if k == ty.OPTION and v.kind == .OPTION:
        return v.copy() if v.count() == 0 else Value.some(coerce_arg(types, v.item(0), info.args[0], what))
    if k == ty.TUPLE and v.kind == .TUPLE and v.count() == len(info.args):
        return Value.tuple([coerce_arg(types, v.item(i), info.args[i], what) for i in range(v.count())])
    if k == ty.MAP and v.kind == .MAP:
        return Value.map(
            [coerce_arg(types, v.item(2 * i), info.args[0], what) for i in range(v.count())],
            [coerce_arg(types, v.item(2 * i + 1), info.args[1], what) for i in range(v.count())],
        )
    if k == ty.RECORD and v.kind == .RECORD:
        var names: List[String] = []
        var vals: List[Value] = []
        for i in range(v.count()):
            var field = v.item(2 * i).text().copy()
            var item = v.item(2 * i + 1)
            vals.append(coerce_arg(types, item, info.args[info.names.index(field)], what) if field in info.names else item.copy())
            names.append(field^)
        return Value.record(v.name().copy(), names, vals^)
    return v.copy()


def has_real(types: ty.Types, t: Int) -> Bool:
    var k = types.kind(t)
    if k == ty.REAL:
        return True
    if k == ty.LIST or k == ty.OPTION or k == ty.MAP or k == ty.TUPLE:
        return any([has_real(types, a) for a in types.info(t).args])
    return False


def fit(types: ty.Types, v: Value, t: Int) -> Value:
    """`v` with integers where `t` expects a `real` made REAL."""
    var k = types.kind(t)
    if k == ty.REAL:
        return to_real_kind(v)
    if not has_real(types, t):
        return v.copy()
    ref info = types.info(t)
    try:
        if k == ty.LIST and v.kind == .LIST:
            return Value.list([fit(types, v.item(i), info.args[0]) for i in range(v.count())])
        if k == ty.OPTION and v.kind == .OPTION and v.count() == 1:
            return Value.some(fit(types, v.item(0), info.args[0]))
        if k == ty.TUPLE and v.kind == .TUPLE and v.count() == len(info.args):
            return Value.tuple([fit(types, v.item(i), info.args[i]) for i in range(v.count())])
        if k == ty.MAP and v.kind == .MAP:
            return Value.map(
                [fit(types, v.item(2 * i), info.args[0]) for i in range(v.count())],
                [fit(types, v.item(2 * i + 1), info.args[1]) for i in range(v.count())],
            )
    except:
        pass
    return v.copy()


# Bit patterns


def int_from_bits(bits: UInt64, width: Int, signed: Bool) -> Value:
    return Value.int(signed_of(bits, width)) if signed else Value.int(BigInt(bits))


def value_from_bits(types: ty.Types, t: Int, bits: UInt64) raises -> Value:
    """The value of fixed-width type `t` with bit pattern `bits`."""
    ref info = types.info(t)
    if info.kind == ty.BOOL:
        return Value.bool(bits != 0)
    if info.kind == ty.FIXED_INT:
        return int_from_bits(bits, info.bits, info.signed)
    if info.kind == ty.FLOAT:
        return Value.float(format_by_id(UInt8(info.bits)), bits)
    raise Error(t"{types.text(t)} is not a fixed-width type")


def bits_of_value(types: ty.Types, t: Int, v: Value) raises -> UInt64:
    """The bit pattern of a value of fixed-width type `t`."""
    ref info = types.info(t)
    if info.kind == ty.BOOL:
        return UInt64(1) if v.as_bool() else UInt64(0)
    if info.kind == ty.FLOAT:
        if v.kind != .FLOAT:
            raise Error(t"expected a float, got {show(v)}")
        return v.float_bits()
    if info.kind == ty.FIXED_INT:
        if v.kind != .INT:
            raise Error(t"expected an integer, got {show(v)}")
        var n = v.as_bigint()
        if n.magnitude.bits() > 64:
            raise Error(t"{show(v)} does not fit {types.text(t)}")
        return pattern_of(n, info.bits)
    raise Error(t"{types.text(t)} is not a fixed-width type")
