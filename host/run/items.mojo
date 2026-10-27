"""The items a spec has: one per clause a run judges, and the built-in clauses."""

from check import types as ty
from eval.text import source_text
from syntax import ast
from wire.value import Value

from .load import Loaded
from .results import Obj, strings


def _models_in(types: ty.Types, t: Int, mut out: List[String]):
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
            _models_in(types, a, out)


def _item(
    decl: String,
    id: String,
    kind: String,
    text: String,
    line: Int,
    tparams: List[String],
) raises -> Value:
    var o = Obj()
    o.text("decl", decl)
    o.text("clause_id", id)
    o.text("kind", kind)
    o.text("text", text)
    o.num("line", line)
    o.put("tparams", strings(tparams))
    return o^.build()


def items_of(loaded: Loaded) raises -> List[Value]:
    """The items of every function of the spec, in source order. A `requires` clause
    and the freedoms are not items."""
    ref spec = loaded.spec
    var out = List[Value]()
    for f in range(len(spec.fns)):
        ref func = spec.fns[f]
        if func.kind != ast.FN:
            continue
        var has_modifies = False
        for c in func.clauses:
            ref cl = spec.clauses[c]
            var k = cl.kind
            if k == ast.ENSURES or k == ast.RELATES or k == ast.RAISES or k == ast.AGGREGATE or k == ast.MODIFIES:
                out.append(
                    _item(func.decl_id, cl.id, String(ast.op_name(k)), source_text(spec, cl.node), spec.ast.nodes[cl.node].span.line, func.tparams)
                )
            if k == ast.MODIFIES:
                has_modifies = True
        var line = spec.ast.nodes[func.node].span.line
        out.append(
            _item(
                func.decl_id,
                func.decl_id + "#type",
                "type",
                String("built-in: the result of ", func.name, " reads as ", spec.types.text(func.result)),
                line,
                func.tparams,
            )
        )
        out.append(
            _item(
                func.decl_id,
                func.decl_id + "#raises",
                "raises",
                String("built-in: ", func.name, " raises only what a raises or may_raise admits"),
                line,
                func.tparams,
            )
        )
        var handles = List[String]()
        for p in func.params:
            ref t = spec.types.info(p.type)
            if t.kind == ty.MODEL and not t.signed:
                handles.append(p.name.copy())
        if len(handles) > 0 and not has_modifies:
            out.append(
                _item(
                    func.decl_id,
                    func.decl_id + "#frame",
                    "frame",
                    String("built-in: ", func.name, " leaves its handle parameters unchanged (no modifies clause)"),
                    line,
                    func.tparams,
                )
            )
        var models = List[String]()
        _models_in(spec.types, func.result, models)
        for p in func.params:
            for n in func.clauses:
                if spec.clauses[n].kind == ast.MODIFIES:
                    for q in spec.clauses[n].names:
                        if q == p.name:
                            _models_in(spec.types, p.type, models)
        for name in models:
            var m = spec.model_named(name)
            if not m:
                continue
            for c in spec.models[m.value()].clauses:
                ref cl = spec.clauses[c]
                if cl.kind == ast.INVARIANT:
                    out.append(
                        _item(func.decl_id, func.decl_id + ":" + cl.id, "invariant", source_text(spec, cl.node), spec.ast.nodes[cl.node].span.line, func.tparams)
                    )
    return out^
