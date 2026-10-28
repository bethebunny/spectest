"""Typing of the system prelude's functions.

`prelude_type` applies a prelude function's typing rule (see
spec/prelude_signatures.mojo) to a call whose arguments are already typed. A rule that
finds the call ill-typed raises a `TypingError` that names the argument to point at.
"""

from spec.prelude_signatures import CallInfo, PreludeSig, TypingError
from spec.types import TypeKind

from specfile.checker_state import Checker


def _argument(i: Int) -> String:
    return String(t"argument {i + 1}")


def _float(c: Checker, info: CallInfo, i: Int) raises TypingError:
    var t = info.args[i].type
    var k = c.tkind(t)
    if k == .FLOAT or k == .ANY:
        return
    var hint = String(t" ({c.text(t)} is not a float type; floats are f16, bf16, f32, f64)") if c.is_numeric(t) else String()
    raise TypingError(t"{info.name} takes a float, but {_argument(i)} is {c.text(t)}{hint}", arg=i)


def _real_like(c: Checker, info: CallInfo, i: Int) raises TypingError:
    var t = info.args[i].type
    if c.is_numeric(t) or c.is_any(t):
        return
    raise TypingError(
        t"{info.name} takes a number (int, fixed-width int, float or real), but {_argument(i)} is {c.text(t)}",
        arg=i,
    )


def _integer(c: Checker, info: CallInfo, i: Int) raises TypingError:
    var t = info.args[i].type
    if c.is_integer(t) or c.is_any(t):
        return
    var hint = " (use // for integer division)" if c.tkind(t) == .REAL else ""
    raise TypingError(t"{info.name} takes an integer, but {_argument(i)} is {c.text(t)}{hint}", arg=i)


def _bytes(c: Checker, info: CallInfo, i: Int) raises TypingError:
    var t = info.args[i].type
    var k = c.tkind(t)
    if k == .BYTES or k == .ANY:
        return
    raise TypingError(t"{info.name} takes bytes, but {_argument(i)} is {c.text(t)}", arg=i)


def _model(c: Checker, info: CallInfo, i: Int) raises TypingError:
    var t = info.args[i].type
    var k = c.tkind(t)
    if k == .MODEL or k == .ANY:
        return
    raise TypingError(t"{info.name} takes a model or interface handle, but {_argument(i)} is {c.text(t)}", arg=i)


def _list_elem(c: Checker, info: CallInfo, i: Int) raises TypingError -> Int:
    """The element type of a list argument."""
    var t = info.args[i].type
    match c.tkind(t):
        case .LIST:
            return c.arg(t, 0)
        case .ANY:
            return t
        case _:
            raise TypingError(t"{info.name} takes a list, but {_argument(i)} is {c.text(t)}", arg=i)


def _option_elem(c: Checker, info: CallInfo, i: Int) raises TypingError -> Int:
    var t = info.args[i].type
    match c.tkind(t):
        case .OPTION:
            return c.arg(t, 0)
        case .ANY:
            return t
        case _:
            raise TypingError(t"{info.name} takes an option, but {_argument(i)} is {c.text(t)}", arg=i)


def _eq_elems(c: Checker, info: CallInfo, elem: Int) raises TypingError:
    var bad = c.non_eq_part(elem)
    if bad < 0:
        return
    ref name = c.spec.types.infos[bad].name
    var hint: String
    match c.tkind(bad):
        case .FLOAT:
            hint = (
                "floats have no canonical equality; map them to bits(x) or real(x) first, "
                "or compare whole values with eq(a, b, float=...)"
            )
        case .MODEL:
            hint = String(t"model {name} handles have no canonical equality")
        case .TYPEVAR:
            hint = String(t"declare the type parameter as {name}: Eq")
        case _:
            hint = String(t"{c.text(bad)} has no canonical equality")
    raise TypingError(
        t"{info.name} compares elements with ==, but {c.text(elem)} has no canonical equality: {hint}"
    )


def _ordered_elems(c: Checker, info: CallInfo, elem: Int) raises TypingError:
    if c.ordered(elem):
        return
    var hint: String
    match c.tkind(elem):
        case .FLOAT:
            hint = "floats have no total order (NaN); map them to real(x) first"
        case .TYPEVAR:
            hint = String(t"declare the type parameter as {c.spec.types.infos[elem].name}: Ord")
        case _:
            hint = String(t"{c.text(elem)} has no total order")
    raise TypingError(t"{info.name} needs ordered elements, but the elements are {c.text(elem)}: {hint}", arg=0)


def _same_type(mut c: Checker, info: CallInfo) raises TypingError -> Int:
    """The common type of the two arguments."""
    var a = info.args[0].type
    var b = info.args[1].type
    var t = c.join(a, b)
    if t < 0:
        raise TypingError(t"{info.name} compares two values of one type, but got {c.text(a)} and {c.text(b)}", arg=1)
    return t


def _type_arg(c: Checker, info: CallInfo, kinds: List[TypeKind], what: StaticString) raises TypingError -> Int:
    var t = info.targs[0]
    var k = c.tkind(t)
    if k == .ANY or k in kinds:
        return t
    raise TypingError(t"{info.name}<{c.text(t)}>: the type argument must be {what}")


def _float_type_arg(c: Checker, info: CallInfo) raises TypingError -> Int:
    return _type_arg(c, info, [.FLOAT], "a float type (f16, bf16, f32, f64)")


def _qe_operand(c: Checker, info: CallInfo, i: Int) raises TypingError -> Int:
    """The type of an operand of qe without a type argument, which is a float."""
    var t = info.args[i].type
    var k = c.tkind(t)
    if k == .FLOAT or k == .ANY:
        return t
    var hint = String(
        t" ({c.text(t)} is not a float: round a real first, qe(result, round<f64>(r)), "
        t"or name the format, qe<f64>(result, r))"
    ) if c.is_numeric(t) else String()
    raise TypingError(t"qe compares two floats of one format, but {_argument(i)} is {c.text(t)}{hint}", arg=i)


def _qe(mut c: Checker, info: CallInfo) raises TypingError -> Int:
    if not info.targs:
        var a = _qe_operand(c, info, 0)
        var b = _qe_operand(c, info, 1)
        if c.tkind(a) == .FLOAT and c.tkind(b) == .FLOAT and a != b:
            raise TypingError(
                t"qe compares two floats of one format, but got {c.text(a)} and {c.text(b)}: convert one first", arg=1
            )
        return c.qerr_
    var t = _float_type_arg(c, info)
    for i, arg in enumerate(info.args):
        var a = arg.type
        if c.is_any(a) or c.is_any(t):
            continue
        if c.tkind(a) == .FLOAT and a != t:
            raise TypingError(t"qe<{c.text(t)}> compares {c.text(t)} values, but {_argument(i)} is {c.text(a)}", arg=i)
        if not c.is_numeric(a):
            raise TypingError(
                t"qe<{c.text(t)}> takes {c.text(t)} values or numbers, but {_argument(i)} is {c.text(a)}", arg=i
            )
    return c.qerr_


def _eq(mut c: Checker, info: CallInfo) raises TypingError -> Int:
    var t = _same_type(c, info)
    for kw in info.keywords:
        if kw.key != "float" and kw.key != "order":
            continue
        var choices = '"bits" | "ieee" | "nan_any"' if kw.key == "float" else '"exact" | "ignore"'
        if c.kind_of(kw.node) != .STR or not _eq_mode_ok(c.text_of(kw.node), kw.key):
            raise TypingError(t"eq: {kw.key}= must be one of {choices}", key=kw.key.copy())
    if not any([kw.key == "float" for kw in info.keywords]) and c.contains_float(t):
        raise TypingError(
            t"eq compares values of type {c.text(t)}, which contain floats: say how to compare them with "
            t'float="bits" (bit-identical), float="ieee" or float="nan_any"'
        )
    return c.bool_


def _eq_mode_ok(value: String, key: String) -> Bool:
    """Whether `value` is a mode of eq's keyword `key`, float or order."""
    match value:
        case "bits" | "ieee" | "nan_any":
            return key == "float"
        case "exact" | "ignore":
            return key == "order"
        case _:
            return False


def prelude_type(mut c: Checker, sig: PreludeSig, info: CallInfo) raises TypingError -> Int:
    """The result type of a prelude call."""
    var first = info.args[0].type if info.args else c.poison
    match sig.rule:
        case .FloatPredicate:
            _float(c, info, 0)
            return c.bool_
        case .Bits:
            _float(c, info, 0)
            return c.int_
        case .SameFloat:
            _float(c, info, 0)
            return first
        case .Ulp:
            _ = _float_type_arg(c, info)
            _real_like(c, info, 0)
            return c.real_
        case .Qe:
            return _qe(c, info)
        case .QerrPart:
            var k = c.tkind(first)
            if k != .QERR and k != .ANY:
                raise TypingError(
                    t"{info.name} takes a qerr (the value of qe(a, b)), but argument 1 is {c.text(first)}", arg=0
                )
            return c.int_
        case .Cr:
            var k = c.tkind(first)
            if k == .FLOAT or k == .ANY:
                return first
            var hint = String(t"; for a real use mp.{info.name[byte=3:]}") if c.is_numeric(first) else String()
            raise TypingError(
                t"{info.name} rounds in the format of its argument, so it takes a float, but argument 1 is "
                t"{c.text(first)}{hint}",
                arg=0,
            )
        case .Same:
            _ = _same_type(c, info)
            return c.bool_
        case .IeeeEq:
            _float(c, info, 0)
            _float(c, info, 1)
            return c.bool_
        case .Real | .Mp:
            _real_like(c, info, 0)
            return c.real_
        case .Round:
            var t = _float_type_arg(c, info)
            _real_like(c, info, 0)
            return t
        case .Wrap:
            var t = _type_arg(c, info, [.FIXED_INT], "a fixed-width integer type (i8 ... u64)")
            _integer(c, info, 0)
            return t
        case .Fits:
            _ = _type_arg(c, info, [.FIXED_INT, .FLOAT], "a fixed-width integer or float type")
            _real_like(c, info, 0)
            return c.bool_
        case .LeUint:
            _bytes(c, info, 0)
            return c.int_
        case .Len:
            match c.tkind(first):
                case .LIST | .STRING | .LITERAL | .BYTES | .MAP | .ANY:
                    return c.int_
                case _:
                    raise TypingError(
                        t"len takes a list, string, bytes or map, but argument 1 is {c.text(first)}", arg=0
                    )
        case .Sorted:
            var elem = _list_elem(c, info, 0)
            _ordered_elems(c, info, elem)
            return first if c.tkind(first) == .LIST else c.spec.types.list_of(elem)
        case .IsSorted:
            _ordered_elems(c, info, _list_elem(c, info, 0))
            return c.bool_
        case .TwoLists:
            var a = _list_elem(c, info, 0)
            var b = _list_elem(c, info, 1)
            var elem = c.join(a, b)
            if elem < 0:
                raise TypingError(
                    t"{info.name} takes two lists of one element type, but got {c.text(first)} and "
                    t"{c.text(info.args[1].type)}",
                    arg=1,
                )
            _eq_elems(c, info, elem)
            return c.bool_
        case .Distinct:
            _eq_elems(c, info, _list_elem(c, info, 0))
            return c.bool_
        case .IndexOf:
            var elem = _list_elem(c, info, 0)
            var x = info.args[1].type
            var t = c.join(elem, x)
            if t < 0:
                raise TypingError(
                    t"index_of looks for a {c.text(elem)} in {c.text(first)}, but argument 2 is {c.text(x)}", arg=1
                )
            _eq_elems(c, info, t)
            return c.int_
        case .Keys | .Values:
            match c.tkind(first):
                case .MAP:
                    return c.spec.types.list_of(c.arg(first, 0 if sig.rule == .Keys else 1))
                case .ANY:
                    return c.spec.types.list_of(first)
                case _:
                    raise TypingError(t"{info.name} takes a map, but argument 1 is {c.text(first)}", arg=0)
        case .Range:
            _integer(c, info, 0)
            _integer(c, info, 1)
            return c.spec.types.list_of(c.int_)
        case .Some:
            return c.spec.types.option_of(first)
        case .OptionPredicate:
            _ = _option_elem(c, info, 0)
            return c.bool_
        case .Unwrap:
            return _option_elem(c, info, 0)
        case .ValidUtf8:
            _bytes(c, info, 0)
            return c.bool_
        case .Codepoints:
            if not (c.is_stringish(first) or c.is_any(first)):
                raise TypingError(t"codepoints takes a string, but {_argument(0)} is {c.text(first)}", arg=0)
            return c.spec.types.list_of(c.int_)
        case .Fresh:
            _model(c, info, 0)
            return c.bool_
        case .TwoModels:
            _model(c, info, 0)
            _model(c, info, 1)
            return c.bool_
        case .Eq:
            return _eq(c, info)
        case .BitLength:
            _integer(c, info, 0)
            return c.int_
        case .FromCodepoints:
            var elem = _list_elem(c, info, 0)
            if not (c.is_integer(elem) or c.is_any(elem)):
                raise TypingError(
                    t"from_codepoints takes a list of integers, but argument 1 is {c.text(first)}", arg=0
                )
            return c.string_
