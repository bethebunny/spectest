"""Aggregate clauses: a bound over a whole input set, judged term by term.

The evaluator judges an expression; this keeps the bookkeeping of v1's
`evaluate_aggregate`: the terms, the worst terms, the count of skipped terms (a planned
call outside `requires` or one that raised), and a seeded sample of a set too large to
visit in full. A sample can only underestimate a sum or a maximum, so sampling may miss
a failure but never invents one."""

from std.time import perf_counter_ns

from interpreter.api import evaluate
from interpreter.core import type_kind, value_of
from interpreter.env import Env, Run
from interpreter.numbers import (
    add_term,
    compare_values,
    elements,
    holds_order,
    larger,
    qerr_compare,
    qerr_zero,
    show,
    term_of,
)
from interpreter.text import located, source_text
from mcheck.rand import Rng
from partition.compile import compiled_set
from partition.sets import SetContext
from spec import types as ty
from spec import ast
from spec.bits import value_from_bits
from spec.spec import Spec
from value.text import format_value
from value.value import Value

from .options import RunOptions
from .results import AggregateSummary, ClauseResult, Counterexample
from .run_host import RunHost

comptime WORST_LIMIT = 5


@fieldwise_init
struct Shape(ImplicitlyCopyable):
    """The parts of an aggregate clause such as `sum(v in S: e) <= c` or `all(v in S: p)`."""

    var top: Int
    """The comprehension."""
    var op: ast.Op
    """The comparison with the bound, NO_OP for all(...)."""
    var bound: Int
    """The bound, 0 for all(...)."""


def _shape(spec: Spec, clause: Int) raises -> Shape:
    ref cl = spec.clauses[clause]
    ref node = spec.ast.nodes[cl.expr]
    if node.kind == .Comprehension and node.op == .ALL:
        return Shape(cl.expr, .NO_OP, 0)
    if node.kind == .Binary and node.op in [ast.Op.LE, ast.Op.LT, ast.Op.EQ]:
        ref comp = spec.ast.nodes[node.children[0]]
        if comp.kind == .Comprehension and comp.op in [ast.Op.SUM, ast.Op.MAX]:
            return Shape(node.children[0], node.op, node.children[1])
    raise Error(
        t"{cl.id}: an aggregate clause is sum(v in S: e) <= c, < c or == 0, max(v in S: e) <= c"
        t" or < c, or all(v in S: p)"
    )


struct Members(Movable):
    """The members of an aggregate's set that its terms are judged on."""

    var values: List[Value]
    var total: Int
    """How many members the set has, at most 2**62."""
    var sampled: Bool
    """Whether `values` is a seeded sample of a larger set."""

    def __init__(out self, var values: List[Value]):
        """Every member of a set."""
        self.total = len(values)
        self.values = values^
        self.sampled = False

    def __init__(out self, *, var sample: List[Value], total: Int):
        self.values = sample^
        self.total = total
        self.sampled = True


def _set_members(
    spec: Spec, mut ctx: SetContext, iterable: Int, *, limit: Int, samples: Int, seed: UInt64
) raises -> Members:
    """The members of a partition set: all of them when there are at most `limit`, else a
    seeded sample."""
    var elem, s = compiled_set(ctx, spec, iterable)
    var count = ctx.count(s)
    if count <= UInt128(limit):
        return Members([value_from_bits(spec.types, elem, bits) for bits in ctx.members(s, limit)])
    var rng = Rng(seed)
    # Only the whole 64-bit type has more members than a UInt64 counts.
    var exact = count <= UInt128(UInt64.MAX)
    # The ends of the set, then random members.
    var indices: List[UInt64] = [0]
    if exact:
        indices.append(UInt64(count - 1))
    for _ in range(samples - 2):
        indices.append(rng.below(UInt64(count)) if exact else rng.next())
    var sample = [value_from_bits(spec.types, elem, ctx.nth(s, index)) for index in indices]
    return Members(sample=sample^, total=Int(min(count, UInt128(1 << 62))))


def _rank_less(a: Value, b: Value) raises -> Bool:
    """Is term `a` smaller than term `b`? A qerr ranks by its NaN part, then its steps."""
    if a.kind == .Qerr and b.kind == .Qerr:
        var na = a.item(1).as_bigint()
        var nb = b.item(1).as_bigint()
        if na != nb:
            return na < nb
        return a.item(0).as_bigint() < b.item(0).as_bigint()
    return compare_values(a, b) < 0


def _is_zero(t: Value) raises -> Bool:
    if t.kind == .Qerr:
        return t.item(0).as_bigint().is_zero() and t.item(1).as_bigint().is_zero()
    return compare_values(t, Value.int(0)) == 0


def _keep_worst(mut worst: List[Tuple[Value, Value]], member: Value, term: Value) raises:
    """Keeps `term` among the largest terms, largest first and earlier first among equals."""
    var at = len(worst)
    while at > 0 and _rank_less(worst[at - 1][1], term):
        at -= 1
    if at < WORST_LIMIT:
        worst.insert(at, (member.copy(), term.copy()))
        if len(worst) > WORST_LIMIT:
            _ = worst.pop()


def _judge(
    spec: Spec,
    mut ctx: SetContext,
    mut host: RunHost[_],
    f: Int,
    clause: Int,
    options: RunOptions,
    seed: UInt64,
    mut result: ClauseResult,
) raises:
    var shape = _shape(spec, clause)
    ref comp = spec.ast.nodes[shape.top]
    var kind = comp.op
    var iterable = comp.children[0]
    var body = comp.children[1]
    var env = Env()
    var bound = evaluate(spec, shape.bound, env, host) if shape.bound != 0 else Value.int(0)
    var members: Members
    if type_kind(spec, iterable) == .Set:
        members = _set_members(
            spec, ctx, iterable, limit=options.exhaustive_limit, samples=options.aggregate_samples, seed=seed
        )
    else:
        var run = Run()
        members = Members(elements(value_of(spec, iterable, env, run, host), String(kind, "(...)")))
    var sum = qerr_zero() if type_kind(spec, shape.top) == .Qerr else Value.int(0)
    var largest: Optional[Value] = None
    var failures = 0
    var evaluated = 0
    var skipped = 0
    # Members and their terms: the largest terms, or the first members all(...) fails on.
    var worst: List[Tuple[Value, Value]] = []
    for member in members.values:
        var run = Run()
        run.push(shape.top, member.copy())
        var term: Value
        try:
            term = value_of(spec, body, env, run, host)
        except err:
            var failure = run.failure_or(err, body)
            if failure.skipped:
                skipped += 1
                continue
            raise Error(located(spec, failure.node, failure.message))
        evaluated += 1
        if kind == .ALL:
            if term.kind != .Bool:
                raise Error(located(spec, body, String(t"the body of all(...) must be a bool, not {show(term)}")))
            if not term.as_bool():
                failures += 1
                if len(worst) < WORST_LIMIT:
                    worst.append((member.copy(), Value.bool(False)))
            continue
        var t = term_of(term)
        if t.kind != .Qerr and compare_values(t, Value.int(0)) < 0:
            var message = String(
                "the term ", show(t), " for ", comp.text, " = ", show(member),
                " is negative: the terms of an aggregate ", kind, "(...) are non-negative",
            )
            raise Error(located(spec, body, message))
        if kind == .SUM:
            sum = add_term(sum, t)
        else:
            largest = larger(largest.value(), t) if largest is not None else t.copy()
        if not _is_zero(t):
            _keep_worst(worst, member, t)
    var summary = AggregateSummary()
    summary.evaluated = evaluated
    summary.skipped = skipped
    summary.total = members.total
    summary.sampled = members.sampled
    summary.worst = [(format_value(member), format_value(term)) for member, term in worst]
    var holds: Bool
    if kind == .ALL:
        holds = failures == 0
        summary.value = String(failures)
        summary.bound = "0"
    else:
        var no_max = kind == .MAX and largest is None
        if no_max and evaluated + skipped == 0:
            raise Error(located(spec, shape.top, "max(...) over a set with no members has no value"))
        var value = sum.copy() if kind == .SUM else largest.copy().or_else(Value.none())
        summary.bound = format_value(bound)
        if value.kind == .Bool or no_max:
            holds = True
            summary.value = "none"
        else:
            summary.value = format_value(value)
            if value.kind == .Qerr or bound.kind == .Qerr:
                holds = qerr_compare(shape.op, value, bound)
            else:
                var c = compare_values(value, bound)
                holds = (c == 0) if shape.op == .EQ else holds_order(shape.op, c)
    result.mode = "sampled" if members.sampled else "exhaustive"
    if holds:
        result.passed = 1
    else:
        result.failed = 1
        result.failing_inputs = 1
        var how = String("a seeded sample of ", evaluated + skipped, " of") if members.sampled else String("every member of")
        var cx = Counterexample()
        cx.inputs = [(comp.text.copy(), String(how, " ", source_text(spec, iterable), " (", members.total, " members)"))]
        cx.observation = String(kind, " = ", summary.value, ", against the bound ", summary.bound)
        cx.seed = Int(options.seed)
        cx.reproduce = String("seed=", options.seed, " decl=", spec.fns[f].decl_id, " clause=", spec.clauses[clause].id)
        result.counterexample = cx^
    result.aggregate = summary^


def run_aggregate(
    spec: Spec,
    mut ctx: SetContext,
    mut host: RunHost[_],
    f: Int,
    clause: Int,
    options: RunOptions,
    seed: UInt64,
) raises -> ClauseResult:
    var started = perf_counter_ns()
    ref cl = spec.clauses[clause]
    var result = ClauseResult(cl.id.copy(), source_text(spec, cl.node), "aggregate", spec.fns[f].decl_id.copy())
    result.mode = "exhaustive"
    try:
        _judge(spec, ctx, host, f, clause, options, seed, result)
    except err:
        if host.take_timeout():
            result.inconclusive = 1
        else:
            result.spec_error = 1
            result.spec_errors.append(String(err))
    result.duration = Float64(perf_counter_ns() - started) / 1e9
    return result^
