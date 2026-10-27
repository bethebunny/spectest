"""Evaluates the system prelude's functions on `Value`s, by id (`prelude.names`).

`call` covers every function in `NAMES` except `fresh`, `same_object` and
`shares_memory`, which ask the host about identity; the evaluator answers those.
An evaluation error raises an `Error` whose message begins with the function's name.
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
from prelude.mpfr import SQRT, EXP, LOG, SIN, COS, TAN, ATAN
from prelude.names import prelude_id, prelude_name
from prelude.text import codepoints, from_codepoints, valid_utf8
from prelude.util import fail
from wire.equality import same
from wire.value import Value


struct CallArgs(Movable):
    var args: List[Value]
    """Positional arguments."""
    var names: List[String]
    """Keyword argument names."""
    var keywords: List[Value]
    """Keyword argument values, in the order of `names`."""
    var type_args: List[Int]
    """`wrap<i32>(x)`: [the type id of i32]."""
    var arg_types: List[Int]
    """The static type of each positional argument."""

    def __init__(out self):
        self.args = List[Value]()
        self.names = List[String]()
        self.keywords = List[Value]()
        self.type_args = List[Int]()
        self.arg_types = List[Int]()

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


comptime BITS = _id("bits")
comptime CODEPOINTS = _id("codepoints")
comptime CR_ATAN = _id("cr.atan")
comptime CR_COS = _id("cr.cos")
comptime CR_EXP = _id("cr.exp")
comptime CR_LOG = _id("cr.log")
comptime CR_SIN = _id("cr.sin")
comptime CR_SQRT = _id("cr.sqrt")
comptime CR_TAN = _id("cr.tan")
comptime DISTINCT = _id("distinct")
comptime EQ = _id("eq")
comptime FITS = _id("fits")
comptime IEEE_EQ = _id("ieee_eq")
comptime INDEX_OF = _id("index_of")
comptime IS_FINITE = _id("is_finite")
comptime IS_INF = _id("is_inf")
comptime IS_NAN = _id("is_nan")
comptime IS_NONE = _id("is_none")
comptime IS_PERMUTATION = _id("is_permutation")
comptime IS_SOME = _id("is_some")
comptime IS_SORTED = _id("is_sorted")
comptime IS_SUBNORMAL = _id("is_subnormal")
comptime IS_SUBSEQUENCE = _id("is_subsequence")
comptime IS_ZERO = _id("is_zero")
comptime KEYS = _id("keys")
comptime LE_UINT = _id("le_uint")
comptime LEN = _id("len")
comptime MP_ATAN = _id("mp.atan")
comptime MP_COS = _id("mp.cos")
comptime MP_EXP = _id("mp.exp")
comptime MP_LOG = _id("mp.log")
comptime MP_SIN = _id("mp.sin")
comptime MP_SQRT = _id("mp.sqrt")
comptime MP_TAN = _id("mp.tan")
comptime NANS = _id("nans")
comptime NEXT_DOWN = _id("next_down")
comptime NEXT_UP = _id("next_up")
comptime QE = _id("qe")
comptime RANGE = _id("range")
comptime REAL = _id("real")
comptime ROUND = _id("round")
comptime SAME = _id("same")
comptime SIGNBIT = _id("signbit")
comptime SOME = _id("some")
comptime SORTED = _id("sorted")
comptime STEPS = _id("steps")
comptime ULP = _id("ulp")
comptime UNWRAP = _id("unwrap")
comptime VALID_UTF8 = _id("valid_utf8")
comptime VALUES = _id("values")
comptime WRAP = _id("wrap")
comptime BIT_LENGTH = _id("bit_length")
comptime FROM_CODEPOINTS = _id("from_codepoints")
comptime FRESH = _id("fresh")
comptime SAME_OBJECT = _id("same_object")
comptime SHARES_MEMORY = _id("shares_memory")


def _arity(who: String, args: CallArgs, n: Int) raises:
    if len(args.args) != n:
        raise fail(
            who,
            "takes " + String(n) + " argument" + ("" if n == 1 else "s") + ", got " + String(len(args.args)),
        )


def _float_type(who: String, args: CallArgs, types: Types) raises -> FloatFormat:
    if len(args.type_args) != 1:
        raise fail(who, "takes exactly one type argument, got " + String(len(args.type_args)))
    var t = args.type_args[0]
    if types.kind(t) != FLOAT_TYPE:
        raise fail(who + "<" + types.text(t) + ">", types.text(t) + " is not a float format")
    return format_by_id(UInt8(types.info(t).bits))


def call(id: Int, args: CallArgs, types: Types) raises -> Value:
    var who = prelude_name(id)
    if id == FRESH or id == SAME_OBJECT or id == SHARES_MEMORY:
        raise fail(who, "asks the host about identity; the evaluator answers it")
    if len(args.names) != len(args.keywords):
        raise fail(who, "malformed call: keyword names and values differ in length")
    if len(args.names) > 0 and id != EQ:
        raise fail(who, "takes no keyword arguments, got " + args.names[0])

    # Classification and bits
    if id == IS_NAN or id == IS_INF or id == IS_FINITE or id == IS_ZERO or id == IS_SUBNORMAL or id == SIGNBIT:
        _arity(who, args, 1)
        return classify(who, args.args[0])
    if id == BITS:
        _arity(who, args, 1)
        return bits(args.args[0])
    if id == NEXT_UP:
        _arity(who, args, 1)
        return next_up(args.args[0])
    if id == NEXT_DOWN:
        _arity(who, args, 1)
        return next_down(args.args[0])
    if id == ULP:
        _arity(who, args, 1)
        return ulp(_float_type(who, args, types), args.args[0])
    if id == ROUND:
        _arity(who, args, 1)
        return round_float(_float_type(who, args, types), args.args[0])
    if id == QE:
        _arity(who, args, 2)
        var format = Optional[FloatFormat]()
        if len(args.type_args) > 0:
            format = _float_type(who, args, types)
        return qe(args.args[0], args.args[1], format)
    if id == STEPS:
        _arity(who, args, 1)
        return qerr_part(who, args.args[0], 0)
    if id == NANS:
        _arity(who, args, 1)
        return qerr_part(who, args.args[0], 1)
    if id == IEEE_EQ:
        _arity(who, args, 2)
        return ieee_eq(args.args[0], args.args[1])
    if id == SAME:
        _arity(who, args, 2)
        return Value.bool(same(args.args[0], args.args[1]))
    if id == REAL:
        _arity(who, args, 1)
        return real(args.args[0])

    # Fixed width
    if id == WRAP or id == FITS:
        _arity(who, args, 1)
        if len(args.type_args) != 1:
            raise fail(who, "takes exactly one type argument, got " + String(len(args.type_args)))
        var t = args.type_args[0]
        var kind = types.kind(t)
        if kind == FIXED_INT:
            var info = types.info(t).copy()
            if id == WRAP:
                return wrap(args.args[0], info.bits, info.signed)
            return fits_int(args.args[0], info.bits, info.signed)
        if id == FITS and kind == FLOAT_TYPE:
            return fits_float(args.args[0], format_by_id(UInt8(types.info(t).bits)))
        raise fail(who + "<" + types.text(t) + ">", types.text(t) + " is not a fixed-width " + ("integer" if id == WRAP else "scalar") + " type")

    # Integers, bytes and text
    if id == LE_UINT:
        _arity(who, args, 1)
        return le_uint(args.args[0])
    if id == BIT_LENGTH:
        _arity(who, args, 1)
        return bit_length(args.args[0])
    if id == VALID_UTF8:
        _arity(who, args, 1)
        return valid_utf8(args.args[0])
    if id == CODEPOINTS:
        _arity(who, args, 1)
        return codepoints(args.args[0])
    if id == FROM_CODEPOINTS:
        _arity(who, args, 1)
        return from_codepoints(args.args[0])

    # Collections and options
    if id == LEN:
        _arity(who, args, 1)
        return length(args.args[0])
    if id == SORTED:
        _arity(who, args, 1)
        return sorted(args.args[0])
    if id == IS_SORTED:
        _arity(who, args, 1)
        return is_sorted(args.args[0])
    if id == IS_PERMUTATION:
        _arity(who, args, 2)
        return is_permutation(args.args[0], args.args[1])
    if id == IS_SUBSEQUENCE:
        _arity(who, args, 2)
        return is_subsequence(args.args[0], args.args[1])
    if id == DISTINCT:
        _arity(who, args, 1)
        return distinct(args.args[0])
    if id == INDEX_OF:
        _arity(who, args, 2)
        return index_of(args.args[0], args.args[1])
    if id == KEYS:
        _arity(who, args, 1)
        return keys(args.args[0])
    if id == VALUES:
        _arity(who, args, 1)
        return values(args.args[0])
    if id == RANGE:
        _arity(who, args, 2)
        return range_(args.args[0], args.args[1])
    if id == SOME:
        _arity(who, args, 1)
        return some(args.args[0])
    if id == IS_SOME:
        _arity(who, args, 1)
        return is_some(args.args[0])
    if id == IS_NONE:
        _arity(who, args, 1)
        return is_none(args.args[0])
    if id == UNWRAP:
        _arity(who, args, 1)
        return unwrap(args.args[0])
    if id == EQ:
        _arity(who, args, 2)
        var float_mode = Optional[Value]()
        var order = Optional[Value]()
        for i in range(len(args.names)):
            if args.names[i] == "float":
                float_mode = args.keywords[i].copy()
            elif args.names[i] == "order":
                order = args.keywords[i].copy()
            else:
                raise fail(who, "unknown keyword argument " + args.names[i])
        return eq(args.args[0], args.args[1], float_mode, order)

    # Elementary functions
    if id == MP_SQRT or id == MP_EXP or id == MP_LOG or id == MP_SIN or id == MP_COS or id == MP_TAN or id == MP_ATAN:
        _arity(who, args, 1)
        var which = (
            SQRT if id == MP_SQRT else EXP if id == MP_EXP else LOG if id == MP_LOG else SIN
            if id == MP_SIN else COS if id == MP_COS else TAN if id == MP_TAN else ATAN
        )
        return mp(which, args.args[0])
    if id == CR_SQRT or id == CR_EXP or id == CR_LOG or id == CR_SIN or id == CR_COS or id == CR_TAN or id == CR_ATAN:
        _arity(who, args, 1)
        var which = (
            SQRT if id == CR_SQRT else EXP if id == CR_EXP else LOG if id == CR_LOG else SIN
            if id == CR_SIN else COS if id == CR_COS else TAN if id == CR_TAN else ATAN
        )
        return cr(which, args.args[0])
    raise Error("unknown prelude function id " + String(id))
