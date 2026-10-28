"""Typing of expressions: names, operators, calls, comprehensions, literals.

`infer` types one expression node in the clause context `Checker.ctx`, records its
type and, for names, attributes and calls that refer to something, its resolution.
Errors go to the checker's diagnostics; an expression that already has an error gets
the poison type, which silences follow-on errors.
"""

from value.literal import is_integer_literal
from value.real import Real

from check.psig import Arg, CallInfo, TypingError
from check.sigs import prelude_type
from check.spec import Param, ResolutionKind
from check.state import Checker, Ctx, NO_TYPE, Var, classifier_hint, is_reserved, last_index_of
from check.types import ANY_TYPE, Types
from check.typesyn import ensure_const, resolve_type

comptime _NAMESPACE_FUNCTIONS: Array[StaticString, 7] = ["sqrt", "exp", "log", "sin", "cos", "tan", "atan"]
"""The functions of `mp` and `cr`, as messages list them."""


# -- small helpers --------------------------------------------------------------


def poison_subtree(mut c: Checker, e: Int):
    for n in c.spec.ast.subtree(e):
        if c.spec.node_types[n] == ANY_TYPE:
            c.spec.node_types[n] = c.poison


def want_bool(mut c: Checker, node: Int, t: Int, what: Some[Writable]):
    var k = c.tkind(t)
    if k != .BOOL and k != .ANY:
        c.error(node, t"{what} must be a bool, but this is {c.text(t)}")


def want_int(mut c: Checker, node: Int, t: Int, what: StaticString):
    if not c.is_integer(t) and not c.is_any(t):
        var hint = " (use // for integer division)" if c.tkind(t) == .REAL else ""
        c.error(node, t"{what} must be an integer, but it is {c.text(t)}{hint}")


def binds_value(c: Checker, name: String) -> Bool:
    """Is name a local, a partition class or a parameter here?"""
    if c.ctx.local_index(name) >= 0 or c.ctx.class_index(name) >= 0:
        return True
    return c.ctx.param_index(name) >= 0 and not c.ctx.in_partition_set


def _root_name(c: Checker, e: Int) -> String:
    var n = e
    while c.kind_of(n) == .ATTR:
        n = c.child(n, 0)
    return c.text_of(n) if c.kind_of(n) == .NAME else String()


def dotted(c: Checker, e: Int) -> String:
    """`a.b.c` for a chain of names and attributes, or "" for anything else."""
    match c.kind_of(e):
        case .NAME:
            return c.text_of(e)
        case .ATTR:
            var inner = dotted(c, c.child(e, 0))
            return String(t"{inner}.{c.text_of(e)}") if inner else String()
        case _:
            return String()


def chain_candidate(c: Checker, e: Int) -> String:
    """The dotted name of a chain whose root is not a bound or reserved name, else ""."""
    var root = _root_name(c, e)
    if root == "" or root == "self" or root == "result" or root == "old":
        return String()
    if binds_value(c, root) or root in c.ctx.hidden:
        return String()
    # A bare observer shadows nothing qualified, but keep fields first.
    if c.ctx.fields_of >= 0 and c.observer_pos(c.ctx.fields_of, root) >= 0:
        return String()
    return dotted(c, e)


def assignable(c: Checker, actual: Int, target: Int, node: Int) -> Bool:
    """May a value of type actual be passed where target is expected? Fixed-width
    numeric targets accept any number: representability is checked at the call."""
    if c.is_any(actual) or c.is_any(target) or actual == target:
        return True
    var kt = c.tkind(target)
    var ka = c.tkind(actual)
    match kt:
        case .FIXED_INT:
            return c.is_integer(actual) or ka == .REAL
        case .FLOAT | .REAL:
            return c.is_numeric(actual)
        case .INT:
            return c.is_integer(actual)
        case .LITERAL | .CHOICE:
            ref names = c.spec.types.infos[target].names
            if ka == kt:
                return all([v in names for v in c.spec.types.infos[actual].names])
            if kt == .LITERAL:
                return node > 0 and c.kind_of(node) == .STR and c.text_of(node) in names
            return node > 0 and _choice_has(c, target, node)
        case .STRING:
            return c.is_stringish(actual)
        case .LIST if ka == .LIST:
            if node > 0 and c.kind_of(node) == .LIST and c.children(node):
                return all([assignable(c, c.spec.node_types[x], c.arg(target, 0), x) for x in c.children(node)])
            return assignable(c, c.arg(actual, 0), c.arg(target, 0), 0)
        case .OPTION if ka == .OPTION:
            return assignable(c, c.arg(actual, 0), c.arg(target, 0), 0)
        case .MAP if ka == .MAP:
            return assignable(c, c.arg(actual, 0), c.arg(target, 0), 0) and assignable(
                c, c.arg(actual, 1), c.arg(target, 1), 0
            )
        case .TUPLE if ka == .TUPLE:
            ref ts = c.spec.types.infos[target].args
            ref xs = c.spec.types.infos[actual].args
            if len(ts) != len(xs):
                return False
            var written = node > 0 and c.kind_of(node) == .TUPLE and len(c.children(node)) == len(ts)
            var elems = c.children(node) if written else List[Int](length=len(ts), fill=0)
            return all([assignable(c, x, t, n) for x, t, n in zip(xs, ts, elems)])
        case _:
            return False


# -- entry point ----------------------------------------------------------------


def infer(mut c: Checker, e: Int, expected: Int = NO_TYPE) -> Int:
    var t: Int
    match c.kind_of(e):
        case .NAME:
            t = lookup(c, e)
        case .BINARY:
            t = infer_binary(c, e, expected)
        case .CALL:
            t = infer_call(c, e)
        case .ATTR:
            t = infer_attr(c, e)
        case .NUM:
            t = c.int_ if is_integer_literal(c.spec.ast.nodes[e].text) else c.real_
        case .STR:
            t = c.string_
        case .BOOL:
            t = c.bool_
        case .NONE:
            t = c.spec.types.option_of(ANY_TYPE)
        case .UNARY:
            t = infer_unary(c, e)
        case .IF:
            t = infer_if(c, e, expected)
        case .LET:
            t = infer_let(c, e, expected)
        case .COMPREHENSION:
            t = infer_comprehension(c, e)
        case .TUPLE_INDEX:
            t = infer_tuple_index(c, e)
        case .INDEX:
            t = infer_index(c, e)
        case .SLICE:
            t = infer_slice(c, e)
        case .LIST:
            t = infer_list(c, e)
        case .TUPLE:
            var elems = [infer(c, x) for x in c.children(e)]
            t = c.spec.types.tuple_of(elems)
        case .SET:
            t = infer_set(c, e, expected)
        case _:
            t = c.poison
    c.set_type(e, t)
    return t


def infer_in(mut c: Checker, var ctx: Ctx, e: Int, expected: Int = NO_TYPE) -> Int:
    """The type of `e` checked in `ctx`, leaving the current context as it was."""
    swap(ctx, c.ctx)
    var t = infer(c, e, expected)
    swap(ctx, c.ctx)
    return t


# -- names ----------------------------------------------------------------------


def _old_local_message(c: Checker, name: String, binder: Int) -> String:
    var how = String(t"{c.op_of(binder)}(...)") if c.kind_of(binder) == .COMPREHENSION else String("let")
    return String(
        t"old(...) is evaluated before the call, so it cannot use {name}, which {how} binds inside this "
        t"clause: bind old(...) of the state first, e.g. let xs = old(self.items) in "
        t"all(i in range(0, len(xs)): xs[i] == self.items[i])"
    )


def _takes_arguments(c: Checker, name: String, model: Int, observer: Int) -> String:
    var params = ", ".join([p.name.copy() for p in c.spec.models[model].observers[observer].params])
    return String(t"{name} takes arguments: {name}({params})")


def _no_observer(c: Checker, model: Int, name: String) -> String:
    return String(t"{c.spec.models[model].name} has no observer {name} (its observers: {c.observer_names(model)})")


def lookup(mut c: Checker, e: Int) -> Int:
    """The type of a bare name, recording its resolution; poison after an error."""
    var name = c.text_of(e)
    var li = c.ctx.local_index(name)
    if li >= 0:
        var binder = c.ctx.locals[li].node
        if c.ctx.in_old and c.ctx.allow_old and li < c.ctx.old_scope:
            c.error(e, _old_local_message(c, name, binder))
            return c.poison
        c.resolve(e, .LOCAL, name, index=binder)
        return c.ctx.locals[li].type
    if case .Some(why) = c.ctx.hidden.get(name):
        c.error(e, why)
        return c.poison
    var ci = c.ctx.class_index(name)
    if ci >= 0:
        c.resolve(e, .CLASS, name, index=c.ctx.classes[ci].node)
        return c.ctx.classes[ci].type
    var pi = c.ctx.param_index(name)
    if pi >= 0:
        var ptype = c.ctx.params[pi].type
        var only = c.ctx.only_param.copy()
        if c.ctx.in_partition_set:
            var pt = c.text(ptype)
            var set_name = "nan" if c.tkind(ptype) == .FLOAT else "all"
            c.error(
                e,
                t"classes of the fixed-width parameter {only} are sets of values, so {name} cannot appear in "
                t"them: build them from {pt}.{set_name}, {pt}.range(a, b), {{v, ...}} and earlier classes",
            )
            return c.poison
        if only != "" and name != only:
            c.error(e, t"a class of partition {only} may only refer to {only}, not to {name}")
            return c.poison
        c.resolve(e, .PARAM, name, index=pi)
        return ptype
    if name == "result":
        if c.ctx.in_old:
            c.error(e, "result does not exist before the call, so old(...) cannot use it")
            return c.poison
        if c.ctx.result < 0:
            c.error(e, c.ctx.no_result.copy())
            return c.poison
        c.resolve(e, .RESULT, "result")
        return c.ctx.result
    if name == "self":
        if c.ctx.self_t < 0:
            c.error(e, c.ctx.no_self.copy())
            return c.poison
        c.resolve(e, .SELF, "self", owner=c.ctx.self_model)
        return c.ctx.self_t
    var m = c.ctx.fields_of
    var oi = c.observer_pos(m, name) if m >= 0 else -1
    if oi >= 0:
        if c.spec.models[m].observers[oi].params:
            c.error(e, _takes_arguments(c, name, m, oi))
            return c.poison
        c.resolve(e, .FIELD, name, index=oi, owner=m)
        return c.spec.models[m].observers[oi].type
    var owners = [en for en in c.spec.enums if name in c.spec.types.infos[en].names]
    if len(owners) == 1:
        var member = c.spec.types.infos[owners[0]].names.try_index(name).value()
        c.resolve(e, .ENUM_MEMBER, name, index=member, owner=owners[0])
        return owners[0]
    if owners:
        var listed = ", ".join([c.text(en) for en in owners])
        c.error(e, t"{name} is a member of several enums ({listed}): write {c.text(owners[0])}.{name}")
        return c.poison
    unknown_name(c, e, name)
    return c.poison


def _namespace_what(ns: String) -> String:
    if ns == "mp":
        return "the reference functions, which return reals"
    return "the correctly rounded functions, which return floats"


def _namespace_members(ns: String) -> String:
    return ", ".join([String(t"{ns}.{f}") for f in materialize[_NAMESPACE_FUNCTIONS]()])


def _namespace_hints(c: Checker, name: String) -> List[String]:
    """`mp.name` and `cr.name`, those that are prelude functions."""
    var qualified = [String(t"mp.{name}"), String(t"cr.{name}")]
    return [q.copy() for q in qualified if q in c.prelude_ids]


def _did_you_mean(options: List[String]) -> String:
    var listed = " or ".join(options)
    return String(t" (did you mean {listed}?)") if options else String()


def unknown_name(mut c: Checker, e: Int, name: String):
    var msg: String
    if name == "old":
        msg = "old is called as old(e)"
    elif name in c.fn_index:
        msg = String(
            t"{name} is a spec function: call it as {name}(...), in an ensures, relates, invariant or aggregate clause"
        )
    elif name in c.def_index:
        msg = String(t"{name} is a definition: call it as {name}(...)")
    elif name in c.prelude_ids:
        msg = String(t"{name} is a function: call it as {name}(...)")
    elif name == "mp" or name == "cr":
        msg = String(t"{name} is the namespace of {_namespace_what(name)}, e.g. {name}.cos(x)")
    elif c.scalar(name) >= 0 or name in c.model_index:
        msg = String(t"{name} is a type, not a value")
    else:
        var hints: List[String] = []
        if c.ctx.self_t >= 0 and c.ctx.self_model >= 0 and c.observer_pos(c.ctx.self_model, name) >= 0:
            hints.append(String(t"self.{name}"))
        for p in c.ctx.params:
            if c.tkind(p.type) == .MODEL and p.name != "":
                var model = c.model_pos_of_type(p.type)
                if model >= 0 and c.observer_pos(model, name) >= 0:
                    hints.append(String(t"{p.name}.{name}"))
        hints.extend(_namespace_hints(c, name))
        msg = String(t"unknown name {name}{_did_you_mean(hints)}")
    c.error(e, msg)


# -- operators ------------------------------------------------------------------


def infer_unary(mut c: Checker, e: Int) -> Int:
    var operand = c.child(e, 0)
    var t = infer(c, operand)
    if c.op_of(e) == .NOT:
        want_bool(c, operand, t, "the operand of not")
        return c.bool_
    if c.is_any(t) or c.tkind(t) == .FLOAT:
        return t
    if c.is_integer(t):
        return c.int_
    if c.tkind(t) == .REAL:
        return c.real_
    c.error(e, t"unary - needs a number, but the operand is {c.text(t)}")
    return c.poison


def infer_binary(mut c: Checker, e: Int, expected: Int) -> Int:
    var op = c.op_of(e)
    var left = c.child(e, 0)
    var right = c.child(e, 1)
    var side = expected if expected >= 0 and c.tkind(expected) == .SET else NO_TYPE
    var lt = infer(c, left, side)
    var rt = infer(c, right, side)
    match op:
        case .AND | .OR | .IMPLIES:
            want_bool(c, left, lt, t"the left operand of {op}")
            want_bool(c, right, rt, t"the right operand of {op}")
            return c.bool_
        case .BITOR | .BITAND:
            return c.int_ if c.is_integer(lt) and c.is_integer(rt) else set_op(c, e, lt, rt)
        case .SUB if c.tkind(lt) == .SET or c.tkind(rt) == .SET:
            return set_op(c, e, lt, rt)
        case .EQ | .NE:
            return equality(c, e, lt, rt)
        case .LT | .LE | .GT | .GE:
            return ordering(c, e, lt, rt)
        case .IN:
            return membership(c, e, lt, rt)
        case .SHL | .SHR | .POW:
            return integer_op(c, e, lt, rt)
        case _:
            return arith(c, e, lt, rt)


def integer_op(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_poison(lt) or c.is_poison(rt):
        return c.poison
    var op = c.op_of(e)
    if (c.is_integer(lt) or c.is_any(lt)) and (c.is_integer(rt) or c.is_any(rt)):
        if op == .POW:
            var exponent = c.literal_value(c.child(e, 1))
            if exponent is not None and exponent.value() < Real(0):
                c.error(e, "** needs a non-negative exponent: a negative power is not an integer")
                return c.poison
        return c.int_
    c.error(e, t"{op} takes integers, but got {c.text(lt)} and {c.text(rt)}")
    return c.poison


def set_op(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_poison(lt) or c.is_poison(rt):
        return c.poison
    var op = c.op_of(e)
    if c.tkind(lt) != .SET or c.tkind(rt) != .SET:
        var bitwise = op == .BITOR or op == .BITAND
        if bitwise and c.tkind(lt) == .BOOL and c.tkind(rt) == .BOOL:
            var word = "or" if op == .BITOR else "and"
            c.error(e, t"{op} combines partition sets or integers; for booleans write {word}")
        elif bitwise:
            c.error(e, t"{op} needs two integers or two partition sets, but got {c.text(lt)} and {c.text(rt)}")
        else:
            c.error(e, t"{op} on partition sets needs a set on both sides, but got {c.text(lt)} and {c.text(rt)}")
        return c.poison
    if c.arg(lt, 0) != c.arg(rt, 0):
        c.error(e, t"cannot combine a set of {c.text(c.arg(lt, 0))} with a set of {c.text(c.arg(rt, 0))}")
        return c.poison
    return lt


def eq_message(c: Checker, op: String, t: Int, bad: Int) -> String:
    var inside = String() if t == bad else String(t" (inside {c.text(t)})")
    var what = c.text(bad)
    match c.tkind(bad):
        case .FLOAT:
            return String(
                t"{op} is not defined on {what}{inside}: floats have no implicit equality. Use same(a, b) for "
                t"bit-identical values, ieee_eq(a, b) for IEEE 754 equality, real(a) {op} real(b) to compare "
                t"numerically, or eq(a, b, float=...) for collections"
            )
        case .MODEL:
            return String(
                t"{op} is not defined on {what} handles{inside}: compare their observers (a.items == b.items) "
                t"or use eq(a, b, ...)"
            )
        case .TYPEVAR:
            return String(t"{op} needs equality on {what}{inside}: declare it as {c.spec.types.infos[bad].name}: Eq")
        case .SET:
            return String(t"{op} is not defined on partition sets")
        case _:
            return String(t"{op} is not defined on {what}{inside}")


def qerr_comparison(mut c: Checker, e: Int, lt: Int, rt: Int) -> Bool:
    """Check a comparison with a qerr operand; False when neither side is a qerr."""
    var lq = c.tkind(lt) == .QERR
    var rq = c.tkind(rt) == .QERR
    if not lq and not rq:
        return False
    var other = rt if lq else lt
    var ok = c.tkind(other) == .QERR or c.is_any(other) or (c.is_numeric(other) and c.tkind(other) != .FLOAT)
    if not ok:
        c.error(
            e,
            t"{c.op_of(e)} compares a qerr with a qerr or a number (an int or real, read "
            t"as c + 0·nan), but the other side is {c.text(other)}",
        )
    return True


def _choice_has(c: Checker, choice: Int, node: Int) -> Bool:
    """Whether `node` names one of the constants of a choice type."""
    var r = c.spec.resolutions.get(node)
    return (
        r is not None
        and r.value().kind == .CONST
        and c.spec.consts[r.value().index].name in c.spec.types.infos[choice].names
    )


def equality(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_poison(lt) or c.is_poison(rt) or qerr_comparison(c, e, lt, rt):
        return c.bool_
    var op = String(c.op_of(e))
    var left = c.child(e, 0)
    var right = c.child(e, 1)
    var lc = c.tkind(lt) == .CHOICE
    if lc or c.tkind(rt) == .CHOICE:
        var choice = lt if lc else rt
        var other = rt if lc else lt
        if not (other == choice or c.is_any(other) or _choice_has(c, choice, right if lc else left)):
            c.error(
                e,
                t"cannot compare {c.text(lt)} with {c.text(rt)}: a choice is compared with one of its constants",
            )
        return c.bool_
    for t in [lt, rt]:
        var bad = c.non_eq_part(t)
        if bad >= 0:
            c.error(e, eq_message(c, op, t, bad))
            return c.bool_
    var j = c.join(lt, rt)
    if j < 0:
        c.error(e, t"cannot compare {c.text(lt)} with {c.text(rt)}")
    elif c.contains_any(j):
        c.error(
            e,
            t"cannot tell the type of both sides of {op} ({c.text(j)}); compare with a value of known type",
        )
    else:
        literal_member(c, lt, right)
        literal_member(c, rt, left)
    return c.bool_


def literal_member(mut c: Checker, at: Int, b: Int):
    """Reports a string literal `b` compared with or given as a literal union `at` that
    is not one of its values."""
    if c.tkind(at) == .LITERAL and c.kind_of(b) == .STR and c.text_of(b) not in c.spec.types.infos[at].names:
        c.error(b, t"\"{c.text_of(b)}\" is not one of {c.text(at)}")


def ordering(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_any(lt) or c.is_any(rt) or qerr_comparison(c, e, lt, rt):
        return c.bool_
    if c.is_numeric(lt) and c.is_numeric(rt):
        return c.bool_
    var j = c.join(lt, rt)
    if j < 0:
        c.error(e, t"cannot compare {c.text(lt)} with {c.text(rt)}")
    elif not c.ordered(j):
        var hint: String
        match c.tkind(j):
            case .TYPEVAR:
                hint = String(t": declare it as {c.spec.types.infos[j].name}: Ord")
            case .MODEL:
                hint = ": compare their observers"
            case _:
                hint = String()
        c.error(e, t"{c.op_of(e)} needs ordered operands, but {c.text(j)} has no total order{hint}")
    return c.bool_


def membership(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_poison(lt) or c.is_poison(rt):
        return c.bool_
    var elem: Int
    match c.tkind(rt):
        case .LIST | .MAP:
            elem = c.arg(rt, 0)
        case .STRING | .LITERAL:
            if not c.is_stringish(lt) and not c.is_any(lt):
                c.error(e, t"in on a string looks for a substring, but the left side is {c.text(lt)}")
            return c.bool_
        case .SET:
            c.error(
                e,
                "partition sets are not values: in a clause test the value directly, e.g. is_nan(x) or x < 0",
            )
            return c.bool_
        case _:
            c.error(e, t"in needs a list, map or string on the right, but it is {c.text(rt)}")
            return c.bool_
    for t in [lt, elem]:
        var bad = c.non_eq_part(t)
        if bad >= 0:
            c.error(e, eq_message(c, "in", t, bad))
            return c.bool_
    if c.join(lt, elem) < 0:
        c.error(e, t"cannot look for a {c.text(lt)} among {c.text(elem)} values")
    return c.bool_


def arith(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    var op = c.op_of(e)
    if c.is_any(lt) or c.is_any(rt):
        return c.poison if c.is_poison(lt) or c.is_poison(rt) else ANY_TYPE
    var lk = c.tkind(lt)
    var rk = c.tkind(rt)
    if lk == .QERR or rk == .QERR:
        if op == .ADD and lk == .QERR and rk == .QERR:
            return c.qerr_
        c.error(
            e,
            t"cannot apply {op} to {c.text(lt)} and {c.text(rt)}: quantized errors only add to each "
            t"other (qe(a, b) + qe(c, d)); read their parts with steps(e) and nans(e)",
        )
        return c.poison
    if op == .ADD:
        if lk == .LIST and rk == .LIST:
            var j = c.join(lt, rt)
            if j < 0:
                c.error(e, t"cannot concatenate {c.text(lt)} and {c.text(rt)}")
                return c.poison
            return j
        if c.is_stringish(lt) and c.is_stringish(rt):
            return c.string_
        if lk == .BYTES and rk == .BYTES:
            return c.bytes_
    if c.is_numeric(lt) and c.is_numeric(rt):
        match op:
            case .DIV:
                return c.real_
            case .FLOORDIV | .MOD:
                if c.is_integer(lt) and c.is_integer(rt):
                    return c.int_
                c.error(
                    e,
                    t"{op} takes integers, but got {c.text(lt)} and {c.text(rt)} (use / for division of reals)",
                )
                return c.poison
            case _:
                var inexact = lk == .FLOAT or lk == .REAL or rk == .FLOAT or rk == .REAL
                return c.real_ if inexact else c.int_
    c.error(e, t"cannot apply {op} to {c.text(lt)} and {c.text(rt)}")
    return c.poison


# -- if, let, comprehensions -----------------------------------------------------


def infer_if(mut c: Checker, e: Int, expected: Int) -> Int:
    var cond = c.child(e, 0)
    want_bool(c, cond, infer(c, cond), "the condition of if")
    var tt = infer(c, c.child(e, 1), expected)
    var et = infer(c, c.child(e, 2), expected)
    if c.is_poison(tt) or c.is_poison(et):
        return c.poison
    var j = c.join(tt, et)
    if j < 0:
        c.error(e, t"the branches of if have different types: {c.text(tt)} and {c.text(et)}")
        return c.poison
    return j


def bind_name(mut c: Checker, node: Int, name: String):
    if is_reserved(name):
        c.error(node, t"{name} is reserved and cannot be bound")


def infer_let(mut c: Checker, e: Int, expected: Int) -> Int:
    var name = c.text_of(e)
    bind_name(c, e, name)
    var vt = infer(c, c.child(e, 0))
    c.ctx.locals.append(Var(name^, vt, e))
    var t = infer(c, c.child(e, 1), expected)
    _ = c.ctx.locals.pop()
    return t


def infer_comprehension(mut c: Checker, e: Int) -> Int:
    var name = c.text_of(e)
    var kind = c.op_of(e)
    bind_name(c, e, name)
    var iterable = c.child(e, 0)
    var body = c.child(e, 1)
    var elem: Int
    if is_set_syntax(c, iterable):
        elem = set_iterable(c, e)
    else:
        var it = infer(c, iterable)
        match c.tkind(it):
            case .LIST | .MAP:
                elem = c.arg(it, 0)
            case .STRING | .LITERAL:
                elem = c.string_
            case .BYTES:
                elem = c.int_
            case .ANY:
                elem = it
            case _:
                c.error(iterable, t"{kind}(...) ranges over a list, string, bytes or map, but this is {c.text(it)}")
                elem = c.poison
    c.ctx.locals.append(Var(name^, elem, e))
    var bt = infer(c, body)
    _ = c.ctx.locals.pop()
    match kind:
        case .ALL | .EXISTS:
            want_bool(c, body, bt, t"the body of {kind}(...)")
            return c.bool_
        case .COUNT:
            want_bool(c, body, bt, t"the body of {kind}(...)")
            return c.int_
        case .FILTER:
            want_bool(c, body, bt, t"the body of {kind}(...)")
            return c.spec.types.list_of(elem)
        case .MAP:
            return c.spec.types.list_of(bt)
        case _:
            if c.is_any(bt):
                return bt
            if c.tkind(bt) == .QERR:
                return c.qerr_
            if c.is_integer(bt):
                return c.int_
            if c.is_numeric(bt):
                return c.real_
            var what = "adds" if kind == .SUM else "takes the largest of"
            c.error(body, t"{kind}(...) {what} numbers or qerr values, but the body is {c.text(bt)}")
            return c.poison


def is_set_syntax(mut c: Checker, e: Int) -> Bool:
    """Is e written as a partition set (f16.all, f32.range(a, b), {v, ...}, | & -)?"""
    match c.kind_of(e):
        case .SET:
            return True
        case .BINARY:
            match c.op_of(e):
                case .BITOR | .BITAND | .SUB:
                    return is_set_syntax(c, c.child(e, 0)) or is_set_syntax(c, c.child(e, 1))
                case _:
                    return False
        case _:
            return set_scalar(c, e) >= 0


def set_scalar(mut c: Checker, e: Int) -> Int:
    """The scalar type T of a `T.<set>` or `T.range(...)` / `T.pattern(...)` node, or -1."""
    var is_call = c.kind_of(e) == .CALL
    var attr = c.child(e, 0) if is_call else e
    if c.kind_of(attr) != .ATTR or c.kind_of(c.child(attr, 0)) != .NAME:
        return NO_TYPE
    var type_name = c.text_of(c.child(attr, 0))
    if binds_value(c, type_name) or type_name in c.ctx.hidden:
        return NO_TYPE
    var scalar = c.scalar(type_name)
    if scalar < 0:
        return NO_TYPE
    var member = c.text_of(attr)
    if is_call:
        return scalar if c.has_set_constructor(scalar, member) else NO_TYPE
    var constant = c.type_constant(scalar, member)
    return scalar if constant >= 0 and c.tkind(constant) == .SET else NO_TYPE


def _find_set_scalar(mut c: Checker, n: Int) -> Int:
    var s = set_scalar(c, n)
    if s >= 0:
        return s
    for k in c.children(n):
        var found = _find_set_scalar(c, k)
        if found >= 0:
            return found
    return NO_TYPE


def set_iterable(mut c: Checker, e: Int) -> Int:
    """Check a set ranged over by a comprehension; the type of its members."""
    var it = c.child(e, 0)
    var kind = c.op_of(e)
    if c.ctx.aggregate_top != e:
        c.error(
            it,
            t"{kind}(...) ranges over a set such as f16.all only as the top comprehension of an "
            t"aggregate clause; elsewhere it ranges over a list, string, bytes or map",
        )
        poison_subtree(c, it)
        return c.poison
    var elem = _find_set_scalar(c, it)
    if elem < 0:
        c.error(it, "the type of this set is unknown: start from a typed set, e.g. f16.all")
        poison_subtree(c, it)
        return c.poison
    var saved = c.ctx.in_partition_set
    c.ctx.in_partition_set = True
    var t = infer(c, it, c.spec.types.set_of(elem))
    c.ctx.in_partition_set = saved
    if c.tkind(t) == .SET:
        return c.arg(t, 0)
    if not c.is_any(t):
        c.error(it, t"{kind}(...) ranges over a set of {c.text(elem)} values, but this is {c.text(t)}")
    return c.poison


# -- calls ----------------------------------------------------------------------


def call_info(mut c: Checker, e: Int, var name: String) -> CallInfo:
    """The call `e` with its arguments typed."""
    var info = CallInfo(name^)
    for node in c.call_args(e):
        var expr = c.child(node, 0)
        var arg = Arg(c.text_of(node), infer(c, expr), expr)
        if arg.key:
            info.keywords.append(arg^)
        else:
            info.args.append(arg^)
    return info^


def fail_call(mut c: Checker, e: Int, node: Int, message: Some[Writable]) -> Int:
    _ = call_info(c, e, "")
    poison_subtree(c, c.child(e, 0))
    var text = String(message)
    if text:
        c.error(node, text)
    return c.poison


def set_call_res(mut c: Checker, e: Int, kind: ResolutionKind, name: String, *, index: Int = 0, owner: Int = -1):
    """Resolves both the call and its callee."""
    c.resolve(e, kind, name, index=index, owner=owner)
    c.resolve(c.child(e, 0), kind, name, index=index, owner=owner)


def infer_call(mut c: Checker, e: Int) -> Int:
    var f = c.child(e, 0)
    match c.kind_of(f):
        case .NAME:
            return _call_by_name(c, e, f)
        case .ATTR:
            return _call_by_attr(c, e, f)
        case _:
            _ = infer(c, f)
            return fail_call(c, e, f, "only functions and observers can be called")


def _call_by_name(mut c: Checker, e: Int, f: Int) -> Int:
    var name = c.text_of(f)
    if binds_value(c, name):
        return fail_call(c, e, f, t"{name} is a value, not a function")
    if name == "old":
        return call_old(c, e)
    var m = c.ctx.fields_of
    if m >= 0 and c.observer_pos(m, name) >= 0:
        return call_observer(c, e, c.spec.models[m].type, m, name, True)
    if case .Some(fi) = c.fn_index.get(name):
        return call_spec_fn(c, e, name, fi)
    if case .Some(di) = c.def_index.get(name):
        return call_def(c, e, name, di)
    if case .Some(pi) = c.prelude_ids.get(name):
        return call_prelude(c, e, name, pi)
    if name == "result" or name == "self" or c.ctx.param_index(name) >= 0:
        return fail_call(c, e, f, t"{name} is a value, not a function")
    return fail_call(c, e, f, t"unknown function {name}{_did_you_mean(_namespace_hints(c, name))}")


def _call_by_attr(mut c: Checker, e: Int, f: Int) -> Int:
    var base = c.child(f, 0)
    var attr = c.text_of(f)
    var chain = chain_candidate(c, f)
    if chain:
        if case .Some(fi) = c.fn_index.get(chain):
            return call_spec_fn(c, e, chain, fi)
        if case .Some(pi) = c.prelude_ids.get(chain):
            return call_prelude(c, e, chain, pi)
        if c.kind_of(base) == .NAME:
            var base_name = c.text_of(base)
            if base_name == "mp" or base_name == "cr":
                c.set_type(base, ANY_TYPE)
                return fail_call(
                    c,
                    e,
                    f,
                    t"unknown function {chain}: {base_name} holds {_namespace_what(base_name)}: "
                    t"{_namespace_members(base_name)}",
                )
            var scalar = c.scalar(base_name)
            if scalar >= 0:
                c.set_type(base, scalar)
                return call_set_ctor(c, e, scalar, attr)
        if c.ctx.extern_result >= 0 and "." in chain:
            var root = _root_name(c, f)
            if root and c.scalar(root) < 0:
                return call_extern(c, e, chain)
        var known_type_root = c.kind_of(base) == .NAME and (
            c.scalar(c.text_of(base)) >= 0 or c.text_of(base) in c.enum_index
        )
        if not known_type_root:
            return fail_call(c, e, f, t"unknown function {chain}")
    var vt = infer(c, base)
    if c.tkind(vt) == .MODEL:
        var model = c.model_pos_of_type(vt)
        if model >= 0:
            return call_observer(c, e, vt, model, attr, False)
    if c.is_any(vt):
        return fail_call(c, e, f, "")
    return fail_call(
        c,
        e,
        f,
        t"{c.text(vt)} has no function {attr}: only observers of models and interfaces can be called with '.'",
    )


def call_extern(mut c: Checker, e: Int, chain: String) -> Int:
    """A call of a qualified callable the spec doesn't declare, in an observer's
    reading expression: it takes the observer's declared type."""
    var info = call_info(c, e, chain)
    set_call_res(c, e, .EXTERN, chain)
    c.set_type(c.child(e, 0), c.spec.types.fn_(info.arg_types(), [], c.ctx.extern_result))
    return c.ctx.extern_result


def call_old(mut c: Checker, e: Int) -> Int:
    var args = c.call_args(e)
    var has_kw = any([c.text_of(a) != "" for a in args])
    if len(args) != 1 or has_kw or c.children(c.child(e, 1)):
        c.error(e, "old takes one expression: old(e)")
    elif c.ctx.in_old:
        c.error(e, "old(...) cannot be nested")
    elif not c.ctx.allow_old:
        c.error(e, c.ctx.no_old.copy())
    var saved_in = c.ctx.in_old
    var saved_scope = c.ctx.old_scope
    c.ctx.in_old = True
    c.ctx.old_scope = len(c.ctx.locals)
    var info = call_info(c, e, "")
    c.ctx.in_old = saved_in
    c.ctx.old_scope = saved_scope
    set_call_res(c, e, .OLD, "old")
    var t = info.args[0].type if len(info.args) == 1 else c.poison
    c.set_type(c.child(e, 0), c.spec.types.fn_([t], [], t))
    return t


@fieldwise_init
struct Binding(Copyable):
    """An argument of a call bound to its parameter."""

    var param: String
    var param_type: Int
    var type: Int
    var node: Int


def bindings(
    mut c: Checker, e: Int, what: String, params: List[Param], param_types: List[Int], info: CallInfo
) -> Optional[List[Binding]]:
    """The arguments of call `e` bound to `params` in order, or None after an error."""
    if len(info.args) > len(params):
        c.error(e, t"{what} takes {len(params)} argument(s), but {len(info.args)} are given")
        return None
    var slots = [Optional(a.copy()) for a in info.args] + List[Optional[Arg]](
        length=len(params) - len(info.args), fill=None
    )
    var names = [p.name.copy() for p in params]
    for kw in info.keywords:
        var at = last_index_of(names, kw.key)
        if at < 0:
            c.error(kw.node, t"{what} has no parameter named {kw.key}")
            return None
        if slots[at] is not None:
            c.error(kw.node, t"argument {kw.key} of {what} is given twice")
            return None
        slots[at] = kw.copy()
    var missing = [p.name.copy() for p, slot in zip(params, slots) if slot is None and p.default == 0]
    if missing:
        var listed = ", ".join(missing)
        c.error(e, t"{what} needs argument {listed}")
        return None
    var out: List[Binding] = []
    for p, t, slot in zip(params, param_types, slots):
        if case .Some(arg) = slot:
            out.append(Binding(p.name.copy(), t, arg.type, arg.node))
    return out^


def bind_tvars(
    mut c: Checker, pattern: Int, actual: Int, mut names: List[String], mut types: List[Int], tvars: List[String]
):
    """Solves the type variables `tvars` in `pattern` from `actual`, into `names` and `types`."""
    var pk = c.tkind(pattern)
    if pk == .TYPEVAR:
        var name = c.spec.types.infos[pattern].name.copy()
        if name in tvars:
            if c.is_any(actual):
                return
            var prev = last_index_of(names, name)
            if prev < 0:
                names.append(name^)
                types.append(actual)
                return
            var j = c.join(types[prev], actual)
            if j >= 0:
                types[prev] = j
            return
    if c.tkind(actual) != pk:
        return
    match pk:
        case .LIST | .OPTION | .SET:
            bind_tvars(c, c.arg(pattern, 0), c.arg(actual, 0), names, types, tvars)
        case .MAP:
            bind_tvars(c, c.arg(pattern, 0), c.arg(actual, 0), names, types, tvars)
            bind_tvars(c, c.arg(pattern, 1), c.arg(actual, 1), names, types, tvars)
        case .TUPLE | .MODEL:
            var pattern_args = c.spec.types.infos[pattern].args.copy()
            var actual_args = c.spec.types.infos[actual].args.copy()
            for p, x in zip(pattern_args, actual_args):
                bind_tvars(c, p, x, names, types, tvars)
        case _:
            pass


def _fn_type(mut types: Types, params: List[Param], result: Int) -> Int:
    return types.fn_([p.type for p in params], [p.name.copy() for p in params], result)


def check_declared_call(
    mut c: Checker,
    e: Int,
    name: String,
    params: List[Param],
    tparams: List[String],
    bounds: List[String],
    result: Int,
    info: CallInfo,
) -> Int:
    """Types a call of a declared function or definition: arguments bound to
    parameters, type variables solved from the arguments, bounds checked."""
    if c.children(c.child(e, 1)):
        c.error(e, t"{name} takes no explicit type arguments")
    var bound = bindings(c, e, name, params, [p.type for p in params], info)
    if bound is None:
        return c.poison
    var solved: List[String] = []
    var solutions: List[Int] = []
    for b in bound.value():
        bind_tvars(c, b.param_type, b.type, solved, solutions, tparams)
    var ok = True
    for tv, t in zip(solved, solutions):
        var bi = last_index_of(tparams, tv)
        if bi >= 0 and not c.satisfies(t, bounds[bi]):
            c.error(e, t"{name}: {c.text(t)} does not satisfy {tparams[bi]}: {bounds[bi]}")
            ok = False
    for b in bound.value():
        var target = c.spec.types.substitute(b.param_type, solved, solutions)
        if not assignable(c, b.type, target, b.node):
            c.error(b.node, t"argument {b.param} of {name} is a {c.text(target)}, but this is {c.text(b.type)}")
            ok = False
    var unsolved = [tp.copy() for tp in tparams if tp not in solved]
    var anys = List[Int](length=len(unsolved), fill=ANY_TYPE)
    var r = c.spec.types.substitute(c.spec.types.substitute(result, solved, solutions), unsolved, anys)
    return r if ok else c.poison


def call_spec_fn(mut c: Checker, e: Int, name: String, pos: Int) -> Int:
    var info = call_info(c, e, name)
    set_call_res(c, e, .SPEC_FN, name, index=pos, owner=c.spec.fns[pos].owner)
    c.set_type(c.child(e, 0), _fn_type(c.spec.types, c.spec.fns[pos].params, c.spec.fns[pos].result))
    if not c.ctx.allow_spec_fn:
        var shadow = " (it shadows the prelude function of the same name)" if name in c.prelude_ids else ""
        c.error(
            e,
            t"{name}(...) calls the spec function {name}{shadow}; calls to spec functions are only "
            t"allowed in ensures, relates, invariant and aggregate clauses, where each one is a "
            t"planned implementation call",
        )
        return c.poison
    if c.has_modifies(c.spec.fns[pos].node):
        c.error(
            e,
            t"{name} modifies its arguments, so it cannot be called in a clause: a planned call must "
            t"leave its inputs unchanged",
        )
        return c.poison
    ref f = c.spec.fns[pos]
    return check_declared_call(c, e, name, f.params.copy(), f.tparams.copy(), f.bounds.copy(), f.result, info)


def call_def(mut c: Checker, e: Int, name: String, pos: Int) -> Int:
    var info = call_info(c, e, name)
    set_call_res(c, e, .DEF, name, index=pos)
    if c.current_def >= 0:
        c.def_calls[c.current_def].append(pos)
    c.set_type(c.child(e, 0), _fn_type(c.spec.types, c.spec.defs[pos].params, c.spec.defs[pos].result))
    ref d = c.spec.defs[pos]
    return check_declared_call(c, e, name, d.params.copy(), d.tparams.copy(), d.bounds.copy(), d.result, info)


def _plural(n: Int) -> String:
    return "" if n == 1 else "s"


def call_prelude(mut c: Checker, e: Int, name: String, pid: Int) -> Int:
    var f = c.child(e, 0)
    var sig = c.prelude_sigs[pid].copy()
    var info = call_info(c, e, name)
    set_call_res(c, e, .PRELUDE, name, index=pid)
    for tn in c.children(c.child(e, 1)):
        info.targs.append(resolve_type(c, tn))
    var ok = True
    var targs = len(info.targs)
    if sig.type_args != targs and not (sig.optional_type_args and targs == 0):
        if sig.type_args > 0 and targs == 0:
            c.error(e, t"{name} needs a type argument: {sig.shape}")
        elif sig.type_args == 0:
            c.error(e, t"{name} takes no type arguments: {sig.shape}")
        else:
            c.error(e, t"{name} takes {sig.type_args} type argument(s): {sig.shape}")
        ok = False
    if len(info.args) != sig.arity:
        c.error(e, t"{name} takes {sig.arity} argument{_plural(sig.arity)}: {sig.shape}")
        ok = False
    for kw in info.keywords:
        if not (sig.has_kwargs and (kw.key == "float" or kw.key == "order")):
            c.error(kw.node, t"{name} has no argument named {kw.key}: {sig.shape}")
            ok = False
    if not ok:
        c.set_type(f, c.poison)
        return c.poison
    var t: Int
    try:
        t = prelude_type(c, sig, info)
    except err:
        c.error(_culprit(info, err, e), err.message)
        t = c.poison
    c.set_type(f, c.spec.types.fn_(info.arg_types(), [], t))
    return t


def _culprit(info: CallInfo, err: TypingError, call: Int) -> Int:
    """The node a typing error points at: its argument, or else the call."""
    if 0 <= err.arg < len(info.args):
        return info.args[err.arg].node
    for kw in reversed(info.keywords):
        if err.key and kw.key == err.key:
            return kw.node
    return call


def call_set_ctor(mut c: Checker, e: Int, scalar: Int, attr: String) -> Int:
    var f = c.child(e, 0)
    var scalar_name = c.text(scalar)
    if attr != "range" and attr != "pattern":
        if c.type_constant(scalar, attr) >= 0:
            return fail_call(c, e, f, t"{scalar_name}.{attr} is a constant, not a function: write {scalar_name}.{attr}")
        return fail_call(c, e, f, t"{scalar_name} has no function {attr}")
    if not c.has_set_constructor(scalar, attr):
        return fail_call(c, e, f, t"{scalar_name} has no {attr}(...) set")
    set_call_res(c, e, .SET_CTOR, attr, index=scalar)
    var ok = c.ctx.in_partition_set
    if not ok:
        c.error(
            e,
            t"{scalar_name}.{attr}(...) is a partition set: it only appears in a partition class of a "
            t"{scalar_name} parameter",
        )
    var args = c.call_args(e)
    var has_kw = any([c.text_of(a) != "" for a in args])
    var arg_types: List[Int] = []
    if attr == "range":
        if len(args) != 2 or has_kw:
            c.error(
                e,
                t"{scalar_name}.range takes two bounds: {scalar_name}.range(a, b), half-open, with none for an "
                t"open end",
            )
            ok = False
        for a in args:
            var bound = c.child(a, 0)
            if c.kind_of(bound) == .NONE:
                var open = c.spec.types.option_of(ANY_TYPE)
                c.set_type(bound, open)
                arg_types.append(open)
                continue
            var t = infer(c, bound)
            arg_types.append(t)
            if not c.is_numeric(t) and not c.is_any(t):
                c.error(bound, t"a bound of {scalar_name}.range must be a number or none, not {c.text(t)}")
                ok = False
    else:
        if len(args) != 1 or has_kw or c.kind_of(c.child(args[0], 0)) != .STR:
            c.error(
                e, t'{scalar_name}.pattern takes one string literal of bits, e.g. {scalar_name}.pattern("0 1* 0")'
            )
            ok = False
        arg_types = [infer(c, c.child(a, 0)) for a in args]
    var set_t = c.spec.types.set_of(scalar)
    c.set_type(f, c.spec.types.fn_(arg_types, [], set_t))
    return set_t if ok else c.poison


def call_observer(mut c: Checker, e: Int, mt: Int, model: Int, name: String, is_field: Bool) -> Int:
    var f = c.child(e, 0)
    var mname = c.spec.models[model].name.copy()
    var oi = c.observer_pos(model, name)
    if oi < 0:
        return fail_call(c, e, f, _no_observer(c, model, name))
    var info = call_info(c, e, name)
    var kind = ResolutionKind.FIELD if is_field else ResolutionKind.OBSERVER
    set_call_res(c, e, kind, name, index=oi, owner=model)
    var params = c.spec.models[model].observers[oi].params.copy()
    var declared = c.spec.models[model].observers[oi].type
    var tparams = c.spec.models[model].tparams.copy()
    var targs = c.spec.types.infos[mt].args.copy()
    var use_env = Bool(tparams) and len(tparams) == len(targs)
    var result = c.spec.types.substitute(declared, tparams, targs) if use_env else declared
    var param_types = [c.spec.types.substitute(p.type, tparams, targs) if use_env else p.type for p in params]
    c.set_type(f, c.spec.types.fn_(param_types, [p.name.copy() for p in params], result))
    if not params:
        var receiver = "" if is_field else "x."
        c.error(e, t"{name} is a field of {mname} and takes no arguments: write {receiver}{name}")
        return c.poison
    var bound = bindings(c, e, String(t"{mname}.{name}"), params, param_types, info)
    if bound is None:
        return c.poison
    var ok = True
    for b in bound.value():
        if not assignable(c, b.type, b.param_type, b.node):
            c.error(
                b.node, t"argument {b.param} of {mname}.{name} is a {c.text(b.param_type)}, but this is {c.text(b.type)}"
            )
            ok = False
    return result if ok else c.poison


# -- attributes, indexing and literals --------------------------------------------


def infer_attr(mut c: Checker, e: Int) -> Int:
    var base = c.child(e, 0)
    var attr = c.text_of(e)
    var chain = chain_candidate(c, e)
    if chain:
        if case .Some(ci) = c.const_index.get(chain):
            ensure_const(c, ci)
            c.resolve(e, .CONST, chain, index=ci)
            return c.spec.consts[ci].type
        if c.kind_of(base) == .NAME:
            var base_name = c.text_of(base)
            if base_name == "mp" or base_name == "cr":
                c.set_type(base, ANY_TYPE)
                if chain in c.prelude_ids:
                    c.error(e, t"{chain} is a function: call it as {chain}(x)")
                else:
                    c.error(e, t"unknown function {chain}")
                return c.poison
            var scalar = c.scalar(base_name)
            if scalar >= 0:
                c.set_type(base, scalar)
                return type_const(c, e, scalar, attr)
            if case .Some(en) = c.enum_index.get(base_name):
                c.set_type(base, en)
                var member = c.spec.types.infos[en].names.try_index(attr)
                if member is None:
                    c.error(e, t"enum {base_name} has no member {attr}")
                    return c.poison
                c.resolve(e, .ENUM_MEMBER, attr, index=member.value(), owner=en)
                return en
    var vt = infer(c, base)
    match c.tkind(vt):
        case .MODEL if c.model_pos_of_type(vt) >= 0:
            var model = c.model_pos_of_type(vt)
            var observer = c.observer_pos(model, attr)
            if observer < 0:
                c.error(e, _no_observer(c, model, attr))
                return c.poison
            if c.spec.models[model].observers[observer].params:
                c.error(e, _takes_arguments(c, attr, model, observer))
                return c.poison
            c.resolve(e, .OBSERVER, attr, index=observer, owner=model)
            return c.observer_type(vt, model, observer)
        case .RECORD:
            var field = c.spec.types.infos[vt].names.try_index(attr)
            if field is None:
                c.error(e, t"record {c.text(vt)} has no field {attr}")
                return c.poison
            c.resolve(e, .RECORD_FIELD, attr, index=field.value(), owner=vt)
            return c.arg(vt, field.value())
        case .QERR:
            if attr == "steps" or attr == "nans":
                c.resolve(e, .QERR_PART, attr)
                return c.int_
            c.error(e, t"qerr has no part {attr}: its parts are steps and nans")
            return c.poison
        case .ANY:
            return c.poison
        case .TUPLE:
            c.error(e, "tuple fields are numbered: .0, .1, ...")
            return c.poison
        case _:
            c.error(e, t"{c.text(vt)} has no field {attr}")
            return c.poison


def type_const(mut c: Checker, e: Int, scalar: Int, attr: String) -> Int:
    var scalar_name = c.text(scalar)
    if c.has_set_constructor(scalar, attr):
        c.error(e, t"{scalar_name}.{attr} is called: {scalar_name}.{attr}(...)")
        return c.poison
    var t = c.type_constant(scalar, attr)
    if t < 0:
        var consts = c.constants_of(scalar)
        var listed = ", ".join([String(t"{scalar_name}.{k}") for k in consts])
        var available = String(t" (available: {listed})") if consts else String()
        c.error(e, t"{scalar_name} has no constant {attr}{available}")
        return c.poison
    c.resolve(e, .TYPE_CONST, attr, index=scalar)
    if c.tkind(t) == .SET and not c.ctx.in_partition_set:
        var hint = classifier_hint(attr) if c.tkind(scalar) == .FLOAT else String()
        var test = String(t"; in a clause, test the value with {hint}") if hint else String()
        c.error(
            e,
            t"{scalar_name}.{attr} is a partition set: it only appears in a partition class of a {scalar_name} "
            t"parameter{test}",
        )
        return c.poison
    return t


def infer_tuple_index(mut c: Checker, e: Int) -> Int:
    var vt = infer(c, c.child(e, 0))
    var digits = c.text_of(e)
    var index = 1 << 40  # past any tuple, when the digits overflow an Int
    try:
        index = Int(digits)
    except:
        pass
    match c.tkind(vt):
        case .TUPLE:
            if index < len(c.spec.types.infos[vt].args):
                return c.arg(vt, index)
            c.error(e, t".{digits} is out of range for {c.text(vt)}")
            return c.poison
        case .ANY:
            return c.poison
        case _:
            c.error(e, t".{digits} needs a tuple, but the value is {c.text(vt)}")
            return c.poison


def infer_index(mut c: Checker, e: Int) -> Int:
    var index = c.child(e, 1)
    var vt = infer(c, c.child(e, 0))
    var it = infer(c, index)
    var k = c.tkind(vt)
    match k:
        case .MAP:
            var key = c.arg(vt, 0)
            var bad = c.non_eq_part(key)
            if bad >= 0:
                c.error(e, eq_message(c, "map lookup", key, bad))
            elif c.join(it, key) < 0 and not c.is_any(it):
                c.error(index, t"the keys of {c.text(vt)} are {c.text(key)}, not {c.text(it)}")
            return c.arg(vt, 1)
        case .LIST | .STRING | .LITERAL | .BYTES:
            want_int(c, index, it, "an index")
            if k == .LIST:
                return c.arg(vt, 0)
            return c.int_ if k == .BYTES else c.string_
        case .ANY:
            return c.poison
        case .TUPLE:
            c.error(e, "tuple fields are selected with .0, .1, ..., not [i]")
            return c.poison
        case _:
            c.error(e, t"cannot index a {c.text(vt)}")
            return c.poison


def infer_slice(mut c: Checker, e: Int) -> Int:
    var vt = infer(c, c.child(e, 0))
    want_int(c, c.child(e, 1), infer(c, c.child(e, 1)), "a slice bound")
    want_int(c, c.child(e, 2), infer(c, c.child(e, 2)), "a slice bound")
    match c.tkind(vt):
        case .LIST | .BYTES:
            return vt
        case .STRING | .LITERAL:
            return c.string_
        case .ANY:
            return c.poison
        case _:
            c.error(e, t"cannot slice a {c.text(vt)}")
            return c.poison


def infer_list(mut c: Checker, e: Int) -> Int:
    var elem = ANY_TYPE
    var ok = True
    for x in c.children(e):
        var xt = infer(c, x)
        if c.is_poison(xt):
            ok = False
            continue
        var j = c.join(elem, xt)
        if j < 0:
            c.error(
                x,
                t"the elements of a list have one type, but this is {c.text(xt)} and an earlier one is "
                t"{c.text(elem)}",
            )
            ok = False
        else:
            elem = j
    return c.spec.types.list_of(elem) if ok else c.poison


def infer_set(mut c: Checker, e: Int, expected: Int) -> Int:
    if not c.ctx.in_partition_set or expected < 0 or c.tkind(expected) != .SET:
        for x in c.children(e):
            _ = infer(c, x)
        c.error(e, "{...} is a partition set: it only appears in a partition class of a fixed-width parameter")
        return c.poison
    var elem = c.arg(expected, 0)
    var ek = c.tkind(elem)
    var ok = True
    for x in c.children(e):
        var t = infer(c, x)
        if c.is_any(t):
            continue
        var good: Bool
        match ek:
            case .FLOAT:
                good = c.is_numeric(t)
            case .FIXED_INT:
                good = c.is_integer(t)
            case _:
                good = c.tkind(t) == .BOOL
        if not good:
            var want = String("number") if c.is_numeric(elem) else c.text(elem)
            c.error(x, t"a member of a set of {c.text(elem)} values must be a {want}, not {c.text(t)}")
            ok = False
    return expected if ok else c.poison
