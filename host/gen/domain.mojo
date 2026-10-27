"""Small domains: types with at most 2**16 values, enumerated by index."""

from check.types import (
    Types,
    BOOL as T_BOOL,
    FIXED_INT as T_FIXED_INT,
    FLOAT as T_FLOAT,
    TUPLE as T_TUPLE,
    OPTION as T_OPTION,
    LITERAL as T_LITERAL,
    ENUM as T_ENUM,
)
from numeric.formats import format_by_id
from mcheck.source import Source
from wire.value import Value

from .scalars import int_value

comptime MAX_DOMAIN: UInt64 = 65536


def domain_size(types: Types, t: Int) -> Optional[UInt64]:
    """How many values type `t` has, when that is at most 2**16: `bool`, fixed-width
    integers of up to 16 bits, `f16` and `bf16`, enums and literal unions, options
    and tuples of these. None otherwise."""
    ref info = types.info(t)
    var k = info.kind
    var n: UInt64
    if k == T_BOOL:
        n = 2
    elif k == T_FIXED_INT:
        if info.bits > 16:
            return None
        n = UInt64(1) << UInt64(info.bits)
    elif k == T_FLOAT:
        if info.bits > 2:
            return None
        n = 65536
    elif k == T_LITERAL or k == T_ENUM:
        n = UInt64(len(info.names))
    elif k == T_OPTION:
        var inner = domain_size(types, info.args[0])
        if not inner:
            return None
        n = inner.value() + 1
    elif k == T_TUPLE:
        n = 1
        for a in info.args:
            var inner = domain_size(types, a)
            if not inner:
                return None
            n *= inner.value()
            if n > MAX_DOMAIN:
                return None
    else:
        return None
    if n == 0 or n > MAX_DOMAIN:
        return None
    return n


def value_at(types: Types, t: Int, index: UInt64) raises -> Value:
    """The value of index `index` in `[0, domain_size)`. Every value has exactly one
    index. Integers and floats are their bit patterns; a tuple's last element varies
    fastest; an option's index 0 is none."""
    var size = domain_size(types, t)
    if not size:
        raise Error("gen: " + types.text(t) + " has no small domain")
    if index >= size.value():
        raise Error("gen: index out of the domain of " + types.text(t))
    ref info = types.info(t)
    var k = info.kind
    if k == T_BOOL:
        return Value.bool(index == 1)
    if k == T_FIXED_INT:
        return int_value(index, info.bits, info.signed)
    if k == T_FLOAT:
        return Value.float(format_by_id(UInt8(info.bits)), index)
    if k == T_LITERAL:
        return Value.enum(String(), info.names[Int(index)])
    if k == T_ENUM:
        return Value.enum(info.name, info.names[Int(index)])
    if k == T_OPTION:
        if index == 0:
            return Value.none()
        return Value.some(value_at(types, info.args[0], index - 1))
    var items = List[Value]()
    var rest = index
    for j in range(len(info.args) - 1, -1, -1):
        var s = domain_size(types, info.args[j]).value()
        items.append(value_at(types, info.args[j], rest % s))
        rest //= s
    items.reverse()
    return Value.tuple(items^)


def draw_small(mut src: Source, types: Types, t: Int) raises -> Value:
    """A value of a small domain, by a uniform index (shrinks toward index 0)."""
    var size = domain_size(types, t)
    if not size:
        raise Error("gen: " + types.text(t) + " has no small domain")
    return value_at(types, t, src.draw_below(size.value()))
