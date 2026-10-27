"""Steering by partition classes."""

from bigint import BigUInt
from check.types import Types, BOOL as T_BOOL, FIXED_INT as T_FIXED_INT, FLOAT as T_FLOAT
from eval.coerce import value_from_bits
from mcheck.source import Source
from sets import BitSet, SetContext
from wire.value import Value


def fixed_value(types: Types, t: Int, bits: UInt64) raises -> Value:
    """The value of fixed-width type `t` with bit pattern `bits`."""
    var k = types.kind(t)
    if k != T_BOOL and k != T_FIXED_INT and k != T_FLOAT:
        raise Error(t"gen: {types.text(t)} is not a fixed-width type")
    return value_from_bits(types, t, bits)


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
    var live = [i for i in range(len(classes)) if not ctx.is_empty(classes[i])]
    if len(live) == 0:
        raise Error("gen: every class is empty")
    var chosen = classes[live[Int(src.draw_below(UInt64(len(live))))]]
    var count = ctx.count(chosen).uint64_or_none()
    # no count means 2**64 members: the whole 64-bit type
    var index = src.draw_below(count.value()) if count is not None else src.draw_bits(64)
    return fixed_value(types, elem, ctx.nth(chosen, BigUInt(index)))
