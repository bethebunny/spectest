"""Type syntax to types: built-ins, enums, records, aliases, models and choices.

Type variables in scope are the ones in `Checker.ctx`. Aliases and records resolve on
first use, so a declaration may use one declared later; a cycle is reported.
"""

from check.state import Checker, Ctx, NO_TYPE, type_hint
from check.types import ANY_TYPE


def _no_args(mut c: Checker, node: Int, t: Int) -> Int:
    if c.children(node):
        c.error(node, t"{c.text_of(node)} takes no type arguments")
    return t


def _top_level_type(mut c: Checker, node: Int) -> Int:
    """The type `node` denotes outside any declaration, where no type variables are in scope."""
    var saved = Ctx()
    swap(saved, c.ctx)
    var t = resolve_type(c, node)
    swap(saved, c.ctx)
    return t


def ensure_const(mut c: Checker, idx: Int):
    """Resolve the declared type of constant `idx` if it is not yet."""
    if c.spec.consts[idx].type < 0:
        c.spec.consts[idx].type = _top_level_type(c, c.child(c.spec.consts[idx].node, 0))


def resolve_type(mut c: Checker, node: Int, self_model: Int = -1) -> Int:
    match c.kind_of(node):
        case .CHOICE_TYPE:
            return _choice(c, node)
        case .TUPLE_TYPE:
            var elems = [resolve_type(c, k, self_model) for k in c.children(node)]
            return c.spec.types.tuple_of(elems)
        case _:
            return _named(c, node, self_model)


def _choice(mut c: Checker, node: Int) -> Int:
    var alternatives = c.children(node)
    var literals = [c.text_of(k) for k in alternatives if c.kind_of(k) == .STR]
    if len(literals) == len(alternatives):
        var values: List[String] = []
        for v in literals:
            if v not in values:
                values.append(v.copy())
        if len(values) < len(literals):
            c.error(node, "a literal union lists a value twice")
        return c.spec.types.literal(values)
    if literals:
        c.error(node, "a choice is either string literals or library constants, not both")
        return c.poison
    var names: List[String] = []
    var elem = NO_TYPE
    var ok = True
    for k in alternatives:
        var name = c.text_of(k)
        var found = c.const_index.get(name)
        if found is None:
            c.error(k, t"unknown constant {name}: declare it with 'const {name}: T'")
            ok = False
            continue
        ensure_const(c, found.value())
        var t = c.spec.consts[found.value()].type
        if elem < 0:
            elem = t
        elif elem != t:
            c.error(
                k,
                t"the alternatives of a choice are declared with one type, but {name} is {c.text(t)} and "
                t"an earlier one is {c.text(elem)}",
            )
            ok = False
        if name in names:
            c.error(k, t"a choice lists {name} twice")
        else:
            names.append(name^)
    return c.spec.types.choice(names, elem) if ok else c.poison


def _named(mut c: Checker, node: Int, self_model: Int) -> Int:
    var name = c.text_of(node)
    var args = [resolve_type(c, k, self_model) for k in c.children(node)]
    var tv = c.ctx.tvar_index(name)
    if tv >= 0:
        return _no_args(c, node, c.ctx.tvars[tv].type)
    var st = c.scalar(name)
    if st >= 0:
        return _no_args(c, node, st)
    match name:
        case "map":
            if len(args) != 2:
                c.error(node, "map takes 2 type arguments: map<K, V>")
                return ANY_TYPE
            return c.spec.types.map_of(args[0], args[1])
        case "list" | "option":
            if len(args) != 1:
                c.error(node, t"{name} takes 1 type argument: {name}<T>")
                return ANY_TYPE
            return c.spec.types.list_of(args[0]) if name == "list" else c.spec.types.option_of(args[0])
        case "set" | "unit":
            c.error(node, t"{name} is not a type that can be written in a spec")
            return ANY_TYPE
        case _:
            pass
    if case .Some(en) = c.enum_index.get(name):
        return _no_args(c, node, en)
    if name in c.record_nodes:
        return _no_args(c, node, record_type(c, name, node))
    if name in c.alias_nodes:
        return _no_args(c, node, alias_type(c, name, node))
    if case .Some(model) = c.model_index.get(name):
        return _model(c, node, name, model, args, self_model)
    var hint = type_hint(name)
    var did_you_mean = String(t" (did you mean {hint}?)") if hint else String()
    c.error(node, t"unknown type {name}{did_you_mean}")
    return ANY_TYPE


def _model(mut c: Checker, node: Int, name: String, model: Int, args: List[Int], self_model: Int) -> Int:
    var tparams = c.spec.models[model].tparams.copy()
    var bounds = c.spec.models[model].bounds.copy()
    var tvars = c.spec.types.typevars(tparams, bounds)
    var is_iface = c.spec.models[model].is_interface
    if not args and tvars and model == self_model:
        return c.spec.types.model(name, tvars, is_iface)
    if len(args) != len(tvars):
        var listed = ", ".join(tparams)
        var shape = String(t"{name}<{listed}>") if tparams else name.copy()
        c.error(node, t"{name} takes {len(tvars)} type argument(s): {shape}")
        return ANY_TYPE
    for arg, tparam, bound in zip(args, tparams, bounds):
        if not c.satisfies(arg, bound):
            var what = "canonical equality" if bound == "Eq" else "a total order"
            c.error(node, t"{c.text(arg)} does not satisfy {tparam}: {bound} of {name} (it needs {what})")
    return c.spec.types.model(name, args, is_iface)


def alias_type(mut c: Checker, name: String, at: Int) -> Int:
    if case .Some(done) = c.spec.aliases.get(name):
        return done
    if name in c.active:
        c.error(at, t"type {name} is defined in terms of itself")
        return ANY_TYPE
    c.active.append(name)
    var t = _top_level_type(c, c.child(c.alias_nodes.get(name).value(), 0))
    _ = c.active.pop()
    c.spec.aliases[name] = t
    return t


def record_type(mut c: Checker, name: String, at: Int) -> Int:
    if case .Some(done) = c.record_types.get(name):
        return done
    if name in c.active:
        c.error(at, t"record {name} contains itself")
        return ANY_TYPE
    c.active.append(name)
    var fields: List[String] = []
    var types: List[Int] = []
    for p in c.children(c.record_nodes.get(name).value()):
        var field = c.text_of(p)
        for _ in range(fields.count(field)):
            c.error(p, t"record {name} has two fields named {field}")
        if c.child(p, 1) != 0:
            c.error(c.child(p, 1), "record fields cannot have defaults")
        fields.append(field^)
        if c.child(p, 0) == 0:
            c.error(p, "a record field needs a type")
            types.append(ANY_TYPE)
        else:
            types.append(_top_level_type(c, c.child(p, 0)))
    _ = c.active.pop()
    var t = c.spec.types.record(name.copy(), fields, types)
    c.record_types[name] = t
    return t
