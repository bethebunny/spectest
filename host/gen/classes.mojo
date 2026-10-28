"""Steering by partition classes."""

import check.types as ty
from check.types import Types
from eval.coerce import value_from_bits
from mcheck.source import Source
from sets import BitSet, SetContext
from wire.value import Value


def fixed_value(types: Types, t: Int, bits: UInt64) raises -> Value:
    """The value of fixed-width type `t` with bit pattern `bits`."""
    if types.kind(t) not in [ty.BOOL, ty.FIXED_INT, ty.FLOAT]:
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
    var live = [c for c in classes if not ctx.is_empty(c)]
    if not live:
        raise Error("gen: every class is empty")
    var chosen = live[src.draw_choice(len(live))]
    var count = ctx.count(chosen)
    # past UInt64 is 2**64 members: the whole 64-bit type
    var index = src.draw_below(UInt64(count)) if count <= UInt128(UInt64.MAX) else src.draw_bits(64)
    return fixed_value(types, elem, ctx.nth(chosen, index))
