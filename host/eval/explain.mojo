"""Why a boolean clause has its value: source text and value text of the
subexpressions that matter, following the failing structure."""

from check import types as ty
from check.spec import Spec, R_OLD
from syntax import ast
from wire import value as wv
from wire.value import Value

from .core import ev, tkind, set_members
from .env import Env, Run
from .host import EvalHost
from .numbers import elements, show
from .text import located, short, source_text


comptime VALUE_CHARS = 300


struct Outcome(Copyable, Movable):
    """The result of evaluating a subexpression while explaining: a value, or the
    reason it has none."""

    var ok: Bool
    var value: Value
    var note: String

    def __init__(out self, var value: Value):
        self.ok = True
        self.value = value^
        self.note = String()

    def __init__(out self, var note: String):
        self.ok = False
        self.value = Value.none()
        self.note = note^

    def is_bool(self, want: Bool) -> Bool:
        return self.ok and self.value.kind == wv.BOOL and self.value.as_bool() == want

    def is_any_bool(self) -> Bool:
        return self.ok and self.value.kind == wv.BOOL

    def text(self) -> String:
        return self.note.copy() if not self.ok else show(self.value)


struct Explainer(Movable):
    var pairs: List[Tuple[String, String]]
    var seen: List[String]
    var limit: Int

    def __init__(out self, limit: Int):
        self.pairs = []
        self.seen = []
        self.limit = limit

    def full(self) -> Bool:
        return len(self.pairs) >= self.limit

    def into_pairs(deinit self) -> List[Tuple[String, String]]:
        return self.pairs^

    def accepts(self, text: String) -> Bool:
        return text not in self.seen and not self.full()

    def add_text(mut self, text: String, shown: String):
        if self.accepts(text):
            self.seen.append(text.copy())
            self.pairs.append((text.copy(), short(shown, VALUE_CHARS)))


def outcome_of[H: EvalHost](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) -> Outcome:
    var base = len(run.locals)
    try:
        return Outcome(ev(spec, e, env, run, host))
    except err:
        var skipped = run.skipped
        var text = String(err)
        if run.err_node >= 0:
            text = located(spec, run.err_node, run.err_message)
        run.truncate(base)
        run.err_node = -1
        run.skipped = False
        return Outcome(String("skipped: " if skipped else "error: ", text))


def is_literal(spec: Spec, e: Int) -> Bool:
    ref n = spec.ast.nodes[e]
    var k = n.kind
    if k == .NUM or k == .STR or k == .BOOL or k == .NONE:
        return True
    if k == .UNARY and n.op == .NEG:
        return is_literal(spec, n.children[0])
    if k == .LIST or k == .TUPLE:
        return all([is_literal(spec, kid) for kid in n.children])
    return False


def chain(spec: Spec, e: Int, op: ast.Op, mut out: List[Int]):
    ref n = spec.ast.nodes[e]
    if n.kind == .BINARY and n.op == op:
        chain(spec, n.children[0], op, out)
        chain(spec, n.children[1], op, out)
    else:
        out.append(e)


def is_old(spec: Spec, e: Int) -> Bool:
    var r = spec.resolutions.get(e)
    return r is not None and r.value().kind == R_OLD


def add[H: EvalHost](mut ex: Explainer, spec: Spec, e: Int, env: Env, mut run: Run, mut host: H):
    var text = source_text(spec, e)
    if ex.accepts(text):
        ex.add_text(text, outcome_of(spec, e, env, run, host).text())


def add_known(mut ex: Explainer, spec: Spec, e: Int, o: Outcome):
    ex.add_text(source_text(spec, e), o.text())


def operand[H: EvalHost](mut ex: Explainer, spec: Spec, e: Int, env: Env, mut run: Run, mut host: H):
    """An operand's value, with the values that feed it when that helps."""
    if is_literal(spec, e):
        return
    ref n = spec.ast.nodes[e]
    if n.kind == .CALL and not is_old(spec, e):
        for k in range(2, len(n.children)):
            var a = spec.ast.nodes[n.children[k]].children[0]
            if not is_literal(spec, a):
                add(ex, spec, a, env, run, host)
    elif n.kind == .INDEX:
        add(ex, spec, n.children[0], env, run, host)
        if not is_literal(spec, n.children[1]):
            add(ex, spec, n.children[1], env, run, host)
    elif n.kind == .SLICE:
        add(ex, spec, n.children[0], env, run, host)
        for j in range(1, 3):
            if not is_literal(spec, n.children[j]):
                add(ex, spec, n.children[j], env, run, host)
    elif n.kind == .IF:
        add(ex, spec, n.children[0], env, run, host)
    add(ex, spec, e, env, run, host)


def walk[H: EvalHost](mut ex: Explainer, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    if ex.full():
        return
    ref n = spec.ast.nodes[e]
    if n.kind == .BINARY:
        var op = n.op
        if op == .AND or op == .OR:
            walk_chain(ex, spec, e, value, env, run, host)
            return
        if op == .IMPLIES:
            if value.is_bool(False):
                var r = outcome_of(spec, n.children[1], env, run, host)
                walk(ex, spec, n.children[1], r, env, run, host)
                return
            var left = outcome_of(spec, n.children[0], env, run, host)
            if left.is_bool(False):
                walk(ex, spec, n.children[0], left, env, run, host)
                return
            if not left.ok:
                add_known(ex, spec, n.children[0], left)
                return
            var right = outcome_of(spec, n.children[1], env, run, host)
            walk(ex, spec, n.children[1], right, env, run, host)
            return
        if (
            op == .EQ or op == .NE or op == .LT or op == .LE
            or op == .GT or op == .GE or op == .IN
        ):
            operand(ex, spec, n.children[0], env, run, host)
            operand(ex, spec, n.children[1], env, run, host)
            return
    if n.kind == .UNARY and n.op == .NOT:
        var inner = outcome_of(spec, n.children[0], env, run, host)
        if not inner.is_any_bool():
            add_known(ex, spec, n.children[0], inner)
            return
        walk(ex, spec, n.children[0], inner, env, run, host)
        return
    if n.kind == .IF:
        var cond = outcome_of(spec, n.children[0], env, run, host)
        add_known(ex, spec, n.children[0], cond)
        if cond.is_any_bool():
            var branch = n.children[1] if cond.value.as_bool() else n.children[2]
            walk(ex, spec, branch, value, env, run, host)
        return
    if n.kind == .LET:
        walk_let(ex, spec, e, value, env, run, host)
        return
    if n.kind == .COMPREHENSION and (n.op == .ALL or n.op == .EXISTS):
        walk_quantifier(ex, spec, e, value, env, run, host)
        return
    if n.kind == .CALL and not is_old(spec, e):
        for k in range(2, len(n.children)):
            var a = spec.ast.nodes[n.children[k]].children[0]
            if not is_literal(spec, a):
                add(ex, spec, a, env, run, host)
        add_known(ex, spec, e, value)
        return
    if n.kind == .BOOL:
        return
    add_known(ex, spec, e, value)


def walk_chain[H: EvalHost](mut ex: Explainer, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    var op = spec.ast.nodes[e].op
    var parts = List[Int]()
    chain(spec, e, op, parts)
    var decisive = value.is_bool(False) if op == .AND else value.is_bool(True)
    for part in parts:
        var v = outcome_of(spec, part, env, run, host)
        if not v.is_any_bool():
            add_known(ex, spec, part, v)
            return
        if decisive:
            if v.value.as_bool() == value.value.as_bool():
                walk(ex, spec, part, v, env, run, host)
                return
        else:
            walk(ex, spec, part, v, env, run, host)


def walk_let[H: EvalHost](mut ex: Explainer, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    ref n = spec.ast.nodes[e]
    var bound = outcome_of(spec, n.children[0], env, run, host)
    if not bound.ok:
        add_known(ex, spec, n.children[0], bound)
        return
    ex.add_text(n.text, bound.text())
    var base = len(run.locals)
    run.push(e, bound.value.copy())
    var body = outcome_of(spec, n.children[1], env, run, host)
    walk(ex, spec, n.children[1], body, env, run, host)
    run.truncate(base)


def walk_quantifier[H: EvalHost](mut ex: Explainer, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    ref n = spec.ast.nodes[e]
    var witness = (n.op == .ALL and value.is_bool(False)) or (
        n.op == .EXISTS and value.is_bool(True)
    )
    var iterable = n.children[0]
    var is_set = tkind(spec, iterable) == ty.SET
    var coll = Outcome(Value.none())
    if not is_set:
        coll = outcome_of(spec, iterable, env, run, host)
    if not witness or not coll.ok:
        if not is_literal(spec, iterable) and not is_set:
            add_known(ex, spec, iterable, coll)
        return
    var items: List[Value]
    try:
        if is_set:
            items = set_members(spec, iterable)
        else:
            items = elements(coll.value, String(n.op, "(...)"))
    except err:
        add_known(ex, spec, iterable, Outcome(String("error: ", err)))
        return
    var base = len(run.locals)
    run.push(e, Value.none())
    for item in items:
        run.set_top(item.copy())
        var v = outcome_of(spec, n.children[1], env, run, host)
        if not v.ok or v.is_bool(value.value.as_bool()):
            ex.add_text(n.text, show(item))
            if not v.ok:
                add_known(ex, spec, n.children[1], v)
            else:
                walk(ex, spec, n.children[1], v, env, run, host)
            break
    run.truncate(base)
