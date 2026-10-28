"""Small domains: types with at most 2**16 values, enumerated by index."""

from check.types import Types
from eval.coerce import value_from_bits
from wire.value import Value

comptime MAX_DOMAIN: UInt64 = 65536


def domain_size(types: Types, t: Int) -> Optional[UInt64]:
    """How many values type `t` has, when that is at most 2**16: `bool`, fixed-width
    integers of up to 16 bits, `f16` and `bf16`, enums and literal unions, options
    and tuples of these. None otherwise."""
    ref info = types.info(t)
    var n: UInt64
    match info.kind:
        case .BOOL:
            n = 2
        case .FIXED_INT:
            if info.bits > 16:
                return None
            n = UInt64(1) << UInt64(info.bits)
        case .FLOAT:
            if info.bits > 2:  # the format ids of f16 and bf16
                return None
            n = 65536
        case .LITERAL | .ENUM:
            n = UInt64(len(info.names))
        case .OPTION:
            var inner = domain_size(types, info.args[0])
            if inner is None:
                return None
            n = inner.value() + 1
        case .TUPLE:
            return product_size(types, info.args, limit=MAX_DOMAIN)
        case _:
            return None
    return n if n > 0 and n <= MAX_DOMAIN else None


def product_size(types: Types, elems: List[Int], *, limit: UInt64) -> Optional[UInt64]:
    """How many tuples of values of the types `elems` there are, when each has a small
    domain and there are at most `limit`."""
    var n: UInt64 = 1
    for t in elems:
        var size = domain_size(types, t)
        # stopping past `limit` keeps the product from overflowing
        if size is None or n > limit:
            return None
        n *= size.value()
    return n if n <= limit else None


def value_at(types: Types, t: Int, index: UInt64) raises -> Value:
    """The value of index `index` in `[0, domain_size)`. Every value has exactly one
    index. Integers and floats are their bit patterns; a tuple's last element varies
    fastest; an option's index 0 is none."""
    var size = domain_size(types, t)
    if size is None:
        raise Error(t"gen: {types.text(t)} has no small domain")
    if index >= size.value():
        raise Error(t"gen: index out of the domain of {types.text(t)}")
    ref info = types.info(t)
    match info.kind:
        case .BOOL | .FIXED_INT | .FLOAT:
            return value_from_bits(types, t, index)
        case .LITERAL | .ENUM:
            return Value.enum(info.name if info.kind == .ENUM else String(), info.names[Int(index)])
        case .OPTION:
            return Value.none() if index == 0 else Value.some(value_at(types, info.args[0], index - 1))
        case _:
            return Value.tuple(values_at(types, info.args, index))


def values_at(types: Types, elems: List[Int], index: UInt64) raises -> List[Value]:
    """The tuple of values of the types `elems` with index `index` in
    `[0, product_size)`, the last varying fastest."""
    var values: List[Value] = []
    var rest = index
    for t in reversed(elems):
        var size = domain_size(types, t).value()
        values.append(value_at(types, t, rest % size))
        rest //= size
    values.reverse()
    return values^
