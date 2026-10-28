"""Typing of expressions: names, operators, calls, comprehensions, literals.

`infer` types one expression node in the clause context `Checker.ctx`, records its
type and, for names, attributes and calls that refer to something, its resolution.
Errors go to the checker's diagnostics; an expression that already has an error gets
the poison type, which silences follow-on errors.
"""

from numeric.real import Real
from numeric.literal import is_integer_literal
from syntax import ast

from check import types as ty
from check.psig import CallInfo
from check.sigs import type_prelude
from check.spec import (
    Param,
    R_CLASS,
    R_CONST,
    R_DEF,
    R_ENUM_MEMBER,
    R_EXTERN,
    R_FIELD,
    R_LOCAL,
    R_OBSERVER,
    R_OLD,
    R_PARAM,
    R_PRELUDE,
    R_QERR_PART,
    R_RECORD_FIELD,
    R_RESULT,
    R_SELF,
    R_SET_CTOR,
    R_SPEC_FN,
    R_TYPE_CONST,
)
from check.state import (
    Checker,
    NO_TYPE,
    K_PARTITION_SET,
    classifier_hint,
)
from check.typesyn import ensure_const, resolve_type


# -- small helpers --------------------------------------------------------------


def poison_subtree(mut c: Checker, e: Int):
    for n in c.spec.ast.subtree(e):
        if c.spec.node_types[n] == 0:
            c.spec.node_types[n] = c.poison


def want_bool(mut c: Checker, node: Int, t: Int, what: String):
    var k = c.tkind(t)
    if k != ty.BOOL and k != ty.ANY:
        c.error(node, t"{what} must be a bool, but this is {c.text(t)}")


def want_int(mut c: Checker, node: Int, t: Int, what: String):
    if not c.is_integer(t) and not c.is_any(t):
        var hint = " (use // for integer division)" if c.tkind(t) == ty.REAL else ""
        c.error(node, t"{what} must be an integer, but it is {c.text(t)}{hint}")


def binds_value(c: Checker, name: String) -> Bool:
    """Is name a local, a partition class or a parameter here?"""
    if c.ctx.local_index(name) >= 0 or c.ctx.class_index(name) >= 0:
        return True
    return c.ctx.param_index(name) >= 0 and c.ctx.kind != K_PARTITION_SET


def _root_name(c: Checker, e: Int) -> String:
    var n = e
    while c.kind_of(n) == .ATTR:
        n = c.child(n, 0)
    if c.kind_of(n) == .NAME:
        return c.text_of(n)
    return String()


def dotted(c: Checker, e: Int) -> String:
    """`a.b.c` for a chain of names and attributes, or "" for anything else."""
    if c.kind_of(e) == .NAME:
        return c.text_of(e)
    if c.kind_of(e) == .ATTR:
        var inner = dotted(c, c.child(e, 0))
        if inner == "":
            return String()
        return inner + "." + c.text_of(e)
    return String()


def chain_candidate(c: Checker, e: Int) -> String:
    """The dotted name of a chain whose root is not a bound or reserved name, else ""."""
    var root = _root_name(c, e)
    if root == "" or root == "self" or root == "result" or root == "old":
        return String()
    if binds_value(c, root) or c.ctx.hidden_index(root) >= 0:
        return String()
    if c.ctx.fields_of >= 0:
        # A bare observer shadows nothing qualified, but keep fields first.
        if c.observer_pos(c.ctx.fields_of, root) >= 0:
            return String()
    return dotted(c, e)


def assignable(mut c: Checker, actual: Int, target: Int, node: Int) -> Bool:
    """May a value of type actual be passed where target is expected? Fixed-width
    numeric targets accept any number: representability is checked at the call."""
    if c.is_any(actual) or c.is_any(target) or actual == target:
        return True
    var kt = c.tkind(target)
    var ka = c.tkind(actual)
    if kt == ty.FIXED_INT:
        return c.is_integer(actual) or ka == ty.REAL
    if kt == ty.FLOAT or kt == ty.REAL:
        return c.is_numeric(actual)
    if kt == ty.INT:
        return c.is_integer(actual)
    if kt == ty.LITERAL:
        var values = c.spec.types.infos[target].names.copy()
        if ka == ty.LITERAL:
            for v in c.spec.types.infos[actual].names:
                var found = False
                for w in values:
                    if v == w:
                        found = True
                if not found:
                    return False
            return True
        if node > 0 and c.kind_of(node) == .STR:
            var text = c.text_of(node)
            for w in values:
                if w == text:
                    return True
        return False
    if kt == ty.CHOICE:
        var names = c.spec.types.infos[target].names.copy()
        if ka == ty.CHOICE:
            for v in c.spec.types.infos[actual].names:
                var found = False
                for w in names:
                    if v == w:
                        found = True
                if not found:
                    return False
            return True
        if node > 0:
            var r = c.spec.resolutions.get(node)
            if r and r.value().kind == R_CONST:
                var nm = c.spec.consts[r.value().index].name
                for w in names:
                    if w == nm:
                        return True
        return False
    if kt == ty.STRING:
        return c.is_stringish(actual)
    if kt == ty.LIST and ka == ty.LIST:
        if node > 0 and c.kind_of(node) == .LIST and c.children(node):
            for x in c.children(node):
                if not assignable(c, c.spec.node_types[x], c.arg(target, 0), x):
                    return False
            return True
        return assignable(c, c.arg(actual, 0), c.arg(target, 0), 0)
    if kt == ty.OPTION and ka == ty.OPTION:
        return assignable(c, c.arg(actual, 0), c.arg(target, 0), 0)
    if kt == ty.MAP and ka == ty.MAP:
        return assignable(c, c.arg(actual, 0), c.arg(target, 0), 0) and assignable(
            c, c.arg(actual, 1), c.arg(target, 1), 0
        )
    if kt == ty.TUPLE and ka == ty.TUPLE:
        var ts = c.spec.types.infos[target].args.copy()
        var xs = c.spec.types.infos[actual].args.copy()
        if len(ts) != len(xs):
            return False
        var subs = List[Int]()
        if node > 0 and c.kind_of(node) == .TUPLE and len(c.children(node)) == len(ts):
            subs = c.children(node)
        for i in range(len(ts)):
            if not assignable(c, xs[i], ts[i], subs[i] if len(subs) > 0 else 0):
                return False
        return True
    return False


# -- entry point ----------------------------------------------------------------


def infer(mut c: Checker, e: Int, expected: Int = NO_TYPE) -> Int:
    var k = c.kind_of(e)
    var t: Int
    if k == .NAME:
        t = infer_name(c, e)
    elif k == .BINARY:
        t = infer_binary(c, e, expected)
    elif k == .CALL:
        t = infer_call(c, e)
    elif k == .ATTR:
        t = infer_attr(c, e)
    elif k == .NUM:
        t = c.int_ if is_integer_literal(c.spec.ast.nodes[e].text) else c.real_
    elif k == .STR:
        t = c.string_
    elif k == .BOOL:
        t = c.bool_
    elif k == .NONE:
        t = c.spec.types.option_of(ty.ANY_TYPE)
    elif k == .UNARY:
        t = infer_unary(c, e)
    elif k == .IF:
        t = infer_if(c, e, expected)
    elif k == .LET:
        t = infer_let(c, e, expected)
    elif k == .COMPREHENSION:
        t = infer_comprehension(c, e)
    elif k == .TUPLE_INDEX:
        t = infer_tuple_index(c, e)
    elif k == .INDEX:
        t = infer_index(c, e)
    elif k == .SLICE:
        t = infer_slice(c, e)
    elif k == .LIST:
        t = infer_list(c, e)
    elif k == .TUPLE:
        t = infer_tuple(c, e)
    elif k == .SET:
        t = infer_set(c, e, expected)
    else:
        t = c.poison
    c.set_type(e, t)
    return t


# -- names ----------------------------------------------------------------------


def infer_name(mut c: Checker, e: Int) -> Int:
    var t = lookup(c, e)
    return c.poison if t < 0 else t


def _old_local_message(c: Checker, name: String, binder: Int) -> String:
    var how = "let"
    if c.kind_of(binder) == .COMPREHENSION:
        how = String(c.op_of(binder)) + "(...)"
    return (
        "old(...) is evaluated before the call, so it cannot use "
        + name
        + ", which "
        + how
        + " binds inside this clause: bind old(...) of the state first, e.g. "
        "let xs = old(self.items) in all(i in range(0, len(xs)): xs[i] == self.items[i])"
    )


def lookup(mut c: Checker, e: Int) -> Int:
    """The type of a bare name, recording its resolution; -1 after an error."""
    var name = c.text_of(e)
    var li = c.ctx.local_index(name)
    if li >= 0:
        if c.ctx.in_old and c.ctx.allow_old and li < c.ctx.old_scope:
            c.error(e, _old_local_message(c, name, c.ctx.loc_binders[li]))
            return NO_TYPE
        c.resolve(e, R_LOCAL, c.ctx.loc_binders[li], -1, name)
        return c.ctx.loc_types[li]
    var hi = c.ctx.hidden_index(name)
    if hi >= 0:
        c.error(e, c.ctx.hidden_msgs[hi].copy())
        return NO_TYPE
    var ci = c.ctx.class_index(name)
    if ci >= 0:
        c.resolve(e, R_CLASS, c.ctx.class_nodes[ci], -1, name)
        return c.ctx.class_types[ci]
    var pi = c.ctx.param_index(name)
    if pi >= 0:
        if c.ctx.kind == K_PARTITION_SET:
            var ptype = c.ctx.param_types[pi]
            var set_name = "nan" if c.tkind(ptype) == ty.FLOAT else "all"
            c.error(
                e,
                String("classes of the fixed-width parameter ", c.ctx.only_param, " are sets of values, so ", name, " cannot appear in them: build them from ", c.text(ptype), ".", set_name, ", ", c.text(ptype), ".range(a, b), {v, ...} and earlier classes"),
            )
            return NO_TYPE
        if c.ctx.only_param != "" and name != c.ctx.only_param:
            c.error(
                e,
                String("a class of partition ", c.ctx.only_param, " may only refer to ", c.ctx.only_param, ", not to ", name),
            )
            return NO_TYPE
        c.resolve(e, R_PARAM, pi, -1, name)
        return c.ctx.param_types[pi]
    if name == "result":
        if c.ctx.in_old:
            c.error(e, "result does not exist before the call, so old(...) cannot use it")
            return NO_TYPE
        if not c.ctx.has_result:
            c.error(e, c.ctx.no_result.copy())
            return NO_TYPE
        c.resolve(e, R_RESULT, 0, -1, "result")
        return c.ctx.result
    if name == "self":
        if c.ctx.self_t < 0:
            c.error(e, c.ctx.no_self.copy())
            return NO_TYPE
        c.resolve(e, R_SELF, 0, c.ctx.self_model, "self")
        return c.ctx.self_t
    if c.ctx.fields_of >= 0:
        var m = c.ctx.fields_of
        var oi = c.observer_pos(m, name)
        if oi >= 0:
            ref obs = c.spec.models[m].observers[oi]
            if len(obs.params) > 0:
                var names = String()
                for j in range(len(obs.params)):
                    names += ", " if j else ""
                    names += obs.params[j].name
                c.error(e, t"{name} takes arguments: {name}({names})")
                return NO_TYPE
            var otype = obs.type
            c.resolve(e, R_FIELD, oi, m, name)
            return otype
    var found = -1
    var member = -1
    var count = 0
    for en in c.spec.enums:
        var names = c.spec.types.infos[en].names.copy()
        for j in range(len(names)):
            if names[j] == name:
                count += 1
                if found < 0:
                    found = en
                    member = j
    if count == 1:
        c.resolve(e, R_ENUM_MEMBER, member, found, name)
        return found
    if count > 1:
        var list = String()
        var first = String()
        var n = 0
        for en in c.spec.enums:
            var names = c.spec.types.infos[en].names.copy()
            for j in range(len(names)):
                if names[j] == name:
                    list += ", " if n else ""
                    list += c.text(en)
                    if n == 0:
                        first = c.text(en)
                    n += 1
        c.error(e, t"{name} is a member of several enums ({list}): write {first}.{name}")
        return NO_TYPE
    unknown_name(c, e, name)
    return NO_TYPE


def _namespace_what(ns: String) -> String:
    if ns == "mp":
        return "the reference functions, which return reals"
    return "the correctly rounded functions, which return floats"


def _namespace_members(c: Checker, ns: String) -> String:
    var out = String()
    var first = True
    for word in "sqrt exp log sin cos tan atan".split(" "):
        out += "" if first else ", "
        first = False
        out += ns + "." + String(word)
    return out


def unknown_name(mut c: Checker, e: Int, name: String):
    var msg: String
    if name == "old":
        msg = "old is called as old(e)"
    elif name in c.fn_index:
        msg = (
            name
            + " is a spec function: call it as "
            + name
            + "(...), in an ensures, relates, invariant or aggregate clause"
        )
    elif name in c.def_index:
        msg = name + " is a definition: call it as " + name + "(...)"
    elif name in c.prelude_ids:
        msg = name + " is a function: call it as " + name + "(...)"
    elif name == "mp" or name == "cr":
        msg = (
            name
            + " is the namespace of "
            + _namespace_what(name)
            + ", e.g. "
            + name
            + ".cos(x)"
        )
    elif c.scalar(name) >= 0 or name in c.model_index:
        msg = name + " is a type, not a value"
    else:
        msg = "unknown name " + name
        var hints = List[String]()
        if c.ctx.self_t >= 0 and c.ctx.self_model >= 0:
            if c.observer_pos(c.ctx.self_model, name) >= 0:
                hints.append("self." + name)
        for i in range(len(c.ctx.param_names)):
            var pt = c.ctx.param_types[i]
            if c.tkind(pt) == ty.MODEL and c.ctx.param_names[i] != "":
                var mp = c.model_pos_of_type(pt)
                if mp >= 0 and c.observer_pos(mp, name) >= 0:
                    hints.append(c.ctx.param_names[i] + "." + name)
        for ns in ["mp", "cr"]:
            if (String(ns) + "." + name) in c.prelude_ids:
                hints.append(String(ns) + "." + name)
        if len(hints) > 0:
            var joined = String()
            for i in range(len(hints)):
                joined += " or " if i else ""
                joined += hints[i]
            msg += " (did you mean " + joined + "?)"
    c.error(e, msg)


# -- operators ------------------------------------------------------------------


def infer_unary(mut c: Checker, e: Int) -> Int:
    var operand = c.child(e, 0)
    var t = infer(c, operand)
    if c.op_of(e) == .NOT:
        want_bool(c, operand, t, "the operand of not")
        return c.bool_
    if c.is_any(t):
        return t
    var k = c.tkind(t)
    if k == ty.FLOAT:
        return t
    if c.is_integer(t):
        return c.int_
    if k == ty.REAL:
        return c.real_
    c.error(e, t"unary - needs a number, but the operand is {c.text(t)}")
    return c.poison


def infer_binary(mut c: Checker, e: Int, expected: Int) -> Int:
    var op = c.op_of(e)
    var left = c.child(e, 0)
    var right = c.child(e, 1)
    var side = NO_TYPE
    if expected >= 0 and c.tkind(expected) == ty.SET:
        side = expected
    var lt = infer(c, left, side)
    var rt = infer(c, right, side)
    if op == .AND or op == .OR or op == .IMPLIES:
        var word = String(op)
        want_bool(c, left, lt, "the left operand of " + word)
        want_bool(c, right, rt, "the right operand of " + word)
        return c.bool_
    if op == .BITOR or op == .BITAND:
        if c.is_integer(lt) and c.is_integer(rt):
            return c.int_
        return set_op(c, e, lt, rt)
    if op == .SUB and (c.tkind(lt) == ty.SET or c.tkind(rt) == ty.SET):
        return set_op(c, e, lt, rt)
    if op == .EQ or op == .NE:
        return equality(c, e, lt, rt)
    if op == .LT or op == .LE or op == .GT or op == .GE:
        return ordering(c, e, lt, rt)
    if op == .IN:
        return membership(c, e, lt, rt)
    if op == .SHL or op == .SHR or op == .POW:
        return integer_op(c, e, lt, rt)
    return arith(c, e, lt, rt)


def integer_op(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    var op = String(c.op_of(e))
    if c.is_poison(lt) or c.is_poison(rt):
        return c.poison
    if (c.is_integer(lt) or c.is_any(lt)) and (c.is_integer(rt) or c.is_any(rt)):
        if c.op_of(e) == .POW:
            var exponent = c.literal_value(c.child(e, 1))
            if exponent and exponent.value() < Real(0):
                c.error(
                    e,
                    "** needs a non-negative exponent: a negative power is not an"
                    " integer",
                )
                return c.poison
        return c.int_
    c.error(e, t"{op} takes integers, but got {c.text(lt)} and {c.text(rt)}")
    return c.poison


def set_op(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_poison(lt) or c.is_poison(rt):
        return c.poison
    var op = String(c.op_of(e))
    if c.tkind(lt) != ty.SET or c.tkind(rt) != ty.SET:
        if (op == "|" or op == "&") and c.tkind(lt) == ty.BOOL and c.tkind(rt) == ty.BOOL:
            var word = "or" if op == "|" else "and"
            c.error(e, t"{op} combines partition sets or integers; for booleans write {word}")
        elif op == "|" or op == "&":
            c.error(
                e,
                t"{op} needs two integers or two partition sets, but got {c.text(lt)} and {c.text(rt)}",
            )
        else:
            c.error(
                e,
                t"{op} on partition sets needs a set on both sides, but got {c.text(lt)} and {c.text(rt)}",
            )
        return c.poison
    if c.arg(lt, 0) != c.arg(rt, 0):
        c.error(
            e,
            t"cannot combine a set of {c.text(c.arg(lt, 0))} with a set of {c.text(c.arg(rt, 0))}",
        )
        return c.poison
    return lt


def eq_message(mut c: Checker, op: String, t: Int, bad: Int) -> String:
    var inside = String() if t == bad else (" (inside " + c.text(t) + ")")
    var k = c.tkind(bad)
    if k == ty.FLOAT:
        return (
            op
            + " is not defined on "
            + c.text(bad)
            + inside
            + ": floats have no implicit equality. Use same(a, b) for bit-identical"
            " values, ieee_eq(a, b) for IEEE 754 equality, real(a) "
            + op
            + " real(b) to compare numerically, or eq(a, b, float=...) for collections"
        )
    if k == ty.MODEL:
        return (
            op
            + " is not defined on "
            + c.text(bad)
            + " handles"
            + inside
            + ": compare their observers (a.items == b.items) or use eq(a, b, ...)"
        )
    if k == ty.TYPEVAR:
        var name = c.spec.types.infos[bad].name
        return op + " needs equality on " + c.text(bad) + inside + ": declare it as " + name + ": Eq"
    if k == ty.SET:
        return op + " is not defined on partition sets"
    return op + " is not defined on " + c.text(bad) + inside


def qerr_comparison(mut c: Checker, e: Int, lt: Int, rt: Int) -> Bool:
    """Check a comparison with a qerr operand; False when neither side is a qerr."""
    var lq = c.tkind(lt) == ty.QERR
    var rq = c.tkind(rt) == ty.QERR
    if not lq and not rq:
        return False
    var other = rt if lq else lt
    if c.tkind(other) == ty.QERR or c.is_any(other):
        return True
    if c.is_numeric(other) and c.tkind(other) != ty.FLOAT:
        return True
    c.error(
        e,
        t"{c.op_of(e)} compares a qerr with a qerr or a number (an int or real, read "
        t"as c + 0·nan), but the other side is {c.text(other)}",
    )
    return True


def _choice_has(mut c: Checker, choice: Int, node: Int) -> Bool:
    var r = c.spec.resolutions.get(node)
    if r and r.value().kind == R_CONST:
        var nm = c.spec.consts[r.value().index].name
        for w in c.spec.types.infos[choice].names:
            if w == nm:
                return True
    return False


def equality(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_poison(lt) or c.is_poison(rt):
        return c.bool_
    if qerr_comparison(c, e, lt, rt):
        return c.bool_
    var op = String(c.op_of(e))
    var left = c.child(e, 0)
    var right = c.child(e, 1)
    var lc = c.tkind(lt) == ty.CHOICE
    var rc = c.tkind(rt) == ty.CHOICE
    if lc or rc:
        var choice = lt if lc else rt
        var other = rt if lc else lt
        var other_node = right if lc else left
        if other == choice or c.is_any(other):
            return c.bool_
        if _choice_has(c, choice, other_node):
            return c.bool_
        c.error(
            e,
            t"cannot compare {c.text(lt)} with {c.text(rt)}: a choice is compared with one of its "
            t"constants",
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
        return c.bool_
    if c.contains_any(j):
        c.error(
            e,
            t"cannot tell the type of both sides of {op} ({c.text(j)}); compare with a value of known "
            t"type",
        )
        return c.bool_
    literal_member(c, lt, right)
    literal_member(c, rt, left)
    return c.bool_


def literal_member(mut c: Checker, at: Int, b: Int):
    if c.tkind(at) == ty.LITERAL and c.kind_of(b) == .STR:
        var text = c.text_of(b)
        for v in c.spec.types.infos[at].names:
            if v == text:
                return
        c.error(b, '"' + text + '" is not one of ' + c.text(at))


def ordering(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_any(lt) or c.is_any(rt):
        return c.bool_
    if qerr_comparison(c, e, lt, rt):
        return c.bool_
    if c.is_numeric(lt) and c.is_numeric(rt):
        return c.bool_
    var j = c.join(lt, rt)
    if j < 0:
        c.error(e, t"cannot compare {c.text(lt)} with {c.text(rt)}")
    elif not c.ordered(j):
        var hint = String()
        var k = c.tkind(j)
        if k == ty.TYPEVAR:
            hint = ": declare it as " + c.spec.types.infos[j].name + ": Ord"
        elif k == ty.MODEL:
            hint = ": compare their observers"
        c.error(
            e,
            t"{c.op_of(e)} needs ordered operands, but {c.text(j)} has no total order"
            t"{hint}",
        )
    return c.bool_


def membership(mut c: Checker, e: Int, lt: Int, rt: Int) -> Int:
    if c.is_poison(lt) or c.is_poison(rt):
        return c.bool_
    var rk = c.tkind(rt)
    var elem: Int
    if rk == ty.LIST:
        elem = c.arg(rt, 0)
    elif rk == ty.MAP:
        elem = c.arg(rt, 0)
    elif c.is_stringish(rt):
        if not c.is_stringish(lt) and not c.is_any(lt):
            c.error(e, t"in on a string looks for a substring, but the left side is {c.text(lt)}")
        return c.bool_
    elif rk == ty.SET:
        c.error(
            e,
            "partition sets are not values: in a clause test the value directly, "
            "e.g. is_nan(x) or x < 0",
        )
        return c.bool_
    else:
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
    var opn = String(op)
    if c.is_any(lt) or c.is_any(rt):
        return c.poison if (c.is_poison(lt) or c.is_poison(rt)) else ty.ANY_TYPE
    var lk = c.tkind(lt)
    var rk = c.tkind(rt)
    if lk == ty.QERR or rk == ty.QERR:
        if op == .ADD and lk == ty.QERR and rk == ty.QERR:
            return c.qerr_
        c.error(
            e,
            t"cannot apply {opn} to {c.text(lt)} and {c.text(rt)}: quantized errors only add to each "
            t"other (qe(a, b) + qe(c, d)); read their parts with steps(e) and nans(e)",
        )
        return c.poison
    if op == .ADD:
        if lk == ty.LIST and rk == ty.LIST:
            var j = c.join(lt, rt)
            if j < 0:
                c.error(e, t"cannot concatenate {c.text(lt)} and {c.text(rt)}")
                return c.poison
            return j
        if c.is_stringish(lt) and c.is_stringish(rt):
            return c.string_
        if lk == ty.BYTES and rk == ty.BYTES:
            return c.bytes_
    if c.is_numeric(lt) and c.is_numeric(rt):
        if op == .DIV:
            return c.real_
        if op == .FLOORDIV or op == .MOD:
            if c.is_integer(lt) and c.is_integer(rt):
                return c.int_
            c.error(
                e,
                t"{opn} takes integers, but got {c.text(lt)} and {c.text(rt)} (use / for division of "
                t"reals)",
            )
            return c.poison
        if lk == ty.FLOAT or lk == ty.REAL or rk == ty.FLOAT or rk == ty.REAL:
            return c.real_
        return c.int_
    c.error(e, t"cannot apply {opn} to {c.text(lt)} and {c.text(rt)}")
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
    if name == "old" or name == "result" or name == "self" or name == "mp" or name == "cr":
        c.error(node, t"{name} is reserved and cannot be bound")


def push_local(mut c: Checker, name: String, t: Int, binder: Int):
    c.ctx.loc_names.append(name)
    c.ctx.loc_types.append(t)
    c.ctx.loc_binders.append(binder)


def pop_local(mut c: Checker):
    _ = c.ctx.loc_names.pop()
    _ = c.ctx.loc_types.pop()
    _ = c.ctx.loc_binders.pop()


def infer_let(mut c: Checker, e: Int, expected: Int) -> Int:
    var name = c.text_of(e)
    bind_name(c, e, name)
    var vt = infer(c, c.child(e, 0))
    push_local(c, name, vt, e)
    var t = infer(c, c.child(e, 1), expected)
    pop_local(c)
    return t


def infer_comprehension(mut c: Checker, e: Int) -> Int:
    var name = c.text_of(e)
    var kind = c.op_of(e)
    var kname = String(kind)
    bind_name(c, e, name)
    var iterable = c.child(e, 0)
    var body = c.child(e, 1)
    var elem: Int
    if is_set_syntax(c, iterable):
        elem = set_iterable(c, e)
    else:
        var it = infer(c, iterable)
        var ik = c.tkind(it)
        if ik == ty.LIST:
            elem = c.arg(it, 0)
        elif c.is_stringish(it):
            elem = c.string_
        elif ik == ty.BYTES:
            elem = c.int_
        elif ik == ty.MAP:
            elem = c.arg(it, 0)
        elif ik == ty.ANY:
            elem = it
        else:
            c.error(
                iterable,
                t"{kname}(...) ranges over a list, string, bytes or map, but this is {c.text(it)}",
            )
            elem = c.poison
    push_local(c, name, elem, e)
    var bt = infer(c, body)
    pop_local(c)
    if kind == .ALL or kind == .EXISTS or kind == .COUNT or kind == .FILTER:
        want_bool(c, body, bt, "the body of " + kname + "(...)")
    if kind == .ALL or kind == .EXISTS:
        return c.bool_
    if kind == .COUNT:
        return c.int_
    if kind == .FILTER:
        return c.spec.types.list_of(elem)
    if kind == .MAP:
        return c.spec.types.list_of(bt)
    if c.is_any(bt):
        return bt
    if c.tkind(bt) == ty.QERR:
        return c.qerr_
    if c.is_integer(bt):
        return c.int_
    if c.is_numeric(bt):
        return c.real_
    var what = "adds" if kind == .SUM else "takes the largest of"
    c.error(body, t"{kname}(...) {what} numbers or qerr values, but the body is {c.text(bt)}")
    return c.poison


def is_set_syntax(mut c: Checker, e: Int) -> Bool:
    """Is e written as a partition set (f16.all, f32.range(a, b), {v, ...}, | & -)?"""
    var k = c.kind_of(e)
    if k == .SET:
        return True
    if k == .BINARY:
        var op = c.op_of(e)
        if op == .BITOR or op == .BITAND or op == .SUB:
            return is_set_syntax(c, c.child(e, 0)) or is_set_syntax(c, c.child(e, 1))
        return False
    return set_scalar(c, e) >= 0


def set_scalar(mut c: Checker, e: Int) -> Int:
    """The scalar type T of a `T.<set>` or `T.range(...)` / `T.pattern(...)` node, or -1."""
    var attr = e
    var is_call = c.kind_of(e) == .CALL
    if is_call:
        attr = c.child(e, 0)
    if c.kind_of(attr) != .ATTR or c.kind_of(c.child(attr, 0)) != .NAME:
        return NO_TYPE
    var name = c.text_of(c.child(attr, 0))
    if binds_value(c, name) or c.ctx.hidden_index(name) >= 0:
        return NO_TYPE
    var st = c.scalar(name)
    if st < 0:
        return NO_TYPE
    var an = c.text_of(attr)
    if is_call:
        return st if c.has_set_constructor(st, an) else NO_TYPE
    var tc = c.type_constant(st, an)
    return st if (tc >= 0 and c.tkind(tc) == ty.SET) else NO_TYPE


def _find_set_scalar(mut c: Checker, n: Int) -> Int:
    var s = set_scalar(c, n)
    if s >= 0:
        return s
    for k in c.children(n):
        var r = _find_set_scalar(c, k)
        if r >= 0:
            return r
    return NO_TYPE


def set_iterable(mut c: Checker, e: Int) -> Int:
    """Check a set ranged over by a comprehension; the type of its members."""
    var it = c.child(e, 0)
    var kname = String(c.op_of(e))
    if c.ctx.aggregate_top != e:
        c.error(
            it,
            t"{kname}(...) ranges over a set such as f16.all only as the top comprehension of an "
            t"aggregate clause; elsewhere it ranges over a list, string, bytes or map",
        )
        poison_subtree(c, it)
        return c.poison
    var elem = _find_set_scalar(c, it)
    if elem < 0:
        c.error(it, "the type of this set is unknown: start from a typed set, e.g. f16.all")
        poison_subtree(c, it)
        return c.poison
    var saved = c.ctx.kind
    c.ctx.kind = K_PARTITION_SET
    var t = infer(c, it, c.spec.types.set_of(elem))
    c.ctx.kind = saved
    if c.tkind(t) == ty.SET:
        return c.arg(t, 0)
    if not c.is_any(t):
        c.error(
            it,
            t"{kname}(...) ranges over a set of {c.text(elem)} values, but this is {c.text(t)}",
        )
    return c.poison


# -- calls ----------------------------------------------------------------------


def infer_args(mut c: Checker, e: Int, mut info: CallInfo):
    var kids = c.children(e)
    for i in range(2, len(kids)):
        var arg = kids[i]
        var expr = c.child(arg, 0)
        var t = infer(c, expr)
        var key = c.text_of(arg)
        if key == "":
            info.args.append(t)
            info.nodes.append(expr)
        else:
            info.kw_keys.append(key^)
            info.kw_types.append(t)
            info.kw_nodes.append(expr)


def fail_call(mut c: Checker, e: Int, node: Int, message: Some[Writable]) -> Int:
    var info = CallInfo(String())
    infer_args(c, e, info)
    poison_subtree(c, c.child(e, 0))
    var text = String(message)
    if text != "":
        c.error(node, text)
    return c.poison


def set_call_res(mut c: Checker, e: Int, kind: UInt8, index: Int, owner: Int, name: String):
    c.resolve(e, kind, index, owner, name)
    c.resolve(c.child(e, 0), kind, index, owner, name)


def infer_call(mut c: Checker, e: Int) -> Int:
    var f = c.child(e, 0)
    var fk = c.kind_of(f)
    if fk == .NAME:
        var name = c.text_of(f)
        if binds_value(c, name):
            return fail_call(c, e, f, t"{name} is a value, not a function")
        if name == "old":
            return call_old(c, e)
        if c.ctx.fields_of >= 0:
            var oi = c.observer_pos(c.ctx.fields_of, name)
            if oi >= 0:
                return call_observer(
                    c, e, c.spec.models[c.ctx.fields_of].type, c.ctx.fields_of, name, True
                )
        var fi = c.fn_index.get(name)
        if fi:
            return call_spec_fn(c, e, name, fi.value())
        var di = c.def_index.get(name)
        if di:
            return call_def(c, e, name, di.value())
        var pi = c.prelude_ids.get(name)
        if pi:
            return call_prelude(c, e, name, pi.value())
        if name == "result" or name == "self" or c.ctx.param_index(name) >= 0:
            return fail_call(c, e, f, t"{name} is a value, not a function")
        var options = List[String]()
        for ns in ["mp", "cr"]:
            if (String(ns) + "." + name) in c.prelude_ids:
                options.append(String(ns) + "." + name)
        var hint = String()
        if len(options) > 0:
            var joined = String()
            for i in range(len(options)):
                joined += " or " if i else ""
                joined += options[i]
            hint = " (did you mean " + joined + "?)"
        return fail_call(c, e, f, t"unknown function {name}{hint}")
    if fk == .ATTR:
        var base = c.child(f, 0)
        var attr = c.text_of(f)
        var chain = chain_candidate(c, f)
        if chain != "":
            var fi = c.fn_index.get(chain)
            if fi:
                return call_spec_fn(c, e, chain, fi.value())
            var pi = c.prelude_ids.get(chain)
            if pi:
                return call_prelude(c, e, chain, pi.value())
            if c.kind_of(base) == .NAME:
                var bname = c.text_of(base)
                if bname == "mp" or bname == "cr":
                    c.set_type(base, ty.ANY_TYPE)
                    return fail_call(
                        c,
                        e,
                        f,
                        t"unknown function {chain}: {bname} holds {_namespace_what(bname)}: "
                        t"{_namespace_members(c, bname)}",
                    )
                var st = c.scalar(bname)
                if st >= 0:
                    c.set_type(base, st)
                    return call_set_ctor(c, e, st, attr)
            if c.ctx.extern_result >= 0 and chain.find(".") >= 0:
                var root = _root_name(c, f)
                if root != "" and c.scalar(root) < 0:
                    return call_extern(c, e, chain)
            var known_type_root = c.kind_of(base) == .NAME and (
                c.scalar(c.text_of(base)) >= 0 or c.text_of(base) in c.enum_index
            )
            if not known_type_root:
                return fail_call(c, e, f, t"unknown function {chain}")
        var vt = infer(c, base)
        if c.tkind(vt) == ty.MODEL:
            var mp = c.model_pos_of_type(vt)
            if mp >= 0:
                return call_observer(c, e, vt, mp, attr, False)
        if c.is_any(vt):
            return fail_call(c, e, f, String())
        return fail_call(
            c,
            e,
            f,
            t"{c.text(vt)} has no function {attr}: only observers of models and interfaces can be "
            t"called with '.'",
        )
    _ = infer(c, f)
    return fail_call(c, e, f, "only functions and observers can be called")


def call_extern(mut c: Checker, e: Int, chain: String) -> Int:
    """A call of a qualified callable the spec doesn't declare, in an observer's
    reading expression: it takes the observer's declared type."""
    var info = CallInfo(chain)
    infer_args(c, e, info)
    set_call_res(c, e, R_EXTERN, 0, -1, chain)
    c.set_type(c.child(e, 0), c.spec.types.fn_(info.args, List[String](), c.ctx.extern_result))
    return c.ctx.extern_result


def call_old(mut c: Checker, e: Int) -> Int:
    var f = c.child(e, 0)
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
    c.ctx.old_scope = len(c.ctx.loc_names)
    var info = CallInfo(String())
    infer_args(c, e, info)
    c.ctx.in_old = saved_in
    c.ctx.old_scope = saved_scope
    set_call_res(c, e, R_OLD, 0, -1, "old")
    var t = info.args[0] if len(info.args) == 1 else c.poison
    c.set_type(f, c.spec.types.fn_([t], List[String](), t))
    return t


struct Bound(Copyable, Movable):
    var names: List[String]
    var ptypes: List[Int]
    var atypes: List[Int]
    var nodes: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.ptypes = List[Int]()
        self.atypes = List[Int]()
        self.nodes = List[Int]()


def bind_args(
    mut c: Checker,
    e: Int,
    what: String,
    params: List[Param],
    ptypes: List[Int],
    info: CallInfo,
    mut out: Bound,
) -> Bool:
    if len(info.args) > len(params):
        c.error(e, t"{what} takes {len(params)} argument(s), but {len(info.args)} are given")
        return False
    var given = List[Bool](length=len(params), fill=False)
    var slot_type = List[Int](length=len(params), fill=0)
    var slot_node = List[Int](length=len(params), fill=0)
    for i in range(len(info.args)):
        given[i] = True
        slot_type[i] = info.args[i]
        slot_node[i] = info.nodes[i]
    for j in range(len(info.kw_keys)):
        var idx = -1
        for i in range(len(params)):
            if params[i].name == info.kw_keys[j]:
                idx = i
        if idx < 0:
            c.error(info.kw_nodes[j], t"{what} has no parameter named {info.kw_keys[j]}")
            return False
        if given[idx]:
            c.error(info.kw_nodes[j], t"argument {info.kw_keys[j]} of {what} is given twice")
            return False
        given[idx] = True
        slot_type[idx] = info.kw_types[j]
        slot_node[idx] = info.kw_nodes[j]
    var missing = String()
    for i in range(len(params)):
        if not given[i] and params[i].default == 0:
            missing += ", " if missing else ""
            missing += params[i].name
    if missing != "":
        c.error(e, t"{what} needs argument {missing}")
        return False
    for i in range(len(params)):
        if given[i]:
            out.names.append(params[i].name)
            out.ptypes.append(ptypes[i])
            out.atypes.append(slot_type[i])
            out.nodes.append(slot_node[i])
    return True


def bind_tvars(
    mut c: Checker,
    pattern: Int,
    actual: Int,
    mut names: List[String],
    mut types: List[Int],
    tvars: List[String],
):
    var pk = c.tkind(pattern)
    if pk == ty.TYPEVAR:
        var nm = c.spec.types.infos[pattern].name
        var known = False
        for t in tvars:
            if t == nm:
                known = True
        if known:
            if c.is_any(actual):
                return
            var prev = -1
            for i in range(len(names)):
                if names[i] == nm:
                    prev = i
            if prev < 0:
                names.append(nm)
                types.append(actual)
            else:
                var j = c.join(types[prev], actual)
                if j >= 0:
                    types[prev] = j
            return
    var ak = c.tkind(actual)
    if (pk == ty.LIST or pk == ty.OPTION or pk == ty.SET) and ak == pk:
        bind_tvars(c, c.arg(pattern, 0), c.arg(actual, 0), names, types, tvars)
    elif pk == ty.MAP and ak == ty.MAP:
        bind_tvars(c, c.arg(pattern, 0), c.arg(actual, 0), names, types, tvars)
        bind_tvars(c, c.arg(pattern, 1), c.arg(actual, 1), names, types, tvars)
    elif pk == ty.TUPLE and ak == ty.TUPLE:
        var ps = c.spec.types.infos[pattern].args.copy()
        var xs = c.spec.types.infos[actual].args.copy()
        for i in range(min(len(ps), len(xs))):
            bind_tvars(c, ps[i], xs[i], names, types, tvars)
    elif pk == ty.MODEL and ak == ty.MODEL:
        var ps = c.spec.types.infos[pattern].args.copy()
        var xs = c.spec.types.infos[actual].args.copy()
        for i in range(min(len(ps), len(xs))):
            bind_tvars(c, ps[i], xs[i], names, types, tvars)


def _fn_type(mut c: Checker, params: List[Param], result: Int) -> Int:
    var ptypes = List[Int]()
    var pnames = List[String]()
    for p in params:
        ptypes.append(p.type)
        pnames.append(p.name)
    return c.spec.types.fn_(ptypes, pnames, result)


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
    var ptypes = List[Int]()
    for p in params:
        ptypes.append(p.type)
    var bound = Bound()
    if not bind_args(c, e, name, params, ptypes, info, bound):
        return c.poison
    var sn = List[String]()
    var st = List[Int]()
    for i in range(len(bound.names)):
        bind_tvars(c, bound.ptypes[i], bound.atypes[i], sn, st, tparams)
    var ok = True
    for i in range(len(sn)):
        var bi = -1
        for j in range(len(tparams)):
            if tparams[j] == sn[i]:
                bi = j
        if bi >= 0 and not c.satisfies(st[i], bounds[bi]):
            c.error(e, t"{name}: {c.text(st[i])} does not satisfy {tparams[bi]}: {bounds[bi]}")
            ok = False
    for i in range(len(bound.names)):
        var target = c.spec.types.substitute(bound.ptypes[i], sn, st)
        if not assignable(c, bound.atypes[i], target, bound.nodes[i]):
            c.error(
                bound.nodes[i],
                t"argument {bound.names[i]} of {name} is a {c.text(target)}, but this is "
                t"{c.text(bound.atypes[i])}",
            )
            ok = False
    var un = List[String]()
    var ut = List[Int]()
    for tp in tparams:
        var solved = False
        for s in sn:
            if s == tp:
                solved = True
        if not solved:
            un.append(tp)
            ut.append(ty.ANY_TYPE)
    var r = c.spec.types.substitute(c.spec.types.substitute(result, sn, st), un, ut)
    return r if ok else c.poison


def call_spec_fn(mut c: Checker, e: Int, name: String, pos: Int) -> Int:
    var f = c.child(e, 0)
    var info = CallInfo(name)
    infer_args(c, e, info)
    var fn_owner = c.spec.fns[pos].owner
    set_call_res(c, e, R_SPEC_FN, pos, fn_owner, name)
    c.set_type(f, _fn_type(c, c.spec.fns[pos].params.copy(), c.spec.fns[pos].result))
    if not c.ctx.allow_spec_fn:
        var shadow = String()
        if name in c.prelude_ids:
            shadow = " (it shadows the prelude function of the same name)"
        c.error(
            e,
            t"{name}(...) calls the spec function {name}{shadow}; calls to spec functions are only "
            t"allowed in ensures, relates, invariant and aggregate clauses, where each one is a "
            t"planned implementation call",
        )
        return c.poison
    if c.fn_modifies[pos]:
        c.error(
            e,
            t"{name} modifies its arguments, so it cannot be called in a clause: a planned call must "
            t"leave its inputs unchanged",
        )
        return c.poison
    return check_declared_call(
        c,
        e,
        name,
        c.spec.fns[pos].params.copy(),
        c.spec.fns[pos].tparams.copy(),
        c.spec.fns[pos].bounds.copy(),
        c.spec.fns[pos].result,
        info,
    )


def call_def(mut c: Checker, e: Int, name: String, pos: Int) -> Int:
    var f = c.child(e, 0)
    var info = CallInfo(name)
    infer_args(c, e, info)
    set_call_res(c, e, R_DEF, pos, -1, name)
    if c.cur_def >= 0:
        c.def_edges[c.cur_def].append(pos)
    c.set_type(f, _fn_type(c, c.spec.defs[pos].params.copy(), c.spec.defs[pos].result))
    return check_declared_call(
        c,
        e,
        name,
        c.spec.defs[pos].params.copy(),
        c.spec.defs[pos].tparams.copy(),
        c.spec.defs[pos].bounds.copy(),
        c.spec.defs[pos].result,
        info,
    )


def _plural(n: Int) -> String:
    return "" if n == 1 else "s"


def call_prelude(mut c: Checker, e: Int, name: String, pid: Int) -> Int:
    var f = c.child(e, 0)
    var sig = c.prelude_sigs[pid].copy()
    var info = CallInfo(name)
    infer_args(c, e, info)
    set_call_res(c, e, R_PRELUDE, pid, -1, name)
    for tn in c.children(c.child(e, 1)):
        info.targs.append(resolve_type(c, tn))
    var ok = True
    var ntargs = len(info.targs)
    if sig.type_args != ntargs and not (sig.optional_type_args and ntargs == 0):
        if sig.type_args > 0 and ntargs == 0:
            c.error(e, t"{name} needs a type argument: {sig.shape}")
        elif sig.type_args == 0:
            c.error(e, t"{name} takes no type arguments: {sig.shape}")
        else:
            c.error(e, t"{name} takes {sig.type_args} type argument(s): {sig.shape}")
        ok = False
    if len(info.args) < sig.lo or len(info.args) > sig.hi:
        c.error(e, t"{name} takes {sig.lo} argument{_plural(sig.lo)}: {sig.shape}")
        ok = False
    for j in range(len(info.kw_keys)):
        if not (sig.has_kwargs and (info.kw_keys[j] == "float" or info.kw_keys[j] == "order")):
            c.error(
                info.kw_nodes[j],
                t"{name} has no argument named {info.kw_keys[j]}: {sig.shape}",
            )
            ok = False
    if not ok:
        c.set_type(f, c.poison)
        return c.poison
    var t = type_prelude(c, sig, info)
    if c.sig_msg != "":
        var where = e
        if c.sig_arg >= 0 and c.sig_arg < len(info.nodes):
            where = info.nodes[c.sig_arg]
        elif c.sig_key != "":
            for j in range(len(info.kw_keys)):
                if info.kw_keys[j] == c.sig_key:
                    where = info.kw_nodes[j]
        c.error(where, c.sig_msg.copy())
        t = c.poison
    c.set_type(f, c.spec.types.fn_(info.args, List[String](), t))
    return t


def call_set_ctor(mut c: Checker, e: Int, st: Int, attr: String) -> Int:
    var f = c.child(e, 0)
    var stext = c.text(st)
    if attr != "range" and attr != "pattern":
        var msg: String
        if c.type_constant(st, attr) >= 0:
            msg = stext + "." + attr + " is a constant, not a function: write " + stext + "." + attr
        else:
            msg = stext + " has no function " + attr
        return fail_call(c, e, f, msg)
    if not c.has_set_constructor(st, attr):
        return fail_call(c, e, f, t"{stext} has no {attr}(...) set")
    set_call_res(c, e, R_SET_CTOR, st, -1, attr)
    var ok = c.ctx.kind == K_PARTITION_SET
    if not ok:
        c.error(
            e,
            t"{stext}.{attr}(...) is a partition set: it only appears in a partition class of a "
            t"{stext} parameter",
        )
    var kids = c.children(e)
    var nargs = len(kids) - 2
    var has_kw = False
    for i in range(2, len(kids)):
        if c.text_of(kids[i]) != "":
            has_kw = True
    var arg_types = List[Int]()
    if attr == "range":
        if nargs != 2 or has_kw:
            c.error(
                e,
                t"{stext}.range takes two bounds: {stext}.range(a, b), half-open, with none for an open "
                t"end",
            )
            ok = False
        for i in range(2, len(kids)):
            var a = c.child(kids[i], 0)
            if c.kind_of(a) == .NONE:
                var ot = c.spec.types.option_of(ty.ANY_TYPE)
                c.set_type(a, ot)
                arg_types.append(ot)
                continue
            var t = infer(c, a)
            arg_types.append(t)
            if not c.is_numeric(t) and not c.is_any(t):
                c.error(a, t"a bound of {stext}.range must be a number or none, not {c.text(t)}")
                ok = False
    else:
        if nargs != 1 or has_kw or c.kind_of(c.child(kids[2], 0)) != .STR:
            c.error(
                e,
                stext
                + '.pattern takes one string literal of bits, e.g. '
                + stext
                + '.pattern("0 1* 0")',
            )
            ok = False
        for i in range(2, len(kids)):
            arg_types.append(infer(c, c.child(kids[i], 0)))
    var set_t = c.spec.types.set_of(st)
    c.set_type(f, c.spec.types.fn_(arg_types, List[String](), set_t))
    return set_t if ok else c.poison


def call_observer(
    mut c: Checker, e: Int, mt: Int, model: Int, name: String, is_field: Bool
) -> Int:
    var f = c.child(e, 0)
    var mname = c.spec.models[model].name
    var oi = c.observer_pos(model, name)
    if oi < 0:
        return fail_call(
            c,
            e,
            f,
            t"{mname} has no observer {name} (its observers: {c.observer_names(model)})",
        )
    var info = CallInfo(name)
    infer_args(c, e, info)
    var kind = R_FIELD if is_field else R_OBSERVER
    set_call_res(c, e, kind, oi, model, name)
    var params = c.spec.models[model].observers[oi].params.copy()
    var declared = c.spec.models[model].observers[oi].type
    var tparams = c.spec.models[model].tparams.copy()
    var targs = c.spec.types.infos[mt].args.copy()
    var use_env = len(tparams) > 0 and len(tparams) == len(targs)
    var result = declared
    if use_env:
        result = c.spec.types.substitute(declared, tparams, targs)
    var ptypes = List[Int]()
    var pnames = List[String]()
    for p in params:
        var pt = p.type
        if use_env:
            pt = c.spec.types.substitute(pt, tparams, targs)
        ptypes.append(pt)
        pnames.append(p.name)
    c.set_type(f, c.spec.types.fn_(ptypes, pnames, result))
    if len(params) == 0:
        c.error(
            e,
            String(name, " is a field of ", mname, " and takes no arguments: write ", ("" if is_field else "x."), name),
        )
        return c.poison
    var bound = Bound()
    if not bind_args(c, e, mname + "." + name, params, ptypes, info, bound):
        return c.poison
    var ok = True
    for i in range(len(bound.names)):
        if not assignable(c, bound.atypes[i], bound.ptypes[i], bound.nodes[i]):
            c.error(
                bound.nodes[i],
                t"argument {bound.names[i]} of {mname}.{name} is a {c.text(bound.ptypes[i])}, but this is "
                t"{c.text(bound.atypes[i])}",
            )
            ok = False
    return result if ok else c.poison


# -- attributes, indexing and literals --------------------------------------------


def infer_attr(mut c: Checker, e: Int) -> Int:
    var base = c.child(e, 0)
    var attr = c.text_of(e)
    var chain = chain_candidate(c, e)
    if chain != "":
        var ci = c.const_index.get(chain)
        if ci:
            ensure_const(c, ci.value())
            c.resolve(e, R_CONST, ci.value(), -1, chain)
            return c.spec.consts[ci.value()].type
        if c.kind_of(base) == .NAME:
            var bname = c.text_of(base)
            if bname == "mp" or bname == "cr":
                c.set_type(base, ty.ANY_TYPE)
                if chain in c.prelude_ids:
                    c.error(e, t"{chain} is a function: call it as {chain}(x)")
                else:
                    c.error(e, t"unknown function {chain}")
                return c.poison
            var st = c.scalar(bname)
            if st >= 0:
                c.set_type(base, st)
                return type_const(c, e, st, attr)
            var en = c.enum_index.get(bname)
            if en:
                c.set_type(base, en.value())
                var names = c.spec.types.infos[en.value()].names.copy()
                for j in range(len(names)):
                    if names[j] == attr:
                        c.resolve(e, R_ENUM_MEMBER, j, en.value(), attr)
                        return en.value()
                c.error(e, t"enum {bname} has no member {attr}")
                return c.poison
    var vt = infer(c, base)
    var k = c.tkind(vt)
    if k == ty.MODEL:
        var mp = c.model_pos_of_type(vt)
        if mp >= 0:
            var oi = c.observer_pos(mp, attr)
            if oi < 0:
                c.error(
                    e,
                    String(c.spec.models[mp].name, " has no observer ", attr, " (its observers: ", c.observer_names(mp), ")"),
                )
                return c.poison
            if len(c.spec.models[mp].observers[oi].params) > 0:
                var names = String()
                for j in range(len(c.spec.models[mp].observers[oi].params)):
                    names += ", " if j else ""
                    names += c.spec.models[mp].observers[oi].params[j].name
                c.error(e, t"{attr} takes arguments: {attr}({names})")
                return c.poison
            c.resolve(e, R_OBSERVER, oi, mp, attr)
            return c.observer_type(vt, mp, oi)
    if k == ty.RECORD:
        var names = c.spec.types.infos[vt].names.copy()
        for j in range(len(names)):
            if names[j] == attr:
                c.resolve(e, R_RECORD_FIELD, j, vt, attr)
                return c.arg(vt, j)
        c.error(e, t"record {c.text(vt)} has no field {attr}")
        return c.poison
    if k == ty.QERR:
        if attr == "steps" or attr == "nans":
            c.resolve(e, R_QERR_PART, 0, -1, attr)
            return c.int_
        c.error(e, t"qerr has no part {attr}: its parts are steps and nans")
        return c.poison
    if k == ty.ANY:
        return c.poison
    if k == ty.TUPLE:
        c.error(e, "tuple fields are numbered: .0, .1, ...")
        return c.poison
    c.error(e, t"{c.text(vt)} has no field {attr}")
    return c.poison


def type_const(mut c: Checker, e: Int, st: Int, attr: String) -> Int:
    var stext = c.text(st)
    if c.has_set_constructor(st, attr):
        c.error(e, t"{stext}.{attr} is called: {stext}.{attr}(...)")
        return c.poison
    var t = c.type_constant(st, attr)
    if t < 0:
        var names = String()
        var consts = c.constants_of(st)
        for i in range(len(consts)):
            names += ", " if i else ""
            names += stext + "." + consts[i]
        c.error(
            e,
            String(stext, " has no constant ", attr, ((" (available: " + names + ")") if len(consts) > 0 else "")),
        )
        return c.poison
    c.resolve(e, R_TYPE_CONST, st, -1, attr)
    if c.tkind(t) == ty.SET and c.ctx.kind != K_PARTITION_SET:
        var hint = String()
        if c.tkind(st) == ty.FLOAT:
            hint = classifier_hint(attr)
        c.error(
            e,
            String(stext, ".", attr, " is a partition set: it only appears in a partition class of a ", stext, " parameter", ((("; in a clause, test the value with " + hint)) if hint else "")),
        )
        return c.poison
    return t


def infer_tuple_index(mut c: Checker, e: Int) -> Int:
    var vt = infer(c, c.child(e, 0))
    var digits = c.text_of(e)
    var index = 1 << 40
    try:
        index = Int(digits)
    except:
        pass
    if c.tkind(vt) == ty.TUPLE:
        if index < len(c.spec.types.infos[vt].args):
            return c.arg(vt, index)
        c.error(e, t".{digits} is out of range for {c.text(vt)}")
        return c.poison
    if c.is_any(vt):
        return c.poison
    c.error(e, t".{digits} needs a tuple, but the value is {c.text(vt)}")
    return c.poison


def infer_index(mut c: Checker, e: Int) -> Int:
    var value = c.child(e, 0)
    var index = c.child(e, 1)
    var vt = infer(c, value)
    var it = infer(c, index)
    var k = c.tkind(vt)
    if k == ty.MAP:
        var key = c.arg(vt, 0)
        var bad = c.non_eq_part(key)
        if bad >= 0:
            c.error(e, eq_message(c, "map lookup", key, bad))
        elif c.join(it, key) < 0 and not c.is_any(it):
            c.error(index, t"the keys of {c.text(vt)} are {c.text(key)}, not {c.text(it)}")
        return c.arg(vt, 1)
    if k == ty.LIST or k == ty.STRING or k == ty.LITERAL or k == ty.BYTES:
        want_int(c, index, it, "an index")
        if k == ty.LIST:
            return c.arg(vt, 0)
        return c.int_ if k == ty.BYTES else c.string_
    if k == ty.ANY:
        return c.poison
    if k == ty.TUPLE:
        c.error(e, "tuple fields are selected with .0, .1, ..., not [i]")
        return c.poison
    c.error(e, t"cannot index a {c.text(vt)}")
    return c.poison


def infer_slice(mut c: Checker, e: Int) -> Int:
    var vt = infer(c, c.child(e, 0))
    want_int(c, c.child(e, 1), infer(c, c.child(e, 1)), "a slice bound")
    want_int(c, c.child(e, 2), infer(c, c.child(e, 2)), "a slice bound")
    var k = c.tkind(vt)
    if k == ty.LIST or k == ty.BYTES:
        return vt
    if c.is_stringish(vt):
        return c.string_
    if k == ty.ANY:
        return c.poison
    c.error(e, t"cannot slice a {c.text(vt)}")
    return c.poison


def infer_list(mut c: Checker, e: Int) -> Int:
    var elem = ty.ANY_TYPE
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


def infer_tuple(mut c: Checker, e: Int) -> Int:
    var elems = List[Int]()
    for x in c.children(e):
        elems.append(infer(c, x))
    return c.spec.types.tuple_of(elems)


def infer_set(mut c: Checker, e: Int, expected: Int) -> Int:
    if c.ctx.kind != K_PARTITION_SET or expected < 0 or c.tkind(expected) != ty.SET:
        for x in c.children(e):
            _ = infer(c, x)
        c.error(
            e,
            "{...} is a partition set: it only appears in a partition class of a"
            " fixed-width parameter",
        )
        return c.poison
    var elem = c.arg(expected, 0)
    var ek = c.tkind(elem)
    var ok = True
    for x in c.children(e):
        var t = infer(c, x)
        if c.is_any(t):
            continue
        var good: Bool
        if ek == ty.FLOAT:
            good = c.is_numeric(t)
        elif ek == ty.FIXED_INT:
            good = c.is_integer(t)
        else:
            good = c.tkind(t) == ty.BOOL
        if not good:
            c.error(
                x,
                String("a member of a set of ", c.text(elem), " values must be a ", ("number" if c.is_numeric(elem) else c.text(elem)), ", not ", c.text(t)),
            )
            ok = False
    return expected if ok else c.poison
