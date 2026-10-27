"""The items a spec has: one per clause a run judges, and the built-in clauses."""

from check import types as ty
from check.spec import Spec
from eval.text import source_text
from syntax import ast
from wire.value import Value

from .load import Loaded
from .results import Obj, strings
from .util import collect_models


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


def _interface_items(spec: Spec, f: Int, mut out: List[Value]) raises:
    """The items of a constructor or method of an interface, which a run of the
    interface covers (`decl` is the interface's name), and after its last member the
    interface's invariants."""
    ref func = spec.fns[f]
    if func.owner < 0:
        return
    ref model = spec.models[func.owner]
    var line = spec.ast.nodes[func.node].span.line
    var has_modifies = False
    for c in func.clauses:
        ref cl = spec.clauses[c]
        var k = cl.kind
        if k == ast.ENSURES or k == ast.RELATES or k == ast.RAISES or k == ast.MODIFIES:
            out.append(
                _item(model.name, cl.id, String(ast.op_name(k)), source_text(spec, cl.node), spec.ast.nodes[cl.node].span.line, model.tparams)
            )
        if k == ast.MODIFIES:
            has_modifies = True
    out.append(
        _item(
            model.name,
            func.decl_id + "#type",
            "type",
            String("built-in: the result of ", func.name, " reads as ", spec.types.text(func.result)),
            line,
            model.tparams,
        )
    )
    out.append(
        _item(
            model.name,
            func.decl_id + "#raises",
            "raises",
            String("built-in: ", func.name, " raises only what a raises or may_raise admits"),
            line,
            model.tparams,
        )
    )
    if func.receiver and not has_modifies:
        out.append(
            _item(
                model.name,
                func.decl_id + "#frame",
                "frame",
                String("built-in: ", func.name, " leaves every live object unchanged (no modifies clause)"),
                line,
                model.tparams,
            )
        )
    var last = len(model.ctors) + len(model.methods) - 1
    var position = -1
    for k in range(len(model.ctors)):
        if model.ctors[k] == f:
            position = k
    for k in range(len(model.methods)):
        if model.methods[k] == f:
            position = len(model.ctors) + k
    if position == last:
        for c in model.clauses:
            ref cl = spec.clauses[c]
            if cl.kind == ast.INVARIANT:
                out.append(
                    _item(model.name, cl.id, "invariant", source_text(spec, cl.node), spec.ast.nodes[cl.node].span.line, model.tparams)
                )


def items_of(loaded: Loaded) raises -> List[Value]:
    """The items of every function of the spec, in source order. A `requires` clause
    and the freedoms are not items."""
    ref spec = loaded.spec
    var out = List[Value]()
    for f in range(len(spec.fns)):
        ref func = spec.fns[f]
        if func.kind != ast.FN:
            _interface_items(spec, f, out)
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
        collect_models(spec.types, func.result, models)
        for p in func.params:
            for n in func.clauses:
                if spec.clauses[n].kind == ast.MODIFIES:
                    for q in spec.clauses[n].names:
                        if q == p.name:
                            collect_models(spec.types, p.type, models)
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
