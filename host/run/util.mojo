"""Small pure helpers of the runner: names of errors, skip causes, models inside types,
instantiation types."""

from std.collections import Set

from check import types as ty
from wire.value import Value

comptime N_CAUSES = 8


def _cause_names() -> List[String]:
    return ["requires", "raised", "raise due", "wrong type", "unrepresentable", "rejected", "planned call", "other"]


def cause_index(cause: String) -> Int:
    for i, name in enumerate(_cause_names()):
        if name == cause:
            return i
    return N_CAUSES - 1


def cause_name(i: Int) -> String:
    return _cause_names()[i] if i < N_CAUSES - 1 else "other"


def norm_name(name: String) -> String:
    return String(name.removeprefix("builtins."))


def _has_parts(kind: UInt8) -> Bool:
    match kind:
        case ty.LIST | ty.OPTION | ty.TUPLE | ty.MAP | ty.RECORD:
            return True
        case _:
            return False


def type_has_model(types: ty.Types, t: Int) -> Bool:
    ref info = types.info(t)
    return info.kind == ty.MODEL or (_has_parts(info.kind) and any([type_has_model(types, a) for a in info.args]))


def collect_models(types: ty.Types, t: Int, mut out: List[String]):
    ref info = types.info(t)
    if info.kind == ty.MODEL:
        if not info.signed and info.name not in out:
            out.append(info.name.copy())
    elif _has_parts(info.kind):
        for a in info.args:
            collect_models(types, a, out)


def handles_of(types: ty.Types, v: Value, t: Int, model: String) -> List[Value]:
    """The handles of model `model` inside `v`, a value of type `t`."""
    ref info = types.info(t)
    var out: List[Value] = []
    match info.kind, v.kind:
        case ty.MODEL, .HANDLE if info.name == model:
            out.append(v.copy())
        case (ty.LIST, .LIST) | (ty.OPTION, .OPTION):
            for item in v.items():
                out += handles_of(types, item, info.args[0], model)
        case ty.TUPLE, .TUPLE if v.count() == len(info.args):
            for i, arg in enumerate(info.args):
                out += handles_of(types, v.item(i), arg, model)
        case ty.MAP, .MAP:
            for key, value in v.pairs():
                out += handles_of(types, key, info.args[0], model)
                out += handles_of(types, value, info.args[1], model)
        case _:
            pass
    return out^


def parse_type(text: String, mut types: ty.Types) raises -> Int:
    """A type as an instantiation writes it: a scalar name, or `list<T>`, `option<T>`."""
    var s = String(text.strip())
    if case .Some(scalar) = types.scalar(s):
        return scalar
    if s.startswith("list<") and s.endswith(">"):
        return types.list_of(parse_type(String(s[byte = 5 : s.byte_length() - 1]), types))
    if s.startswith("option<") and s.endswith(">"):
        return types.option_of(parse_type(String(s[byte = 7 : s.byte_length() - 1]), types))
    raise Error(t"the instantiation names a type that is not a scalar, list or option: {text}")


def contains_name(items: List[String], name: String) -> Bool:
    return any([norm_name(n) == norm_name(name) for n in items])


def names_text(items: List[String]) -> String:
    var names = List(Set(items))
    sort(names)
    return String("{", ", ".join(names), "}")
