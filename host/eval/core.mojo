"""The expression evaluator: checked expressions on `Value`s.

`value_of` evaluates one node against an `Env`. A failure raises an `Error` and is recorded
in the `Run`: the node it is attributed to, and whether it is a skip of the clause (a
planned call that raised in the library) rather than an error.
"""

from check import types as ty
from check.spec import Spec, Param
from value.fixed import int_max, int_min
from value.float_formats import format_by_id
from value.literal import is_integer_literal, parse_number
from partitions.compile import compiled_set
from prelude import api
from prelude.collections import EqMode, equal
from prelude.util import real_value
from sets import SetContext
from syntax.ast import Op
from value.equality import same
from value.value import Kind, Value

from .coerce import bits_of_value, coerce_arg, fit, value_from_bits
from .env import Env, Failure, Run
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


def type_kind(spec: Spec, node: Int) -> ty.TypeKind:
    return spec.types.infos[spec.node_types[node]].kind


def scalar_type_id(types: ty.Types, name: String) -> Optional[Int]:
    """The interned scalar type `name` denotes (`bool`, `i32`, `f64`, ...), if any."""
    for t, info in enumerate(types.infos):
        var scalar = info.kind in [
            ty.TypeKind.BOOL,
            ty.TypeKind.INT,
            ty.TypeKind.REAL,
            ty.TypeKind.STRING,
            ty.TypeKind.BYTES,
            ty.TypeKind.FIXED_INT,
            ty.TypeKind.FLOAT,
        ]
        if scalar and types.text(t) == name:
            return t
    return None


def type_arg(spec: Spec, node: Int, env: Env) raises -> Int:
    """The type a type argument names: a bound type parameter, a scalar or an alias."""
    ref name = spec.ast.nodes[node].text
    if case .Some(t) = env.types.get(name):
        return t
    if case .Some(t) = scalar_type_id(spec.types, name):
        return t
    if case .Some(t) = spec.aliases.get(name):
        return t
    raise Error(t"cannot resolve the type argument {name}")


def self_of(env: Env) raises -> Value:
    if case .Some(value) = env.self_value:
        return value.copy()
    if env.params:
        return env.params[0].copy()
    raise Error("no value for self")


def want_bool(v: Value, what: String) raises -> Bool:
    if v.kind != .BOOL:
        raise Error(t"{what} must be a bool, but it is {show(v)}")
    return v.as_bool()


def is_sequence(v: Value) -> Bool:
    return v.kind in [Kind.LIST, Kind.STRING, Kind.BYTES, Kind.ENUM]


def is_old_call(spec: Spec, e: Int) -> Bool:
    if spec.ast.nodes[e].kind != .CALL:
        return False
    var r = spec.resolution(e)
    return r is not None and r.value().kind == .OLD


def value_of[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    """The value of node `e`, with a failure recorded in `run` at the innermost node that raised."""
    try:
        return _value(spec, e, env, run, host)
    except err:
        if run.failure is None:
            run.failure = Failure(String(err), e, skipped=False)
        raise err^


def _small_literal(text: String) -> Optional[Int]:
    """A decimal literal of at most 18 digits, which an Int holds."""
    if text.byte_length() > 18 or not text.is_ascii_digit():
        return None
    try:
        return Int(text)
    except:
        return None


def _value[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    match n.kind:
        case .NAME:
            return _name_value(spec, e, env, run, host)
        case .BINARY:
            return _binary_value(spec, e, env, run, host)
        case .CALL:
            return _call_value(spec, e, env, run, host)
        case .ATTR:
            return _attr_value(spec, e, env, run, host)
        case .NUM:
            if case .Some(small) = _small_literal(n.text):
                return Value.int(small)
            var r = parse_number(n.text)
            return Value.int(r.numerator.copy()) if is_integer_literal(n.text) else real_value(r)
        case .STR:
            return Value.string(n.text.copy())
        case .BOOL:
            return Value.bool(n.op == .TRUE)
        case .NONE:
            return Value.none()
        case .UNARY:
            var operand = value_of(spec, n.children[0], env, run, host)
            if n.op == .NOT:
                return Value.bool(not want_bool(operand, "the operand of not"))
            return fit(spec.types, negate(operand), spec.node_types[e])
        case .IF:
            var condition = want_bool(value_of(spec, n.children[0], env, run, host), "the condition of if")
            var branch = n.children[1] if condition else n.children[2]
            return fit(spec.types, value_of(spec, branch, env, run, host), spec.node_types[e])
        case .LET:
            run.push(e, value_of(spec, n.children[0], env, run, host))
            var body = value_of(spec, n.children[1], env, run, host)
            run.pop()
            return body^
        case .COMPREHENSION:
            return _comprehension_value(spec, e, env, run, host)
        case .INDEX:
            var v = value_of(spec, n.children[0], env, run, host)
            var i = value_of(spec, n.children[1], env, run, host)
            if v.kind == .MAP:
                return map_lookup(v, i)
            if not is_sequence(v):
                raise Error(t"cannot index {show(v)}")
            return index_value(v, i)
        case .SLICE:
            var v = value_of(spec, n.children[0], env, run, host)
            var lo = value_of(spec, n.children[1], env, run, host)
            var hi = value_of(spec, n.children[2], env, run, host)
            if not is_sequence(v):
                raise Error(t"cannot slice {show(v)}")
            return slice_value(v, lo, hi)
        case .TUPLE_INDEX:
            var v = value_of(spec, n.children[0], env, run, host)
            if v.kind not in [Kind.TUPLE, Kind.LIST]:
                raise Error(t".{n.text} needs a tuple, but the value is {show(v)}")
            var index = Int(n.text)
            if not 0 <= index < v.count():
                raise Error(t".{n.text} is out of range for a tuple of {v.count()} elements")
            return v.item(index)
        case .LIST:
            var items = [value_of(spec, child, env, run, host) for child in n.children]
            return fit(spec.types, Value.list(items^), spec.node_types[e])
        case .TUPLE:
            return Value.tuple([value_of(spec, child, env, run, host) for child in n.children])
        case .SET:
            raise Error("{...} is a partition set: it has no value in a clause")
        case _:
            raise Error(t"cannot evaluate a {n.kind} node")


def map_lookup(m: Value, key: Value) raises -> Value:
    for entry_key, value in m.pairs():
        if values_equal(key, entry_key):
            return value.copy()
    raise Error(t"key {show(key)} is not in the map")


# Names


def _name_value[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref name = spec.ast.nodes[e].text
    var found = spec.resolution(e)
    if found is None:
        raise Error(t"{name} has no value: the checker did not resolve it")
    ref r = found.value()
    match r.kind:
        case .PARAM:
            if r.index >= len(env.params):
                raise Error(t"no value for the parameter {name}")
            return env.params[r.index].copy()
        case .RESULT:
            if case .Some(result) = env.result:
                return result.copy()
            raise Error("no value for the result")
        case .SELF:
            return self_of(env)
        case .LOCAL:
            var local = run.innermost(r.index)
            if local is None:
                raise Error(t"no value for the local {name}")
            return local.take()
        case .FIELD:
            return host.observe(self_of(env), r.owner, r.index, [])
        case .ENUM_MEMBER:
            return enum_member(spec, enum_type=r.owner, index=r.index)
        case .CLASS:
            var expr = spec.ast.child(r.index, 0)
            if type_kind(spec, expr) == .BOOL:
                return value_of(spec, expr, env, run, host)
            raise Error(t"class {name} is a partition set: it has no value in a clause")
        case .CONST:
            return host.constant(r.index)
        case _:
            raise Error(t"{name} cannot be evaluated as a value")


def enum_member(spec: Spec, *, enum_type: Int, index: Int) -> Value:
    ref info = spec.types.infos[enum_type]
    return Value.enum(info.name.copy(), info.names[index].copy())


def _attr_value[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var found = spec.resolution(e)
    if found is None:
        raise Error(t".{n.text} cannot be evaluated: the checker did not resolve it")
    ref r = found.value()
    match r.kind:
        case .ENUM_MEMBER:
            return enum_member(spec, enum_type=r.owner, index=r.index)
        case .CONST:
            return host.constant(r.index)
        case .TYPE_CONST:
            if type_kind(spec, e) == .SET:
                raise Error(t"{spec.ast.source_text(e)} is a partition set: it has no value in a clause")
            ref scalar = spec.types.infos[r.index]
            if scalar.kind == .FIXED_INT:
                var low = r.name == "min"
                return Value.int(int_min(scalar.bits, scalar.signed) if low else int_max(scalar.bits, scalar.signed))
            var f = format_by_id(UInt8(scalar.bits))
            var top = f.max_finite()
            return Value.float(f, top if r.name == "max" else top | f.sign_mask())
        case .OBSERVER:
            var obj = value_of(spec, n.children[0], env, run, host)
            if obj.kind != .HANDLE:
                raise Error(t"observer {n.text} needs a handle, but got {show(obj)}")
            return host.observe(obj, r.owner, r.index, [])
        case .RECORD_FIELD:
            var record = value_of(spec, n.children[0], env, run, host)
            if record.kind != .RECORD:
                raise Error(t".{n.text} needs a record, but got {show(record)}")
            if case .Some(field) = record.field(n.text):
                return field.copy()
            raise Error(t"record {record.name()} has no field {n.text}")
        case .QERR_PART:
            var q = value_of(spec, n.children[0], env, run, host)
            if q.kind != .QERR:
                raise Error(t".{n.text} needs a qerr, but got {show(q)}")
            return q.item(0 if n.text == "steps" else 1)
        case .SET_CTOR:
            raise Error(t"{spec.ast.source_text(e)} is a partition set constructor")
        case _:
            raise Error(t".{n.text} cannot be evaluated")


# Operators


def _binary_value[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var op = n.op
    if op in [Op.IMPLIES, Op.AND, Op.OR]:
        var left = want_bool(value_of(spec, n.children[0], env, run, host), String(t"the left operand of {op}"))
        # `true or`, `false and` and `false implies` are decided without the right operand.
        if left == (op == .OR):
            return Value.bool(op != .AND)
        return Value.bool(want_bool(value_of(spec, n.children[1], env, run, host), String(t"the right operand of {op}")))
    if type_kind(spec, e) == .SET:
        raise Error(t"{op} combines partition sets: it has no value in a clause")
    if op == .IN and type_kind(spec, n.children[1]) == .SET:
        return Value.bool(set_contains(spec, n.children[1], value_of(spec, n.children[0], env, run, host)))
    var a = value_of(spec, n.children[0], env, run, host)
    var b = value_of(spec, n.children[1], env, run, host)
    var has_qerr = a.kind == .QERR or b.kind == .QERR
    match op:
        case .EQ | .NE:
            var is_equal: Bool
            if has_qerr:
                is_equal = qerr_compare(Op.EQ, a, b)
            elif type_kind(spec, n.children[0]) == .CHOICE or type_kind(spec, n.children[1]) == .CHOICE:
                is_equal = same(a, b)
            else:
                is_equal = values_equal(a, b)
            return Value.bool(is_equal if op == .EQ else not is_equal)
        case .LT | .LE | .GT | .GE:
            return Value.bool(qerr_compare(op, a, b) if has_qerr else holds_order(op, compare_values(a, b)))
        case .IN:
            return Value.bool(contains(b, a))
        case .ADD:
            if has_qerr:
                if a.kind == .QERR and b.kind == .QERR:
                    return qerr_add(a, b)
                raise Error(t"+ adds two qerr values, not {show(a)} and {show(b)}")
            if case .Some(joined) = concat(a, b):
                return joined.copy()
        case _:
            if has_qerr:
                raise Error(t"{op} is not defined on qerr values")
    return fit(spec.types, arith(op, a, b), spec.node_types[e])


# Comprehensions


def set_members(spec: Spec, iterable: Int) raises -> List[Value]:
    var ctx = SetContext()
    var elem, s = compiled_set(ctx, spec, iterable)
    return [value_from_bits(spec.types, elem, bits) for bits in ctx.members(s, SET_LIMIT)]


def set_contains(spec: Spec, set_node: Int, x: Value) raises -> Bool:
    """Is the fixed-width value `x` a member of the partition set at `set_node`?"""
    var ctx = SetContext()
    var elem, s = compiled_set(ctx, spec, set_node)
    return ctx.contains(s, bits_of_value(spec.types, elem, x))


def _body_at[
    H: EvalHost
](spec: Spec, body: Int, item: Value, env: Env, mut run: Run, mut host: H) raises -> Value:
    """The body of a comprehension with its variable bound to `item`."""
    run.set_top(item.copy())
    return value_of(spec, body, env, run, host)


def _comprehension_value[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var kind = n.op
    var iterable = n.children[0]
    var body = n.children[1]
    var what = String(t"the body of {kind}(...)")
    var items: List[Value]
    if type_kind(spec, iterable) == .SET:
        items = set_members(spec, iterable)
    else:
        items = elements(value_of(spec, iterable, env, run, host), String(t"{kind}(...)"))
    run.push(e, Value.none())
    var result: Value
    match kind:
        case .ALL | .EXISTS:
            # all stops at the first false body, exists at the first true one.
            var want = kind == .EXISTS
            var found = False
            for item in items:
                if want_bool(_body_at(spec, body, item, env, run, host), what) == want:
                    found = True
                    break
            result = Value.bool(found == want)
        case .COUNT:
            var count = 0
            for item in items:
                if want_bool(_body_at(spec, body, item, env, run, host), what):
                    count += 1
            result = Value.int(count)
        case .FILTER:
            result = Value.list(
                [item.copy() for item in items if want_bool(_body_at(spec, body, item, env, run, host), what)]
            )
        case .MAP:
            result = Value.list([_body_at(spec, body, item, env, run, host) for item in items])
        case .SUM:
            var total = qerr_zero() if type_kind(spec, e) == .QERR else Value.int(0)
            for item in items:
                total = add_term(total, _body_at(spec, body, item, env, run, host))
            result = total^
        case _:
            var best: Optional[Value] = None
            for item in items:
                var term = term_of(_body_at(spec, body, item, env, run, host))
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
    var names = [param.name.copy() for param in params]
    var bound = List[Optional[Value]](length=len(params), fill=None)
    var next_position = 0
    for child in spec.ast.nodes[e].children[2:]:
        ref arg = spec.ast.nodes[child]
        var value = value_of(spec, arg.children[0], env, run, host)
        var at: Int
        if not arg.text:
            if next_position >= len(params):
                raise Error(t"{what} takes {len(params)} argument(s), but more are given")
            at = next_position
            next_position += 1
        else:
            var named = names.try_index(arg.text)
            if named is None:
                raise Error(t"{what} has no parameter named {arg.text}")
            at = named.value()
        bound[at] = value^
    var args: List[Value] = []
    for param, value in zip(params, bound):
        if value is not None:
            args.append(value.value().copy())
        elif param.default == 0:
            raise Error(t"{what} needs argument {param.name}")
        else:
            args.append(value_of(spec, param.default, Env(), run, host))
    return args^


def coerced(spec: Spec, args: List[Value], params: List[Param], what: String) raises -> List[Value]:
    """The arguments of a call made exact for the types of their parameters."""
    return [
        coerce_arg(spec.types, arg, param.type, String(t"argument {param.name} of {what}"))
        for arg, param in zip(args, params)
    ]


def _call_value[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var found = spec.resolution(e)
    if found is None:
        found = spec.resolution(n.children[0])
    if found is None:
        raise Error("this call cannot be evaluated: the checker did not resolve it")
    ref r = found.value()
    match r.kind:
        case .PRELUDE:
            return _prelude_value(spec, e, r.index, env, run, host)
        case .OLD:
            if e not in env.olds:
                raise Error(
                    "old(...) has no snapshot of the state before the call (snapshot_olds must run before the call)"
                )
            ref old = env.olds[e]
            if case .Some(failure) = old.failure:
                raise run.reraise(failure)
            return old.value.copy()
        case .SPEC_FN:
            ref f = spec.fns[r.index]
            var args = coerced(spec, bind_args(spec, e, f.params, f.name, env, run, host), f.params, f.name)
            var out = host.call_fn(r.index, args)
            if out.kind == .ERROR:
                raise run.skip(e, String(t"the call of {f.name} raised {out.error_text()}"))
            return fit(spec.types, out, spec.node_types[e])
        case .DEF:
            ref d = spec.defs[r.index]
            var def_env = Env(bind_args(spec, e, d.params, d.name, env, run, host))
            def_env.types = env.types.copy()
            return fit(spec.types, value_of(spec, d.body, def_env, run, host), spec.node_types[e])
        case .OBSERVER | .FIELD:
            ref observer = spec.models[r.owner].observers[r.index]
            var obj: Value
            if r.kind == .FIELD:
                obj = self_of(env)
            else:
                var callee = n.children[0]
                if spec.ast.nodes[callee].kind != .ATTR:
                    raise Error(t"observer call {r.name} has no handle")
                obj = value_of(spec, spec.ast.child(callee, 0), env, run, host)
            if obj.kind != .HANDLE:
                raise Error(t"observer {r.name} needs a handle, but got {show(obj)}")
            var what = String(t"{spec.models[r.owner].name}.{r.name}")
            var args = coerced(spec, bind_args(spec, e, observer.params, what, env, run, host), observer.params, what)
            return host.observe(obj, r.owner, r.index, args)
        case .EXTERN:
            var args = [value_of(spec, spec.ast.child(child, 0), env, run, host) for child in n.children[2:]]
            return host.call_extern(r.name, args)
        case .SET_CTOR:
            raise Error(t"{spec.ast.source_text(n.children[0])}(...) is a partition set")
        case _:
            raise Error(t"a call of {r.name} cannot be evaluated")


def _prelude_value[
    H: EvalHost
](spec: Spec, e: Int, id: Int, env: Env, mut run: Run, mut host: H) raises -> Value:
    ref n = spec.ast.nodes[e]
    var args = api.CallArgs([])
    for child in n.children[2:]:
        ref arg = spec.ast.nodes[child]
        var value = value_of(spec, arg.children[0], env, run, host)
        if arg.text:
            args.keywords.append(api.Keyword(arg.text.copy(), value^))
        else:
            args.args.append(value^)
    match id:
        case api.FRESH:
            return Value.bool(host.fresh(args.args[0]))
        case api.SAME_OBJECT:
            return Value.bool(host.same_object(args.args[0], args.args[1]))
        case api.SHARES_MEMORY:
            return Value.bool(host.shares_memory(args.args[0], args.args[1]))
        case api.EQ if len(args.args) == 2:
            var t = spec.node_types[_positional(spec, e)[0]]
            if _holds_handles(spec.types, t):
                return Value.bool(model_eq(spec, args.args[0], args.args[1], t, api.eq_mode(args.keywords), host))
        case _:
            pass
    args.type_args = [type_arg(spec, child, env) for child in spec.ast.nodes[n.children[1]].children]
    return fit(spec.types, api.call(id, args, spec.types), spec.node_types[e])


def _positional(spec: Spec, call: Int) -> List[Int]:
    """The expressions of a call's positional arguments."""
    return [spec.ast.child(arg, 0) for arg in spec.ast.nodes[call].children[2:] if not spec.ast.nodes[arg].text]


def _holds_handles(types: ty.Types, t: Int) -> Bool:
    """A model, or a list of models: `eq` compares such values through their observers."""
    var k = types.kind(t)
    return k == .MODEL or (k == .LIST and types.kind(types.info(t).args[0]) == .MODEL)


def model_eq[
    H: EvalHost
](
    spec: Spec,
    a: Value,
    b: Value,
    t: Int,
    mode: EqMode,
    mut host: H,
) raises -> Bool:
    """`eq` of two values holding model handles: handles compare through their
    zero-argument observers, read with the host."""
    var k = spec.types.kind(t)
    if k == .LIST:
        if a.count() != b.count():
            return False
        for x, y in zip(a.items(), b.items()):
            if not model_eq(spec, x, y, spec.types.info(t).args[0], mode, host):
                return False
        return True
    if k != .MODEL:
        return equal(a, b, mode)
    var found = spec.model_named(spec.types.info(t).name)
    if found is None:
        raise Error(t"eq: no model {spec.types.info(t).name}")
    var model = found.value()
    for o, observer in enumerate(spec.models[model].observers):
        if observer.params:
            continue
        var va = host.observe(a, model, o, [])
        var vb = host.observe(b, model, o, [])
        if not model_eq(spec, va, vb, observer.type, mode, host):
            return False
    return True
