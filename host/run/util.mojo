"""Small pure helpers of the runner: names of errors, skip causes, models inside types,
instantiation types."""

from std.builtin.sort import sort

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
    if name.startswith("builtins."):
        return String(name[byte = 9 :])
    return name.copy()


def _has_parts(kind: UInt8) -> Bool:
    return kind == ty.LIST or kind == ty.OPTION or kind == ty.TUPLE or kind == ty.MAP or kind == ty.RECORD


def type_has_model(types: ty.Types, t: Int) -> Bool:
    ref info = types.info(t)
    return info.kind == ty.MODEL or (_has_parts(info.kind) and any([type_has_model(types, a) for a in info.args]))


def collect_models(types: ty.Types, t: Int, mut out: List[String]):
    ref info = types.info(t)
    if info.kind == ty.MODEL:
        if not info.signed and info.name not in out:
            out.append(info.name.copy())
        return
    if _has_parts(info.kind):
        for a in info.args:
            collect_models(types, a, out)


def handles_of(types: ty.Types, v: Value, t: Int, model: String, mut out: List[Value]):
    """The handles of model `model` inside `v`, a value of type `t`."""
    ref info = types.info(t)
    if info.kind == ty.MODEL:
        if info.name == model and v.kind == .HANDLE:
            out.append(v.copy())
        return
    if (info.kind == ty.LIST and (v.kind == .LIST)) or (info.kind == ty.OPTION and v.kind == .OPTION):
        for i in range(v.count()):
            handles_of(types, v.item(i), info.args[0], model, out)
    elif info.kind == ty.TUPLE and v.kind == .TUPLE and v.count() == len(info.args):
        for i in range(v.count()):
            handles_of(types, v.item(i), info.args[i], model, out)
    elif info.kind == ty.MAP and v.kind == .MAP:
        for i in range(v.count()):
            handles_of(types, v.item(2 * i), info.args[0], model, out)
            handles_of(types, v.item(2 * i + 1), info.args[1], model, out)


def parse_type(text: String, mut types: ty.Types) raises -> Int:
    """A type as an instantiation writes it: a scalar name, or `list<T>`, `option<T>`."""
    var s = String(text.strip())
    var scalar = types.scalar(s)
    if scalar is not None:
        return scalar.value()
    if s.startswith("list<") and s.endswith(">"):
        return types.list_of(parse_type(String(s[byte = 5 : s.byte_length() - 1]), types))
    if s.startswith("option<") and s.endswith(">"):
        return types.option_of(parse_type(String(s[byte = 7 : s.byte_length() - 1]), types))
    raise Error(String("the instantiation names a type that is not a scalar, list or option: ", text))


def contains_name(items: List[String], name: String) -> Bool:
    return any([norm_name(n) == norm_name(name) for n in items])


def names_text(items: List[String]) -> String:
    var names = items.copy()
    sort(names)
    var distinct = [n for i, n in enumerate(names) if i == 0 or n != names[i - 1]]
    return String("{", ", ".join(distinct), "}")
