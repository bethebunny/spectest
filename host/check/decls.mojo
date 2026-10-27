"""Declarations: collecting names, signatures, clause ids, partitions and the clause
rules of functions, models and interfaces, then the whole-file `run`.
"""

from std.builtin.sort import sort

from numeric.floats import exactly
from numeric.formats import format_by_id
from numeric.real import Real
from numeric.bigint import BigInt
from syntax import ast
from syntax.ast import Diagnostic

from check import types as ty
from check.exprs import (
    assignable,
    binds_value,
    infer,
    poison_subtree,
    want_bool,
)
from check.spec import (
    Build,
    Clause,
    Const,
    Def,
    Fn,
    Model,
    Observer,
    Param,
    Partition,
    PartitionClass,
    R_FIELD,
    R_OBSERVER,
    R_PRELUDE,
    R_TYPE_CONST,
)
from check.state import (
    Checker,
    Ctx,
    K_DEF,
    K_DEFAULT,
    K_OBSERVER,
    K_PARTITION,
    K_PARTITION_SET,
    NO_TYPE,
    is_builtin_type_name,
    is_reserved,
    qualify_error,
)
from check.typesyn import alias_type, ensure_const, record_type, resolve_type


# -- names ----------------------------------------------------------------------


def _where(c: Checker, here: Int, other: Int) -> String:
    """`line N` of `other`, with its file when that is not the file of `here`."""
    var line = "line " + String(c.line_of(other))
    if c.spec.ast.file_of(here) != c.spec.ast.file_of(other):
        return c.spec.ast.path_of(other) + ", " + line
    return line


def declare(mut c: Checker, name: String, node: Int) -> Bool:
    if is_builtin_type_name(name):
        c.error(node, t"{name} is a built-in type and cannot be redeclared")
    elif is_reserved(name):
        c.error(node, t"{name} is reserved and cannot name a declaration")
    elif name in c.names:
        c.error(node, t"{name} is already declared at {_where(c, node, c.names.get(name).value())}")
    else:
        c.names[name] = node
        return True
    c.duplicate[node] = True
    return False


def tvars_of(
    mut c: Checker, tparams: Int, mut names: List[String], mut bounds: List[String]
):
    for tp in c.kids_of(tparams):
        var name = c.text_of(tp)
        var bound = String()
        if c.nkids(tp) > 0:
            bound = c.text_of(c.kid(tp, 0))
            if bound != "Eq" and bound != "Ord":
                c.error(tp, t"unknown bound {bound}: a type parameter's bound is Eq or Ord")
                bound = String()
        var dup = False
        for n in names:
            if n == name:
                dup = True
        if dup:
            c.error(tp, t"type parameter {name} is declared twice")
        elif is_builtin_type_name(name):
            c.error(tp, t"type parameter {name} shadows a built-in type")
        names.append(name^)
        bounds.append(bound^)


def set_tvars(mut c: Checker, names: List[String], bounds: List[String]):
    c.ctx.tv_names = names.copy()
    c.ctx.tv_types = c.spec.types.typevars(names, bounds)


def _has_modifies(c: Checker, decl: Int) -> Bool:
    for k in c.spec.ast.nodes[decl].kids:
        if c.kind_of(k) == ast.CLAUSE and c.op_of(k) == ast.MODIFIES:
            return True
    return False


def _new_fn(
    mut c: Checker,
    name: String,
    target: String,
    decl_id: String,
    kind: UInt8,
    node: Int,
    owner: Int,
    tparams: List[String],
    bounds: List[String],
) -> Int:
    c.spec.fns.append(
        Fn(
            name,
            target,
            decl_id,
            kind,
            node,
            owner,
            tparams.copy(),
            bounds.copy(),
            List[Param](),
            False,
            0,
            List[Partition](),
            List[Int](),
        )
    )
    c.fn_modifies.append(_has_modifies(c, node))
    c.decl_pos[node] = len(c.spec.fns) - 1
    return len(c.spec.fns) - 1


def collect(mut c: Checker):
    for d in c.decl_nodes():
        var k = c.kind_of(d)
        if k == ast.ERROR:
            var name = c.text_of(d)
            if declare(c, name, d):
                c.spec.errors.append(qualify_error(name))
        elif k == ast.CONST:
            var name = c.text_of(d)
            if declare(c, name, d):
                c.spec.consts.append(Const(name, -1, d))
                c.const_index[name] = len(c.spec.consts) - 1
        elif k == ast.ENUM:
            var name = c.text_of(d)
            var members = List[String]()
            for m in c.kids_of(d):
                var mn = c.text_of(m)
                var seen = False
                for x in members:
                    if x == mn:
                        seen = True
                if seen:
                    c.error(d, t"enum {name} lists a member twice")
                else:
                    members.append(mn^)
            if declare(c, name, d):
                var t = c.spec.types.enum_(name.copy(), members)
                c.spec.enums.append(t)
                c.enum_index[name] = t
        elif k == ast.RECORD:
            var name = c.text_of(d)
            if declare(c, name, d):
                c.record_nodes[name] = d
        elif k == ast.ALIAS:
            var name = c.text_of(d)
            if declare(c, name, d):
                c.alias_nodes[name] = d
        elif k == ast.MODEL or k == ast.INTERFACE:
            _collect_model(c, d)
        elif k == ast.FN:
            var name = c.text_of(d)
            if declare(c, name, d):
                var tn = List[String]()
                var tb = List[String]()
                tvars_of(c, c.kid(d, 0), tn, tb)
                var pos = _new_fn(c, name.copy(), name.copy(), name.copy(), ast.FN, d, -1, tn, tb)
                c.fn_index[name] = pos
            else:
                var tn = List[String]()
                var tb = List[String]()
                tvars_of(c, c.kid(d, 0), tn, tb)
        elif k == ast.DEF:
            var name = c.text_of(d)
            var tn = List[String]()
            var tb = List[String]()
            tvars_of(c, c.kid(d, 0), tn, tb)
            if name in c.prelude_ids:
                c.error(d, t"{name} is a prelude function and cannot be redefined")
                c.duplicate[d] = True
            elif (
                name in c.names
                and c.spec.ast.kind_of_file(c.names.get(name).value()) == ast.FILE
                and c.spec.ast.kind_of_file(d) == ast.PRELUDE_FILE
            ):
                # A definition of the spec itself shadows the attached prelude's.
                c.duplicate[d] = True
            elif declare(c, name, d):
                c.spec.defs.append(
                    Def(name.copy(), d, tn^, tb^, List[Param](), 0, c.kid(d, 3))
                )
                c.def_index[name] = len(c.spec.defs) - 1
                c.decl_pos[d] = len(c.spec.defs) - 1
                c.def_edges.append(List[Int]())
                c.def_nodes.append(d)
    # Aliases and records resolve on first use; force them in declaration order.
    for d in c.decl_nodes():
        var k = c.kind_of(d)
        if c.duplicate[d]:
            continue
        if k == ast.ALIAS:
            _ = alias_type(c, c.text_of(d), d)
        elif k == ast.RECORD:
            var t = record_type(c, c.text_of(d), d)
            c.spec.records.append(t)
    for i in range(len(c.spec.consts)):
        ensure_const(c, i)


def _collect_model(mut c: Checker, d: Int):
    var name = c.text_of(d)
    var is_iface = c.kind_of(d) == ast.INTERFACE
    var tn = List[String]()
    var tb = List[String]()
    tvars_of(c, c.kid(d, 0), tn, tb)
    if not declare(c, name, d):
        return
    var t = c.spec.types.model(name.copy(), c.spec.types.typevars(tn, tb), is_iface)
    c.spec.models.append(
        Model(
            name.copy(),
            d,
            is_iface,
            t,
            tn.copy(),
            tb.copy(),
            List[Observer](),
            List[Build](),
            List[Int](),
            List[Int](),
            List[Int](),
        )
    )
    var pos = len(c.spec.models) - 1
    c.model_index[name] = pos
    c.decl_pos[d] = pos
    if is_iface:
        var kids = c.kids_of(d)
        for i in range(1, len(kids)):
            var m = kids[i]
            var mk = c.kind_of(m)
            if mk == ast.CTOR or mk == ast.METHOD:
                var mname = c.text_of(m)
                var fpos = _new_fn(
                    c,
                    mname.copy(),
                    name + "." + mname,
                    name + "." + mname,
                    mk,
                    m,
                    pos,
                    tn,
                    tb,
                )
                if mk == ast.CTOR:
                    c.spec.models[pos].ctors.append(fpos)
                else:
                    c.spec.models[pos].methods.append(fpos)


# -- signatures -----------------------------------------------------------------


def build_params(
    mut c: Checker,
    params: Int,
    self_type: Int,
    allow_self: Bool,
    self_model: Int,
    self_reported: Bool = False,
) -> List[Param]:
    var out = List[Param]()
    var kids = c.kids_of(params)
    for i in range(len(kids)):
        var p = kids[i]
        var name = c.text_of(p)
        var tnode = c.kid(p, 0)
        var default = c.kid(p, 1)
        if tnode == 0 and name == "self":
            if i != 0 or not allow_self:
                if i != 0 or not self_reported:
                    c.error(p, "self is the receiver: it is only the first parameter of a method")
                out.append(Param(name^, c.poison, 0, p))
            else:
                out.append(Param(name^, self_type, 0, p))
            continue
        for q in out:
            if q.name == name:
                c.error(p, t"parameter {name} is declared twice")
        if is_reserved(name):
            c.error(p, t"{name} is reserved and cannot name a parameter")
        var t = resolve_type(c, tnode, self_model)
        if c.contains_real(t):
            c.error(tnode, "real is clause-only and cannot be a parameter type")
        out.append(Param(name^, t, default, p))
    return out^


def _member_dup(mut c: Checker, members: List[String], name: String, node: Int, owner: String):
    for m in members:
        if m == name:
            c.error(node, t"{owner} already has a member named {name}")


def declare_signatures(mut c: Checker):
    for d in c.decl_nodes():
        if c.duplicate[d]:
            continue
        var k = c.kind_of(d)
        if k == ast.MODEL or k == ast.INTERFACE:
            _declare_model(c, d)
        elif k == ast.FN:
            _declare_fn(c, d)
        elif k == ast.DEF:
            _declare_def(c, d)


def _declare_model(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    var name = c.spec.models[pos].name.copy()
    var self_t = c.spec.models[pos].type
    set_tvars(c, c.spec.models[pos].tparams.copy(), c.spec.models[pos].bounds.copy())
    var members = List[String]()
    var kids = c.kids_of(d)
    for i in range(1, len(kids)):
        var m = kids[i]
        var mk = c.kind_of(m)
        if mk == ast.OBSERVE:
            var oname = c.text_of(m)
            _member_dup(c, members, oname, m, name)
            members.append(oname.copy())
            var params = List[Param]()
            if c.kid(m, 0) != 0:
                params = build_params(c, c.kid(m, 0), -1, False, pos)
            var t = resolve_type(c, c.kid(m, 1), pos)
            c.spec.models[pos].observers.append(
                Observer(oname^, params^, t, c.kid(m, 2), m)
            )
        elif mk == ast.BUILD:
            var params = build_params(c, c.kid(m, 0), -1, False, pos)
            c.spec.models[pos].builds.append(Build(c.text_of(m), params^, m))
        elif mk == ast.CTOR:
            var fpos = c.decl_pos[m]
            var mname = c.text_of(m)
            _member_dup(c, members, mname, m, name)
            members.append(mname^)
            var _bp = build_params(c, c.kid(m, 1), -1, False, pos)
            c.spec.fns[fpos].params = _bp^
            var ret = c.kid(m, 2)
            var rt = self_t
            if ret != 0:
                var declared = resolve_type(c, ret, pos)
                if not c.is_any(declared) and declared != self_t:
                    c.error(ret, t"a constructor returns its interface: -> {name}")
            else:
                c.error(m, t"a constructor returns its interface: -> {name}")
            c.spec.fns[fpos].result = rt
        elif mk == ast.METHOD:
            var fpos = c.decl_pos[m]
            var mname = c.text_of(m)
            _member_dup(c, members, mname, m, name)
            members.append(mname^)
            var _bp = build_params(c, c.kid(m, 1), self_t, True, pos)
            c.spec.fns[fpos].params = _bp^
            c.spec.fns[fpos].receiver = True
            var ret = c.kid(m, 2)
            c.spec.fns[fpos].result = c.unit if ret == 0 else resolve_type(c, ret, pos)
    c.ctx = Ctx()


def _declare_fn(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    var name = c.spec.fns[pos].name.copy()
    set_tvars(c, c.spec.fns[pos].tparams.copy(), c.spec.fns[pos].bounds.copy())
    var params_node = c.kid(d, 1)
    var pkids = c.kids_of(params_node)
    var self_t = -1
    var allow_self = False
    var self_reported = False
    if len(pkids) > 0 and c.text_of(pkids[0]) == "self" and c.kid(pkids[0], 0) == 0:
        var dot = name.rfind(".")
        self_reported = True
        if dot < 0:
            c.error(
                pkids[0],
                t"{name} takes self, but it is not named after a model: write fn Model.{name}(self, ...)",
            )
        else:
            var prefix = String(name[byte=0:dot])
            var mp = c.model_index.get(prefix)
            if not mp:
                c.error(
                    pkids[0],
                    t"{name} takes self, but there is no model or interface named {prefix} to be its receiver",
                )
            else:
                self_t = c.spec.models[mp.value()].type
                allow_self = True
                self_reported = False
                c.spec.fns[pos].owner = mp.value()
                c.spec.fns[pos].receiver = True
    var _bp = build_params(c, params_node, self_t, allow_self, c.spec.fns[pos].owner, self_reported)
    c.spec.fns[pos].params = _bp^
    var ret = c.kid(d, 2)
    c.spec.fns[pos].result = c.unit if ret == 0 else resolve_type(c, ret)
    c.ctx = Ctx()


def _declare_def(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    set_tvars(c, c.spec.defs[pos].tparams.copy(), c.spec.defs[pos].bounds.copy())
    var _bp = build_params(c, c.kid(d, 1), -1, False, -1)
    c.spec.defs[pos].params = _bp^
    c.spec.defs[pos].result = resolve_type(c, c.kid(d, 2))
    c.ctx = Ctx()


# -- defaults -------------------------------------------------------------------


def _int_range_text(bits: Int, signed: Bool) -> String:
    if signed:
        var lo = -(1 << (bits - 1)) if bits < 64 else Int.MIN
        var hi = (1 << (bits - 1)) - 1 if bits < 64 else Int.MAX
        return String(lo, " to ", hi)
    if bits == 64:
        return "0 to 18446744073709551615"
    return String("0 to ", (1 << bits) - 1)


def _in_fixed_range(value: Real, bits: Int, signed: Bool) -> Bool:
    if not value.is_integer():
        return False
    try:
        var top = Real(BigInt(1) << (bits - 1 if signed else bits))
        var hi = top - Real(1)
        var lo = -top if signed else Real(0)
        return not (value < lo) and not (hi < value)
    except:
        return False


def check_default(mut c: Checker, p: Param):
    var default = p.default
    var saved = c.ctx.copy()
    var ctx = Ctx()
    ctx.kind = K_DEFAULT
    ctx.decl = p.name.copy()
    ctx.tv_names = saved.tv_names.copy()
    ctx.tv_types = saved.tv_types.copy()
    ctx.no_result = "a default value cannot refer to result"
    c.ctx = ctx^
    var dt = infer(c, default)
    c.ctx = saved^
    if c.is_poison(dt):
        return
    var t = p.type
    if not assignable(c, dt, t, default):
        if c.tkind(t) == ty.LITERAL and c.kind_of(default) == ast.STR:
            c.error(default, '"' + c.text_of(default) + '" is not one of ' + c.text(t))
        else:
            c.error(
                default,
                t"the default of {p.name} must be a {c.text(t)}, but it is {c.text(dt)}",
            )
        return
    var value = c.literal_value(default)
    if not value:
        return
    var k = c.tkind(t)
    if k == ty.FIXED_INT:
        var bits = c.spec.types.infos[t].bits
        var signed = c.spec.types.infos[t].signed
        if not _in_fixed_range(value.value(), bits, signed):
            c.error(
                default,
                t"{c.source_of(default)} is not a {c.text(t)} value ({_int_range_text(bits, signed)})",
            )
    elif k == ty.FLOAT:
        try:
            var fmt = format_by_id(UInt8(c.spec.types.infos[t].bits))
            if not exactly(fmt, value.value()):
                c.error(
                    default,
                    t"{c.source_of(default)} is not exactly representable as {c.text(t)}",
                )
        except:
            pass


def _check_defaults(mut c: Checker, var params: List[Param]):
    for p in params:
        if p.default != 0:
            check_default(c, p)


def check_defaults(mut c: Checker):
    for d in c.decl_nodes():
        if c.duplicate[d]:
            continue
        var k = c.kind_of(d)
        if k == ast.FN:
            var pos = c.decl_pos[d]
            set_tvars(c, c.spec.fns[pos].tparams.copy(), c.spec.fns[pos].bounds.copy())
            _check_defaults(c, c.spec.fns[pos].params.copy())
        elif k == ast.DEF:
            var pos = c.decl_pos[d]
            set_tvars(c, c.spec.defs[pos].tparams.copy(), c.spec.defs[pos].bounds.copy())
            _check_defaults(c, c.spec.defs[pos].params.copy())
        elif k == ast.MODEL or k == ast.INTERFACE:
            var pos = c.decl_pos[d]
            set_tvars(c, c.spec.models[pos].tparams.copy(), c.spec.models[pos].bounds.copy())
            for i in range(len(c.spec.models[pos].observers)):
                _check_defaults(c, c.spec.models[pos].observers[i].params.copy())
            for i in range(len(c.spec.models[pos].builds)):
                _check_defaults(c, c.spec.models[pos].builds[i].params.copy())
            for f in c.spec.models[pos].ctors + c.spec.models[pos].methods.copy():
                _check_defaults(c, c.spec.fns[f].params.copy())
        c.ctx = Ctx()


# -- clause ids -----------------------------------------------------------------


def _add_clause(
    mut c: Checker, id: String, node: Int, label: String, owner_fn: Int, owner_model: Int
) -> Int:
    var op = c.op_of(node)
    var expr = 0
    var error = String()
    var names = List[String]()
    var kids = c.kids_of(node)
    if op == ast.RAISES or op == ast.MAY_RAISE:
        error = qualify_error(c.text_of(kids[0]))
        expr = kids[1]
    elif op == ast.MODIFIES:
        for k in kids:
            names.append(c.text_of(k))
    elif op == ast.UNSPECIFIED or op == ast.IMPL_DEFINED:
        names.append(c.text_of(kids[0]))
    elif op == ast.PERF:
        pass
    else:
        expr = kids[0]
    c.spec.clauses.append(
        Clause(id.copy(), op, label.copy(), node, expr, error^, names^, owner_fn, owner_model)
    )
    c.clause_ids[id] = len(c.spec.clauses) - 1
    return len(c.spec.clauses) - 1


def assign_ids(
    mut c: Checker,
    decl_id: String,
    clauses: List[Int],
    owner_fn: Int,
    owner_model: Int,
    member_names: List[String],
    member_kinds: List[String],
) -> List[Int]:
    """Clause IDs `<decl>.<label>` or `<decl>#<n>`; the positions of the new clauses."""
    var out = List[Int]()
    var labels = List[String]()
    var label_nodes = List[Int]()
    for i in range(len(clauses)):
        var cl = clauses[i]
        var label = c.text_of(cl)
        var id: String
        var is_member = -1
        if label != "":
            for j in range(len(member_names)):
                if member_names[j] == label:
                    is_member = j
        if label != "" and is_member >= 0:
            var cid = decl_id + "." + label
            c.error(
                cl,
                t"clause label {label} gives the ID {cid}, which already names the "
                t"{member_kinds[is_member]} {cid}: rename the label (e.g. {ast.op_name(c.op_of(cl))} "
                t"{label}_holds:)",
            )
            id = decl_id + "#" + String(i + 1)
            label = String()
        elif label != "":
            var prev = -1
            for j in range(len(labels)):
                if labels[j] == label:
                    prev = j
            if prev >= 0:
                c.error(
                    cl,
                    t"clause label {label} is already used in {decl_id} (line {c.line_of(label_nodes[prev])})",
                )
                id = decl_id + "#" + String(i + 1)
                label = String()
            else:
                labels.append(label.copy())
                label_nodes.append(cl)
                id = decl_id + "." + label
        else:
            id = decl_id + "#" + String(i + 1)
        if id in c.clause_ids:
            c.error(cl, t"clause ID {id} is already in use")
        out.append(_add_clause(c, id, cl, label, owner_fn, owner_model))
    return out^


def check_freedoms(mut c: Checker, decl_id: String, clauses: List[Int]):
    var names = List[String]()
    var nodes = List[Int]()
    for ci in clauses:
        var cl = c.spec.clauses[ci].node
        var op = c.spec.clauses[ci].kind
        if op == ast.UNSPECIFIED or op == ast.IMPL_DEFINED:
            var f = c.spec.clauses[ci].names[0].copy()
            var dup = False
            for n in names:
                if n == f:
                    dup = True
            if dup:
                c.error(cl, t"{f} is already declared a freedom of {decl_id}")
            names.append(f^)
            nodes.append(cl)
    if len(names) == 0:
        return
    for ci in clauses:
        var expr = c.spec.clauses[ci].expr
        if expr == 0:
            continue
        var reported = List[String]()
        var stack = List[Int]()
        stack.append(expr)
        var found = List[Int]()
        while len(stack) > 0:
            var n = stack.pop()
            found.append(n)
            for k in c.spec.ast.nodes[n].kids:
                stack.append(k)
        # Source order: nodes in ascending position.
        sort(found)
        for n in found:
            var r = c.spec.resolutions.get(n)
            if not r:
                continue
            var rk = r.value().kind
            if rk != R_PRELUDE and rk != R_OBSERVER and rk != R_FIELD:
                continue
            var rname = r.value().name.copy()
            for j in range(len(names)):
                if names[j] != rname:
                    continue
                var done = False
                for x in reported:
                    if x == rname:
                        done = True
                if done:
                    continue
                reported.append(rname.copy())
                c.error(
                    n,
                    t"this clause observes {rname}, which {decl_id} declares {ast.op_name(c.op_of(nodes[j]))} "
                    t"(line {c.line_of(nodes[j])}): no clause may observe it",
                )


# -- models and interfaces ---------------------------------------------------------


def check_model(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    var name = c.spec.models[pos].name.copy()
    var is_iface = c.spec.models[pos].is_interface
    var what = "interface" if is_iface else "model"
    var mt = c.spec.models[pos].type
    set_tvars(c, c.spec.models[pos].tparams.copy(), c.spec.models[pos].bounds.copy())
    # Observers' reading expressions.
    for i in range(len(c.spec.models[pos].observers)):
        _check_observer_expr(c, pos, i)
    var member_names = List[String]()
    var member_kinds = List[String]()
    for o in c.spec.models[pos].observers:
        member_names.append(o.name.copy())
        member_kinds.append("observer")
    if is_iface:
        for f in c.spec.models[pos].ctors:
            member_names.append(c.spec.fns[f].name.copy())
            member_kinds.append("constructor")
        for f in c.spec.models[pos].methods:
            member_names.append(c.spec.fns[f].name.copy())
            member_kinds.append("method")
    # Qualified functions named under the model are its methods and statics.
    var prefix = name + "."
    for f in range(len(c.spec.fns)):
        if c.spec.fns[f].kind != ast.FN or not c.spec.fns[f].name.startswith(prefix):
            continue
        var rest = String(c.spec.fns[f].name[byte = prefix.byte_length() :])
        if "." not in rest:
            member_names.append(rest^)
            member_kinds.append("method" if c.spec.fns[f].receiver else "function")
    var clauses = List[Int]()
    for m in c.kids_of(d):
        if c.kind_of(m) == ast.CLAUSE:
            clauses.append(m)
    var ids = assign_ids(c, name, clauses, -1, pos, member_names, member_kinds)
    c.spec.models[pos].clauses = ids.copy()
    for ci in ids:
        var op = c.spec.clauses[ci].kind
        var node = c.spec.clauses[ci].node
        if (
            op != ast.INVARIANT
            and op != ast.UNSPECIFIED
            and op != ast.IMPL_DEFINED
            and op != ast.PERF
        ):
            c.error(
                node,
                t"{ast.op_name(op)} belongs to a function, constructor or method, not to {what} {name}",
            )
            if c.spec.clauses[ci].expr != 0:
                poison_subtree(c, c.spec.clauses[ci].expr)
            continue
        if op != ast.INVARIANT or c.spec.clauses[ci].expr == 0:
            continue
        var ctx = Ctx()
        ctx.kind = Int(ast.INVARIANT)
        ctx.decl = name.copy()
        ctx.tv_names = c.ctx.tv_names.copy()
        ctx.tv_types = c.ctx.tv_types.copy()
        ctx.self_t = mt
        ctx.self_model = pos
        ctx.fields_of = pos
        ctx.allow_spec_fn = True
        ctx.no_result = "an invariant describes an object's state: there is no result"
        var saved = c.ctx.copy()
        c.ctx = ctx^
        var expr = c.spec.clauses[ci].expr
        want_bool(c, expr, infer(c, expr), "an invariant")
        c.ctx = saved^
    check_freedoms(c, name, ids)
    if is_iface:
        for f in c.spec.models[pos].ctors.copy():
            check_callable(c, f, "constructor")
        for f in c.spec.models[pos].methods.copy():
            check_callable(c, f, "method")
    c.ctx = Ctx()


def _check_observer_expr(mut c: Checker, model: Int, oi: Int):
    var expr = c.spec.models[model].observers[oi].expr
    if expr == 0:
        return
    var declared = c.spec.models[model].observers[oi].type
    var oname = c.spec.models[model].observers[oi].name.copy()
    var ctx = Ctx()
    ctx.kind = K_OBSERVER
    ctx.decl = oname.copy()
    ctx.tv_names = c.ctx.tv_names.copy()
    ctx.tv_types = c.ctx.tv_types.copy()
    for p in c.spec.models[model].observers[oi].params:
        ctx.param_names.append(p.name.copy())
        ctx.param_types.append(p.type)
    ctx.self_t = c.spec.models[model].type
    ctx.self_model = model
    ctx.fields_of = model
    ctx.extern_result = declared
    ctx.no_result = "an observer's reading expression has no result"
    var saved = c.ctx.copy()
    c.ctx = ctx^
    var t = infer(c, expr)
    c.ctx = saved^
    if not c.is_poison(t) and not assignable(c, t, declared, expr):
        c.error(
            expr,
            t"the reading expression of {oname} is a {c.text(t)}, but {oname} is declared "
            t"{c.text(declared)}",
        )


# -- callables -------------------------------------------------------------------


def _callable_ctx(mut c: Checker, fpos: Int) -> Ctx:
    var ctx = Ctx()
    ctx.decl = c.spec.fns[fpos].decl_id.copy()
    var tn = c.spec.fns[fpos].tparams.copy()
    var tb = c.spec.fns[fpos].bounds.copy()
    ctx.tv_names = tn.copy()
    ctx.tv_types = c.spec.types.typevars(tn, tb)
    var receiver = c.spec.fns[fpos].receiver
    var is_ctor = c.spec.fns[fpos].kind == ast.CTOR
    for i in range(len(c.spec.fns[fpos].params)):
        var p = c.spec.fns[fpos].params[i].copy()
        ctx.param_names.append(String() if (receiver and i == 0) else p.name.copy())
        ctx.param_types.append(p.type)
    if receiver and len(c.spec.fns[fpos].params) > 0:
        ctx.self_t = c.spec.fns[fpos].params[0].type
        ctx.self_model = c.spec.fns[fpos].owner
    if is_ctor:
        ctx.no_self = "a constructor has no self: the new object is result"
    else:
        ctx.no_self = "self is only available in methods"
    return ctx^


def check_fn(mut c: Checker, d: Int):
    check_callable(c, c.decl_pos[d], "function")


def check_callable(mut c: Checker, fpos: Int, what: String):
    var node = c.spec.fns[fpos].node
    var decl_id = c.spec.fns[fpos].decl_id.copy()
    var result = c.spec.fns[fpos].result
    var base = _callable_ctx(c, fpos)
    var has_state = base.self_t >= 0
    for t in base.param_types:
        if c.contains_model(t):
            has_state = True
    var body = List[Int]()
    var parts = List[Int]()
    var kids = c.kids_of(node)
    var first = 3
    for i in range(first, len(kids)):
        if c.kind_of(kids[i]) == ast.CLAUSE:
            body.append(kids[i])
        elif c.kind_of(kids[i]) == ast.PARTITION:
            parts.append(kids[i])
    var no_members = List[String]()
    var ids = assign_ids(c, decl_id, body, fpos, c.spec.fns[fpos].owner, no_members, no_members)
    c.spec.fns[fpos].clauses = ids.copy()
    var seen_params = List[String]()
    var seen_nodes = List[Int]()
    for p in parts:
        _check_partition(c, fpos, p, base, decl_id, seen_params, seen_nodes)
    for ci in ids:
        var op = c.spec.clauses[ci].kind
        var cnode = c.spec.clauses[ci].node
        if op == ast.INVARIANT:
            c.error(cnode, t"invariant belongs to a model or interface; in a {what} use ensures")
            if c.spec.clauses[ci].expr != 0:
                poison_subtree(c, c.spec.clauses[ci].expr)
            continue
        if op == ast.MODIFIES:
            _check_modifies(c, ci, decl_id, base)
            continue
        if op == ast.AGGREGATE:
            _check_aggregate(c, ci, fpos, decl_id, base, what)
            continue
        var expr = c.spec.clauses[ci].expr
        if expr == 0:
            continue
        var ctx = base.copy()
        ctx.kind = Int(op)
        if op == ast.REQUIRES or op == ast.RAISES or op == ast.MAY_RAISE:
            var word = String(ast.op_name(op))
            ctx.no_result = (
                "result is not available in "
                + word
                + ": it is evaluated on the inputs, before the call"
            )
            ctx.no_old = (
                "old(...) is only allowed in ensures; "
                + word
                + " already sees the state before the call"
            )
        else:
            if result != c.unit:
                ctx.has_result = True
                ctx.result = result
            ctx.no_result = decl_id + " returns nothing, so there is no result"
            ctx.allow_spec_fn = True
            if op == ast.ENSURES:
                ctx.allow_old = has_state
                ctx.no_old = String(
                    "old(...) needs state that the call can change, but ", decl_id, " has no handle parameter or self"
                )
        var what_clause: String
        if op == ast.RAISES or op == ast.MAY_RAISE:
            what_clause = "the condition of " + String(ast.op_name(op))
        else:
            what_clause = "the " + String(ast.op_name(op)) + " clause"
        c.ctx = ctx^
        want_bool(c, expr, infer(c, expr), what_clause)
    check_freedoms(c, decl_id, ids)
    c.ctx = Ctx()


def _check_modifies(mut c: Checker, ci: Int, decl_id: String, base: Ctx):
    var node = c.spec.clauses[ci].node
    var seen = List[String]()
    for n in c.spec.clauses[ci].names.copy():
        for s in seen:
            if s == n:
                c.error(node, t"modifies lists {n} twice")
        seen.append(n.copy())
        if n == "self":
            if base.self_t < 0:
                c.error(node, "modifies self: self is only available in methods")
            continue
        var pi = base.param_index(n)
        if pi < 0:
            c.error(node, t"modifies {n}: {decl_id} has no parameter {n}")
        elif not c.contains_model(base.param_types[pi]):
            c.error(
                node,
                t"modifies names handle parameters (models or interfaces) or self; {n} is a "
                t"{c.text(base.param_types[pi])} value, which a call cannot change",
            )


def _check_partition(
    mut c: Checker,
    fpos: Int,
    part: Int,
    base: Ctx,
    decl_id: String,
    mut seen: List[String],
    mut seen_nodes: List[Int],
):
    var pname = c.text_of(part)
    var classes_nodes = c.kids_of(part)
    for i in range(len(seen)):
        if seen[i] == pname:
            c.error(part, t"{pname} is already partitioned at line {c.line_of(seen_nodes[i])}")
    seen.append(pname.copy())
    seen_nodes.append(part)
    var pi = base.param_index(pname)
    if pi < 0:
        if pname == "self":
            c.error(part, "self cannot be partitioned: partition the method's parameters")
        else:
            c.error(part, t"partition {pname}: {decl_id} has no parameter {pname}")
        for cls in classes_nodes:
            poison_subtree(c, c.kid(cls, 0))
        return
    var ptype = base.param_types[pi]
    var fixed = c.spec.types.is_fixed_width(ptype)
    var out = Partition(pi, part, List[PartitionClass]())
    var cnames = List[String]()
    var cnodes = List[Int]()
    var ctypes = List[Int]()
    for cls in classes_nodes:
        var cname = c.text_of(cls)
        var expr = c.kid(cls, 0)
        var dup = False
        for x in cnames:
            if x == cname:
                dup = True
        if dup:
            c.error(cls, t"partition {pname} already has a class named {cname}")
        elif base.param_index(cname) >= 0:
            c.error(cls, t"class {cname} has the name of a parameter of {decl_id}")
        var ctx = base.copy()
        ctx.kind = K_PARTITION_SET if fixed else K_PARTITION
        ctx.only_param = pname.copy()
        ctx.class_names = cnames.copy()
        ctx.class_nodes = cnodes.copy()
        ctx.class_types = ctypes.copy()
        ctx.no_result = "a partition class describes an input: there is no result"
        ctx.no_self = "self cannot appear in a partition class"
        c.ctx = ctx^
        if fixed:
            var st = c.spec.types.set_of(ptype)
            var t = infer(c, expr, st)
            if not c.is_any(t) and t != st:
                var all_name = "nan" if c.tkind(ptype) == ty.FLOAT else "all"
                c.error(
                    expr,
                    t"class {cname} of the {c.text(ptype)} parameter {pname} must be a set of {c.text(ptype)} "
                    t"values ({c.text(ptype)}.{all_name}, {c.text(ptype)}.range(a, b), {{v, ...}}, combined "
                    t"with | & -), but it is {c.text(t)}",
                )
            cnames.append(cname.copy())
            cnodes.append(cls)
            ctypes.append(st)
        else:
            var t = infer(c, expr)
            want_bool(
                c,
                expr,
                t,
                "class " + cname + " (a predicate over " + pname + ")",
            )
            cnames.append(cname.copy())
            cnodes.append(cls)
            ctypes.append(c.bool_)
        out.classes.append(PartitionClass(cname^, cls, expr))
    c.spec.fns[fpos].partitions.append(out^)


# -- aggregates -------------------------------------------------------------------


comptime _AGGREGATE_SHAPES = (
    "an aggregate clause has one of the shapes sum(v in S: e) <= c, sum(v in S: e) <"
    " c, sum(v in S: e) == 0, max(v in S: e) <= c, max(v in S: e) < c or all(v in S:"
    " p), with S a set such as f16.all or a list, and c a constant"
)
comptime _SUM_EQUALS_ZERO = (
    "sum(...) == c is an aggregate shape only for c = 0, where it demands that every"
    " term is 0; bound the total with sum(...) <= c instead"
)


struct Shape(Copyable, Movable):
    var top: Int
    var bound: Int
    var problem: String

    def __init__(out self):
        self.top = 0
        self.bound = 0
        self.problem = String()


def aggregate_shape(mut c: Checker, e: Int) -> Shape:
    var out = Shape()
    var shapes = _AGGREGATE_SHAPES
    if c.kind_of(e) == ast.COMPREHENSION:
        out.top = e
        if c.op_of(e) != ast.ALL:
            out.problem = shapes
        return out^
    if c.kind_of(e) == ast.BINARY:
        var left = c.kid(e, 0)
        var right = c.kid(e, 1)
        var side = 0
        if c.kind_of(left) == ast.COMPREHENSION:
            side = left
        elif c.kind_of(right) == ast.COMPREHENSION:
            side = right
        if side == 0:
            out.problem = shapes
            return out^
        out.top = side
        if side != left:
            out.problem = shapes
            return out^
        var lk = c.op_of(left)
        var op = c.op_of(e)
        var allowed = False
        if lk == ast.SUM:
            allowed = op == ast.LE or op == ast.LT or op == ast.EQ
        elif lk == ast.MAX:
            allowed = op == ast.LE or op == ast.LT
        if not allowed:
            out.problem = shapes
            return out^
        if op == ast.EQ:
            var v = c.literal_value(right)
            if not v or not (v.value() == Real(0)):
                out.problem = _SUM_EQUALS_ZERO
                return out^
        out.bound = right
        return out^
    out.problem = shapes
    return out^


def is_constant(mut c: Checker, e: Int) -> Bool:
    var k = c.kind_of(e)
    if k == ast.NUM:
        return True
    if k == ast.UNARY and c.op_of(e) == ast.NEG:
        return is_constant(c, c.kid(e, 0))
    if k == ast.BINARY:
        var op = c.op_of(e)
        if (
            op == ast.ADD
            or op == ast.SUB
            or op == ast.MUL
            or op == ast.DIV
            or op == ast.FLOORDIV
            or op == ast.MOD
        ):
            return is_constant(c, c.kid(e, 0)) and is_constant(c, c.kid(e, 1))
        return False
    if k == ast.ATTR:
        var r = c.spec.resolutions.get(e)
        return r.__bool__() and r.value().kind == R_TYPE_CONST
    return False


def _check_aggregate(
    mut c: Checker, ci: Int, fpos: Int, decl_id: String, base: Ctx, what: String
):
    var node = c.spec.clauses[ci].node
    var expr = c.spec.clauses[ci].expr
    if c.spec.fns[fpos].kind != ast.FN:
        c.error(
            node,
            t"aggregate clauses belong to functions (fn), not to a {what}: a bound over a whole input "
            t"set needs inputs that do not depend on an object's state",
        )
        poison_subtree(c, expr)
        return
    var ctx = base.copy()
    ctx.kind = Int(ast.AGGREGATE)
    var fname = c.spec.fns[fpos].name.copy()
    for i in range(len(base.param_names)):
        var p = base.param_names[i].copy()
        if p == "":
            continue
        ctx.hidden_names.append(p.copy())
        ctx.hidden_msgs.append(
            "an aggregate clause cannot use the parameter "
            + p
            + " of "
            + decl_id
            + ": it ranges over its own variable, e.g. sum(v in S: qe("
            + fname
            + "(v), ...))"
        )
    ctx.allow_spec_fn = True
    ctx.no_result = (
        "an aggregate clause is evaluated once over a set of inputs, so there is no"
        " result: call "
        + fname
        + "(v) for each member instead"
    )
    ctx.no_old = "old(...) has no meaning in an aggregate clause: it is not tied to one call"
    ctx.no_self = "an aggregate clause has no self"
    var shape = aggregate_shape(c, expr)
    ctx.aggregate_top = shape.top
    c.ctx = ctx^
    want_bool(c, expr, infer(c, expr), "the aggregate clause")
    if shape.problem != "":
        c.error(expr, shape.problem)
    elif shape.bound != 0 and not is_constant(c, shape.bound):
        c.error(
            shape.bound,
            "the bound of an aggregate clause must be a constant (numbers, and T.min or"
            " T.max, combined with + - * /), the same for every member",
        )


# -- definitions -------------------------------------------------------------------


def check_def(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    var name = c.spec.defs[pos].name.copy()
    var ctx = Ctx()
    ctx.kind = K_DEF
    ctx.decl = name.copy()
    var tn = c.spec.defs[pos].tparams.copy()
    var tb = c.spec.defs[pos].bounds.copy()
    ctx.tv_names = tn.copy()
    ctx.tv_types = c.spec.types.typevars(tn, tb)
    for p in c.spec.defs[pos].params:
        ctx.param_names.append(p.name.copy())
        ctx.param_types.append(p.type)
    ctx.no_result = "a definition has no result: its value is the expression"
    ctx.no_self = "a definition has no self"
    c.ctx = ctx^
    c.cur_def = pos
    var body = c.spec.defs[pos].body
    var t = infer(c, body)
    c.cur_def = -1
    var declared = c.spec.defs[pos].result
    if not c.is_poison(t) and not assignable(c, t, declared, body):
        c.error(
            body,
            t"the body of {name} is a {c.text(t)}, but it is declared to return {c.text(declared)}",
        )
    c.ctx = Ctx()


def check_def_cycles(mut c: Checker):
    """Definitions may not call themselves, directly or through others."""
    var n = len(c.spec.defs)
    # state: 0 unvisited, 1 on the path, 2 done
    var state = List[Int](length=n, fill=0)
    var reported = List[Bool](length=n, fill=False)
    for start in range(n):
        if state[start] != 0:
            continue
        var path = List[Int]()
        var cursor = List[Int]()
        path.append(start)
        cursor.append(0)
        state[start] = 1
        while len(path) > 0:
            var top = path[len(path) - 1]
            var i = cursor[len(cursor) - 1]
            if i >= len(c.def_edges[top]):
                state[top] = 2
                _ = path.pop()
                _ = cursor.pop()
                continue
            cursor[len(cursor) - 1] = i + 1
            var nxt = c.def_edges[top][i]
            if state[nxt] == 1:
                var from_index = 0
                for j in range(len(path)):
                    if path[j] == nxt:
                        from_index = j
                var first = c.spec.defs[nxt].name.copy()
                var cycle = [c.spec.defs[d].name.copy() for d in path[from_index:]]
                var text = " -> ".join(cycle + [first.copy()])
                var at = c.def_nodes[nxt]
                if not reported[nxt]:
                    reported[nxt] = True
                    if len(path) - from_index == 1:
                        c.error(at, t"definition {first} calls itself")
                    else:
                        c.error(at, t"definitions cannot call each other in a cycle: {text}")
            elif state[nxt] == 0:
                state[nxt] = 1
                path.append(nxt)
                cursor.append(0)


# -- the whole file ------------------------------------------------------------------


def run(mut c: Checker):
    collect(c)
    declare_signatures(c)
    check_defaults(c)
    for d in c.decl_nodes():
        if c.duplicate[d]:
            continue
        var k = c.kind_of(d)
        if k == ast.DEF:
            check_def(c, d)
        elif k == ast.MODEL or k == ast.INTERFACE:
            check_model(c, d)
        elif k == ast.FN:
            check_fn(c, d)
    check_def_cycles(c)
