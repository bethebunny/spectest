"""Evaluates the system prelude's functions on `Value`s, by id (`prelude.names`).

`call` covers every function in `NAMES` except `fresh`, `same_object` and `shares_memory`
(the evaluator answers those). An error's message begins with the function's name.
"""

from check import types as ty
from check.psig import make_sig
from numeric.formats import FloatFormat, format_by_id
from prelude.collections import (
    EqMode,
    distinct,
    equal,
    float_eq,
    ignores_order,
    index_of,
    is_none,
    is_permutation,
    is_some,
    is_sorted,
    is_subsequence,
    keys,
    length,
    range_,
    some,
    sorted,
    unwrap,
    values,
)
from prelude.elementary import cr, mp
from prelude.floatfns import (
    bits,
    classify,
    ieee_eq,
    next_down,
    next_up,
    qe,
    qerr_part,
    real,
    round_float,
    ulp,
)
from prelude.ints import bit_length, fits_float, fits_int, le_uint, wrap
from prelude.names import prelude_id, prelude_name
from prelude.text import codepoints, from_codepoints, valid_utf8
from prelude.util import fail
from wire.equality import same
from wire.value import Value


@fieldwise_init
struct Keyword(Copyable):
    var name: String
    var value: Value


struct CallArgs(Movable):
    """The arguments of a prelude call."""

    var args: List[Value]
    var keywords: List[Keyword]
    var type_args: List[Int]
    """`wrap<i32>(x)` has the type id of i32."""

    def __init__(
        out self,
        var args: List[Value],
        *,
        var keywords: List[Keyword] = [],
        var type_args: List[Int] = [],
    ):
        self.args = args^
        self.keywords = keywords^
        self.type_args = type_args^


def _id(name: StringSlice) -> Int:
    return prelude_id(name).value()


# The ids the evaluator itself answers or special-cases.
comptime EQ = _id("eq")
comptime FRESH = _id("fresh")
comptime SAME_OBJECT = _id("same_object")
comptime SHARES_MEMORY = _id("shares_memory")


def eq_mode(keywords: List[Keyword]) raises -> EqMode:
    """What the keyword arguments of an `eq` call ask for."""
    var floats: Optional[Value] = None
    var order: Optional[Value] = None
    for keyword in keywords:
        match keyword.name:
            case "float":
                floats = keyword.value.copy()
            case "order":
                order = keyword.value.copy()
            case _:
                raise fail("eq", t"unknown keyword argument {keyword.name}")
    return EqMode(float_eq(floats), ignores_order(order))


def _type_arg(who: String, args: CallArgs) raises -> Int:
    if len(args.type_args) != 1:
        raise fail(who, t"takes exactly one type argument, got {len(args.type_args)}")
    return args.type_args[0]


def _float_type(who: String, args: CallArgs, types: ty.Types) raises -> FloatFormat:
    var t = _type_arg(who, args)
    if types.kind(t) != ty.FLOAT:
        raise fail(String(t"{who}<{types.text(t)}>"), t"{types.text(t)} is not a float format")
    return format_by_id(UInt8(types.info(t).bits))


def _fixed_width(who: String, args: CallArgs, types: ty.Types) raises -> Value:
    """`wrap<T>(x)` and `fits<T>(x)`."""
    var t = _type_arg(who, args)
    ref info = types.info(t)
    ref x = args.args[0]
    match info.kind:
        case ty.FIXED_INT:
            return wrap(x, info.bits, info.signed) if who == "wrap" else fits_int(x, info.bits, info.signed)
        case ty.FLOAT if who == "fits":
            return fits_float(x, format_by_id(UInt8(info.bits)))
        case _:
            var kind = "integer" if who == "wrap" else "scalar"
            raise fail(String(t"{who}<{types.text(t)}>"), t"{types.text(t)} is not a fixed-width {kind} type")


def call(id: Int, args: CallArgs, types: ty.Types) raises -> Value:
    var who = prelude_name(id)
    if id in [FRESH, SAME_OBJECT, SHARES_MEMORY]:
        raise fail(who, "asks the host about identity; the evaluator answers it")
    if args.keywords and id != EQ:
        raise fail(who, t"takes no keyword arguments, got {args.keywords[0].name}")
    var arity = make_sig(who).lo
    if len(args.args) != arity:
        raise fail(who, t"takes {arity} argument{'' if arity == 1 else 's'}, got {len(args.args)}")

    ref x = args.args[0]
    match who:
        case "is_nan" | "is_inf" | "is_finite" | "is_zero" | "is_subnormal" | "signbit":
            return classify(who, x)
        case "bits":
            return bits(x)
        case "next_up":
            return next_up(x)
        case "next_down":
            return next_down(x)
        case "ulp":
            return ulp(_float_type(who, args, types), x)
        case "round":
            return round_float(_float_type(who, args, types), x)
        case "qe":
            var format: Optional[FloatFormat] = None
            if args.type_args:
                format = _float_type(who, args, types)
            return qe(x, args.args[1], format)
        case "steps":
            return qerr_part(who, x, 0)
        case "nans":
            return qerr_part(who, x, 1)
        case "ieee_eq":
            return ieee_eq(x, args.args[1])
        case "same":
            return Value.bool(same(x, args.args[1]))
        case "real":
            return real(x)
        case "wrap" | "fits":
            return _fixed_width(who, args, types)
        case "le_uint":
            return le_uint(x)
        case "bit_length":
            return bit_length(x)
        case "valid_utf8":
            return valid_utf8(x)
        case "codepoints":
            return codepoints(x)
        case "from_codepoints":
            return from_codepoints(x)
        case "len":
            return length(x)
        case "sorted":
            return sorted(x)
        case "is_sorted":
            return is_sorted(x)
        case "is_permutation":
            return is_permutation(x, args.args[1])
        case "is_subsequence":
            return is_subsequence(x, args.args[1])
        case "distinct":
            return distinct(x)
        case "index_of":
            return index_of(x, args.args[1])
        case "keys":
            return keys(x)
        case "values":
            return values(x)
        case "range":
            return range_(x, args.args[1])
        case "some":
            return some(x)
        case "is_some":
            return is_some(x)
        case "is_none":
            return is_none(x)
        case "unwrap":
            return unwrap(x)
        case "eq":
            return Value.bool(equal(x, args.args[1], eq_mode(args.keywords)))
        case "mp.sqrt" | "mp.exp" | "mp.log" | "mp.sin" | "mp.cos" | "mp.tan" | "mp.atan":
            return mp(String(who.removeprefix("mp.")), x)
        case "cr.sqrt" | "cr.exp" | "cr.log" | "cr.sin" | "cr.cos" | "cr.tan" | "cr.atan":
            return cr(String(who.removeprefix("cr.")), x)
        case _:
            raise Error(t"unknown prelude function id {id}")
