"""The evaluator's entry points: evaluate, judge, snapshot_olds, observe_with,
explain and class_holds."""

from spec import types as ty
from spec.spec import Fn, Partition, Spec
from partition.compile import compile_set_aliased
from partition.sets import BitSet, SetContext
from spec.ast import Op
from value.value import Value

from .coerce import bits_of_value, fit
from .core import is_old_call, type_kind, value_of
from .env import Env, Failure, Old, Run
from .explain import Explanation, add_known, outcome_of, walk
from .host import EvalHost
from .numbers import show
from .text import located


comptime EXPLAIN_LIMIT = 16


__enum Verdict(Equatable, ImplicitlyCopyable):
    """Whether a clause holds: true, false, or neither for an error or a skip."""

    case TRUE
    case FALSE
    case ERROR
    case SKIP

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()


struct Judgment(Copyable):
    """The outcome of judging a clause."""

    var verdict: Verdict
    var message: String
    """An error's message or a skip's cause, without the location."""
    var node: Int
    """The node the error or skip is attributed to, or 0."""

    def __init__(out self, verdict: Verdict, var message: String = "", node: Int = 0):
        self.verdict = verdict
        self.message = message^
        self.node = node

    def __init__(out self, failure: Failure):
        self = Self(Verdict.SKIP if failure.skipped else Verdict.ERROR, failure.message.copy(), failure.node)

    def is_true(self) -> Bool:
        return self.verdict == .TRUE

    def is_false(self) -> Bool:
        return self.verdict == .FALSE

    def is_error(self) -> Bool:
        return self.verdict == .ERROR

    def is_skip(self) -> Bool:
        return self.verdict == .SKIP

    def located_message(self, spec: Spec) -> String:
        """The message, with the location and source of its node when it has one."""
        return located(spec, self.node, self.message) if self.node > 0 else self.message.copy()

    def describe(self, spec: Spec) -> String:
        """`true`, `false`, `error: message (at ...)` or `skip: cause (at ...)`."""
        match self.verdict:
            case .TRUE:
                return "true"
            case .FALSE:
                return "false"
            case .ERROR:
                return String("error: ", self.located_message(spec))
            case .SKIP:
                return String("skip: ", self.located_message(spec))


def evaluate[
    H: EvalHost
](spec: Spec, node: Int, env: Env, mut host: H) raises -> Value:
    """The value of the checked expression at `node`. An error carries the location
    and source text of the expression that failed."""
    var run = Run()
    try:
        return value_of(spec, node, env, run, host)
    except err:
        if case .Some(failure) = run.failure:
            raise Error(located(spec, failure.node, failure.message))
        raise err^


def judge[
    H: EvalHost
](spec: Spec, clause: Int, env: Env, mut host: H) -> Judgment:
    """Does the clause hold? A `raises` or `may_raise` clause judges its `when` condition."""
    ref c = spec.clauses[clause]
    if c.expr == 0:
        if c.kind in [Op.RAISES, Op.MAY_RAISE]:
            return Judgment(Verdict.TRUE)
        return Judgment(Verdict.ERROR, String(t"{c.id}: a {c.kind} clause has no condition to evaluate"), c.node)
    var run = Run()
    try:
        var v = value_of(spec, c.expr, env, run, host)
        if v.kind != .BOOL:
            return Judgment(Verdict.ERROR, String(t"the clause must evaluate to a bool, but it is {show(v)}"), c.expr)
        return Judgment(Verdict.TRUE if v.as_bool() else Verdict.FALSE)
    except err:
        return Judgment(run.failure_or(err, c.expr))


def old_calls(spec: Spec, root: Int) -> List[Int]:
    """The `old(...)` calls at or below `root`, in source order."""
    return [node for node in spec.ast.subtree(root) if is_old_call(spec, node)]


def snapshot_olds[
    H: EvalHost
](spec: Spec, clauses: List[Int], mut env: Env, mut host: H):
    """Records in `env` the value of each `old(e)` of the clauses; a failure is recorded too."""
    for clause in clauses:
        var expr = spec.clauses[clause].expr
        if expr == 0:
            continue
        for call in old_calls(spec, expr):
            if call in env.olds:
                continue
            ref children = spec.ast.nodes[call].children
            var arg = spec.ast.child(children[2], 0) if len(children) > 2 else 0
            var run = Run()
            var old: Old
            try:
                old = Old(value_of(spec, arg, env, run, host), None)
            except err:
                old = Old(Value.none(), run.failure_or(err, call))
            env.olds[call] = old^


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
    var name = String(t"{spec.models[model].name}.{o.name}")
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
    var explanation = Explanation(limit)
    ref c = spec.clauses[clause]
    if c.expr != 0:
        var run = Run()
        var value = outcome_of(spec, c.expr, env, run, host)
        if value.is_any_bool():
            walk(explanation, spec, c.expr, value, env, run, host)
        if not value.is_any_bool() or not explanation.pairs:
            add_known(explanation, spec, c.expr, value)
    return explanation^.into_pairs()


def class_holds[
    H: EvalHost
](spec: Spec, class_node: Int, value: Value, mut host: H) raises -> Bool:
    """Is `value`, a value of the partitioned parameter, in the partition class at
    `class_node` (a CLASS node)?"""
    for func in spec.fns:
        for part in func.partitions:
            for c, cls in enumerate(part.classes):
                if cls.node == class_node:
                    return _class_holds(spec, func, part, c, value, host)
    raise Error(t"node {class_node} is not a partition class")


def _class_holds[
    H: EvalHost
](spec: Spec, func: Fn, part: Partition, c: Int, value: Value, mut host: H) raises -> Bool:
    var expr = part.classes[c].expr
    if type_kind(spec, expr) != .SET:
        var params = List[Value](length=len(func.params), fill=Value.none())
        params[part.param] = value.copy()
        var held = evaluate(spec, expr, Env(params^), host)
        if held.kind != .BOOL:
            raise Error(t"a predicate class must be a bool, but it is {show(held)}")
        return held.as_bool()
    # A class's set may name the classes before it.
    var t = func.params[part.param].type
    var ctx = SetContext()
    var earlier: Dict[String, BitSet] = {}
    var chosen = ctx.empty(1)
    for cls in part.classes[: c + 1]:
        chosen = compile_set_aliased(ctx, spec.ast, spec.types, t, cls.expr, earlier, spec.aliases)
        earlier[cls.name] = chosen
    return ctx.contains(chosen, bits_of_value(spec.types, t, value))
