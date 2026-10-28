"""Why a boolean clause has its value: source text and value text of the
subexpressions that matter, following the failing structure."""

from check import types as ty
from check.spec import Spec
from syntax.ast import Op
from wire.value import Value

from .core import is_old_call, set_members, type_kind, value_of
from .env import Env, Run
from .host import EvalHost
from .numbers import elements, show
from .text import located, short, source_text


comptime VALUE_CHARS = 300
"""The most bytes of a value's text an explanation shows."""


struct Outcome(Copyable):
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
        return self.is_any_bool() and self.value.as_bool() == want

    def is_any_bool(self) -> Bool:
        return self.ok and self.value.kind == .BOOL

    def text(self) -> String:
        return show(self.value) if self.ok else self.note.copy()


struct Explanation(Movable):
    """The (source text, value text) pairs found so far: at most `limit`, each source
    text once."""

    var pairs: List[Tuple[String, String]]
    var limit: Int

    def __init__(out self, limit: Int):
        self.pairs = []
        self.limit = limit

    def full(self) -> Bool:
        return len(self.pairs) >= self.limit

    def into_pairs(deinit self) -> List[Tuple[String, String]]:
        return self.pairs^

    def accepts(self, text: String) -> Bool:
        return not self.full() and not any([pair[0] == text for pair in self.pairs])

    def add_text(mut self, text: String, shown: String):
        if self.accepts(text):
            self.pairs.append((text.copy(), short(shown, VALUE_CHARS)))


def outcome_of[
    H: EvalHost
](spec: Spec, e: Int, env: Env, mut run: Run, mut host: H) -> Outcome:
    """The value of `e`, or why it has none. A failure leaves `run` as it was."""
    var base = len(run.locals)
    try:
        return Outcome(value_of(spec, e, env, run, host))
    except err:
        var text = String(err)
        var skipped = False
        if case .Some(failure) = run.failure:
            text = located(spec, failure.node, failure.message)
            skipped = failure.skipped
        run.locals.shrink(base)
        run.failure = None
        return Outcome(String("skipped: " if skipped else "error: ", text))


def is_literal(spec: Spec, e: Int) -> Bool:
    ref n = spec.ast.nodes[e]
    match n.kind:
        case .NUM | .STR | .BOOL | .NONE:
            return True
        case .UNARY:
            return n.op == .NEG and is_literal(spec, n.children[0])
        case .LIST | .TUPLE:
            return all([is_literal(spec, child) for child in n.children])
        case _:
            return False


def _operands(spec: Spec, e: Int, op: Op) -> List[Int]:
    """The operands of the run of `op` at `e`, left to right: `a and b and c` has three."""
    ref n = spec.ast.nodes[e]
    if n.kind == .BINARY and n.op == op:
        return _operands(spec, n.children[0], op) + _operands(spec, n.children[1], op)
    return [e]


def add[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, env: Env, mut run: Run, mut host: H):
    var text = source_text(spec, e)
    if explanation.accepts(text):
        explanation.add_text(text, outcome_of(spec, e, env, run, host).text())


def add_known(mut explanation: Explanation, spec: Spec, e: Int, outcome: Outcome):
    explanation.add_text(source_text(spec, e), outcome.text())


def _add_unless_literal[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, env: Env, mut run: Run, mut host: H):
    if not is_literal(spec, e):
        add(explanation, spec, e, env, run, host)


def _add_args[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, call: Int, env: Env, mut run: Run, mut host: H):
    for arg in spec.ast.nodes[call].children[2:]:
        _add_unless_literal(explanation, spec, spec.ast.child(arg, 0), env, run, host)


def operand[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, env: Env, mut run: Run, mut host: H):
    """An operand's value, with the values that feed it when that helps."""
    if is_literal(spec, e):
        return
    ref n = spec.ast.nodes[e]
    match n.kind:
        case .CALL:
            if not is_old_call(spec, e):
                _add_args(explanation, spec, e, env, run, host)
        case .INDEX:
            add(explanation, spec, n.children[0], env, run, host)
            _add_unless_literal(explanation, spec, n.children[1], env, run, host)
        case .SLICE:
            add(explanation, spec, n.children[0], env, run, host)
            for bound in n.children[1:]:
                _add_unless_literal(explanation, spec, bound, env, run, host)
        case .IF:
            add(explanation, spec, n.children[0], env, run, host)
        case _:
            pass
    add(explanation, spec, e, env, run, host)


def walk[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    if explanation.full():
        return
    ref n = spec.ast.nodes[e]
    # TODO: a guarded case of an `__enum` match runs on into the cases after it in Mojo
    # 1.2, so each guarded case returns.
    match n.kind:
        case .BINARY if n.op in [Op.AND, Op.OR]:
            walk_chain(explanation, spec, e, value, env, run, host)
            return
        case .BINARY if n.op == .IMPLIES:
            walk_implies(explanation, spec, e, value, env, run, host)
            return
        case .BINARY if n.op in [Op.EQ, Op.NE, Op.LT, Op.LE, Op.GT, Op.GE, Op.IN]:
            operand(explanation, spec, n.children[0], env, run, host)
            operand(explanation, spec, n.children[1], env, run, host)
            return
        case .UNARY if n.op == .NOT:
            var inner = outcome_of(spec, n.children[0], env, run, host)
            if inner.is_any_bool():
                walk(explanation, spec, n.children[0], inner, env, run, host)
            else:
                add_known(explanation, spec, n.children[0], inner)
            return
        case .IF:
            var condition = outcome_of(spec, n.children[0], env, run, host)
            add_known(explanation, spec, n.children[0], condition)
            if condition.is_any_bool():
                var branch = n.children[1] if condition.value.as_bool() else n.children[2]
                walk(explanation, spec, branch, value, env, run, host)
        case .LET:
            walk_let(explanation, spec, e, value, env, run, host)
        case .COMPREHENSION if n.op in [Op.ALL, Op.EXISTS]:
            walk_quantifier(explanation, spec, e, value, env, run, host)
            return
        case .CALL if not is_old_call(spec, e):
            _add_args(explanation, spec, e, env, run, host)
            add_known(explanation, spec, e, value)
            return
        case .BOOL:
            pass
        case _:
            add_known(explanation, spec, e, value)


def walk_implies[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    ref n = spec.ast.nodes[e]
    if value.is_bool(False):
        # A false implication has a true left side, so its right side explains it.
        var right = outcome_of(spec, n.children[1], env, run, host)
        walk(explanation, spec, n.children[1], right, env, run, host)
        return
    var left = outcome_of(spec, n.children[0], env, run, host)
    if left.is_bool(False):
        walk(explanation, spec, n.children[0], left, env, run, host)
    elif not left.ok:
        add_known(explanation, spec, n.children[0], left)
    else:
        var right = outcome_of(spec, n.children[1], env, run, host)
        walk(explanation, spec, n.children[1], right, env, run, host)


def walk_chain[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    """`a and b and c`, or the same with `or`: the operand that decides it, else each one."""
    var op = spec.ast.nodes[e].op
    # A false `and` is decided by a false operand, a true `or` by a true one.
    var decided = value.is_bool(op == .OR)
    for part in _operands(spec, e, op):
        var v = outcome_of(spec, part, env, run, host)
        if not v.is_any_bool():
            add_known(explanation, spec, part, v)
            return
        if not decided:
            walk(explanation, spec, part, v, env, run, host)
        elif v.value.as_bool() == value.value.as_bool():
            walk(explanation, spec, part, v, env, run, host)
            return


def walk_let[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    ref n = spec.ast.nodes[e]
    var bound = outcome_of(spec, n.children[0], env, run, host)
    if not bound.ok:
        add_known(explanation, spec, n.children[0], bound)
        return
    explanation.add_text(n.text, bound.text())
    var base = len(run.locals)
    run.push(e, bound.value.copy())
    var body = outcome_of(spec, n.children[1], env, run, host)
    walk(explanation, spec, n.children[1], body, env, run, host)
    run.locals.shrink(base)


def walk_quantifier[
    H: EvalHost
](mut explanation: Explanation, spec: Spec, e: Int, value: Outcome, env: Env, mut run: Run, mut host: H):
    """A false `all` or a true `exists`: the first element that decides it."""
    ref n = spec.ast.nodes[e]
    var decided = value.is_bool(n.op == .EXISTS)
    var iterable = n.children[0]
    var is_set = type_kind(spec, iterable) == ty.SET
    var collection = Outcome(Value.none()) if is_set else outcome_of(spec, iterable, env, run, host)
    if not decided or not collection.ok:
        if not is_set and not is_literal(spec, iterable):
            add_known(explanation, spec, iterable, collection)
        return
    var items: List[Value]
    try:
        items = set_members(spec, iterable) if is_set else elements(collection.value, String(t"{n.op}(...)"))
    except err:
        add_known(explanation, spec, iterable, Outcome(String("error: ", err)))
        return
    var base = len(run.locals)
    run.push(e, Value.none())
    for item in items:
        run.set_top(item.copy())
        var v = outcome_of(spec, n.children[1], env, run, host)
        if v.ok and not v.is_bool(value.value.as_bool()):
            continue
        explanation.add_text(n.text, show(item))
        if v.ok:
            walk(explanation, spec, n.children[1], v, env, run, host)
        else:
            add_known(explanation, spec, n.children[1], v)
        break
    run.locals.shrink(base)
