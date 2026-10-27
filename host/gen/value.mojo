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
from mcheck.source import Source, Many, MANY_LABEL
from numeric.formats import format_by_id
from wire.value import Value

from .scalars import (
    Seq,
    draw_bytes,
    draw_float_bits,
    draw_fixed_pattern,
    draw_int_value,
    draw_is_long,
    draw_seq,
    draw_string,
    draw_unbounded_int,
    int_value,
)
from .sizes import Sizes


def is_flat(types: Types, t: Int) -> Bool:
    """Scalars, and tuples, options and records of them: what a long list holds."""
    ref info = types.info(t)
    var k = info.kind
    if k == T_LIST or k == T_MAP:
        return False
    if k == T_TUPLE or k == T_OPTION or k == T_RECORD:
        for a in info.args:
            if not is_flat(types, a):
                return False
    return True


def _unsupported(types: Types, t: Int) -> Error:
    return Error("gen: no values of type " + types.text(t))


def _draw_list(
    mut src: Source, types: Types, elem: Int, sizes: Sizes, depth: Int
) raises -> Value:
    var short = sizes.max_list if depth == 0 else sizes.max_inner
    var items = List[Value]()
    if depth == 0 and is_flat(types, elem) and sizes.has_long(short, sizes.long_list):
        if src.draw_bool(sizes.long_share):
            # A long list repeats up to 17 drawn values. Its length is drawn once, to
            # steer generation; every element then carries its own continue flag, so
            # deleting an element's span shortens the list (down to the long minimum).
            var lo = sizes.long_lo(short)
            var palette = List[Value]()
            var pal = Seq(0, lo)
            while pal.more(src):
                palette.append(_draw(src, types, elem, sizes, depth + 1))
            if len(palette) == 0:
                palette.append(_draw(src, types, elem, sizes, depth + 1))
            var n = src.draw_int(lo, sizes.long_list)
            while len(items) < sizes.long_list:
                src.start_span(MANY_LABEL)
                var more = src.draw_bool(1.0 if len(items) < n else 0.0)
                if not more:
                    src.stop_span()
                    break
                items.append(palette[Int(src.draw_below(UInt64(len(palette))))].copy())
                src.stop_span()
            if len(items) < lo:
                src.reject()
            return Value.list(items^)
    var seq = Seq(0, short)
    while seq.more(src):
        items.append(_draw(src, types, elem, sizes, depth + 1))
    return Value.list(items^)


def _draw_map(
    mut src: Source, types: Types, key: Int, val: Int, sizes: Sizes, depth: Int
) raises -> Value:
    var short = sizes.max_list if depth == 0 else sizes.max_inner
    var keys = List[Value]()
    var vals = List[Value]()
    var seq = Seq(0, short)
    while seq.more(src):
        var k = _draw(src, types, key, sizes, depth + 1)
        var v = _draw(src, types, val, sizes, depth + 1)
        var fresh = True
        for i in range(len(keys)):
            if keys[i] == k:
                fresh = False
                break
        if fresh:
            keys.append(k^)
            vals.append(v^)
    return Value.map(keys^, vals^)


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
        var items = List[Value]()
        for i in range(len(info.args)):
            items.append(_draw(src, types, info.args[i], sizes, depth + 1))
        return Value.tuple(items^)
    if k == T_OPTION:
        if src.draw_bool(0.75):
            return Value.some(_draw(src, types, info.args[0], sizes, depth + 1))
        return Value.none()
    if k == T_LITERAL:
        return Value.enum(String(), info.names[src.draw_choice(len(info.names))])
    if k == T_ENUM:
        return Value.enum(info.name, info.names[src.draw_choice(len(info.names))])
    if k == T_RECORD:
        var items = List[Value]()
        for i in range(len(info.args)):
            items.append(_draw(src, types, info.args[i], sizes, depth + 1))
        return Value.record(info.name, info.names, items^)
    raise _unsupported(types, t)


def _draw(
    mut src: Source, types: Types, t: Int, sizes: Sizes, depth: Int
) raises -> Value:
    var k = types.kind(t)
    if k == T_BOOL or k == T_INT or k == T_FIXED_INT or k == T_FLOAT or k == T_LITERAL or k == T_ENUM:
        # One or two choices: the span would repeat the element's own.
        return _draw_inner(src, types, t, sizes, depth)
    src.start_span(Int(k))
    var v = _draw_inner(src, types, t, sizes, depth)
    src.stop_span()
    return v^


def draw_value(
    mut src: Source, mut types: Types, t: Int, sizes: Sizes, depth: Int
) raises -> Value:
    """A value of type `t`. `depth` is 0 for a top-level value (an argument), where long
    lists, strings and bytes can occur, and grows with nesting.

    Types with no values drawn here (sets, models, type variables, reals, unit)
    raise; models go through `draw_model`.
    """
    return _draw(src, types, t, sizes, depth)
