"""Values made exact for the types of the parameters they are passed to, and the bit
patterns of fixed-width values."""

from std.memory import bitcast

from bigint import BigUInt
from check import types as ty
from numeric.bigint import BigInt
from numeric.floats import exactly, is_nan, is_zero, round_to, signbit, to_real
from numeric.formats import FloatFormat, format_by_id
from wire.value import (
    Value,
    BOOL,
    INT,
    FLOAT,
    LIST,
    TUPLE,
    MAP,
    OPTION,
    RECORD,
    REAL,
)

from .numbers import real_of, show, to_real_kind


def needs_exact(types: ty.Types, t: Int) -> Bool:
    """Do values of type t hold fixed-width integers or floats?"""
    var k = types.kind(t)
    if k == ty.FIXED_INT or k == ty.FLOAT:
        return True
    if k == ty.LIST or k == ty.OPTION or k == ty.MAP or k == ty.TUPLE or k == ty.RECORD:
        for a in types.info(t).args:
            if needs_exact(types, a):
                return True
    return False


def int_min(width: Int, signed: Bool) -> BigInt:
    if not signed:
        return BigInt(0)
    return -BigInt(negative=False, magnitude=BigUInt(1) << (width - 1))


def int_max(width: Int, signed: Bool) -> BigInt:
    var bits = width - 1 if signed else width
    return BigInt(negative=False, magnitude=BigUInt(1) << bits) - BigInt(1)


def float_max(f: FloatFormat) -> UInt64:
    """The bit pattern of the largest finite value."""
    return f.exponent_mask() - 1


def _to_int(v: Value, width: Int, signed: Bool, what: String) raises -> Value:
    var n: BigInt
    if v.kind == INT:
        n = v.as_bigint()
    elif v.kind == REAL and v.item(1).as_bigint() == BigInt(1):
        n = v.item(0).as_bigint()
    else:
        raise Error(
            what + ": expected an integer for " + ("i" if signed else "u") + String(width) + ", got " + show(v)
        )
    if n < int_min(width, signed) or int_max(width, signed) < n:
        raise Error(
            what
            + ": "
            + String(n)
            + " is out of range for "
            + ("i" if signed else "u")
            + String(width)
        )
    return Value.int(n^)


def _to_float(v: Value, f: FloatFormat, what: String) raises -> Value:
    if v.kind == FLOAT:
        var src = format_by_id(v.float_format_id())
        if src == f:
            return v.copy()
        var bits = v.float_bits()
        if is_nan(src, bits):
            raise Error(what + ": " + show(v) + " is not exactly representable as " + String(f))
        if is_zero(src, bits):
            return Value.float(f, f.sign_mask() if signbit(src, bits) else UInt64(0))
        var r = to_real(src, bits)
        if r.is_inf():
            return Value.float(f, round_to(f, r))
        var found = exactly(f, r)
        if not found:
            raise Error(what + ": " + show(v) + " is not exactly representable as " + String(f))
        return Value.float(f, found.value())
    if v.kind == INT or v.kind == REAL:
        var r = real_of(v)
        if r.is_inf():
            return Value.float(f, round_to(f, r))
        var found = exactly(f, r)
        if not found:
            raise Error(what + ": " + show(v) + " is not exactly representable as " + String(f))
        return Value.float(f, found.value())
    raise Error(what + ": expected a number for " + String(f) + ", got " + show(v))


def coerce_arg(types: ty.Types, v: Value, t: Int, what: String) raises -> Value:
    """`v` as an argument of a parameter of type `t`: fixed-width integers must be
    integers in range, floats exactly representable (integers, reals and floats of
    other formats convert). Collections convert element by element."""
    if not needs_exact(types, t):
        return v.copy()
    ref info = types.info(t)
    var k = info.kind
    if k == ty.FIXED_INT:
        return _to_int(v, info.bits, info.signed, what)
    if k == ty.FLOAT:
        return _to_float(v, format_by_id(UInt8(info.bits)), what)
    if k == ty.LIST and v.kind == LIST:
        var out = List[Value](capacity=v.count())
        for i in range(v.count()):
            out.append(coerce_arg(types, v.item(i), info.args[0], what))
        return Value.list(out^)
    if k == ty.OPTION and v.kind == OPTION:
        if v.count() == 0:
            return v.copy()
        return Value.some(coerce_arg(types, v.item(0), info.args[0], what))
    if k == ty.TUPLE and v.kind == TUPLE and v.count() == len(info.args):
        var out = List[Value](capacity=v.count())
        for i in range(v.count()):
            out.append(coerce_arg(types, v.item(i), info.args[i], what))
        return Value.tuple(out^)
    if k == ty.MAP and v.kind == MAP:
        var keys = List[Value]()
        var vals = List[Value]()
        for i in range(v.count()):
            keys.append(coerce_arg(types, v.item(2 * i), info.args[0], what))
            vals.append(coerce_arg(types, v.item(2 * i + 1), info.args[1], what))
        return Value.map(keys^, vals^)
    if k == ty.RECORD and v.kind == RECORD:
        var names = List[String]()
        var vals = List[Value]()
        for i in range(v.count()):
            var field = v.item(2 * i).text().copy()
            var ft = -1
            for j in range(len(info.names)):
                if info.names[j] == field:
                    ft = info.args[j]
            var item = v.item(2 * i + 1)
            names.append(field^)
            vals.append(item^ if ft < 0 else coerce_arg(types, item, ft, what))
        return Value.record(v.name().copy(), names, vals^)
    return v.copy()


def has_real(types: ty.Types, t: Int) -> Bool:
    var k = types.kind(t)
    if k == ty.REAL:
        return True
    if k == ty.LIST or k == ty.OPTION or k == ty.MAP or k == ty.TUPLE:
        for a in types.info(t).args:
            if has_real(types, a):
                return True
    return False


def fit(types: ty.Types, v: Value, t: Int) -> Value:
    """`v` as a value of the static type `t`: integers where a `real` is expected become
    REAL values, so a `list<real>` holds only REALs."""
    var k = types.kind(t)
    if k == ty.REAL:
        return to_real_kind(v)
    if not has_real(types, t):
        return v.copy()
    ref info = types.info(t)
    try:
        if k == ty.LIST and v.kind == LIST:
            var out = List[Value](capacity=v.count())
            for i in range(v.count()):
                out.append(fit(types, v.item(i), info.args[0]))
            return Value.list(out^)
        if k == ty.OPTION and v.kind == OPTION and v.count() == 1:
            return Value.some(fit(types, v.item(0), info.args[0]))
        if k == ty.TUPLE and v.kind == TUPLE and v.count() == len(info.args):
            var out = List[Value](capacity=v.count())
            for i in range(v.count()):
                out.append(fit(types, v.item(i), info.args[i]))
            return Value.tuple(out^)
        if k == ty.MAP and v.kind == MAP:
            var keys = List[Value]()
            var vals = List[Value]()
            for i in range(v.count()):
                keys.append(fit(types, v.item(2 * i), info.args[0]))
                vals.append(fit(types, v.item(2 * i + 1), info.args[1]))
            return Value.map(keys^, vals^)
    except:
        pass
    return v.copy()


# Bit patterns


def int_from_bits(bits: UInt64, width: Int, signed: Bool) -> Value:
    if signed:
        var shift = 64 - width
        var wide = bitcast[DType.int64](bits << UInt64(shift))
        return Value.int(Int(wide >> Int64(shift)))
    if bits < (UInt64(1) << 63):
        return Value.int(Int(bits))
    return Value.int(BigInt(bits))


def value_from_bits(types: ty.Types, t: Int, bits: UInt64) raises -> Value:
    """The value of fixed-width type `t` with bit pattern `bits`."""
    ref info = types.info(t)
    if info.kind == ty.BOOL:
        return Value.bool(bits != 0)
    if info.kind == ty.FIXED_INT:
        return int_from_bits(bits, info.bits, info.signed)
    if info.kind == ty.FLOAT:
        return Value.float(format_by_id(UInt8(info.bits)), bits)
    raise Error(types.text(t) + " is not a fixed-width type")


def bits_of_value(types: ty.Types, t: Int, v: Value) raises -> UInt64:
    """The bit pattern of a value of fixed-width type `t`."""
    ref info = types.info(t)
    if info.kind == ty.BOOL:
        return UInt64(1) if v.as_bool() else UInt64(0)
    if info.kind == ty.FLOAT:
        if v.kind != FLOAT:
            raise Error("expected a float, got " + show(v))
        return v.float_bits()
    if info.kind == ty.FIXED_INT:
        if v.kind != INT:
            raise Error("expected an integer, got " + show(v))
        var small = v.small_int()
        var mask = ~UInt64(0) if info.bits == 64 else (UInt64(1) << UInt64(info.bits)) - 1
        if small:
            return UInt64(bitcast[DType.uint64](Int64(small.value()))) & mask
        var m = v.as_bigint().magnitude.uint64_or_none()
        if not m:
            raise Error(show(v) + " does not fit " + types.text(t))
        return m.value() & mask
    raise Error(types.text(t) + " is not a fixed-width type")
