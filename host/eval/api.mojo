"""The evaluator's entry points: evaluate, judge, snapshot_olds, observe_with,
explain and class_holds."""

from check import types as ty
from check.spec import Spec, R_OLD
from numeric.bigint import BigInt
from partitions.compile import compile_set_aliased
from sets import BitSet, SetContext
from syntax import ast
from wire.value import Value, BOOL

from .coerce import bits_of_value, fit
from .core import ev, tkind
from .env import Env, Run
from .explain import Explainer, Outcome, add_known, outcome_of, shown, walk
from .host import EvalHost
from .numbers import show
from .text import located


comptime EXPLAIN_LIMIT = 16

comptime J_TRUE = 0
comptime J_FALSE = 1
comptime J_ERROR = 2
comptime J_SKIP = 3


struct Judgment(Copyable, Movable):
    """The outcome of judging a clause: true, false, an evaluation error (message and
    node) or a skip (cause and node)."""

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
        """The judgment as a line: `true`, `false`, `error: message (at ...)`."""
        if self.kind == J_TRUE:
            return "true"
        if self.kind == J_FALSE:
            return "false"
        var what = "error: " if self.kind == J_ERROR else "skip: "
        if self.node > 0:
            return what + located(spec, self.node, self.message)
        return what + self.message


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
    """Does the clause `spec.clauses[clause]` hold? For `raises` and `may_raise` this
    judges the `when` condition (true when there is none)."""
    ref c = spec.clauses[clause]
    if c.expr == 0:
        if c.kind == ast.RAISES or c.kind == ast.MAY_RAISE:
            return Judgment(J_TRUE)
        return Judgment(
            J_ERROR,
            String(
                c.id, ": a ", ast.op_name(c.kind), " clause has no condition to evaluate"
            ),
            c.node,
        )
    var run = Run()
    try:
        var v = ev(spec, c.expr, env, run, host)
        if v.kind != BOOL:
            return Judgment(
                J_ERROR,
                "the clause must evaluate to a bool, but it is " + show(v),
                c.expr,
            )
        return Judgment(J_TRUE if v.as_bool() else J_FALSE)
    except err:
        var node = run.err_node if run.err_node >= 0 else c.expr
        var message = run.err_message.copy() if run.err_node >= 0 else String(err)
        return Judgment(J_SKIP if run.skipped else J_ERROR, message^, node)


def collect_olds(spec: Spec, root: Int, mut out: List[Int]):
    """The `old(...)` calls below `root`, in source order."""
    var stack = List[Int]()
    stack.append(root)
    while len(stack) > 0:
        var n = stack.pop()
        ref node = spec.ast.nodes[n]
        if node.kind == ast.CALL:
            var r = spec.resolutions.get(n)
            if r and r.value().kind == R_OLD:
                out.append(n)
                continue
        var i = len(node.kids) - 1
        while i >= 0:
            stack.append(node.kids[i])
            i -= 1


def snapshot_olds[
    H: EvalHost
](spec: Spec, clauses: List[Int], mut env: Env, mut host: H):
    """Evaluates every `old(e)` of the given clauses (positions in `Spec.clauses`) on
    the state before the call, and records the values in `env`. An `old` whose
    evaluation fails records the failure, which the clause meets when it reads it."""
    var calls = List[Int]()
    for ci in clauses:
        if spec.clauses[ci].expr != 0:
            collect_olds(spec, spec.clauses[ci].expr, calls)
    for call in calls:
        if env.old_index(call) >= 0:
            continue
        var arg = spec.ast.nodes[spec.ast.nodes[call].kids[2]].kids[0] if len(
            spec.ast.nodes[call].kids
        ) > 2 else 0
        var run = Run()
        var value = Value.none()
        var message = String()
        var node = 0
        var skipped = False
        try:
            value = ev(spec, arg, env, run, host)
        except err:
            message = run.err_message.copy() if run.err_node >= 0 else String(err)
            node = run.err_node if run.err_node >= 0 else call
            skipped = run.skipped
        env.old_nodes.append(call)
        env.old_values.append(value^)
        env.old_errors.append(message^)
        env.old_error_nodes.append(node)
        env.old_skips.append(skipped)


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
    """The value of an observer given by a reading expression, with `self` bound to
    `obj`. Calls the reading expression makes outside the spec go to `host.call_extern`."""
    ref o = spec.models[model].observers[observer]
    if o.expr == 0:
        raise Error(
            spec.models[model].name + "." + o.name + " has no reading expression: it reads the attribute of the same name"
        )
    if len(args) != len(o.params):
        raise Error(
            spec.models[model].name + "." + o.name + " takes " + String(len(o.params)) + " argument(s), but " + String(len(args)) + " are given"
        )
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
    """Why a clause has its value: (source text, value text) pairs of the
    subexpressions that matter. For a false clause it follows the failing structure.
    It never raises."""
    var ex = Explainer(limit)
    ref c = spec.clauses[clause]
    if c.expr != 0:
        var run = Run()
        var value = outcome_of(spec, c.expr, env, run, host)
        if not value.is_any_bool():
            add_known(ex, spec, c.expr, value)
        else:
            walk(ex, spec, c.expr, value, env, run, host)
            if len(ex.pairs) == 0:
                add_known(ex, spec, c.expr, value)
    return ex^.into_pairs()


def class_holds[
    H: EvalHost
](spec: Spec, class_node: Int, value: Value, mut host: H) raises -> Bool:
    """Is `value`, a value of the partitioned parameter, in the partition class at
    `class_node` (a CLASS node)?"""
    for f in range(len(spec.fns)):
        ref func = spec.fns[f]
        for p in range(len(func.partitions)):
            ref part = func.partitions[p]
            for c in range(len(part.classes)):
                if part.classes[c].node != class_node:
                    continue
                var t = func.params[part.param].type
                var expr = part.classes[c].expr
                if tkind(spec, expr) != ty.SET:
                    var params = List[Value]()
                    for _ in range(len(func.params)):
                        params.append(Value.none())
                    params[part.param] = value.copy()
                    var env = Env(params^)
                    var v = evaluate(spec, expr, env, host)
                    if v.kind != BOOL:
                        raise Error("a predicate class must be a bool, but it is " + show(v))
                    return v.as_bool()
                var ctx = SetContext()
                var earlier = Dict[String, BitSet]()
                var chosen = ctx.empty(1)
                for j in range(c + 1):
                    var s = compile_set_aliased(
                        ctx, spec.ast, spec.types, t, part.classes[j].expr, earlier, spec.aliases
                    )
                    earlier[part.classes[j].name] = s
                    chosen = s
                return ctx.contains(chosen, bits_of_value(spec.types, t, value))
    raise Error("node " + String(class_node) + " is not a partition class")
