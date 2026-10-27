"""The expression evaluator: checked expressions on `Value`s.

`ev` evaluates one node against an `Env`. A failure raises an `Error` and is recorded
in the `Run`: the node it is attributed to, and whether it is a skip of the clause (a
planned call that raised in the library) rather than an error.
"""

from check import types as ty
from check.spec import (
    Spec,
    Param,
    R_PARAM,
    R_RESULT,
    R_SELF,
    R_LOCAL,
    R_FIELD,
    R_PRELUDE,
    R_DEF,
    R_TYPE_CONST,
    R_SET_CTOR,
    R_SPEC_FN,
    R_OBSERVER,
    R_RECORD_FIELD,
    R_OLD,
    R_CLASS,
    R_ENUM_MEMBER,
    R_CONST,
    R_QERR_PART,
    R_EXTERN,
)
from numeric.bigint import BigInt
from numeric.formats import format_by_id
from numeric.literal import is_integer_literal, parse_number
from partitions.compile import compile_set_aliased
from prelude import api
from prelude.collections import eq as prelude_eq
from sets import BitSet, SetContext
from syntax import ast
from wire.equality import same
from wire.value import (
    Value,
    BOOL,
    INT,
    FLOAT,
    STRING,
    BYTES,
    LIST,
    TUPLE,
    MAP,
    OPTION,
    RECORD,
    ENUM,
    HANDLE,
    ERROR,
    REAL,
    QERR,
)

from .coerce import (
    bits_of_value,
    coerce_arg,
    fit,
    float_max,
    int_max,
    int_min,
    value_from_bits,
)
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


def scalar_type_id(types: ty.Types, name: String) -> Int:
    """The id of the interned scalar type `name` denotes, or -1."""
    for t in range(len(types.infos)):
        ref i = types.infos[t]
        if i.kind == ty.BOOL and name == "bool":
            return t
        if i.kind == ty.INT and name == "int":
            return t
        if i.kind == ty.REAL and name == "real":
            return t
        if i.kind == ty.STRING and name == "string":
            return t
        if i.kind == ty.BYTES and name == "bytes":
            return t
        if i.kind == ty.FIXED_INT and name == String("i" if i.signed else "u", i.bits):
            return t
        if i.kind == ty.FLOAT:
            if (
                (i.bits == 1 and name == "f16")
                or (i.bits == 2 and name == "bf16")
                or (i.bits == 3 and name == "f32")
                or (i.bits == 4 and name == "f64")
            ):
                return t
    return -1


def type_arg(spec: Spec, node: Int, env: Env) raises -> Int:
    var name = spec.ast.nodes[node].text.copy()
    for i in range(len(env.tvars)):
        if env.tvars[i] == name:
            return env.tvals[i]
    var found = scalar_type_id(spec.types, name)
    if found >= 0:
        return found
    var alias = spec.aliases.get(name)
    if alias:
        return alias.value()
    raise Error("cannot resolve the type argument " + name)


def self_of(env: Env) raises -> Value:
    if env.has_self:
        return env.self_value.copy()
    if len(env.params) > 0:
        return env.params[0].copy()
    raise Error("no value for self")


def want_bool(v: Value, what: String) raises -> Bool:
    if v.kind != BOOL:
        raise Error(what + " must be a bool, but it is " + show(v))
    return v.as_bool()


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
    var bytes = text.as_bytes()
    if len(bytes) == 0 or len(bytes) > 18:
        return None
    var n = 0
    for b in bytes:
        var d = Int(b) - ord("0")
        if d < 0 or d > 9:
            return None
        n = n * 10 + d
    return n


def ev_inner[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var k = n.kind
    if k == ast.NAME:
        return ev_name(spec, e, env, run, host)
    if k == ast.BINARY:
        return ev_binary(spec, e, env, run, host)
    if k == ast.CALL:
        return ev_call(spec, e, env, run, host)
    if k == ast.ATTR:
        return ev_attr(spec, e, env, run, host)
    if k == ast.NUM:
        var small = _int_literal(n.text)
        if small:
            return Value.int(small.value())
        var r = parse_number(n.text)
        if is_integer_literal(n.text):
            return Value.int(r.numerator.copy())
        return Value.real(r.numerator.copy(), r.denominator.copy())
    if k == ast.STR:
        return Value.string(n.text.copy())
    if k == ast.BOOL:
        return Value.bool(n.op == ast.TRUE)
    if k == ast.NONE:
        return Value.none()
    if k == ast.UNARY:
        var operand = ev(spec, n.kids[0], env, run, host)
        if n.op == ast.NOT:
            return Value.bool(not want_bool(operand, "the operand of not"))
        return fit(spec.types, negate(operand), spec.node_types[e])
    if k == ast.IF:
        var c = ev(spec, n.kids[0], env, run, host)
        var branch = n.kids[1] if want_bool(c, "the condition of if") else n.kids[2]
        return fit(spec.types, ev(spec, branch, env, run, host), spec.node_types[e])
    if k == ast.LET:
        var bound = ev(spec, n.kids[0], env, run, host)
        run.push(e, bound^)
        var body = ev(spec, n.kids[1], env, run, host)
        run.pop()
        return body^
    if k == ast.COMPREHENSION:
        return ev_comprehension(spec, e, env, run, host)
    if k == ast.INDEX:
        var v = ev(spec, n.kids[0], env, run, host)
        var i = ev(spec, n.kids[1], env, run, host)
        if v.kind == MAP:
            return map_lookup(v, i)
        if not (v.kind == LIST or v.kind == STRING or v.kind == BYTES or v.kind == ENUM):
            raise Error("cannot index " + show(v))
        return index_value(v, i)
    if k == ast.SLICE:
        var v = ev(spec, n.kids[0], env, run, host)
        var a = ev(spec, n.kids[1], env, run, host)
        var b = ev(spec, n.kids[2], env, run, host)
        if not (v.kind == LIST or v.kind == STRING or v.kind == BYTES or v.kind == ENUM):
            raise Error("cannot slice " + show(v))
        return slice_value(v, a, b)
    if k == ast.TUPLE_INDEX:
        var v = ev(spec, n.kids[0], env, run, host)
        if v.kind != TUPLE and v.kind != LIST:
            raise Error("." + n.text + " needs a tuple, but the value is " + show(v))
        var idx = Int(n.text)
        if idx < 0 or idx >= v.count():
            raise Error("." + n.text + " is out of range for a tuple of " + String(v.count()) + " elements")
        return v.item(idx)
    if k == ast.LIST or k == ast.TUPLE:
        var items = List[Value](capacity=len(n.kids))
        for kid in n.kids:
            items.append(ev(spec, kid, env, run, host))
        if k == ast.TUPLE:
            return Value.tuple(items^)
        return fit(spec.types, Value.list(items^), spec.node_types[e])
    if k == ast.SET:
        raise Error("{...} is a partition set: it has no value in a clause")
    raise Error("cannot evaluate a " + String(ast.kind_name(k)) + " node")


def map_lookup(m: Value, key: Value) raises -> Value:
    for i in range(m.count()):
        if values_equal(key, m.item(2 * i)):
            return m.item(2 * i + 1)
    raise Error("key " + show(key) + " is not in the map")


# Names


def ev_name[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    var found = spec.resolutions.get(e)
    ref name = spec.ast.nodes[e].text
    if not found:
        raise Error(name + " has no value: the checker did not resolve it")
    var r = found.value().copy()
    var kind = r.kind
    if kind == R_PARAM:
        if r.index >= len(env.params):
            raise Error("no value for the parameter " + name)
        return env.params[r.index].copy()
    if kind == R_RESULT:
        if not env.has_result:
            raise Error("no value for the result")
        return env.result.copy()
    if kind == R_SELF:
        return self_of(env)
    if kind == R_LOCAL:
        var at = run.local(r.index)
        if at < 0:
            raise Error("no value for the local " + name)
        return run.local_values[at].copy()
    if kind == R_FIELD:
        return host.observe(self_of(env), r.owner, r.index, List[Value]())
    if kind == R_ENUM_MEMBER:
        return enum_member(spec, r.owner, r.index)
    if kind == R_CLASS:
        var expr = spec.ast.nodes[r.index].kids[0]
        if tkind(spec, expr) == ty.BOOL:
            return ev(spec, expr, env, run, host)
        raise Error("class " + name + " is a partition set: it has no value in a clause")
    if kind == R_CONST:
        return host.constant(r.index)
    raise Error(name + " cannot be evaluated as a value")


def enum_member(spec: Spec, enum_type: Int, index: Int) -> Value:
    ref info = spec.types.infos[enum_type]
    return Value.enum(info.name.copy(), info.names[index].copy())


def ev_attr[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var found = spec.resolutions.get(e)
    if not found:
        raise Error("." + n.text + " cannot be evaluated: the checker did not resolve it")
    var r = found.value().copy()
    var kind = r.kind
    if kind == R_ENUM_MEMBER:
        return enum_member(spec, r.owner, r.index)
    if kind == R_CONST:
        return host.constant(r.index)
    if kind == R_TYPE_CONST:
        if tkind(spec, e) == ty.SET:
            raise Error(source_of(spec, e) + " is a partition set: it has no value in a clause")
        ref st = spec.types.infos[r.index]
        if st.kind == ty.FIXED_INT:
            if r.name == "min":
                return Value.int(int_min(st.bits, st.signed))
            return Value.int(int_max(st.bits, st.signed))
        var f = format_by_id(UInt8(st.bits))
        var top = float_max(f)
        if r.name == "max":
            return Value.float(f, top)
        return Value.float(f, top | f.sign_mask())
    if kind == R_OBSERVER:
        var obj = ev(spec, n.kids[0], env, run, host)
        if obj.kind != HANDLE:
            raise Error("observer " + n.text + " needs a handle, but got " + show(obj))
        return host.observe(obj, r.owner, r.index, List[Value]())
    if kind == R_RECORD_FIELD:
        var rec = ev(spec, n.kids[0], env, run, host)
        if rec.kind != RECORD:
            raise Error("." + n.text + " needs a record, but got " + show(rec))
        for i in range(rec.count()):
            if rec.item(2 * i).text() == n.text:
                return rec.item(2 * i + 1)
        raise Error("record " + rec.name() + " has no field " + n.text)
    if kind == R_QERR_PART:
        var q = ev(spec, n.kids[0], env, run, host)
        if q.kind != QERR:
            raise Error("." + n.text + " needs a qerr, but got " + show(q))
        return q.item(0 if n.text == "steps" else 1)
    if kind == R_SET_CTOR:
        raise Error(source_of(spec, e) + " is a partition set constructor")
    raise Error("." + n.text + " cannot be evaluated")


def source_of(spec: Spec, e: Int) -> String:
    return spec.ast.source_text(e)


# Operators


def ev_binary[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var op = n.op
    if op == ast.IMPLIES:
        var a = ev(spec, n.kids[0], env, run, host)
        if not want_bool(a, "the left operand of implies"):
            return Value.bool(True)
        return Value.bool(want_bool(ev(spec, n.kids[1], env, run, host), "the right operand of implies"))
    if op == ast.AND:
        var a = ev(spec, n.kids[0], env, run, host)
        if not want_bool(a, "the left operand of and"):
            return Value.bool(False)
        return Value.bool(want_bool(ev(spec, n.kids[1], env, run, host), "the right operand of and"))
    if op == ast.OR:
        var a = ev(spec, n.kids[0], env, run, host)
        if want_bool(a, "the left operand of or"):
            return Value.bool(True)
        return Value.bool(want_bool(ev(spec, n.kids[1], env, run, host), "the right operand of or"))
    if tkind(spec, e) == ty.SET:
        raise Error(String(ast.op_name(op)) + " combines partition sets: it has no value in a clause")
    if op == ast.IN and tkind(spec, n.kids[1]) == ty.SET:
        var x = ev(spec, n.kids[0], env, run, host)
        return Value.bool(set_contains(spec, n.kids[1], x))
    var a = ev(spec, n.kids[0], env, run, host)
    var b = ev(spec, n.kids[1], env, run, host)
    if op == ast.EQ or op == ast.NE:
        var eq: Bool
        if a.kind == QERR or b.kind == QERR:
            eq = qerr_compare(ast.EQ, a, b)
        elif tkind(spec, n.kids[0]) == ty.CHOICE or tkind(spec, n.kids[1]) == ty.CHOICE:
            eq = same(a, b)
        else:
            eq = values_equal(a, b)
        return Value.bool(eq if op == ast.EQ else not eq)
    if op == ast.LT or op == ast.LE or op == ast.GT or op == ast.GE:
        if a.kind == QERR or b.kind == QERR:
            return Value.bool(qerr_compare(op, a, b))
        return Value.bool(holds_order(op, compare_values(a, b)))
    if op == ast.IN:
        return Value.bool(contains(b, a))
    if op == ast.ADD:
        if a.kind == QERR or b.kind == QERR:
            if a.kind == QERR and b.kind == QERR:
                return qerr_add(a, b)
            raise Error("+ adds two qerr values, not " + show(a) + " and " + show(b))
        var joined = concat(a, b)
        if joined:
            return joined.take()
    elif a.kind == QERR or b.kind == QERR:
        raise Error(String(ast.op_name(op)) + " is not defined on qerr values")
    return fit(spec.types, arith(op, a, b), spec.node_types[e])


# Comprehensions


def set_members(spec: Spec, iterable: Int) raises -> List[Value]:
    var t = spec.node_types[iterable]
    var elem = spec.types.info(t).args[0]
    var ctx = SetContext()
    var s = compile_set_aliased(
        ctx, spec.ast, spec.types, elem, iterable, Dict[String, BitSet](), spec.aliases
    )
    var bits = ctx.members(s, SET_LIMIT)
    var out = List[Value](capacity=len(bits))
    for b in bits:
        out.append(value_from_bits(spec.types, elem, b))
    return out^


def set_contains(spec: Spec, set_node: Int, x: Value) raises -> Bool:
    """Is the fixed-width value `x` a member of the partition set at `set_node`?"""
    var elem = spec.types.info(spec.node_types[set_node]).args[0]
    var ctx = SetContext()
    var s = compile_set_aliased(
        ctx, spec.ast, spec.types, elem, set_node, Dict[String, BitSet](), spec.aliases
    )
    return ctx.contains(s, bits_of_value(spec.types, elem, x))


def ev_comprehension[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var kind = n.op
    var iterable = n.kids[0]
    var body = n.kids[1]
    var what = String("the body of ", ast.op_name(kind), "(...)")
    var items: List[Value]
    if tkind(spec, iterable) == ty.SET:
        items = set_members(spec, iterable)
    else:
        items = elements(
            ev(spec, iterable, env, run, host), String(ast.op_name(kind), "(...)")
        )
    run.push(e, Value.none())
    var result: Value
    if kind == ast.ALL or kind == ast.EXISTS:
        var want = kind == ast.EXISTS
        var hit = False
        for i in range(len(items)):
            run.set_top(items[i].copy())
            if want_bool(ev(spec, body, env, run, host), what) == want:
                hit = True
                break
        result = Value.bool(hit if want else not hit)
    elif kind == ast.COUNT:
        var count = 0
        for i in range(len(items)):
            run.set_top(items[i].copy())
            if want_bool(ev(spec, body, env, run, host), what):
                count += 1
        result = Value.int(count)
    elif kind == ast.FILTER:
        var kept = List[Value]()
        for i in range(len(items)):
            run.set_top(items[i].copy())
            if want_bool(ev(spec, body, env, run, host), what):
                kept.append(items[i].copy())
        result = Value.list(kept^)
    elif kind == ast.MAP:
        var mapped = List[Value]()
        for i in range(len(items)):
            run.set_top(items[i].copy())
            mapped.append(ev(spec, body, env, run, host))
        result = Value.list(mapped^)
    elif kind == ast.SUM:
        var total = qerr_zero() if tkind(spec, e) == ty.QERR else Value.int(0)
        for i in range(len(items)):
            run.set_top(items[i].copy())
            total = add_term(total, ev(spec, body, env, run, host))
        result = total^
    else:
        var best = Optional[Value]()
        for i in range(len(items)):
            run.set_top(items[i].copy())
            var v = term_of(ev(spec, body, env, run, host))
            if best:
                best = larger(best.value(), v)
            else:
                best = v^
        if not best:
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
    ref kids = spec.ast.nodes[e].kids
    var vals = List[Value](capacity=len(params))
    var have = List[Bool](capacity=len(params))
    for _ in range(len(params)):
        vals.append(Value.none())
        have.append(False)
    var pos = 0
    for k in range(2, len(kids)):
        ref arg = spec.ast.nodes[kids[k]]
        var v = ev(spec, arg.kids[0], env, run, host)
        if arg.text == "":
            if pos >= len(params):
                raise Error(
                    what + " takes " + String(len(params)) + " argument(s), but more are given"
                )
            vals[pos] = v^
            have[pos] = True
            pos += 1
        else:
            var idx = -1
            for i in range(len(params)):
                if params[i].name == arg.text:
                    idx = i
            if idx < 0:
                raise Error(what + " has no parameter named " + arg.text)
            vals[idx] = v^
            have[idx] = True
    for i in range(len(params)):
        if not have[i]:
            if params[i].default == 0:
                raise Error(what + " needs argument " + params[i].name)
            var empty = Env()
            vals[i] = ev(spec, params[i].default, empty, run, host)
    return vals^


def coerce_args(
    spec: Spec, mut args: List[Value], params: List[Param], what: String
) raises:
    for i in range(len(params)):
        args[i] = coerce_arg(
            spec.types, args[i], params[i].type, "argument " + params[i].name + " of " + what
        )


def ev_call[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var found = spec.resolutions.get(e)
    if not found:
        found = spec.resolutions.get(n.kids[0])
    if not found:
        raise Error("this call cannot be evaluated: the checker did not resolve it")
    var r = found.value().copy()
    var kind = r.kind
    if kind == R_PRELUDE:
        return ev_prelude(spec, e, r.index, env, run, host)
    if kind == R_OLD:
        var at = env.old_index(e)
        if at < 0:
            raise Error(
                "old(...) has no snapshot of the state before the call (snapshot_olds"
                " must run before the call)"
            )
        if env.old_errors[at] != "":
            raise run.reraise(env.old_error_nodes[at], env.old_errors[at].copy(), env.old_skips[at])
        return env.old_values[at].copy()
    if kind == R_SPEC_FN:
        ref f = spec.fns[r.index]
        var args = bind_args(spec, e, f.params, f.name, env, run, host)
        coerce_args(spec, args, f.params, f.name)
        var out = host.call_fn(r.index, args^)
        if out.kind == ERROR:
            raise run.skip(
                e,
                String("the call of ", f.name, " raised ", out.name(), ": ", out.text()),
            )
        return fit(spec.types, out, spec.node_types[e])
    if kind == R_DEF:
        ref d = spec.defs[r.index]
        var args = bind_args(spec, e, d.params, d.name, env, run, host)
        var denv = Env(args^)
        denv.tvars = env.tvars.copy()
        denv.tvals = env.tvals.copy()
        return fit(spec.types, ev(spec, d.body, denv, run, host), spec.node_types[e])
    if kind == R_OBSERVER or kind == R_FIELD:
        ref obs = spec.models[r.owner].observers[r.index]
        var obj: Value
        if kind == R_FIELD:
            obj = self_of(env)
        else:
            var callee = n.kids[0]
            if spec.ast.nodes[callee].kind != ast.ATTR:
                raise Error("observer call " + r.name + " has no handle")
            obj = ev(spec, spec.ast.nodes[callee].kids[0], env, run, host)
        if obj.kind != HANDLE:
            raise Error("observer " + r.name + " needs a handle, but got " + show(obj))
        var args = bind_args(spec, e, obs.params, spec.models[r.owner].name + "." + r.name, env, run, host)
        coerce_args(spec, args, obs.params, spec.models[r.owner].name + "." + r.name)
        return host.observe(obj, r.owner, r.index, args^)
    if kind == R_EXTERN:
        var args = List[Value]()
        for k in range(2, len(n.kids)):
            args.append(ev(spec, spec.ast.nodes[n.kids[k]].kids[0], env, run, host))
        return host.call_extern(r.name, args^)
    if kind == R_SET_CTOR:
        raise Error(source_of(spec, n.kids[0]) + "(...) is a partition set")
    raise Error("a call of " + r.name + " cannot be evaluated")


def ev_prelude[
    H: EvalHost
](spec: Spec, e: Int, pid: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var args = List[Value]()
    var arg_types = List[Int]()
    var names = List[String]()
    var keywords = List[Value]()
    for k in range(2, len(n.kids)):
        ref arg = spec.ast.nodes[n.kids[k]]
        var v = ev(spec, arg.kids[0], env, run, host)
        if arg.text == "":
            args.append(v^)
            arg_types.append(spec.node_types[arg.kids[0]])
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
            for i in range(len(names)):
                if names[i] == "float":
                    float_mode = keywords[i].copy()
                elif names[i] == "order":
                    order = keywords[i].copy()
            return Value.bool(model_eq(spec, args[0], args[1], t, float_mode, order, host))
    var type_args = List[Int]()
    for tn in spec.ast.nodes[n.kids[1]].kids:
        type_args.append(type_arg(spec, tn, env))
    var out = api.call(
        pid,
        api.CallArgs(args^, names^, keywords^, type_args^, arg_types^),
        spec.types,
    )
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
    var m = spec.model_named(spec.types.info(t).name)
    if not m:
        raise Error("eq: no model " + spec.types.info(t).name)
    var mp = m.value()
    for o in range(len(spec.models[mp].observers)):
        ref obs = spec.models[mp].observers[o]
        if len(obs.params) > 0:
            continue
        var va = host.observe(a, mp, o, List[Value]())
        var vb = host.observe(b, mp, o, List[Value]())
        if not model_eq(spec, va, vb, obs.type, float_mode, order, host):
            return False
    return True
