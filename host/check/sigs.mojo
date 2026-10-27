"""Typing of the system prelude's functions.

`make_sig` gives the signature record of one prelude name (arity, type arguments,
keyword arguments, a human-readable shape for messages and the typing rule), and
`type_prelude` applies the rule to a call whose arguments are already typed. A rule
that finds the call ill-typed sets `Checker.sig_msg` (and `sig_arg` or `sig_key` for
the argument to point at) and returns the poison type.
"""

from syntax import ast

from check import types as ty
from check.psig import (
    CallInfo,
    PreludeSig,
    T_FLOAT_PRED,
    T_BITS,
    T_SAME_FLOAT,
    T_ULP,
    T_QE,
    T_QERR_PART,
    T_SAME,
    T_IEEE_EQ,
    T_REAL,
    T_ROUND,
    T_WRAP,
    T_FITS,
    T_MP,
    T_CR,
    T_LE_UINT,
    T_LEN,
    T_SORTED,
    T_IS_SORTED,
    T_TWO_LISTS,
    T_DISTINCT,
    T_INDEX_OF,
    T_KEYS,
    T_VALUES,
    T_RANGE,
    T_SOME,
    T_OPT_PRED,
    T_UNWRAP,
    T_VALID_UTF8,
    T_CODEPOINTS,
    T_FRESH,
    T_TWO_MODELS,
    T_BIT_LENGTH,
    T_FROM_CODEPOINTS,
)
from check.state import Checker, NO_TYPE


def _ord(i: Int) -> String:
    return "argument " + String(i + 1)


def _fail(mut c: Checker, message: Some[Writable], arg: Int = -1, key: String = "") -> Int:
    c.sig_msg = String(message)
    c.sig_arg = arg
    c.sig_key = key
    return c.poison


def _float(mut c: Checker, info: CallInfo, i: Int) -> Bool:
    var t = info.args[i]
    var k = c.tkind(t)
    if k == ty.FLOAT or k == ty.ANY:
        return True
    var hint = String()
    if c.is_numeric(t):
        hint = (
            " (" + c.text(t) + " is not a float type; floats are f16, bf16, f32, f64)"
        )
    _ = _fail(
        c,
        info.name + " takes a float, but " + _ord(i) + " is " + c.text(t) + hint,
        i,
    )
    return False


def _real_like(mut c: Checker, info: CallInfo, i: Int) -> Bool:
    var t = info.args[i]
    if c.is_numeric(t) or c.is_any(t):
        return True
    _ = _fail(
        c,
        info.name
        + " takes a number (int, fixed-width int, float or real), but "
        + _ord(i)
        + " is "
        + c.text(t),
        i,
    )
    return False


def _integer(mut c: Checker, info: CallInfo, i: Int) -> Bool:
    var t = info.args[i]
    if c.is_integer(t) or c.is_any(t):
        return True
    var hint = String()
    if c.tkind(t) == ty.REAL:
        hint = " (use // for integer division)"
    _ = _fail(
        c,
        info.name + " takes an integer, but " + _ord(i) + " is " + c.text(t) + hint,
        i,
    )
    return False


def _list(mut c: Checker, info: CallInfo, i: Int) -> Int:
    """The element type of a list argument; -1 (with the failure recorded) otherwise."""
    var t = info.args[i]
    var k = c.tkind(t)
    if k == ty.LIST:
        return c.arg(t, 0)
    if k == ty.ANY:
        return t
    _ = _fail(
        c, info.name + " takes a list, but " + _ord(i) + " is " + c.text(t), i
    )
    return NO_TYPE


def _option(mut c: Checker, info: CallInfo, i: Int) -> Int:
    var t = info.args[i]
    var k = c.tkind(t)
    if k == ty.OPTION:
        return c.arg(t, 0)
    if k == ty.ANY:
        return t
    _ = _fail(
        c, info.name + " takes an option, but " + _ord(i) + " is " + c.text(t), i
    )
    return NO_TYPE


def _bytes(mut c: Checker, info: CallInfo, i: Int) -> Bool:
    var t = info.args[i]
    var k = c.tkind(t)
    if k == ty.BYTES or k == ty.ANY:
        return True
    _ = _fail(
        c, info.name + " takes bytes, but " + _ord(i) + " is " + c.text(t), i
    )
    return False


def _model(mut c: Checker, info: CallInfo, i: Int) -> Bool:
    var t = info.args[i]
    var k = c.tkind(t)
    if k == ty.MODEL or k == ty.ANY:
        return True
    _ = _fail(
        c,
        info.name
        + " takes a model or interface handle, but "
        + _ord(i)
        + " is "
        + c.text(t),
        i,
    )
    return False


def _eq_elems(mut c: Checker, info: CallInfo, elem: Int, what: String) -> Bool:
    var bad = c.non_eq_part(elem)
    if bad < 0:
        return True
    var hint: String
    var bk = c.tkind(bad)
    if bk == ty.FLOAT:
        hint = (
            "floats have no canonical equality; map them to bits(x) or real(x) first, "
            "or compare whole values with eq(a, b, float=...)"
        )
    elif bk == ty.MODEL:
        hint = "model " + c.spec.types.infos[bad].name + " handles have no canonical equality"
    elif bk == ty.TYPEVAR:
        hint = "declare the type parameter as " + c.spec.types.infos[bad].name + ": Eq"
    else:
        hint = c.text(bad) + " has no canonical equality"
    _ = _fail(
        c,
        t"{info.name} compares {what} with ==, but {c.text(elem)} has no canonical equality: "
        t"{hint}",
    )
    return False


def _ordered_elems(mut c: Checker, info: CallInfo, elem: Int) -> Bool:
    if c.ordered(elem):
        return True
    var hint: String
    var k = c.tkind(elem)
    if k == ty.FLOAT:
        hint = "floats have no total order (NaN); map them to real(x) first"
    elif k == ty.TYPEVAR:
        hint = "declare the type parameter as " + c.spec.types.infos[elem].name + ": Ord"
    else:
        hint = c.text(elem) + " has no total order"
    _ = _fail(
        c,
        info.name
        + " needs ordered elements, but the elements are "
        + c.text(elem)
        + ": "
        + hint,
        0,
    )
    return False


def _same_type(mut c: Checker, info: CallInfo, i: Int, j: Int) -> Int:
    var t = c.join(info.args[i], info.args[j])
    if t < 0:
        _ = _fail(
            c,
            info.name
            + " compares two values of one type, but got "
            + c.text(info.args[i])
            + " and "
            + c.text(info.args[j]),
            j,
        )
    return t


def _type_arg(mut c: Checker, info: CallInfo, kinds: List[UInt8], what: String) -> Int:
    var t = info.targs[0]
    var k = c.tkind(t)
    if k == ty.ANY:
        return t
    for want in kinds:
        if k == want:
            return t
    _ = _fail(c, t"{info.name}<{c.text(t)}>: the type argument must be {what}")
    return NO_TYPE


def _qe_untyped(mut c: Checker, info: CallInfo, i: Int) -> Int:
    var t = info.args[i]
    var k = c.tkind(t)
    if k == ty.FLOAT or k == ty.ANY:
        return t
    var hint = String()
    if c.is_numeric(t):
        hint = (
            " ("
            + c.text(t)
            + " is not a float: round a real first, qe(result, round<f64>(r)), "
            "or name the format, qe<f64>(result, r))"
        )
    _ = _fail(
        c,
        "qe compares two floats of one format, but "
        + _ord(i)
        + " is "
        + c.text(t)
        + hint,
        i,
    )
    return NO_TYPE


def _float_type_arg(mut c: Checker, info: CallInfo) -> Int:
    return _type_arg(
        c, info, [ty.FLOAT], "a float type (f16, bf16, f32, f64)"
    )


def _eq_mode_ok(value: String, key: String) -> Bool:
    if key == "float":
        return value == "bits" or value == "ieee" or value == "nan_any"
    return value == "exact" or value == "ignore"


def type_prelude(mut c: Checker, sig: PreludeSig, info: CallInfo) -> Int:
    """The result type of a prelude call, or the poison type with `sig_msg` set."""
    c.sig_msg = String()
    var k = sig.typer
    var t0 = info.args[0] if len(info.args) > 0 else c.poison
    if k == T_FLOAT_PRED:
        if not _float(c, info, 0):
            return c.poison
        return c.bool_
    if k == T_BITS:
        if not _float(c, info, 0):
            return c.poison
        return c.int_
    if k == T_SAME_FLOAT:
        if not _float(c, info, 0):
            return c.poison
        return t0
    if k == T_ULP:
        if _float_type_arg(c, info) < 0:
            return c.poison
        if not _real_like(c, info, 0):
            return c.poison
        return c.real_
    if k == T_QE:
        if len(info.targs) > 0:
            var t = _float_type_arg(c, info)
            if t < 0:
                return c.poison
            for i in range(2):
                var a = info.args[i]
                if c.is_any(a) or c.is_any(t):
                    continue
                if c.tkind(a) == ty.FLOAT and a != t:
                    return _fail(
                        c,
                        "qe<"
                        + c.text(t)
                        + "> compares "
                        + c.text(t)
                        + " values, but "
                        + _ord(i)
                        + " is "
                        + c.text(a),
                        i,
                    )
                if not c.is_numeric(a):
                    return _fail(
                        c,
                        "qe<"
                        + c.text(t)
                        + "> takes "
                        + c.text(t)
                        + " values or numbers, but "
                        + _ord(i)
                        + " is "
                        + c.text(a),
                        i,
                    )
            return c.qerr_
        var a = _qe_untyped(c, info, 0)
        if a < 0:
            return c.poison
        var b = _qe_untyped(c, info, 1)
        if b < 0:
            return c.poison
        if c.tkind(a) == ty.FLOAT and c.tkind(b) == ty.FLOAT and a != b:
            return _fail(
                c,
                "qe compares two floats of one format, but got "
                + c.text(a)
                + " and "
                + c.text(b)
                + ": convert one first",
                1,
            )
        return c.qerr_
    if k == T_QERR_PART:
        var kk = c.tkind(t0)
        if kk != ty.QERR and kk != ty.ANY:
            return _fail(
                c,
                info.name
                + " takes a qerr (the value of qe(a, b)), but argument 1 is "
                + c.text(t0),
                0,
            )
        return c.int_
    if k == T_CR:
        var kk = c.tkind(t0)
        if kk == ty.FLOAT or kk == ty.ANY:
            return t0
        var hint = String()
        if c.is_numeric(t0):
            hint = "; for a real use mp." + String(info.name[byte=3:])
        return _fail(
            c,
            info.name
            + " rounds in the format of its argument, so it takes a float, but "
            "argument 1 is "
            + c.text(t0)
            + hint,
            0,
        )
    if k == T_SAME:
        if _same_type(c, info, 0, 1) < 0:
            return c.poison
        return c.bool_
    if k == T_IEEE_EQ:
        if not _float(c, info, 0) or not _float(c, info, 1):
            return c.poison
        return c.bool_
    if k == T_REAL or k == T_MP:
        if not _real_like(c, info, 0):
            return c.poison
        return c.real_
    if k == T_ROUND:
        var t = _float_type_arg(c, info)
        if t < 0:
            return c.poison
        if not _real_like(c, info, 0):
            return c.poison
        return t
    if k == T_WRAP:
        var t = _type_arg(
            c, info, [ty.FIXED_INT], "a fixed-width integer type (i8 ... u64)"
        )
        if t < 0:
            return c.poison
        if not _integer(c, info, 0):
            return c.poison
        return t
    if k == T_FITS:
        if (
            _type_arg(
                c, info, [ty.FIXED_INT, ty.FLOAT], "a fixed-width integer or float type"
            )
            < 0
        ):
            return c.poison
        if not _real_like(c, info, 0):
            return c.poison
        return c.bool_
    if k == T_LE_UINT:
        if not _bytes(c, info, 0):
            return c.poison
        return c.int_
    if k == T_LEN:
        var kk = c.tkind(t0)
        if (
            kk == ty.LIST
            or kk == ty.STRING
            or kk == ty.LITERAL
            or kk == ty.BYTES
            or kk == ty.MAP
            or kk == ty.ANY
        ):
            return c.int_
        return _fail(
            c,
            "len takes a list, string, bytes or map, but argument 1 is " + c.text(t0),
            0,
        )
    if k == T_SORTED:
        var elem = _list(c, info, 0)
        if elem < 0 or not _ordered_elems(c, info, elem):
            return c.poison
        if c.tkind(t0) == ty.LIST:
            return t0
        return c.spec.types.list_of(elem)
    if k == T_IS_SORTED:
        var elem = _list(c, info, 0)
        if elem < 0 or not _ordered_elems(c, info, elem):
            return c.poison
        return c.bool_
    if k == T_TWO_LISTS:
        var a = _list(c, info, 0)
        if a < 0:
            return c.poison
        var b = _list(c, info, 1)
        if b < 0:
            return c.poison
        var elem = c.join(a, b)
        if elem < 0:
            return _fail(
                c,
                info.name
                + " takes two lists of one element type, but got "
                + c.text(info.args[0])
                + " and "
                + c.text(info.args[1]),
                1,
            )
        if not _eq_elems(c, info, elem, "elements"):
            return c.poison
        return c.bool_
    if k == T_DISTINCT:
        var elem = _list(c, info, 0)
        if elem < 0 or not _eq_elems(c, info, elem, "elements"):
            return c.poison
        return c.bool_
    if k == T_INDEX_OF:
        var elem = _list(c, info, 0)
        if elem < 0:
            return c.poison
        var t = c.join(elem, info.args[1])
        if t < 0:
            return _fail(
                c,
                "index_of looks for a "
                + c.text(elem)
                + " in "
                + c.text(info.args[0])
                + ", but argument 2 is "
                + c.text(info.args[1]),
                1,
            )
        if not _eq_elems(c, info, t, "elements"):
            return c.poison
        return c.int_
    if k == T_KEYS or k == T_VALUES:
        var kk = c.tkind(t0)
        if kk != ty.MAP and kk != ty.ANY:
            return _fail(
                c, info.name + " takes a map, but argument 1 is " + c.text(t0), 0
            )
        if kk == ty.MAP:
            return c.spec.types.list_of(c.arg(t0, 0 if k == T_KEYS else 1))
        return c.spec.types.list_of(t0)
    if k == T_RANGE:
        if not _integer(c, info, 0) or not _integer(c, info, 1):
            return c.poison
        return c.spec.types.list_of(c.int_)
    if k == T_SOME:
        return c.spec.types.option_of(t0)
    if k == T_OPT_PRED:
        if _option(c, info, 0) < 0:
            return c.poison
        return c.bool_
    if k == T_UNWRAP:
        var elem = _option(c, info, 0)
        return c.poison if elem < 0 else elem
    if k == T_VALID_UTF8:
        if not _bytes(c, info, 0):
            return c.poison
        return c.bool_
    if k == T_CODEPOINTS:
        if not (c.is_stringish(t0) or c.is_any(t0)):
            return _fail(
                c, "codepoints takes a string, but " + _ord(0) + " is " + c.text(t0), 0
            )
        return c.spec.types.list_of(c.int_)
    if k == T_FRESH:
        if not _model(c, info, 0):
            return c.poison
        return c.bool_
    if k == T_TWO_MODELS:
        if not _model(c, info, 0) or not _model(c, info, 1):
            return c.poison
        return c.bool_
    if k == T_BIT_LENGTH:
        if not _integer(c, info, 0):
            return c.poison
        return c.int_
    if k == T_FROM_CODEPOINTS:
        var elem = _list(c, info, 0)
        if elem < 0:
            return c.poison
        if not (c.is_integer(elem) or c.is_any(elem)):
            return _fail(
                c,
                "from_codepoints takes a list of integers, but argument 1 is "
                + c.text(t0),
                0,
            )
        return c.string_
    # eq
    var t = _same_type(c, info, 0, 1)
    if t < 0:
        return c.poison
    for j in range(len(info.kw_keys)):
        var key = info.kw_keys[j]
        if key != "float" and key != "order":
            continue
        var node = info.kw_nodes[j]
        var choices = '"bits" | "ieee" | "nan_any"' if key == "float" else '"exact" | "ignore"'
        if c.kind_of(node) != .STR or not _eq_mode_ok(c.text_of(node), key):
            return _fail(c, "eq: " + key + "= must be one of " + choices, -1, key)
    var has_float = False
    for key in info.kw_keys:
        if key == "float":
            has_float = True
    if not has_float and c.contains_float(t):
        return _fail(
            c,
            "eq compares values of type "
            + c.text(t)
            + ", which contain floats: say how to compare them with "
            'float="bits" (bit-identical), float="ieee" or float="nan_any"',
        )
    return c.bool_
