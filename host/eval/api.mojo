"""The evaluator's entry points: evaluate, judge, snapshot_olds, observe_with,
explain and class_holds."""

from check import types as ty
from check.spec import Spec, R_OLD
from partitions.compile import compile_set_aliased
from sets import BitSet, SetContext
from syntax import ast
from wire import value as wv
from wire.value import Value

from .coerce import bits_of_value, fit
from .core import ev, tkind
from .env import Env, Old, Run
from .explain import Explainer, add_known, outcome_of, walk
from .host import EvalHost
from .numbers import show
from .text import located


comptime EXPLAIN_LIMIT = 16

comptime J_TRUE = 0
comptime J_FALSE = 1
comptime J_ERROR = 2
comptime J_SKIP = 3


struct Judgment(Copyable, Movable):
    """The outcome of judging a clause: true, false, an error or a skip."""

    var kind: Int
    var message: String
    """An error's message or a skip's cause, without the location."""
    var node: Int
    """The node the error or skip is attributed to, or 0."""

    def __init__(out self, kind: Int, var message: String = String(), node: Int = 0):
        self.kind = kind
        self.message = message^
        self.node = node

    def is_true(self) -> Bool:
        return self.kind == J_TRUE

    def is_false(self) -> Bool:
        return self.kind == J_FALSE

    def is_error(self) -> Bool:
        return self.kind == J_ERROR

    def is_skip(self) -> Bool:
        return self.kind == J_SKIP

    def describe(self, spec: Spec) -> String:
        """`true`, `false`, or `error: message (at ...)`."""
        if self.kind == J_TRUE:
            return "true"
        if self.kind == J_FALSE:
            return "false"
        var prefix = "error: " if self.kind == J_ERROR else "skip: "
        return String(prefix, located(spec, self.node, self.message) if self.node > 0 else self.message)


def evaluate[
    H: EvalHost
](spec: Spec, node: Int, env: Env, mut host: H) raises -> Value:
    """The value of the checked expression at `node`. An error carries the location
    and source text of the expression that failed."""
    var run = Run()
    try:
        return ev(spec, node, env, run, host)
    except err:
        if run.err_node < 0:
            raise err^
        raise Error(located(spec, run.err_node, run.err_message))


def judge[
    H: EvalHost
](spec: Spec, clause: Int, env: Env, mut host: H) -> Judgment:
    """Does the clause hold? A `raises` or `may_raise` clause judges its `when` condition."""
    ref c = spec.clauses[clause]
    if c.expr == 0:
        if c.kind == .RAISES or c.kind == .MAY_RAISE:
            return Judgment(J_TRUE)
        return Judgment(
            J_ERROR, String(t"{c.id}: a {c.kind} clause has no condition to evaluate"), c.node
        )
    var run = Run()
    try:
        var v = ev(spec, c.expr, env, run, host)
        if v.kind != wv.BOOL:
            return Judgment(J_ERROR, String(t"the clause must evaluate to a bool, but it is {show(v)}"), c.expr)
        return Judgment(J_TRUE if v.as_bool() else J_FALSE)
    except err:
        var node = run.err_node if run.err_node >= 0 else c.expr
        var message = run.err_message.copy() if run.err_node >= 0 else String(err)
        return Judgment(J_SKIP if run.skipped else J_ERROR, message^, node)


def collect_olds(spec: Spec, root: Int, mut out: List[Int]):
    """The `old(...)` calls below `root`, in source order."""
    var stack: List[Int] = [root]
    while len(stack) > 0:
        var n = stack.pop()
        ref node = spec.ast.nodes[n]
        if node.kind == .CALL:
            var r = spec.resolutions.get(n)
            if r is not None and r.value().kind == R_OLD:
                out.append(n)
                continue
        for kid in reversed(node.children):
            stack.append(kid)


def snapshot_olds[
    H: EvalHost
](spec: Spec, clauses: List[Int], mut env: Env, mut host: H):
    """Records in `env` the value of each `old(e)` of the clauses; a failure is recorded too."""
    var calls: List[Int] = []
    for ci in clauses:
        if spec.clauses[ci].expr != 0:
            collect_olds(spec, spec.clauses[ci].expr, calls)
    for call in calls:
        if call in env.olds:
            continue
        ref kids = spec.ast.nodes[call].children
        var arg = spec.ast.nodes[kids[2]].children[0] if len(kids) > 2 else 0
        var run = Run()
        try:
            var old = Old(ev(spec, arg, env, run, host), String(), 0, False)
            env.olds[call] = old^
        except err:
            var failed_here = run.err_node >= 0
            env.olds[call] = Old(
                Value.none(),
                run.err_message.copy() if failed_here else String(err),
                run.err_node if failed_here else call,
                run.skipped,
            )


def observe_with[
    H: EvalHost
](
    spec: Spec,
    model: Int,
    observer: Int,
    obj: Value,
    args: List[Value],
    mut host: H,
) raises -> Value:
    """The value of an observer's reading expression with `self` bound to `obj`."""
    ref o = spec.models[model].observers[observer]
    var name = String(spec.models[model].name, ".", o.name)
    if o.expr == 0:
        raise Error(t"{name} has no reading expression: it reads the attribute of the same name")
    if len(args) != len(o.params):
        raise Error(t"{name} takes {len(o.params)} argument(s), but {len(args)} are given")
    var env = Env(args.copy())
    env.set_self(obj.copy())
    return fit(spec.types, evaluate(spec, o.expr, env, host), o.type)


def explain[
    H: EvalHost
](
    spec: Spec,
    clause: Int,
    env: Env,
    mut host: H,
    limit: Int = EXPLAIN_LIMIT,
) -> List[Tuple[String, String]]:
    """(source text, value text) pairs of the subexpressions that explain a clause. Never raises."""
    var ex = Explainer(limit)
    ref c = spec.clauses[clause]
    if c.expr != 0:
        var run = Run()
        var value = outcome_of(spec, c.expr, env, run, host)
        if value.is_any_bool():
            walk(ex, spec, c.expr, value, env, run, host)
        if not value.is_any_bool() or len(ex.pairs) == 0:
            add_known(ex, spec, c.expr, value)
    return ex^.into_pairs()


def class_holds[
    H: EvalHost
](spec: Spec, class_node: Int, value: Value, mut host: H) raises -> Bool:
    """Is `value`, a value of the partitioned parameter, in the partition class at
    `class_node` (a CLASS node)?"""
    for func in spec.fns:
        for part in func.partitions:
            for c in range(len(part.classes)):
                if part.classes[c].node != class_node:
                    continue
                var t = func.params[part.param].type
                var expr = part.classes[c].expr
                if tkind(spec, expr) != ty.SET:
                    var params = [Value.none() for _ in func.params]
                    params[part.param] = value.copy()
                    var held = evaluate(spec, expr, Env(params^), host)
                    if held.kind != wv.BOOL:
                        raise Error(t"a predicate class must be a bool, but it is {show(held)}")
                    return held.as_bool()
                var ctx = SetContext()
                var earlier: Dict[String, BitSet] = {}
                var chosen = ctx.empty(1)
                for j in range(c + 1):
                    var s = compile_set_aliased(
                        ctx, spec.ast, spec.types, t, part.classes[j].expr, earlier, spec.aliases
                    )
                    earlier[part.classes[j].name] = s
                    chosen = s
                return ctx.contains(chosen, bits_of_value(spec.types, t, value))
    raise Error(t"node {class_node} is not a partition class")
