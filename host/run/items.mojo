"""The items a spec has: one per clause a run judges, and the built-in clauses."""

from check import types as ty
from check.spec import Fn, Model, Spec
from eval.text import source_text
from syntax import ast
from wire.value import Value

from .load import Loaded
from .results import Obj, strings
from .util import collect_models


def _item(
    spec: Spec, decl: String, tparams: List[String], clause_id: String, kind: String, text: String, node: Int
) raises -> Value:
    var o = Obj()
    o.text("decl", decl)
    o.text("clause_id", clause_id)
    o.text("kind", kind)
    o.text("text", text)
    o.num("line", spec.ast.nodes[node].span.line)
    o.text("file", spec.ast.path_of(node))
    o.put("tparams", strings(tparams))
    return o^.build()


def _clause_items(
    spec: Spec, func: Fn, decl: String, tparams: List[String], kinds: List[UInt8], mut out: List[Value]
) raises -> Bool:
    """Appends the items of the clauses of `func` with one of `kinds`; True when it has a modifies clause."""
    var modifies = False
    for c in func.clauses:
        ref cl = spec.clauses[c]
        if cl.kind in kinds:
            out.append(_item(spec, decl, tparams, cl.id, String(ast.op_name(cl.kind)), source_text(spec, cl.node), cl.node))
        modifies = modifies or cl.kind == ast.MODIFIES
    return modifies


def _builtin_items(
    spec: Spec, func: Fn, decl: String, tparams: List[String], frame: String, mut out: List[Value]
) raises:
    """The built-in `#type` and `#raises` items, and `#frame` when `frame` says what it checks."""
    var id = func.decl_id
    var type_text = String("built-in: the result of ", func.name, " reads as ", spec.types.text(func.result))
    out.append(_item(spec, decl, tparams, id + "#type", "type", type_text, func.node))
    var raises_text = String("built-in: ", func.name, " raises only what a raises or may_raise admits")
    out.append(_item(spec, decl, tparams, id + "#raises", "raises", raises_text, func.node))
    if frame:
        out.append(_item(spec, decl, tparams, id + "#frame", "frame", String("built-in: ", func.name, " ", frame), func.node))


def _invariant_items(
    spec: Spec, model: Model, decl: String, tparams: List[String], prefix: String, mut out: List[Value]
) raises:
    for c in model.clauses:
        ref cl = spec.clauses[c]
        if cl.kind == ast.INVARIANT:
            out.append(_item(spec, decl, tparams, prefix + cl.id, "invariant", source_text(spec, cl.node), cl.node))


def _interface_items(spec: Spec, f: Int, mut out: List[Value]) raises:
    """A constructor or method of an interface (`decl` is the interface's name), and
    after the last member the interface's invariants."""
    ref func = spec.fns[f]
    if func.owner < 0:
        return
    ref model = spec.models[func.owner]
    var modifies = _clause_items(spec, func, model.name, model.tparams, [ast.ENSURES, ast.RELATES, ast.RAISES, ast.MODIFIES], out)
    var frame = "leaves every live object unchanged (no modifies clause)" if func.receiver and not modifies else ""
    _builtin_items(spec, func, model.name, model.tparams, frame, out)
    var members = model.ctors + model.methods.copy()
    if members[len(members) - 1] == f:
        _invariant_items(spec, model, model.name, model.tparams, "", out)


def items_of(loaded: Loaded) raises -> List[Value]:
    """The items of every function of the spec, in source order (`requires` and the freedoms are not items)."""
    ref spec = loaded.spec
    var out = List[Value]()
    for f in range(len(spec.fns)):
        ref func = spec.fns[f]
        if func.kind != ast.FN:
            _interface_items(spec, f, out)
            continue
        var decl = func.decl_id
        var modifies = _clause_items(
            spec, func, decl, func.tparams, [ast.ENSURES, ast.RELATES, ast.RAISES, ast.AGGREGATE, ast.MODIFIES], out
        )
        var has_handles = any([spec.types.info(p.type).kind == ty.MODEL and not spec.types.info(p.type).signed for p in func.params])
        var frame = "leaves its handle parameters unchanged (no modifies clause)" if has_handles and not modifies else ""
        _builtin_items(spec, func, decl, func.tparams, frame, out)
        var models = List[String]()
        collect_models(spec.types, func.result, models)
        for p in func.params:
            for n in func.clauses:
                if spec.clauses[n].kind == ast.MODIFIES and p.name in spec.clauses[n].names:
                    collect_models(spec.types, p.type, models)
        for name in models:
            var m = spec.model_named(name)
            if m is not None:
                _invariant_items(spec, spec.models[m.value()], decl, func.tparams, decl + ":", out)
    return out^
