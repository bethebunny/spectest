"""The items a spec has: one per clause a run judges, and the built-in clauses."""

from spec.spec import Fn, Model, Spec
from eval.text import source_text
from spec import ast
from value.value import Value

from .load import Loaded
from .results import Obj, strings
from .util import invariant_models, is_handle


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
    spec: Spec, func: Fn, decl: String, tparams: List[String], kinds: List[ast.Op], mut out: List[Value]
) raises:
    """Appends the items of the clauses of `func` with one of `kinds`."""
    for c in func.clauses:
        ref cl = spec.clauses[c]
        if cl.kind in kinds:
            out.append(_item(spec, decl, tparams, cl.id, String(cl.kind), source_text(spec, cl.node), cl.node))


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
        if cl.kind == .INVARIANT:
            out.append(_item(spec, decl, tparams, prefix + cl.id, "invariant", source_text(spec, cl.node), cl.node))


def _modified(spec: Spec, func: Fn) -> List[String]:
    """The parameters the modifies clauses of `func` name."""
    var names: List[String] = []
    for c in func.clauses:
        if spec.clauses[c].kind == .MODIFIES:
            names += spec.clauses[c].names.copy()
    return names^


def _modifies(spec: Spec, func: Fn) -> Bool:
    return any([spec.clauses[c].kind == .MODIFIES for c in func.clauses])


def _interface_items(spec: Spec, f: Int, mut out: List[Value]) raises:
    """A constructor or method of an interface (`decl` is the interface's name), and
    after the last member the interface's invariants."""
    ref func = spec.fns[f]
    if func.owner < 0:
        return
    ref model = spec.models[func.owner]
    var kinds: List[ast.Op] = [.ENSURES, .RELATES, .RAISES, .MODIFIES]
    _clause_items(spec, func, model.name, model.tparams, kinds, out)
    var frame = "leaves every live object unchanged (no modifies clause)" if func.receiver and not _modifies(spec, func) else ""
    _builtin_items(spec, func, model.name, model.tparams, frame, out)
    var members = model.ctors + model.methods.copy()
    if members[len(members) - 1] == f:
        _invariant_items(spec, model, model.name, model.tparams, "", out)


def items_of(loaded: Loaded) raises -> List[Value]:
    """The items of every function of the spec, in source order (`requires` and the freedoms are not items)."""
    ref spec = loaded.spec
    var out: List[Value] = []
    for f in range(len(spec.fns)):
        ref func = spec.fns[f]
        if func.kind != .FN:
            _interface_items(spec, f, out)
            continue
        ref decl = func.decl_id
        var kinds: List[ast.Op] = [.ENSURES, .RELATES, .RAISES, .AGGREGATE, .MODIFIES]
        _clause_items(spec, func, decl, func.tparams, kinds, out)
        var has_handles = any([is_handle(spec.types, p.type) for p in func.params])
        var frame = "leaves its handle parameters unchanged (no modifies clause)" if has_handles and not _modifies(spec, func) else ""
        _builtin_items(spec, func, decl, func.tparams, frame, out)
        var param_types = [p.type for p in func.params]
        for m in invariant_models(spec, func, param_types, func.result, _modified(spec, func)):
            _invariant_items(spec, spec.models[m], decl, func.tparams, decl + ":", out)
    return out^
