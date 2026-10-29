"""Values made exact for the types of the parameters they are passed to, and the bit
patterns of fixed-width values."""

from spec import types as ty
from value.fixed import int_max, int_min, pattern_of
from value.float_formats import FloatFormat, format_by_id
from value.floats import converted, exactly, is_nan
from value.value import Value

from .numbers import integer_of, real_of, show, to_real_kind


def needs_exact(types: ty.Types, t: Int) -> Bool:
    """Do values of type t hold fixed-width integers or floats?"""
    match types.kind(t):
        case .FixedInt | .Float:
            return True
        case .List | .Option | .Map | .Tuple | .Record:
            return any([needs_exact(types, arg) for arg in types.info(t).args])
        case _:
            return False


def _to_int(types: ty.Types, t: Int, v: Value, what: String) raises -> Value:
    ref info = types.info(t)
    var n = integer_of(v)
    if n is None:
        raise Error(t"{what}: expected an integer for {types.text(t)}, got {show(v)}")
    if n.value() < int_min(info.bits, info.signed) or int_max(info.bits, info.signed) < n.value():
        raise Error(t"{what}: {n.value()} is out of range for {types.text(t)}")
    return Value.int(n.take())


def _inexact(what: String, v: Value, f: FloatFormat) -> Error:
    return Error(t"{what}: {show(v)} is not exactly representable as {f}")


def _to_float(v: Value, f: FloatFormat, what: String) raises -> Value:
    var found: Optional[UInt64]
    match v.kind:
        case .Float:
            var source = v.float_format()
            if source == f:
                return v.copy()
            if is_nan(source, v.float_bits()):
                raise _inexact(what, v, f)
            found = converted(source, f, v.float_bits())
        case .Int | .Real:
            found = exactly(f, real_of(v))
        case _:
            raise Error(t"{what}: expected a number for {f}, got {show(v)}")
    if case .Some(bits) = found:
        return Value.float(f, bits)
    raise _inexact(what, v, f)


def coerce_arg(types: ty.Types, v: Value, t: Int, what: String) raises -> Value:
    """`v` as an argument of type `t`: fixed-width ints in range, floats exact."""
    if not needs_exact(types, t):
        return v.copy()
    ref info = types.info(t)
    match info.kind:
        case .FixedInt:
            return _to_int(types, t, v, what)
        case .Float:
            return _to_float(v, format_by_id(UInt8(info.bits)), what)
        case .List if v.kind == .List:
            return Value.list([coerce_arg(types, item, info.args[0], what) for item in v.items()])
        case .Option if v.kind == .Option and v.count() == 1:
            return Value.some(coerce_arg(types, v.item(0), info.args[0], what))
        case .Tuple if v.kind == .Tuple and v.count() == len(info.args):
            return Value.tuple([coerce_arg(types, item, arg, what) for item, arg in zip(v.items(), info.args)])
        case .Map if v.kind == .Map:
            return Value.map(
                [coerce_arg(types, key, info.args[0], what) for key in v.keys()],
                [coerce_arg(types, value, info.args[1], what) for value in v.values()],
            )
        case .Record if v.kind == .Record:
            var names: List[String] = []
            var values: List[Value] = []
            for name, value in v.pairs():
                names.append(name.text().copy())
                if case .Some(field) = info.names.try_index(name.text()):
                    values.append(coerce_arg(types, value, info.args[field], what))
                else:
                    values.append(value.copy())
            return Value.record(v.name().copy(), names, values^)
        case _:
            return v.copy()


def has_real(types: ty.Types, t: Int) -> Bool:
    """Do values of type t hold reals, outside records?"""
    match types.kind(t):
        case .Real:
            return True
        case .List | .Option | .Map | .Tuple:
            return any([has_real(types, arg) for arg in types.info(t).args])
        case _:
            return False


def fit(types: ty.Types, v: Value, t: Int) -> Value:
    """`v` with integers where `t` expects a `real` made Real."""
    var k = types.kind(t)
    if k == .Real:
        return to_real_kind(v)
    if not has_real(types, t):
        return v.copy()
    ref info = types.info(t)
    match k:
        case .List if v.kind == .List:
            return Value.list([fit(types, item, info.args[0]) for item in v.items()])
        case .Option if v.kind == .Option and v.count() == 1:
            return Value.some(fit(types, v.item(0), info.args[0]))
        case .Tuple if v.kind == .Tuple and v.count() == len(info.args):
            return Value.tuple([fit(types, item, arg) for item, arg in zip(v.items(), info.args)])
        case .Map if v.kind == .Map:
            try:
                return Value.map(
                    [fit(types, key, info.args[0]) for key in v.keys()],
                    [fit(types, value, info.args[1]) for value in v.values()],
                )
            except:
                # Keys made Real can collide, eg. the int 1 and the real 1.
                return v.copy()
        case _:
            return v.copy()


# Bit patterns


def bits_of_value(types: ty.Types, t: Int, v: Value) raises -> UInt64:
    """The bit pattern of a value of fixed-width type `t`."""
    ref info = types.info(t)
    match info.kind:
        case .Bool:
            return UInt64(1) if v.as_bool() else UInt64(0)
        case .Float:
            if v.kind != .Float:
                raise Error(t"expected a float, got {show(v)}")
            return v.float_bits()
        case .FixedInt:
            if v.kind != .Int:
                raise Error(t"expected an integer, got {show(v)}")
            var n = v.as_bigint()
            if n.magnitude.bits() > 64:
                raise Error(t"{show(v)} does not fit {types.text(t)}")
            return pattern_of(n, info.bits)
        case _:
            raise Error(t"{types.text(t)} is not a fixed-width type")
