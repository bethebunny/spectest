"""The expression evaluator: checked expressions on `Value`s.

`ev` evaluates one node against an `Env`. A failure raises an `Error` and is recorded
in the `Run`: the node it is attributed to, and whether it is a skip of the clause (a
planned call that raised in the library) rather than an error.
"""

from check import spec as sp
from check import types as ty
from check.spec import Spec, Param
from numeric.fixed import int_max, int_min
from numeric.formats import format_by_id
from numeric.literal import is_integer_literal, parse_number
from partitions.compile import compile_set_aliased
from prelude import api
from prelude.collections import eq as prelude_eq
from sets import BitSet, SetContext
from syntax import ast
from wire.equality import same
from wire.value import Value

from .coerce import bits_of_value, coerce_arg, fit, value_from_bits
from .env import Env, Run
from .host import EvalHost
from .numbers import (
    add_term,
    arith,
    compare_values,
    concat,
    contains,
    elements,
    holds_order,
    index_value,
    larger,
    negate,
    qerr_add,
    qerr_compare,
    qerr_zero,
    show,
    slice_value,
    term_of,
    values_equal,
)


comptime SET_LIMIT = 1 << 16
"""The most members of a partition set a comprehension visits."""


def tkind(spec: Spec, node: Int) -> UInt8:
    return spec.types.infos[spec.node_types[node]].kind


def scalar_name(info: ty.TypeInfo) -> String:
    """The name a scalar type is written with, or an empty string."""
    if info.kind == ty.BOOL:
        return "bool"
    if info.kind == ty.INT:
        return "int"
    if info.kind == ty.REAL:
        return "real"
    if info.kind == ty.STRING:
        return "string"
    if info.kind == ty.BYTES:
        return "bytes"
    if info.kind == ty.FIXED_INT:
        return String("i" if info.signed else "u", info.bits)
    if info.kind == ty.FLOAT:
        return ["f16", "bf16", "f32", "f64"][info.bits - 1]
    return ""


def scalar_type_id(types: ty.Types, name: String) -> Int:
    """The id of the interned scalar type `name` denotes, or -1."""
    for t in range(len(types.infos)):
        if scalar_name(types.infos[t]) == name:
            return t
    return -1


def type_arg(spec: Spec, node: Int, env: Env) raises -> Int:
    var name = spec.ast.nodes[node].text.copy()
    if name in env.types:
        return env.types[name]
    var scalar = scalar_type_id(spec.types, name)
    if scalar >= 0:
        return scalar
    var alias = spec.aliases.get(name)
    if alias is None:
        raise Error(t"cannot resolve the type argument {name}")
    return alias.value()


def self_of(env: Env) raises -> Value:
    if env.has_self:
        return env.self_value.copy()
    if len(env.params) > 0:
        return env.params[0].copy()
    raise Error("no value for self")


def want_bool(v: Value, what: String) raises -> Bool:
    if v.kind != .BOOL:
        raise Error(t"{what} must be a bool, but it is {show(v)}")
    return v.as_bool()


def is_sequence(v: Value) -> Bool:
    return v.kind == .LIST or v.kind == .STRING or v.kind == .BYTES or v.kind == .ENUM


def ev[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    """The value of the expression at node `e`."""
    try:
        return ev_inner(spec, e, env, run, host)
    except err:
        if run.err_node < 0:
            run.err_node = e
            run.err_message = String(err)
        raise err^


def _int_literal(text: String) -> Optional[Int]:
    if len(text.as_bytes()) == 0 or len(text.as_bytes()) > 18:
        return None
    var n = 0
    for b in text.as_bytes():
        var digit = Int(b) - ord("0")
        if digit < 0 or digit > 9:
            return None
        n = n * 10 + digit
    return n


def ev_inner[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var k = n.kind
    if k == .NAME:
        return ev_name(spec, e, env, run, host)
    if k == .BINARY:
        return ev_binary(spec, e, env, run, host)
    if k == .CALL:
        return ev_call(spec, e, env, run, host)
    if k == .ATTR:
        return ev_attr(spec, e, env, run, host)
    if k == .NUM:
        var small = _int_literal(n.text)
        if small is not None:
            return Value.int(small.value())
        var r = parse_number(n.text)
        if is_integer_literal(n.text):
            return Value.int(r.numerator.copy())
        return Value.real(r.numerator.copy(), r.denominator.copy())
    if k == .STR:
        return Value.string(n.text.copy())
    if k == .BOOL:
        return Value.bool(n.op == .TRUE)
    if k == .NONE:
        return Value.none()
    if k == .UNARY:
        var operand = ev(spec, n.children[0], env, run, host)
        if n.op == .NOT:
            return Value.bool(not want_bool(operand, "the operand of not"))
        return fit(spec.types, negate(operand), spec.node_types[e])
    if k == .IF:
        var branch = n.children[1] if want_bool(ev(spec, n.children[0], env, run, host), "the condition of if") else n.children[2]
        return fit(spec.types, ev(spec, branch, env, run, host), spec.node_types[e])
    if k == .LET:
        run.push(e, ev(spec, n.children[0], env, run, host))
        var body = ev(spec, n.children[1], env, run, host)
        run.pop()
        return body^
    if k == .COMPREHENSION:
        return ev_comprehension(spec, e, env, run, host)
    if k == .INDEX:
        var v = ev(spec, n.children[0], env, run, host)
        var i = ev(spec, n.children[1], env, run, host)
        if v.kind == .MAP:
            return map_lookup(v, i)
        if not is_sequence(v):
            raise Error(t"cannot index {show(v)}")
        return index_value(v, i)
    if k == .SLICE:
        var v = ev(spec, n.children[0], env, run, host)
        var lo = ev(spec, n.children[1], env, run, host)
        var hi = ev(spec, n.children[2], env, run, host)
        if not is_sequence(v):
            raise Error(t"cannot slice {show(v)}")
        return slice_value(v, lo, hi)
    if k == .TUPLE_INDEX:
        var v = ev(spec, n.children[0], env, run, host)
        if v.kind != .TUPLE and v.kind != .LIST:
            raise Error(t".{n.text} needs a tuple, but the value is {show(v)}")
        var index = Int(n.text)
        if index < 0 or index >= v.count():
            raise Error(t".{n.text} is out of range for a tuple of {v.count()} elements")
        return v.item(index)
    if k == .LIST or k == .TUPLE:
        var items = [ev(spec, kid, env, run, host) for kid in n.children]
        if k == .TUPLE:
            return Value.tuple(items^)
        return fit(spec.types, Value.list(items^), spec.node_types[e])
    if k == .SET:
        raise Error("{...} is a partition set: it has no value in a clause")
    raise Error(t"cannot evaluate a {k} node")


def map_lookup(m: Value, key: Value) raises -> Value:
    for i in range(m.count()):
        if values_equal(key, m.item(2 * i)):
            return m.item(2 * i + 1)
    raise Error(t"key {show(key)} is not in the map")


# Names


def ev_name[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    var found = spec.resolutions.get(e)
    ref name = spec.ast.nodes[e].text
    if found is None:
        raise Error(t"{name} has no value: the checker did not resolve it")
    var r = found.value().copy()
    var kind = r.kind
    if kind == sp.R_PARAM:
        if r.index >= len(env.params):
            raise Error(t"no value for the parameter {name}")
        return env.params[r.index].copy()
    if kind == sp.R_RESULT:
        if not env.has_result:
            raise Error("no value for the result")
        return env.result.copy()
    if kind == sp.R_SELF:
        return self_of(env)
    if kind == sp.R_LOCAL:
        var local = run.innermost(r.index)
        if local is None:
            raise Error(t"no value for the local {name}")
        return local.take()
    if kind == sp.R_FIELD:
        return host.observe(self_of(env), r.owner, r.index, [])
    if kind == sp.R_ENUM_MEMBER:
        return enum_member(spec, r.owner, r.index)
    if kind == sp.R_CLASS:
        var expr = spec.ast.nodes[r.index].children[0]
        if tkind(spec, expr) == ty.BOOL:
            return ev(spec, expr, env, run, host)
        raise Error(t"class {name} is a partition set: it has no value in a clause")
    if kind == sp.R_CONST:
        return host.constant(r.index)
    raise Error(t"{name} cannot be evaluated as a value")


def enum_member(spec: Spec, enum_type: Int, index: Int) -> Value:
    ref info = spec.types.infos[enum_type]
    return Value.enum(info.name.copy(), info.names[index].copy())


def ev_attr[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var found = spec.resolutions.get(e)
    if found is None:
        raise Error(t".{n.text} cannot be evaluated: the checker did not resolve it")
    var r = found.value().copy()
    var kind = r.kind
    if kind == sp.R_ENUM_MEMBER:
        return enum_member(spec, r.owner, r.index)
    if kind == sp.R_CONST:
        return host.constant(r.index)
    if kind == sp.R_TYPE_CONST:
        if tkind(spec, e) == ty.SET:
            raise Error(t"{spec.ast.source_text(e)} is a partition set: it has no value in a clause")
        ref scalar = spec.types.infos[r.index]
        if scalar.kind == ty.FIXED_INT:
            return Value.int(int_min(scalar.bits, scalar.signed) if r.name == "min" else int_max(scalar.bits, scalar.signed))
        var f = format_by_id(UInt8(scalar.bits))
        var top = f.max_finite()
        return Value.float(f, top if r.name == "max" else top | f.sign_mask())
    if kind == sp.R_OBSERVER:
        var obj = ev(spec, n.children[0], env, run, host)
        if obj.kind != .HANDLE:
            raise Error(t"observer {n.text} needs a handle, but got {show(obj)}")
        return host.observe(obj, r.owner, r.index, [])
    if kind == sp.R_RECORD_FIELD:
        var rec = ev(spec, n.children[0], env, run, host)
        if rec.kind != .RECORD:
            raise Error(t".{n.text} needs a record, but got {show(rec)}")
        for i in range(rec.count()):
            if rec.item(2 * i).text() == n.text:
                return rec.item(2 * i + 1)
        raise Error(t"record {rec.name()} has no field {n.text}")
    if kind == sp.R_QERR_PART:
        var q = ev(spec, n.children[0], env, run, host)
        if q.kind != .QERR:
            raise Error(t".{n.text} needs a qerr, but got {show(q)}")
        return q.item(0 if n.text == "steps" else 1)
    if kind == sp.R_SET_CTOR:
        raise Error(t"{spec.ast.source_text(e)} is a partition set constructor")
    raise Error(t".{n.text} cannot be evaluated")


# Operators


def ev_binary[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var op = n.op
    if op == .IMPLIES or op == .AND or op == .OR:
        var name = "implies" if op == .IMPLIES else ("and" if op == .AND else "or")
        var left = want_bool(ev(spec, n.children[0], env, run, host), String("the left operand of ", name))
        if left if op == .OR else not left:
            return Value.bool(op != .AND)
        return Value.bool(want_bool(ev(spec, n.children[1], env, run, host), String("the right operand of ", name)))
    if tkind(spec, e) == ty.SET:
        raise Error(t"{op} combines partition sets: it has no value in a clause")
    if op == .IN and tkind(spec, n.children[1]) == ty.SET:
        return Value.bool(set_contains(spec, n.children[1], ev(spec, n.children[0], env, run, host)))
    var a = ev(spec, n.children[0], env, run, host)
    var b = ev(spec, n.children[1], env, run, host)
    var has_qerr = a.kind == .QERR or b.kind == .QERR
    if op == .EQ or op == .NE:
        var equal: Bool
        if has_qerr:
            equal = qerr_compare(ast.Op.EQ, a, b)
        elif tkind(spec, n.children[0]) == ty.CHOICE or tkind(spec, n.children[1]) == ty.CHOICE:
            equal = same(a, b)
        else:
            equal = values_equal(a, b)
        return Value.bool(equal if op == .EQ else not equal)
    if op == .LT or op == .LE or op == .GT or op == .GE:
        return Value.bool(qerr_compare(op, a, b) if has_qerr else holds_order(op, compare_values(a, b)))
    if op == .IN:
        return Value.bool(contains(b, a))
    if op == .ADD:
        if has_qerr:
            if a.kind == .QERR and b.kind == .QERR:
                return qerr_add(a, b)
            raise Error(t"+ adds two qerr values, not {show(a)} and {show(b)}")
        var joined = concat(a, b)
        if joined is not None:
            return joined.take()
    elif has_qerr:
        raise Error(t"{op} is not defined on qerr values")
    return fit(spec.types, arith(op, a, b), spec.node_types[e])


# Comprehensions


def set_members(spec: Spec, iterable: Int) raises -> List[Value]:
    var elem = spec.types.info(spec.node_types[iterable]).args[0]
    var ctx = SetContext()
    var s = compile_set_aliased(ctx, spec.ast, spec.types, elem, iterable, {}, spec.aliases)
    return [value_from_bits(spec.types, elem, bits) for bits in ctx.members(s, SET_LIMIT)]


def set_contains(spec: Spec, set_node: Int, x: Value) raises -> Bool:
    """Is the fixed-width value `x` a member of the partition set at `set_node`?"""
    var elem = spec.types.info(spec.node_types[set_node]).args[0]
    var ctx = SetContext()
    var s = compile_set_aliased(ctx, spec.ast, spec.types, elem, set_node, {}, spec.aliases)
    return ctx.contains(s, bits_of_value(spec.types, elem, x))


def ev_comprehension[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var kind = n.op
    var iterable = n.children[0]
    var body = n.children[1]
    var what = String("the body of ", kind, "(...)")
    var items = set_members(spec, iterable) if tkind(spec, iterable) == ty.SET else elements(
        ev(spec, iterable, env, run, host), String(kind, "(...)")
    )
    run.push(e, Value.none())
    var result: Value
    if kind == .ALL or kind == .EXISTS:
        var want = kind == .EXISTS
        var hit = False
        for item in items:
            run.set_top(item.copy())
            if want_bool(ev(spec, body, env, run, host), what) == want:
                hit = True
                break
        result = Value.bool(hit if want else not hit)
    elif kind == .COUNT:
        var count = 0
        for item in items:
            run.set_top(item.copy())
            if want_bool(ev(spec, body, env, run, host), what):
                count += 1
        result = Value.int(count)
    elif kind == .FILTER:
        var kept: List[Value] = []
        for item in items:
            run.set_top(item.copy())
            if want_bool(ev(spec, body, env, run, host), what):
                kept.append(item.copy())
        result = Value.list(kept^)
    elif kind == .MAP:
        var mapped: List[Value] = []
        for item in items:
            run.set_top(item.copy())
            mapped.append(ev(spec, body, env, run, host))
        result = Value.list(mapped^)
    elif kind == .SUM:
        var total = qerr_zero() if tkind(spec, e) == ty.QERR else Value.int(0)
        for item in items:
            run.set_top(item.copy())
            total = add_term(total, ev(spec, body, env, run, host))
        result = total^
    else:
        var best = Optional[Value]()
        for item in items:
            run.set_top(item.copy())
            var term = term_of(ev(spec, body, env, run, host))
            best = larger(best.value(), term) if best is not None else term^
        if best is None:
            raise Error("max(...) of no elements has no value")
        result = best.take()
    run.pop()
    return fit(spec.types, result, spec.node_types[e])


# Calls


def bind_args[
    H: EvalHost
](
    spec: Spec,
    e: Int,
    params: List[Param],
    what: String,
    env: Env,
    mut run: Run,
    mut host: H,
) raises -> List[Value]:
    """The arguments of the call at `e` in the order of `params`, defaults filled in."""
    ref kids = spec.ast.nodes[e].children
    var names = [param.name.copy() for param in params]
    var vals = [Value.none() for _ in params]
    var have = [False for _ in params]
    var next_position = 0
    for k in range(2, len(kids)):
        ref arg = spec.ast.nodes[kids[k]]
        var v = ev(spec, arg.children[0], env, run, host)
        var at = next_position
        if arg.text == "":
            if next_position >= len(params):
                raise Error(t"{what} takes {len(params)} argument(s), but more are given")
            next_position += 1
        elif arg.text in names:
            at = names.index(arg.text)
        else:
            raise Error(t"{what} has no parameter named {arg.text}")
        vals[at] = v^
        have[at] = True
    for i in range(len(params)):
        if have[i]:
            continue
        if params[i].default == 0:
            raise Error(t"{what} needs argument {params[i].name}")
        vals[i] = ev(spec, params[i].default, Env(), run, host)
    return vals^


def coerce_args(
    spec: Spec, mut args: List[Value], params: List[Param], what: String
) raises:
    for i in range(len(params)):
        args[i] = coerce_arg(spec.types, args[i], params[i].type, String(t"argument {params[i].name} of {what}"))


def ev_call[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var found = spec.resolutions.get(e)
    if found is None:
        found = spec.resolutions.get(n.children[0])
    if found is None:
        raise Error("this call cannot be evaluated: the checker did not resolve it")
    var r = found.value().copy()
    var kind = r.kind
    if kind == sp.R_PRELUDE:
        return ev_prelude(spec, e, r.index, env, run, host)
    if kind == sp.R_OLD:
        if e not in env.olds:
            raise Error(
                "old(...) has no snapshot of the state before the call (snapshot_olds must run before the call)"
            )
        ref old = env.olds[e]
        if old.error != "":
            raise run.reraise(old.error_node, old.error.copy(), old.skipped)
        return old.value.copy()
    if kind == sp.R_SPEC_FN:
        ref f = spec.fns[r.index]
        var args = bind_args(spec, e, f.params, f.name, env, run, host)
        coerce_args(spec, args, f.params, f.name)
        var out = host.call_fn(r.index, args^)
        if out.kind == .ERROR:
            raise run.skip(e, String(t"the call of {f.name} raised {out.name()}: {out.text()}"))
        return fit(spec.types, out, spec.node_types[e])
    if kind == sp.R_DEF:
        ref d = spec.defs[r.index]
        var denv = Env(bind_args(spec, e, d.params, d.name, env, run, host))
        denv.types = env.types.copy()
        return fit(spec.types, ev(spec, d.body, denv, run, host), spec.node_types[e])
    if kind == sp.R_OBSERVER or kind == sp.R_FIELD:
        ref obs = spec.models[r.owner].observers[r.index]
        var obj: Value
        if kind == sp.R_FIELD:
            obj = self_of(env)
        else:
            var callee = n.children[0]
            if spec.ast.nodes[callee].kind != .ATTR:
                raise Error(t"observer call {r.name} has no handle")
            obj = ev(spec, spec.ast.nodes[callee].children[0], env, run, host)
        if obj.kind != .HANDLE:
            raise Error(t"observer {r.name} needs a handle, but got {show(obj)}")
        var what = String(spec.models[r.owner].name, ".", r.name)
        var args = bind_args(spec, e, obs.params, what, env, run, host)
        coerce_args(spec, args, obs.params, what)
        return host.observe(obj, r.owner, r.index, args^)
    if kind == sp.R_EXTERN:
        var args = [ev(spec, spec.ast.nodes[n.children[k]].children[0], env, run, host) for k in range(2, len(n.children))]
        return host.call_extern(r.name, args^)
    if kind == sp.R_SET_CTOR:
        raise Error(t"{spec.ast.source_text(n.children[0])}(...) is a partition set")
    raise Error(t"a call of {r.name} cannot be evaluated")


def ev_prelude[
    H: EvalHost
](spec: Spec, e: Int, pid: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var args: List[Value] = []
    var arg_types: List[Int] = []
    var names: List[String] = []
    var keywords: List[Value] = []
    for k in range(2, len(n.children)):
        ref arg = spec.ast.nodes[n.children[k]]
        var v = ev(spec, arg.children[0], env, run, host)
        if arg.text == "":
            args.append(v^)
            arg_types.append(spec.node_types[arg.children[0]])
        else:
            names.append(arg.text.copy())
            keywords.append(v^)
    if pid == api.FRESH:
        return Value.bool(host.fresh(args[0]))
    if pid == api.SAME_OBJECT:
        return Value.bool(host.same_object(args[0], args[1]))
    if pid == api.SHARES_MEMORY:
        return Value.bool(host.shares_memory(args[0], args[1]))
    if pid == api.EQ and len(args) == 2:
        var t = arg_types[0]
        if spec.types.kind(t) == ty.MODEL or (
            spec.types.kind(t) == ty.LIST and spec.types.kind(spec.types.info(t).args[0]) == ty.MODEL
        ):
            var float_mode = Optional[Value]()
            var order = Optional[Value]()
            if "float" in names:
                float_mode = keywords[names.index("float")].copy()
            if "order" in names:
                order = keywords[names.index("order")].copy()
            return Value.bool(model_eq(spec, args[0], args[1], t, float_mode, order, host))
    var type_args = [type_arg(spec, tn, env) for tn in spec.ast.nodes[n.children[1]].children]
    var out = api.call(pid, api.CallArgs(args^, names^, keywords^, type_args^, arg_types^), spec.types)
    return fit(spec.types, out, spec.node_types[e])


def model_eq[
    H: EvalHost
](
    spec: Spec,
    a: Value,
    b: Value,
    t: Int,
    float_mode: Optional[Value],
    order: Optional[Value],
    mut host: H,
) raises -> Bool:
    """`eq` of two values holding model handles: handles compare through their
    zero-argument observers, read with the host."""
    var k = spec.types.kind(t)
    if k == ty.LIST:
        if a.count() != b.count():
            return False
        for i in range(a.count()):
            if not model_eq(spec, a.item(i), b.item(i), spec.types.info(t).args[0], float_mode, order, host):
                return False
        return True
    if k != ty.MODEL:
        return prelude_eq(a, b, float_mode, order).as_bool()
    var model = spec.model_named(spec.types.info(t).name)
    if model is None:
        raise Error(t"eq: no model {spec.types.info(t).name}")
    var mp = model.value()
    for o in range(len(spec.models[mp].observers)):
        ref obs = spec.models[mp].observers[o]
        if len(obs.params) > 0:
            continue
        var va = host.observe(a, mp, o, [])
        var vb = host.observe(b, mp, o, [])
        if not model_eq(spec, va, vb, obs.type, float_mode, order, host):
            return False
    return True
