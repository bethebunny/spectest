"""Steering by partition classes."""

from check.types import (
    Types,
    BOOL as T_BOOL,
    FIXED_INT as T_FIXED_INT,
    FLOAT as T_FLOAT,
)
from mcheck.source import Source
from numeric.formats import format_by_id
from sets import BitSet, SetContext
from wire.value import Value
from bigint import BigUInt

from .scalars import int_value


def fixed_value(types: Types, t: Int, bits: UInt64) raises -> Value:
    """The value of fixed-width type `t` with bit pattern `bits`."""
    ref info = types.info(t)
    if info.kind == T_BOOL:
        return Value.bool(bits != 0)
    if info.kind == T_FIXED_INT:
        return int_value(bits, info.bits, info.signed)
    if info.kind == T_FLOAT:
        return Value.float(format_by_id(UInt8(info.bits)), bits)
    raise Error("gen: " + types.text(t) + " is not a fixed-width type")


def draw_in_classes(
    mut src: Source,
    mut ctx: SetContext,
    types: Types,
    classes: List[BitSet],
    elem: Int,
) raises -> Value:
    """A value of the fixed-width type `elem`: a non-empty class uniformly, then a
    member of it through `nth` with a uniform index, so each member of a class is as
    likely as any other (-0 as a normal float). Raises when every class is empty."""
    var live = List[Int]()
    for i in range(len(classes)):
        if not ctx.is_empty(classes[i]):
            live.append(i)
    if len(live) == 0:
        raise Error("gen: every class is empty")
    var chosen = classes[live[Int(src.draw_below(UInt64(len(live))))]]
    var count = ctx.count(chosen).uint64_or_none()
    var index: UInt64
    if count:
        index = src.draw_below(count.value())
    else:
        # 2**64 members: the whole 64-bit type.
        index = src.draw_bits(64)
    return fixed_value(types, elem, ctx.nth(chosen, BigUInt(index)))
