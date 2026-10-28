"""draw_value: a value of any spec type a parameter can have."""

from check.types import TypeKind, Types
from mcheck.source import MANY_LABEL, Source
from value.float_formats import format_by_id
from value.value import Value

from .scalars import (
    Seq,
    draw_bytes,
    draw_float_bits,
    draw_int_value,
    draw_string,
    draw_unbounded_int,
)
from .sizes import Sizes


def is_flat(types: Types, t: Int) -> Bool:
    """Scalars, and tuples, options and records of them: what a long list holds."""
    ref info = types.info(t)
    match info.kind:
        case .LIST | .MAP:
            return False
        case .TUPLE | .OPTION | .RECORD:
            return all([is_flat(types, a) for a in info.args])
        case _:
            return True


def _draw_list(
    mut src: Source, types: Types, elem: Int, sizes: Sizes, depth: Int
) raises -> Value:
    var short = sizes.max_list if depth == 0 else sizes.max_inner
    if depth == 0 and is_flat(types, elem) and sizes.has_long(short, long=sizes.long_list):
        if src.draw_bool(sizes.long_share):
            return _draw_long_list(src, types, elem, sizes, short)
    var items: List[Value] = []
    var seq = Seq(0, short)
    while seq.more(src):
        items.append(draw_value(src, types, elem, sizes, depth + 1))
    return Value.list(items^)


def _draw_long_list(
    mut src: Source, types: Types, elem: Int, sizes: Sizes, short: Int
) raises -> Value:
    """A top-level list of `long_lo(short)` to `long_list` elements, each a copy of one
    of a few drawn values.

    Every element carries its own continue flag, so deleting an element's span
    shortens the list (down to the long minimum)."""
    var lo = sizes.long_lo(short)
    var palette: List[Value] = []
    var palette_seq = Seq(0, lo)
    while palette_seq.more(src):
        palette.append(draw_value(src, types, elem, sizes, 1))
    if not palette:
        palette.append(draw_value(src, types, elem, sizes, 1))
    var n = src.draw_int(lo, sizes.long_list)
    var items: List[Value] = []
    while len(items) < sizes.long_list:
        src.start_span(MANY_LABEL)
        if not src.draw_bool(1.0 if len(items) < n else 0.0):
            src.stop_span()
            break
        items.append(palette[src.draw_choice(len(palette))].copy())
        src.stop_span()
    if len(items) < lo:
        src.reject()
    return Value.list(items^)


def _draw_map(
    mut src: Source, types: Types, key_type: Int, value_type: Int, sizes: Sizes, depth: Int
) raises -> Value:
    var keys: List[Value] = []
    var values: List[Value] = []
    var seq = Seq(0, sizes.max_list if depth == 0 else sizes.max_inner)
    while seq.more(src):
        var key = draw_value(src, types, key_type, sizes, depth + 1)
        var value = draw_value(src, types, value_type, sizes, depth + 1)
        if key not in keys:
            keys.append(key^)
            values.append(value^)
    return Value.map(keys^, values^)


def _draw_inner(
    mut src: Source, types: Types, t: Int, sizes: Sizes, depth: Int
) raises -> Value:
    ref info = types.info(t)
    match info.kind:
        case .BOOL:
            return Value.bool(src.draw_bool())
        case .INT:
            return draw_unbounded_int(src)
        case .FIXED_INT:
            return draw_int_value(src, info.bits, info.signed)
        case .FLOAT:
            var format = format_by_id(UInt8(info.bits))
            return Value.float(format, draw_float_bits(src, format))
        case .STRING:
            return draw_string(src, sizes, depth)
        case .BYTES:
            return draw_bytes(src, sizes, depth)
        case .LIST:
            return _draw_list(src, types, info.args[0], sizes, depth)
        case .MAP:
            return _draw_map(src, types, info.args[0], info.args[1], sizes, depth)
        case .TUPLE:
            return Value.tuple([draw_value(src, types, a, sizes, depth + 1) for a in info.args])
        case .OPTION:
            if src.draw_bool(0.75):
                return Value.some(draw_value(src, types, info.args[0], sizes, depth + 1))
            return Value.none()
        case .LITERAL | .ENUM:
            var name = info.name if info.kind == .ENUM else String()
            return Value.enum(name, info.names[src.draw_choice(len(info.names))])
        case .RECORD:
            var fields = [draw_value(src, types, a, sizes, depth + 1) for a in info.args]
            return Value.record(info.name, info.names, fields^)
        case _:
            raise Error(t"gen: no values of type {types.text(t)}")


def draw_value(
    mut src: Source, types: Types, t: Int, sizes: Sizes, depth: Int
) raises -> Value:
    """A value of type `t`. `depth` is 0 for a top-level value (an argument), where long
    lists, strings and bytes can occur, and grows with nesting.

    Types with no values drawn here (sets, models, type variables, reals, unit)
    raise; models go through `draw_model`.
    """
    var kind = types.kind(t)
    if kind in [TypeKind.BOOL, TypeKind.INT, TypeKind.FIXED_INT, TypeKind.FLOAT, TypeKind.LITERAL, TypeKind.ENUM]:
        # one or two choices: a span would repeat the element's own
        return _draw_inner(src, types, t, sizes, depth)
    src.start_span(Int(kind))
    var v = _draw_inner(src, types, t, sizes, depth)
    src.stop_span()
    return v^
