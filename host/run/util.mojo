"""Small pure helpers of the runner: names of errors, skip causes, models inside types,
instantiation types."""

from check import types as ty
from wire.value import HANDLE, LIST, MAP, OPTION, TUPLE, Value

comptime N_CAUSES = 8


def cause_index(cause: String) -> Int:
    if cause == "requires":
        return 0
    if cause == "raised":
        return 1
    if cause == "raise due":
        return 2
    if cause == "wrong type":
        return 3
    if cause == "unrepresentable":
        return 4
    if cause == "rejected":
        return 5
    if cause == "planned call":
        return 6
    return 7


def cause_name(i: Int) -> String:
    if i == 0:
        return "requires"
    if i == 1:
        return "raised"
    if i == 2:
        return "raise due"
    if i == 3:
        return "wrong type"
    if i == 4:
        return "unrepresentable"
    if i == 5:
        return "rejected"
    if i == 6:
        return "planned call"
    return "other"


def norm_name(name: String) -> String:
    if name.startswith("builtins."):
        return String(name[byte = 9 :])
    return name.copy()


def type_has_model(types: ty.Types, t: Int) -> Bool:
    ref info = types.info(t)
    if info.kind == ty.MODEL:
        return True
    if info.kind == ty.LIST or info.kind == ty.OPTION or info.kind == ty.TUPLE or info.kind == ty.MAP or info.kind == ty.RECORD:
        for a in info.args:
            if type_has_model(types, a):
                return True
    return False


def collect_models(types: ty.Types, t: Int, mut out: List[String]):
    ref info = types.info(t)
    if info.kind == ty.MODEL:
        if not info.signed:
            for n in out:
                if n == info.name:
                    return
            out.append(info.name.copy())
        return
    if info.kind == ty.LIST or info.kind == ty.OPTION or info.kind == ty.TUPLE or info.kind == ty.MAP or info.kind == ty.RECORD:
        for a in info.args:
            collect_models(types, a, out)


def handles_of(types: ty.Types, v: Value, t: Int, model: String, mut out: List[Value]):
    """The handles of model `model` inside `v`, a value of type `t`."""
    ref info = types.info(t)
    if info.kind == ty.MODEL:
        if info.name == model and v.kind == HANDLE:
            out.append(v.copy())
        return
    if (info.kind == ty.LIST and (v.kind == LIST)) or (info.kind == ty.OPTION and v.kind == OPTION):
        for i in range(v.count()):
            handles_of(types, v.item(i), info.args[0], model, out)
    elif info.kind == ty.TUPLE and v.kind == TUPLE and v.count() == len(info.args):
        for i in range(v.count()):
            handles_of(types, v.item(i), info.args[i], model, out)
    elif info.kind == ty.MAP and v.kind == MAP:
        for i in range(v.count()):
            handles_of(types, v.item(2 * i), info.args[0], model, out)
            handles_of(types, v.item(2 * i + 1), info.args[1], model, out)


def parse_type(text: String, mut types: ty.Types) raises -> Int:
    """A type as an instantiation writes it: a scalar name, or `list<T>`, `option<T>`."""
    var s = String(text.strip())
    var found = types.scalar(s)
    if found:
        return found.value()
    if s.startswith("list<") and s.endswith(">"):
        return types.list_of(parse_type(String(s[byte = 5 : s.byte_length() - 1]), types))
    if s.startswith("option<") and s.endswith(">"):
        return types.option_of(parse_type(String(s[byte = 7 : s.byte_length() - 1]), types))
    raise Error(String("the instantiation names a type that is not a scalar, list or option: ", text))


def contains_name(items: List[String], name: String) -> Bool:
    for n in items:
        if norm_name(n) == norm_name(name):
            return True
    return False


def names_text(items: List[String]) -> String:
    var sorted_names = List[String]()
    for n in items:
        var seen = False
        for m in sorted_names:
            if m == n:
                seen = True
        if not seen:
            sorted_names.append(n)
    # Insertion sort: there are few.
    for a in range(1, len(sorted_names)):
        var v = sorted_names[a]
        var b = a - 1
        while b >= 0 and sorted_names[b] > v:
            sorted_names[b + 1] = sorted_names[b]
            b -= 1
        sorted_names[b + 1] = v
    var out = String("{")
    for k in range(len(sorted_names)):
        out += (", " if k else "") + sorted_names[k]
    return out + "}"


