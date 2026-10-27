"""Evaluates the system prelude's functions on `Value`s, by id (`prelude.names`).

`call` covers every function in `NAMES` except `fresh`, `same_object` and `shares_memory`
(the evaluator answers those). An error's message begins with the function's name.
"""

from check.types import Types, FIXED_INT, FLOAT as FLOAT_TYPE
from numeric.formats import FloatFormat, format_by_id
from prelude.collections import (
    distinct,
    eq,
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


struct CallArgs(Movable):
    var args: List[Value]
    var names: List[String]
    var keywords: List[Value]
    """In the order of `names`."""
    var type_args: List[Int]
    """`wrap<i32>(x)` has the type id of i32."""
    var arg_types: List[Int]
    """The static type of each positional argument."""

    def __init__(
        out self,
        var args: List[Value],
        var names: List[String] = List[String](),
        var keywords: List[Value] = List[Value](),
        var type_args: List[Int] = List[Int](),
        var arg_types: List[Int] = List[Int](),
    ):
        self.args = args^
        self.names = names^
        self.keywords = keywords^
        self.type_args = type_args^
        self.arg_types = arg_types^


def _id(name: StringSlice) -> Int:
    return prelude_id(name).value()


# the ids the evaluator itself answers or special-cases
comptime EQ = _id("eq")
comptime FRESH = _id("fresh")
comptime SAME_OBJECT = _id("same_object")
comptime SHARES_MEMORY = _id("shares_memory")


def _arity(who: String, args: CallArgs, n: Int) raises:
    if len(args.args) != n:
        raise fail(who, t"takes {n} argument{'' if n == 1 else 's'}, got {len(args.args)}")


def _type_arg(who: String, args: CallArgs) raises -> Int:
    if len(args.type_args) != 1:
        raise fail(who, t"takes exactly one type argument, got {len(args.type_args)}")
    return args.type_args[0]


def _float_type(who: String, args: CallArgs, types: Types) raises -> FloatFormat:
    var t = _type_arg(who, args)
    if types.kind(t) != FLOAT_TYPE:
        raise fail(String(who, "<", types.text(t), ">"), t"{types.text(t)} is not a float format")
    return format_by_id(UInt8(types.info(t).bits))


def _fixed_width(who: String, args: CallArgs, types: Types) raises -> Value:
    var t = _type_arg(who, args)
    var kind = types.kind(t)
    var info = types.info(t).copy()
    if kind == FIXED_INT:
        if who == "wrap":
            return wrap(args.args[0], info.bits, info.signed)
        return fits_int(args.args[0], info.bits, info.signed)
    if who == "fits" and kind == FLOAT_TYPE:
        return fits_float(args.args[0], format_by_id(UInt8(info.bits)))
    raise fail(String(who, "<", types.text(t), ">"), t"{types.text(t)} is not a fixed-width {'integer' if who == 'wrap' else 'scalar'} type")


def _eq(who: String, args: CallArgs) raises -> Value:
    var float_mode = Optional[Value]()
    var order = Optional[Value]()
    for name, keyword in zip(args.names, args.keywords):
        if name == "float":
            float_mode = keyword.copy()
        elif name == "order":
            order = keyword.copy()
        else:
            raise fail(who, t"unknown keyword argument {name}")
    return eq(args.args[0], args.args[1], float_mode, order)


def call(id: Int, args: CallArgs, types: Types) raises -> Value:
    var who = prelude_name(id)
    if id in [FRESH, SAME_OBJECT, SHARES_MEMORY]:
        raise fail(who, "asks the host about identity; the evaluator answers it")
    if len(args.names) != len(args.keywords):
        raise fail(who, "malformed call: keyword names and values differ in length")
    if len(args.names) > 0 and id != EQ:
        raise fail(who, t"takes no keyword arguments, got {args.names[0]}")
    _arity(who, args, 2 if who in ["eq", "ieee_eq", "index_of", "is_permutation", "is_subsequence", "qe", "range", "same"] else 1)

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
            var format = Optional[FloatFormat]()
            if len(args.type_args) > 0:
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
            return _eq(who, args)
        case "mp.sqrt" | "mp.exp" | "mp.log" | "mp.sin" | "mp.cos" | "mp.tan" | "mp.atan":
            return mp(String(who[byte=3:]), x)
        case "cr.sqrt" | "cr.exp" | "cr.log" | "cr.sin" | "cr.cos" | "cr.tan" | "cr.atan":
            return cr(String(who[byte=3:]), x)
        case _:
            raise Error(t"unknown prelude function id {id}")
