"""Type syntax to types: built-ins, enums, records, aliases, models and choices.

Type variables in scope are the ones in `Checker.ctx`. Aliases and records resolve on
first use, so a declaration may use one declared later; a cycle is reported.
"""

from syntax import ast

from check import types as ty
from check.state import Checker, Ctx, NO_TYPE, type_hint


def _no_args(mut c: Checker, node: Int, t: Int) -> Int:
    if c.nkids(node) > 0:
        c.error(node, t"{c.text_of(node)} takes no type arguments")
    return t


def ensure_const(mut c: Checker, idx: Int):
    """Resolve the declared type of constant `idx` if it is not yet."""
    if c.spec.consts[idx].type >= 0:
        return
    var node = c.spec.consts[idx].node
    var saved = c.ctx.copy()
    c.ctx = Ctx()
    var t = resolve_type(c, c.kid(node, 0))
    c.ctx = saved^
    c.spec.consts[idx].type = t


def resolve_type(mut c: Checker, node: Int, self_model: Int = -1) -> Int:
    var k = c.kind_of(node)
    if k == ast.CHOICE_TYPE:
        return _choice(c, node)
    if k == ast.TUPLE_TYPE:
        var elems = List[Int]()
        for kid in c.kids_of(node):
            elems.append(resolve_type(c, kid, self_model))
        return c.spec.types.tuple_of(elems)
    return _named(c, node, self_model)


def _choice(mut c: Checker, node: Int) -> Int:
    var kids = c.kids_of(node)
    var strs = 0
    for kid in kids:
        if c.kind_of(kid) == ast.STR:
            strs += 1
    if strs == len(kids):
        var values = List[String]()
        var dup = False
        for kid in kids:
            var v = c.text_of(kid)
            var seen = False
            for x in values:
                if x == v:
                    seen = True
            if seen:
                dup = True
            else:
                values.append(v^)
        if dup:
            c.error(node, "a literal union lists a value twice")
        return c.spec.types.literal(values)
    if strs > 0:
        c.error(node, "a choice is either string literals or library constants, not both")
        return c.poison
    var names = List[String]()
    var elem = NO_TYPE
    var ok = True
    for kid in kids:
        var name = c.text_of(kid)
        var found = c.const_index.get(name)
        if not found:
            c.error(kid, t"unknown constant {name}: declare it with 'const {name}: T'")
            ok = False
            continue
        ensure_const(c, found.value())
        var t = c.spec.consts[found.value()].type
        if elem < 0:
            elem = t
        elif elem != t:
            c.error(
                kid,
                t"the alternatives of a choice are declared with one type, but {name} is {c.text(t)} and "
                t"an earlier one is {c.text(elem)}",
            )
            ok = False
        var dup = False
        for x in names:
            if x == name:
                dup = True
        if dup:
            c.error(kid, t"a choice lists {name} twice")
        else:
            names.append(name^)
    if not ok:
        return c.poison
    return c.spec.types.choice(names, elem)


def _named(mut c: Checker, node: Int, self_model: Int) -> Int:
    var name = c.text_of(node)
    var args = List[Int]()
    for kid in c.kids_of(node):
        args.append(resolve_type(c, kid, self_model))
    var tv = c.ctx.tv_index(name)
    if tv >= 0:
        return _no_args(c, node, c.ctx.tv_types[tv])
    var st = c.scalar(name)
    if st >= 0:
        return _no_args(c, node, st)
    if name == "list" or name == "option" or name == "map":
        var n = 2 if name == "map" else 1
        if len(args) != n:
            var shape = "list<T>"
            if name == "map":
                shape = "map<K, V>"
            elif name == "option":
                shape = "option<T>"
            c.error(
                node,
                String(name, " takes ", n, " type argument", ("s" if n > 1 else ""), ": ", shape),
            )
            return 0
        if name == "list":
            return c.spec.types.list_of(args[0])
        if name == "option":
            return c.spec.types.option_of(args[0])
        return c.spec.types.map_of(args[0], args[1])
    if name == "set" or name == "unit":
        c.error(node, t"{name} is not a type that can be written in a spec")
        return 0
    var en = c.enum_index.get(name)
    if en:
        return _no_args(c, node, en.value())
    if name in c.record_nodes:
        return _no_args(c, node, record_type(c, name, node))
    if name in c.alias_nodes:
        return _no_args(c, node, alias_type(c, name, node))
    var mp = c.model_index.get(name)
    if mp:
        return _model(c, node, name, mp.value(), args, self_model)
    var hint = type_hint(name)
    c.error(
        node,
        String("unknown type ", name, ((" (did you mean " + hint + "?)") if hint else "")),
    )
    return 0


def model_tvar_types(mut c: Checker, model: Int) -> List[Int]:
    return c.spec.types.typevars(c.spec.models[model].tparams, c.spec.models[model].bounds)


def _model(
    mut c: Checker, node: Int, name: String, model: Int, args: List[Int], self_model: Int
) -> Int:
    var tvars = model_tvar_types(c, model)
    var is_iface = c.spec.models[model].is_interface
    if len(args) == 0 and len(tvars) > 0 and model == self_model:
        return c.spec.types.model(name, tvars, is_iface)
    if len(args) != len(tvars):
        var shape = name
        if len(tvars) > 0:
            shape += "<"
            for i in range(len(tvars)):
                shape += ", " if i else ""
                shape += c.spec.types.infos[tvars[i]].name
            shape += ">"
        c.error(node, t"{name} takes {len(tvars)} type argument(s): {shape}")
        return 0
    var tparams = c.spec.models[model].tparams.copy()
    var bounds = c.spec.models[model].bounds.copy()
    for i in range(len(args)):
        if not c.satisfies(args[i], bounds[i]):
            var what = "canonical equality" if bounds[i] == "Eq" else "a total order"
            c.error(
                node,
                t"{c.text(args[i])} does not satisfy {tparams[i]}: {bounds[i]} of {name} (it needs {what})",
            )
    return c.spec.types.model(name, args, is_iface)


def alias_type(mut c: Checker, name: String, at: Int) -> Int:
    var done = c.spec.aliases.get(name)
    if done:
        return done.value()
    for a in c.active:
        if a == name:
            c.error(at, t"type {name} is defined in terms of itself")
            return 0
    c.active.append(name)
    var decl = c.alias_nodes.get(name).value()
    var saved = c.ctx.copy()
    c.ctx = Ctx()
    var t = resolve_type(c, c.kid(decl, 0))
    c.ctx = saved^
    _ = c.active.pop()
    c.spec.aliases[name] = t
    return t


def record_type(mut c: Checker, name: String, at: Int) -> Int:
    var done = c.record_types.get(name)
    if done:
        return done.value()
    for a in c.active:
        if a == name:
            c.error(at, t"record {name} contains itself")
            return 0
    c.active.append(name)
    var decl = c.record_nodes.get(name).value()
    var saved = c.ctx.copy()
    c.ctx = Ctx()
    var fields = List[String]()
    var types = List[Int]()
    for p in c.kids_of(decl):
        var fname = c.text_of(p)
        for f in fields:
            if f == fname:
                c.error(p, t"record {name} has two fields named {fname}")
        if c.kid(p, 1) != 0:
            c.error(c.kid(p, 1), "record fields cannot have defaults")
        fields.append(fname^)
        if c.kid(p, 0) == 0:
            c.error(p, "a record field needs a type")
            types.append(0)
        else:
            types.append(resolve_type(c, c.kid(p, 0)))
    c.ctx = saved^
    _ = c.active.pop()
    var t = c.spec.types.record(name.copy(), fields, types)
    c.record_types[name] = t
    return t
