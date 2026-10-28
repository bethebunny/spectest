"""Declarations: collecting names, signatures, clause ids, partitions and the clause
rules of functions, models and interfaces, then the whole-file `run`.
"""

from spec.ast import Op
from spec.spec import (
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
    aggregate_shape,
)
from spec.types import Types
from value.fixed import int_max, int_min
from value.floats import exactly
from value.real import Real

from specfile.checker_state import Checker, Ctx, Var, Visit, cycle_text, is_builtin_type_name, is_reserved, qualify_error
from specfile.expression_types import assignable, infer_in, literal_member, poison_subtree, want_bool
from specfile.typesyn import alias_type, ensure_const, record_type, resolve_type


# -- names ----------------------------------------------------------------------


def _where(c: Checker, here: Int, other: Int) -> String:
    """`line N` of `other`, with its file when that is not the file of `here`."""
    var line = String(t"line {c.line_of(other)}")
    if c.spec.ast.nodes[here].file != c.spec.ast.nodes[other].file:
        return String(t"{c.spec.ast.path_of(other)}, {line}")
    return line


def declare(mut c: Checker, name: String, node: Int) -> Bool:
    if is_builtin_type_name(name):
        c.error(node, t"{name} is a built-in type and cannot be redeclared")
    elif is_reserved(name):
        c.error(node, t"{name} is reserved and cannot name a declaration")
    elif case .Some(earlier) = c.names.get(name):
        c.error(node, t"{name} is already declared at {_where(c, node, earlier)}")
    else:
        c.names[name] = node
        return True
    c.duplicate[node] = True
    return False


def _declared(c: Checker) -> List[Int]:
    """The declarations whose names are declared once."""
    return [d for d in c.decls if not c.duplicate[d]]


@fieldwise_init
struct TypeParams(Copyable):
    var names: List[String]
    var bounds: List[String]
    """Each one's bound: "Eq", "Ord" or ""."""


def type_params(mut c: Checker, tparams: Int) -> TypeParams:
    """The type parameters of a TPARAMS node."""
    var out = TypeParams([], [])
    for tp in c.children(tparams):
        var name = c.text_of(tp)
        var bound = String()
        if c.children(tp):
            bound = c.text_of(c.child(tp, 0))
            if bound != "Eq" and bound != "Ord":
                c.error(tp, t"unknown bound {bound}: a type parameter's bound is Eq or Ord")
                bound = String()
        if name in out.names:
            c.error(tp, t"type parameter {name} is declared twice")
        elif is_builtin_type_name(name):
            c.error(tp, t"type parameter {name} shadows a built-in type")
        out.names.append(name^)
        out.bounds.append(bound^)
    return out^


def _tvars(mut types: Types, names: List[String], bounds: List[String]) -> List[Var]:
    """Type variables in scope, from a declaration's type parameters."""
    return [Var(name.copy(), t, 0) for name, t in zip(names, types.typevars(names, bounds))]


def _param_vars(params: List[Param]) -> List[Var]:
    return [Var(p.name.copy(), p.type, 0) for p in params]


def _new_fn(mut c: Checker, node: Int, var name: String, var target: String, owner: Int, tparams: TypeParams) -> Int:
    """Adds the callable declared at `node`, whose clause ids start with its target."""
    var decl_id = target.copy()
    c.spec.fns.append(
        Fn(
            name^,
            target^,
            decl_id^,
            c.kind_of(node),
            node,
            owner,
            tparams.names.copy(),
            tparams.bounds.copy(),
            [],
            False,
            0,
            [],
            [],
        )
    )
    c.decl_pos[node] = len(c.spec.fns) - 1
    return len(c.spec.fns) - 1


def collect(mut c: Checker):
    for d in c.decls.copy():
        var name = c.text_of(d)
        match c.kind_of(d):
            case .ERROR:
                if declare(c, name, d):
                    c.spec.errors.append(qualify_error(name))
            case .CONST:
                if declare(c, name, d):
                    c.spec.consts.append(Const(name.copy(), -1, d))
                    c.const_index[name] = len(c.spec.consts) - 1
            case .ENUM:
                var members: List[String] = []
                for m in c.children(d):
                    var member = c.text_of(m)
                    if member in members:
                        c.error(d, t"enum {name} lists a member twice")
                    else:
                        members.append(member^)
                if declare(c, name, d):
                    var t = c.spec.types.enum_(name.copy(), members)
                    c.spec.enums.append(t)
                    c.enum_index[name] = t
            case .RECORD:
                if declare(c, name, d):
                    c.record_nodes[name] = d
            case .ALIAS:
                if declare(c, name, d):
                    c.alias_nodes[name] = d
            case .MODEL | .INTERFACE:
                _collect_model(c, d)
            case .FN:
                var declared = declare(c, name, d)
                var tparams = type_params(c, c.child(d, 0))
                if declared:
                    c.fn_index[name] = _new_fn(c, d, name.copy(), name.copy(), -1, tparams)
            case .DEF:
                var tparams = type_params(c, c.child(d, 0))
                if name in c.prelude_ids:
                    c.error(d, t"{name} is a prelude function and cannot be redefined")
                    c.duplicate[d] = True
                elif (
                    name in c.names
                    and c.spec.ast.kind_of_file(c.names.get(name).value()) == .FILE
                    and c.spec.ast.kind_of_file(d) == .PRELUDE_FILE
                ):
                    # A definition of the spec itself shadows the attached prelude's.
                    c.duplicate[d] = True
                elif declare(c, name, d):
                    c.spec.defs.append(Def(name.copy(), d, tparams.names.copy(), tparams.bounds.copy(), [], 0, c.child(d, 3)))
                    c.def_index[name] = len(c.spec.defs) - 1
                    c.decl_pos[d] = len(c.spec.defs) - 1
                    c.def_calls.append([])
            case _:
                pass
    # Aliases and records resolve on first use; force them in declaration order.
    for d in _declared(c):
        match c.kind_of(d):
            case .ALIAS:
                _ = alias_type(c, c.text_of(d), d)
            case .RECORD:
                var t = record_type(c, c.text_of(d), d)
                c.spec.records.append(t)
            case _:
                pass
    for i in range(len(c.spec.consts)):
        ensure_const(c, i)


def _collect_model(mut c: Checker, d: Int):
    var name = c.text_of(d)
    var is_iface = c.kind_of(d) == .INTERFACE
    var tparams = type_params(c, c.child(d, 0))
    if not declare(c, name, d):
        return
    var t = c.spec.types.model(name.copy(), c.spec.types.typevars(tparams.names, tparams.bounds), is_iface)
    c.spec.models.append(Model(name.copy(), d, is_iface, t, tparams.names.copy(), tparams.bounds.copy(), [], [], [], [], []))
    var pos = len(c.spec.models) - 1
    c.model_index[name] = pos
    c.decl_pos[d] = pos
    if not is_iface:
        return
    var members = c.children(d)
    for m in members[1:]:
        var kind = c.kind_of(m)
        if kind != .CTOR and kind != .METHOD:
            continue
        var member = c.text_of(m)
        var target = String(t"{name}.{member}")
        var at = _new_fn(c, m, member^, target^, pos, tparams)
        if kind == .CTOR:
            c.spec.models[pos].ctors.append(at)
        else:
            c.spec.models[pos].methods.append(at)


# -- signatures -----------------------------------------------------------------


def build_params(
    mut c: Checker,
    params: Int,
    *,
    self_type: Int = -1,
    allow_self: Bool = False,
    self_model: Int = -1,
    self_reported: Bool = False,
) -> List[Param]:
    var out: List[Param] = []
    for i, p in enumerate(c.children(params)):
        var name = c.text_of(p)
        var tnode = c.child(p, 0)
        if tnode == 0 and name == "self":
            if i == 0 and allow_self:
                out.append(Param(name^, self_type, 0, p))
                continue
            if i != 0 or not self_reported:
                c.error(p, "self is the receiver: it is only the first parameter of a method")
            out.append(Param(name^, c.poison, 0, p))
            continue
        for q in out:
            if q.name == name:
                c.error(p, t"parameter {name} is declared twice")
        if is_reserved(name):
            c.error(p, t"{name} is reserved and cannot name a parameter")
        var t = resolve_type(c, tnode, self_model)
        if c.contains_real(t):
            c.error(tnode, "real is clause-only and cannot be a parameter type")
        out.append(Param(name^, t, c.child(p, 1), p))
    return out^


def _add_member(mut c: Checker, mut members: List[String], var name: String, node: Int, owner: String):
    for _ in range(members.count(name)):
        c.error(node, t"{owner} already has a member named {name}")
    members.append(name^)


def declare_signatures(mut c: Checker):
    for d in _declared(c):
        match c.kind_of(d):
            case .MODEL | .INTERFACE:
                _declare_model(c, d)
            case .FN:
                _declare_fn(c, d)
            case .DEF:
                _declare_def(c, d)
            case _:
                pass


def _declare_model(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    var name = c.spec.models[pos].name.copy()
    var self_t = c.spec.models[pos].type
    c.ctx = Ctx(tvars=_tvars(c.spec.types, c.spec.models[pos].tparams, c.spec.models[pos].bounds))
    var members: List[String] = []
    var children = c.children(d)
    for m in children[1:]:
        match c.kind_of(m):
            case .OBSERVE:
                _add_member(c, members, c.text_of(m), m, name)
                var params = build_params(c, c.child(m, 0), self_model=pos) if c.child(m, 0) != 0 else List[Param]()
                var t = resolve_type(c, c.child(m, 1), pos)
                c.spec.models[pos].observers.append(Observer(c.text_of(m), params^, t, c.child(m, 2), m))
            case .BUILD:
                var params = build_params(c, c.child(m, 0), self_model=pos)
                c.spec.models[pos].builds.append(Build(c.text_of(m), params^, m))
            case .CTOR:
                var fpos = c.decl_pos[m]
                _add_member(c, members, c.text_of(m), m, name)
                var params = build_params(c, c.child(m, 1), self_model=pos)
                c.spec.fns[fpos].params = params^
                var ret = c.child(m, 2)
                if ret == 0:
                    c.error(m, t"a constructor returns its interface: -> {name}")
                else:
                    var declared = resolve_type(c, ret, pos)
                    if not c.is_any(declared) and declared != self_t:
                        c.error(ret, t"a constructor returns its interface: -> {name}")
                c.spec.fns[fpos].result = self_t
            case .METHOD:
                var fpos = c.decl_pos[m]
                _add_member(c, members, c.text_of(m), m, name)
                var params = build_params(c, c.child(m, 1), self_type=self_t, allow_self=True, self_model=pos)
                c.spec.fns[fpos].params = params^
                c.spec.fns[fpos].receiver = True
                var ret = c.child(m, 2)
                var result = c.unit if ret == 0 else resolve_type(c, ret, pos)
                c.spec.fns[fpos].result = result
            case _:
                pass
    c.ctx = Ctx()


def _declare_fn(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    var name = c.spec.fns[pos].name.copy()
    c.ctx = Ctx(tvars=_tvars(c.spec.types, c.spec.fns[pos].tparams, c.spec.fns[pos].bounds))
    var params = c.children(c.child(d, 1))
    var takes_self = Bool(params) and c.text_of(params[0]) == "self" and c.child(params[0], 0) == 0
    var self_t = -1
    if takes_self:
        var dot = name.rfind(".")
        var prefix = String(name[byte=0:dot]) if dot >= 0 else String()
        var model = c.model_index.get(prefix).or_else(-1)
        if dot < 0:
            c.error(
                params[0], t"{name} takes self, but it is not named after a model: write fn Model.{name}(self, ...)"
            )
        elif model < 0:
            c.error(
                params[0], t"{name} takes self, but there is no model or interface named {prefix} to be its receiver"
            )
        else:
            self_t = c.spec.models[model].type
            c.spec.fns[pos].owner = model
            c.spec.fns[pos].receiver = True
    var built = build_params(
        c,
        c.child(d, 1),
        self_type=self_t,
        allow_self=self_t >= 0,
        self_model=c.spec.fns[pos].owner,
        self_reported=takes_self and self_t < 0,
    )
    c.spec.fns[pos].params = built^
    var ret = c.child(d, 2)
    var result = c.unit if ret == 0 else resolve_type(c, ret)
    c.spec.fns[pos].result = result
    c.ctx = Ctx()


def _declare_def(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    c.ctx = Ctx(tvars=_tvars(c.spec.types, c.spec.defs[pos].tparams, c.spec.defs[pos].bounds))
    var params = build_params(c, c.child(d, 1))
    c.spec.defs[pos].params = params^
    var result = resolve_type(c, c.child(d, 2))
    c.spec.defs[pos].result = result
    c.ctx = Ctx()


# -- defaults -------------------------------------------------------------------


def _in_fixed_range(value: Real, bits: Int, signed: Bool) -> Bool:
    ref n = value.numerator
    return value.is_integer() and int_min(bits, signed) <= n and n <= int_max(bits, signed)


def check_default(mut c: Checker, p: Param):
    var default = p.default
    var dt = infer_in(c, Ctx(tvars=c.ctx.tvars.copy(), no_result="a default value cannot refer to result"), default)
    if c.is_poison(dt):
        return
    var t = p.type
    if not assignable(c, dt, t, default):
        if c.tkind(t) == .LITERAL and c.kind_of(default) == .STR:
            literal_member(c, t, default)
        else:
            c.error(default, t"the default of {p.name} must be a {c.text(t)}, but it is {c.text(dt)}")
        return
    var value = c.literal_value(default)
    if value is None:
        return
    match c.tkind(t):
        case .FIXED_INT:
            var bits = c.spec.types.infos[t].bits
            var signed = c.spec.types.infos[t].signed
            if not _in_fixed_range(value.value(), bits, signed):
                c.error(
                    default,
                    t"{c.source_of(default)} is not a {c.text(t)} value ({int_min(bits, signed)} to "
                    t"{int_max(bits, signed)})",
                )
        case .FLOAT:
            if exactly(c.spec.types.format(t), value.value()) is None:
                c.error(default, t"{c.source_of(default)} is not exactly representable as {c.text(t)}")
        case _:
            pass


def check_defaults(mut c: Checker):
    for d in _declared(c):
        var pos = c.decl_pos[d]
        var param_lists: List[List[Param]]
        match c.kind_of(d):
            case .FN:
                c.ctx = Ctx(tvars=_tvars(c.spec.types, c.spec.fns[pos].tparams, c.spec.fns[pos].bounds))
                param_lists = [c.spec.fns[pos].params.copy()]
            case .DEF:
                c.ctx = Ctx(tvars=_tvars(c.spec.types, c.spec.defs[pos].tparams, c.spec.defs[pos].bounds))
                param_lists = [c.spec.defs[pos].params.copy()]
            case .MODEL | .INTERFACE:
                ref model = c.spec.models[pos]
                c.ctx = Ctx(tvars=_tvars(c.spec.types, model.tparams, model.bounds))
                param_lists = [o.params.copy() for o in model.observers] + [b.params.copy() for b in model.builds]
                param_lists.extend([c.spec.fns[f].params.copy() for f in model.ctors + model.methods.copy()])
            case _:
                param_lists = []
        for params in param_lists:
            for p in params:
                if p.default != 0:
                    check_default(c, p)
        c.ctx = Ctx()


# -- clause ids -----------------------------------------------------------------


def _add_clause(mut c: Checker, id: String, node: Int, label: String, owner_fn: Int, owner_model: Int) -> Int:
    var op = c.op_of(node)
    var children = c.children(node)
    var expr = 0
    var error = String()
    var names: List[String] = []
    match op:
        case .RAISES | .MAY_RAISE:
            error = qualify_error(c.text_of(children[0]))
            expr = children[1]
        case .MODIFIES:
            names = [c.text_of(k) for k in children]
        case .UNSPECIFIED | .IMPL_DEFINED:
            names = [c.text_of(children[0])]
        case .PERF:
            pass
        case _:
            expr = children[0]
    c.spec.clauses.append(Clause(id.copy(), op, label.copy(), node, expr, error^, names^, owner_fn, owner_model))
    c.clause_ids[id] = len(c.spec.clauses) - 1
    return len(c.spec.clauses) - 1


def assign_ids(
    mut c: Checker,
    decl_id: String,
    clauses: List[Int],
    *,
    owner_fn: Int,
    owner_model: Int,
    members: Dict[String, String],
) -> List[Int]:
    """Gives each clause its id, `<decl>.<label>` or `<decl>#<n>`; the positions of the new
    clauses. `members` maps the names of the declaration's members to what each is, eg.
    "observer", since a label may not repeat one."""
    var out: List[Int] = []
    var labels: Dict[String, Int] = {}
    for i, cl in enumerate(clauses):
        var label = c.text_of(cl)
        var id = String(t"{decl_id}#{i + 1}")
        if label:
            var labelled = String(t"{decl_id}.{label}")
            if case .Some(member) = members.get(label):
                c.error(
                    cl,
                    t"clause label {label} gives the ID {labelled}, which already names the "
                    t"{member} {labelled}: rename the label (e.g. {c.op_of(cl)} {label}_holds:)",
                )
                label = String()
            elif case .Some(earlier) = labels.get(label):
                c.error(cl, t"clause label {label} is already used in {decl_id} (line {c.line_of(earlier)})")
                label = String()
            else:
                labels[label] = cl
                id = labelled^
        if id in c.clause_ids:
            c.error(cl, t"clause ID {id} is already in use")
        out.append(_add_clause(c, id, cl, label, owner_fn, owner_model))
    return out^


def check_freedoms(mut c: Checker, decl_id: String, clauses: List[Int]):
    var freedoms: Dict[String, Int] = {}
    for ci in clauses:
        var op = c.spec.clauses[ci].kind
        if op != .UNSPECIFIED and op != .IMPL_DEFINED:
            continue
        var cl = c.spec.clauses[ci].node
        var f = c.spec.clauses[ci].names[0].copy()
        if f in freedoms:
            c.error(cl, t"{f} is already declared a freedom of {decl_id}")
        else:
            freedoms[f^] = cl
    if not freedoms:
        return
    for ci in clauses:
        var expr = c.spec.clauses[ci].expr
        if expr == 0:
            continue
        var reported: List[String] = []
        for n in c.spec.ast.subtree(expr):
            var name = _observed(c, n)
            if name in reported:
                continue
            if case .Some(at) = freedoms.get(name):
                reported.append(name.copy())
                c.error(
                    n,
                    t"this clause observes {name}, which {decl_id} declares {c.op_of(at)} (line {c.line_of(at)}): no "
                    t"clause may observe it",
                )


def _observed(c: Checker, n: Int) -> String:
    """The prelude function, observer or field that node `n` names, or ""."""
    if case .Some(r) = c.spec.resolutions.get(n):
        match r.kind:
            case .PRELUDE | .OBSERVER | .FIELD:
                return r.name.copy()
            case _:
                pass
    return String()


# -- models and interfaces ---------------------------------------------------------


def check_model(mut c: Checker, d: Int):
    var pos = c.decl_pos[d]
    var name = c.spec.models[pos].name.copy()
    var is_iface = c.spec.models[pos].is_interface
    var what = "interface" if is_iface else "model"
    var mt = c.spec.models[pos].type
    c.ctx = Ctx(tvars=_tvars(c.spec.types, c.spec.models[pos].tparams, c.spec.models[pos].bounds))
    for i in range(len(c.spec.models[pos].observers)):
        _check_observer_expr(c, pos, i)
    var members: Dict[String, String] = {}
    for o in c.spec.models[pos].observers:
        members[o.name.copy()] = "observer"
    if is_iface:
        for f in c.spec.models[pos].ctors:
            members[c.spec.fns[f].name.copy()] = "constructor"
        for f in c.spec.models[pos].methods:
            members[c.spec.fns[f].name.copy()] = "method"
    # Qualified functions named under the model are its methods and statics.
    var prefix = name + "."
    for f in c.spec.fns:
        if f.kind == .FN and f.name.startswith(prefix):
            var rest = String(f.name[byte = prefix.byte_length() :])
            if "." not in rest:
                members[rest^] = "method" if f.receiver else "function"
    var clauses = [m for m in c.children(d) if c.kind_of(m) == .CLAUSE]
    var ids = assign_ids(c, name, clauses, owner_fn=-1, owner_model=pos, members=members)
    c.spec.models[pos].clauses = ids.copy()
    for ci in ids:
        var op = c.spec.clauses[ci].kind
        var expr = c.spec.clauses[ci].expr
        match op:
            case .INVARIANT if expr != 0:
                var ctx = Ctx(
                    tvars=c.ctx.tvars.copy(),
                    self_t=mt,
                    self_model=pos,
                    fields_of=pos,
                    allow_spec_fn=True,
                    no_result="an invariant describes an object's state: there is no result",
                )
                want_bool(c, expr, infer_in(c, ctx^, expr), "an invariant")
            case .INVARIANT | .UNSPECIFIED | .IMPL_DEFINED | .PERF:
                pass
            case _:
                c.error(
                    c.spec.clauses[ci].node, t"{op} belongs to a function, constructor or method, not to {what} {name}"
                )
                if expr != 0:
                    poison_subtree(c, expr)
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
    var ctx = Ctx(
        tvars=c.ctx.tvars.copy(),
        params=_param_vars(c.spec.models[model].observers[oi].params),
        self_t=c.spec.models[model].type,
        self_model=model,
        fields_of=model,
        extern_result=declared,
        no_result="an observer's reading expression has no result",
    )
    var t = infer_in(c, ctx^, expr)
    if not c.is_poison(t) and not assignable(c, t, declared, expr):
        c.error(
            expr,
            t"the reading expression of {oname} is a {c.text(t)}, but {oname} is declared {c.text(declared)}",
        )


# -- callables -------------------------------------------------------------------


def _callable_ctx(mut c: Checker, fpos: Int) -> Ctx:
    ref f = c.spec.fns[fpos]
    var receiver = f.receiver
    var ctx = Ctx(
        tvars=_tvars(c.spec.types, f.tparams, f.bounds),
        params=[Var(String() if receiver and i == 0 else p.name.copy(), p.type, 0) for i, p in enumerate(f.params)],
        no_self="a constructor has no self: the new object is result" if f.kind == .CTOR else "self is only available in methods",
    )
    if receiver and f.params:
        ctx.self_t = f.params[0].type
        ctx.self_model = f.owner
    return ctx^


def check_callable(mut c: Checker, fpos: Int, what: String):
    var decl_id = c.spec.fns[fpos].decl_id.copy()
    var base = _callable_ctx(c, fpos)
    var body: List[Int] = []
    var parts: List[Int] = []
    var children = c.children(c.spec.fns[fpos].node)
    for k in children[3:]:
        match c.kind_of(k):
            case .CLAUSE:
                body.append(k)
            case .PARTITION:
                parts.append(k)
            case _:
                pass
    var ids = assign_ids(c, decl_id, body, owner_fn=fpos, owner_model=c.spec.fns[fpos].owner, members={})
    c.spec.fns[fpos].clauses = ids.copy()
    for i, p in enumerate(parts):
        _check_partition(c, fpos, p, base, decl_id, List(parts[:i]))
    for ci in ids:
        var op = c.spec.clauses[ci].kind
        var expr = c.spec.clauses[ci].expr
        match op:
            case .INVARIANT:
                c.error(c.spec.clauses[ci].node, t"invariant belongs to a model or interface; in a {what} use ensures")
                if expr != 0:
                    poison_subtree(c, expr)
            case .MODIFIES:
                _check_modifies(c, ci, decl_id, base)
            case .AGGREGATE:
                _check_aggregate(c, ci, fpos, decl_id, base, what)
            case .RAISES | .MAY_RAISE if expr != 0:
                want_bool(c, expr, infer_in(c, _before_call_ctx(base, op), expr), t"the condition of {op}")
            case .REQUIRES if expr != 0:
                want_bool(c, expr, infer_in(c, _before_call_ctx(base, op), expr), t"the {op} clause")
            case _ if expr != 0:
                want_bool(c, expr, infer_in(c, _after_call_ctx(c, base, fpos, op), expr), t"the {op} clause")
            case _:
                pass
    check_freedoms(c, decl_id, ids)
    c.ctx = Ctx()


def _before_call_ctx(base: Ctx, op: Op) -> Ctx:
    """The context of a clause evaluated on a call's inputs: requires, raises, may_raise."""
    var ctx = base.copy()
    ctx.no_result = String(t"result is not available in {op}: it is evaluated on the inputs, before the call")
    ctx.no_old = String(t"old(...) is only allowed in ensures; {op} already sees the state before the call")
    return ctx^


def _after_call_ctx(c: Checker, base: Ctx, fpos: Int, op: Op) -> Ctx:
    """The context of a clause that sees a call's result, a planned call of a spec function and,
    in ensures, old(...)."""
    ref f = c.spec.fns[fpos]
    var ctx = base.copy()
    if f.result != c.unit:
        ctx.result = f.result
    ctx.no_result = String(t"{f.decl_id} returns nothing, so there is no result")
    ctx.allow_spec_fn = True
    if op == .ENSURES:
        ctx.allow_old = base.self_t >= 0 or any([c.contains_model(p.type) for p in base.params])
        ctx.no_old = String(
            t"old(...) needs state that the call can change, but {f.decl_id} has no handle parameter or self"
        )
    return ctx^


def _check_modifies(mut c: Checker, ci: Int, decl_id: String, base: Ctx):
    var node = c.spec.clauses[ci].node
    var seen: List[String] = []
    for n in c.spec.clauses[ci].names.copy():
        for _ in range(seen.count(n)):
            c.error(node, t"modifies lists {n} twice")
        seen.append(n.copy())
        if n == "self":
            if base.self_t < 0:
                c.error(node, "modifies self: self is only available in methods")
            continue
        var pi = base.param_index(n)
        if pi < 0:
            c.error(node, t"modifies {n}: {decl_id} has no parameter {n}")
        elif not c.contains_model(base.params[pi].type):
            c.error(
                node,
                t"modifies names handle parameters (models or interfaces) or self; {n} is a "
                t"{c.text(base.params[pi].type)} value, which a call cannot change",
            )


def _check_partition(mut c: Checker, fpos: Int, part: Int, base: Ctx, decl_id: String, earlier: List[Int]):
    """Checks a partition of a callable, after the `earlier` ones."""
    var pname = c.text_of(part)
    var classes = c.children(part)
    for e in earlier:
        if c.text_of(e) == pname:
            c.error(part, t"{pname} is already partitioned at line {c.line_of(e)}")
    var pi = base.param_index(pname)
    if pi < 0:
        if pname == "self":
            c.error(part, "self cannot be partitioned: partition the method's parameters")
        else:
            c.error(part, t"partition {pname}: {decl_id} has no parameter {pname}")
        for cls in classes:
            poison_subtree(c, c.child(cls, 0))
        return
    var ptype = base.params[pi].type
    var fixed = c.spec.types.is_fixed_width(ptype)
    var out = Partition(pi, part, [])
    var done: List[Var] = []
    for cls in classes:
        var cname = c.text_of(cls)
        var expr = c.child(cls, 0)
        if any([v.name == cname for v in done]):
            c.error(cls, t"partition {pname} already has a class named {cname}")
        elif base.param_index(cname) >= 0:
            c.error(cls, t"class {cname} has the name of a parameter of {decl_id}")
        var ctx = base.copy()
        ctx.in_partition_set = fixed
        ctx.only_param = pname.copy()
        ctx.classes = done.copy()
        ctx.no_result = "a partition class describes an input: there is no result"
        ctx.no_self = "self cannot appear in a partition class"
        if fixed:
            var st = c.spec.types.set_of(ptype)
            var t = infer_in(c, ctx^, expr, st)
            if not c.is_any(t) and t != st:
                var pt = c.text(ptype)
                var all_name = "nan" if c.tkind(ptype) == .FLOAT else "all"
                c.error(
                    expr,
                    t"class {cname} of the {pt} parameter {pname} must be a set of {pt} values ({pt}.{all_name}, "
                    t"{pt}.range(a, b), {{v, ...}}, combined with | & -), but it is {c.text(t)}",
                )
            done.append(Var(cname.copy(), st, cls))
        else:
            want_bool(c, expr, infer_in(c, ctx^, expr), String(t"class {cname} (a predicate over {pname})"))
            done.append(Var(cname.copy(), c.bool_, cls))
        out.classes.append(PartitionClass(cname^, cls, expr))
    c.spec.fns[fpos].partitions.append(out^)


# -- aggregates -------------------------------------------------------------------


def is_constant(c: Checker, e: Int) -> Bool:
    match c.kind_of(e):
        case .NUM:
            return True
        case .UNARY:
            return c.op_of(e) == .NEG and is_constant(c, c.child(e, 0))
        case .BINARY:
            match c.op_of(e):
                case .ADD | .SUB | .MUL | .DIV | .FLOORDIV | .MOD:
                    return is_constant(c, c.child(e, 0)) and is_constant(c, c.child(e, 1))
                case _:
                    return False
        case .ATTR:
            var r = c.spec.resolutions.get(e)
            return r is not None and r.value().kind == .TYPE_CONST
        case _:
            return False


def _check_aggregate(mut c: Checker, ci: Int, fpos: Int, decl_id: String, base: Ctx, what: String):
    var node = c.spec.clauses[ci].node
    var expr = c.spec.clauses[ci].expr
    if c.spec.fns[fpos].kind != .FN:
        c.error(
            node,
            t"aggregate clauses belong to functions (fn), not to a {what}: a bound over a whole input "
            t"set needs inputs that do not depend on an object's state",
        )
        poison_subtree(c, expr)
        return
    var fname = c.spec.fns[fpos].name.copy()
    var ctx = base.copy()
    for p in base.params:
        if p.name:
            ctx.hidden[p.name.copy()] = String(
                t"an aggregate clause cannot use the parameter {p.name} of {decl_id}: it ranges over its own "
                t"variable, e.g. sum(v in S: qe({fname}(v), ...))"
            )
    ctx.allow_spec_fn = True
    ctx.no_result = String(
        t"an aggregate clause is evaluated once over a set of inputs, so there is no result: call {fname}(v) "
        t"for each member instead"
    )
    ctx.no_old = "old(...) has no meaning in an aggregate clause: it is not tied to one call"
    ctx.no_self = "an aggregate clause has no self"
    var shape = aggregate_shape(c.spec.ast, expr)
    ctx.aggregate_top = shape.top
    want_bool(c, expr, infer_in(c, ctx^, expr), "the aggregate clause")
    if shape.problem:
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
    var ctx = Ctx(
        tvars=_tvars(c.spec.types, c.spec.defs[pos].tparams, c.spec.defs[pos].bounds),
        params=_param_vars(c.spec.defs[pos].params),
        no_result="a definition has no result: its value is the expression",
        no_self="a definition has no self",
    )
    var body = c.spec.defs[pos].body
    c.current_def = pos
    var t = infer_in(c, ctx^, body)
    c.current_def = -1
    var declared = c.spec.defs[pos].result
    if not c.is_poison(t) and not assignable(c, t, declared, body):
        c.error(body, t"the body of {name} is a {c.text(t)}, but it is declared to return {c.text(declared)}")


def check_def_cycles(mut c: Checker):
    """Definitions may not call themselves, directly or through others."""
    var visits = List[Visit](length=len(c.spec.defs), fill=.UNSEEN)
    var reported = List[Bool](length=len(c.spec.defs), fill=False)
    for d in range(len(c.spec.defs)):
        if visits[d] == .UNSEEN:
            var path: List[Int] = []
            _visit_def(c, d, visits, path, reported)


def _visit_def(mut c: Checker, d: Int, mut visits: List[Visit], mut path: List[Int], mut reported: List[Bool]):
    """Reports each cycle through `d` once, at the definition it returns to."""
    visits[d] = .ON_PATH
    path.append(d)
    for callee in c.def_calls[d].copy():
        if visits[callee] == .UNSEEN:
            _visit_def(c, callee, visits, path, reported)
        elif visits[callee] == .ON_PATH and not reported[callee]:
            reported[callee] = True
            var start = path.try_index(callee).value()
            var at = c.spec.defs[callee].node
            if start == len(path) - 1:
                var name = c.spec.defs[callee].name.copy()
                c.error(at, t"definition {name} calls itself")
            else:
                var cycle = cycle_text([c.spec.defs[p].name.copy() for p in path[start:]])
                c.error(at, t"definitions cannot call each other in a cycle: {cycle}")
    _ = path.pop()
    visits[d] = .DONE


# -- the whole file ------------------------------------------------------------------


def run(mut c: Checker):
    collect(c)
    declare_signatures(c)
    check_defaults(c)
    for d in _declared(c):
        match c.kind_of(d):
            case .DEF:
                check_def(c, d)
            case .MODEL | .INTERFACE:
                check_model(c, d)
            case .FN:
                check_callable(c, c.decl_pos[d], "function")
            case _:
                pass
    check_def_cycles(c)
