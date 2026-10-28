"""Steering by partition classes."""

from mcheck.source import Source
from partition.sets import BitSet, SetContext
from spec.bits import value_from_bits
from spec.types import Types
from value.value import Value


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
    return value_from_bits(types, elem, ctx.nth(chosen, index))
