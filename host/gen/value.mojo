"""draw_value: a value of any spec type a parameter can have."""

from check.types import (
    Types,
    BOOL as T_BOOL,
    INT as T_INT,
    FIXED_INT as T_FIXED_INT,
    FLOAT as T_FLOAT,
    STRING as T_STRING,
    BYTES as T_BYTES,
    LIST as T_LIST,
    MAP as T_MAP,
    TUPLE as T_TUPLE,
    OPTION as T_OPTION,
    LITERAL as T_LITERAL,
    ENUM as T_ENUM,
    RECORD as T_RECORD,
)
from mcheck.source import Source, MANY_LABEL
from numeric.formats import format_by_id
from wire.value import Value

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
    var k = info.kind
    if k == T_LIST or k == T_MAP:
        return False
    return not (k == T_TUPLE or k == T_OPTION or k == T_RECORD) or all([is_flat(types, a) for a in info.args])


def _draw_list(
    mut src: Source, types: Types, elem: Int, sizes: Sizes, depth: Int
) raises -> Value:
    var short = sizes.max_list if depth == 0 else sizes.max_inner
    var items = List[Value]()
    if depth == 0 and is_flat(types, elem) and sizes.has_long(short, long=sizes.long_list):
        if src.draw_bool(sizes.long_share):
            # Every element carries its own continue flag, so deleting an element's
            # span shortens the list (down to the long minimum).
            var lo = sizes.long_lo(short)
            var palette = List[Value]()
            var pal = Seq(0, lo)
            while pal.more(src):
                palette.append(draw_value(src, types, elem, sizes, depth + 1))
            if len(palette) == 0:
                palette.append(draw_value(src, types, elem, sizes, depth + 1))
            var n = src.draw_int(lo, sizes.long_list)
            while len(items) < sizes.long_list:
                src.start_span(MANY_LABEL)
                if not src.draw_bool(1.0 if len(items) < n else 0.0):
                    src.stop_span()
                    break
                items.append(palette[Int(src.draw_below(UInt64(len(palette))))].copy())
                src.stop_span()
            if len(items) < lo:
                src.reject()
            return Value.list(items^)
    var seq = Seq(0, short)
    while seq.more(src):
        items.append(draw_value(src, types, elem, sizes, depth + 1))
    return Value.list(items^)


def _draw_map(
    mut src: Source, types: Types, key: Int, val: Int, sizes: Sizes, depth: Int
) raises -> Value:
    var keys = List[Value]()
    var vals = List[Value]()
    var seq = Seq(0, sizes.max_list if depth == 0 else sizes.max_inner)
    while seq.more(src):
        var k = draw_value(src, types, key, sizes, depth + 1)
        var v = draw_value(src, types, val, sizes, depth + 1)
        if k not in keys:
            keys.append(k^)
            vals.append(v^)
    return Value.map(keys^, vals^)


def _draw_items(
    mut src: Source, types: Types, elems: List[Int], sizes: Sizes, depth: Int
) raises -> List[Value]:
    var items = List[Value]()
    for elem in elems:
        items.append(draw_value(src, types, elem, sizes, depth + 1))
    return items^


def _draw_inner(
    mut src: Source, types: Types, t: Int, sizes: Sizes, depth: Int
) raises -> Value:
    ref info = types.info(t)
    var k = info.kind
    if k == T_BOOL:
        return Value.bool(src.draw_bool())
    if k == T_INT:
        return draw_unbounded_int(src)
    if k == T_FIXED_INT:
        return draw_int_value(src, info.bits, info.signed)
    if k == T_FLOAT:
        var f = format_by_id(UInt8(info.bits))
        return Value.float(f, draw_float_bits(src, f))
    if k == T_STRING:
        return draw_string(src, sizes, depth)
    if k == T_BYTES:
        return draw_bytes(src, sizes, depth)
    if k == T_LIST:
        return _draw_list(src, types, info.args[0], sizes, depth)
    if k == T_MAP:
        return _draw_map(src, types, info.args[0], info.args[1], sizes, depth)
    if k == T_TUPLE:
        return Value.tuple(_draw_items(src, types, info.args, sizes, depth))
    if k == T_OPTION:
        if src.draw_bool(0.75):
            return Value.some(draw_value(src, types, info.args[0], sizes, depth + 1))
        return Value.none()
    if k == T_LITERAL or k == T_ENUM:
        return Value.enum(info.name if k == T_ENUM else String(), info.names[src.draw_choice(len(info.names))])
    if k == T_RECORD:
        return Value.record(info.name, info.names, _draw_items(src, types, info.args, sizes, depth))
    raise Error(t"gen: no values of type {types.text(t)}")


def draw_value(
    mut src: Source, types: Types, t: Int, sizes: Sizes, depth: Int
) raises -> Value:
    """A value of type `t`. `depth` is 0 for a top-level value (an argument), where long
    lists, strings and bytes can occur, and grows with nesting.

    Types with no values drawn here (sets, models, type variables, reals, unit)
    raise; models go through `draw_model`.
    """
    var k = types.kind(t)
    if k in [T_BOOL, T_INT, T_FIXED_INT, T_FLOAT, T_LITERAL, T_ENUM]:
        # one or two choices: a span would repeat the element's own
        return _draw_inner(src, types, t, sizes, depth)
    src.start_span(Int(k))
    var v = _draw_inner(src, types, t, sizes, depth)
    src.stop_span()
    return v^
