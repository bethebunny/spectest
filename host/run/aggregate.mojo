"""Aggregate clauses: a bound over a whole input set, judged term by term.

The evaluator judges an expression; this keeps the bookkeeping of v1's
`evaluate_aggregate`: the terms, the worst terms, the count of skipped terms (a planned
call outside `requires` or one that raised), and a seeded sample of a set too large to
visit in full. A sample can only underestimate a sum or a maximum, so sampling may miss
a failure but never invents one."""

from std.time import perf_counter_ns

from bigint import BigUInt
from check import types as ty
from check.spec import Spec
from eval.api import evaluate
from eval.coerce import value_from_bits
from eval.core import ev, tkind
from eval.env import Env, Run
from eval.numbers import (
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
from eval.text import located, source_text
from mcheck.rand import Rng
from partitions.compile import compile_set_aliased
from sets import BitSet, SetContext
from syntax import ast
from wire.format import format_value
from wire.value import Value

from .host import RunHost
from .options import RunOptions
from .results import AggregateSummary, ClauseResult, Counterexample

comptime WORST_LIMIT = 5


def _rank_less(a: Value, b: Value) raises -> Bool:
    """Is term `a` smaller than term `b`? A qerr ranks by its NaN part, then its steps."""
    if a.kind == .QERR and b.kind == .QERR:
        var na = a.item(1).as_bigint()
        var nb = b.item(1).as_bigint()
        if na != nb:
            return na < nb
        return a.item(0).as_bigint() < b.item(0).as_bigint()
    return compare_values(a, b) < 0


def _is_zero(t: Value) raises -> Bool:
    if t.kind == .QERR:
        return t.item(0).as_bigint().is_zero() and t.item(1).as_bigint().is_zero()
    return compare_values(t, Value.int(0)) == 0


def _members(
    spec: Spec,
    mut ctx: SetContext,
    iterable: Int,
    limit: Int,
    samples: Int,
    seed: UInt64,
    mut total_out: Int,
    mut sampled: Bool,
) raises -> List[Value]:
    """The members of a partition set: all of them when there are at most `limit`,
    else a seeded sample."""
    var elem = spec.types.info(spec.node_types[iterable]).args[0]
    var s = compile_set_aliased(
        ctx, spec.ast, spec.types, elem, iterable, Dict[String, BitSet](), spec.aliases
    )
    var count = ctx.count(s)
    var exact = count.uint64_or_none()
    if exact is not None and exact.value() <= UInt64(limit):
        total_out = Int(exact.value())
        return [value_from_bits(spec.types, elem, bits) for bits in ctx.members(s, limit)]
    var out = List[Value]()
    sampled = True
    total_out = Int(exact.value()) if exact is not None and exact.value() < UInt64(1 << 62) else (1 << 62)
    var rng = Rng(seed)
    # The ends of the set, then random members.
    out.append(value_from_bits(spec.types, elem, ctx.nth(s, BigUInt(0))))
    if exact is not None:
        out.append(value_from_bits(spec.types, elem, ctx.nth(s, BigUInt(exact.value() - 1))))
    for _ in range(max(0, samples - 2)):
        var index = rng.below(exact.value()) if exact is not None else rng.next()
        out.append(value_from_bits(spec.types, elem, ctx.nth(s, BigUInt(index))))
    return out^


def run_aggregate(
    spec: Spec,
    mut ctx: SetContext,
    mut host: RunHost,
    f: Int,
    clause: Int,
    options: RunOptions,
    seed: UInt64,
) raises -> ClauseResult:
    var started = perf_counter_ns()
    ref cl = spec.clauses[clause]
    var result = ClauseResult(
        cl.id.copy(), source_text(spec, cl.node), "aggregate", spec.fns[f].decl_id.copy()
    )
    result.mode = "exhaustive"
    try:
        var e = cl.expr
        var top = 0
        var op = ast.Op.NO_OP
        var bound_node = 0
        ref en = spec.ast.nodes[e]
        if en.kind == .COMPREHENSION and en.op == .ALL:
            top = e
        elif (
            en.kind == .BINARY
            and spec.ast.nodes[en.children[0]].kind == .COMPREHENSION
            and (spec.ast.nodes[en.children[0]].op == .SUM or spec.ast.nodes[en.children[0]].op == .MAX)
            and (en.op == .LE or en.op == .LT or en.op == .EQ)
        ):
            top = en.children[0]
            op = en.op
            bound_node = en.children[1]
        else:
            raise Error(
                String(
                    cl.id,
                    ": an aggregate clause is sum(v in S: e) <= c, < c or == 0,"
                    " max(v in S: e) <= c or < c, or all(v in S: p)",
                )
            )
        ref comp = spec.ast.nodes[top]
        var kind = comp.op
        var iterable = comp.children[0]
        var body = comp.children[1]
        var env = Env()
        var bound = Value.int(0)
        if bound_node != 0:
            bound = evaluate(spec, bound_node, env, host)
        var total = 0
        var sampled = False
        var members: List[Value]
        if tkind(spec, iterable) == ty.SET:
            members = _members(
                spec, ctx, iterable, options.exhaustive_limit, options.aggregate_samples, seed, total, sampled
            )
        else:
            var run = Run()
            members = elements(ev(spec, iterable, env, run, host), String(kind, "(...)"))
            total = len(members)
        var acc = qerr_zero() if tkind(spec, top) == ty.QERR else Value.int(0)
        var best = Optional[Value]()
        var failures = 0
        var evaluated = 0
        var skipped = 0
        var worst_members = List[Value]()
        var worst_terms = List[Value]()
        for member in members:
            var run = Run()
            run.push(top, member.copy())
            var term: Value
            try:
                term = ev(spec, body, env, run, host)
            except err:
                if run.skipped:
                    skipped += 1
                    continue
                var node = run.err_node if run.err_node >= 0 else body
                raise Error(located(spec, node, run.err_message if run.err_node >= 0 else String(err)))
            evaluated += 1
            if kind == .ALL:
                if term.kind != .BOOL:
                    raise Error(located(spec, body, String("the body of all(...) must be a bool, not ", show(term))))
                if not term.as_bool():
                    failures += 1
                    if len(worst_members) < WORST_LIMIT:
                        worst_members.append(member.copy())
                        worst_terms.append(Value.bool(False))
                continue
            var t = term_of(term)
            if t.kind != .QERR and compare_values(t, Value.int(0)) < 0:
                raise Error(
                    located(
                        spec,
                        body,
                        String(
                            "the term ", show(t), " for ", comp.text, " = ", show(member),
                            " is negative: the terms of an aggregate ", kind, "(...) are non-negative",
                        ),
                    )
                )
            if kind == .SUM:
                acc = add_term(acc, t)
            elif best is not None:
                best = larger(best.value(), t)
            else:
                best = t.copy()
            if not _is_zero(t):
                # Keep the largest terms, largest first and earlier first among equals.
                var at = len(worst_terms)
                while at > 0 and _rank_less(worst_terms[at - 1], t):
                    at -= 1
                if at < WORST_LIMIT:
                    worst_terms.insert(at, t.copy())
                    worst_members.insert(at, member.copy())
                    if len(worst_terms) > WORST_LIMIT:
                        _ = worst_terms.pop()
                        _ = worst_members.pop()
        var summary = AggregateSummary()
        summary.evaluated = evaluated
        summary.skipped = skipped
        summary.total = total
        summary.sampled = sampled
        summary.worst_members = [format_value(m) for m in worst_members]
        summary.worst_terms = [format_value(t) for t in worst_terms]
        var holds: Bool
        var value_text: String
        if kind == .ALL:
            holds = failures == 0
            value_text = String(failures)
            summary.bound = "0"
        else:
            var value: Value
            if kind == .SUM:
                value = acc.copy()
            elif best is not None:
                value = best.value().copy()
            else:
                if evaluated + skipped == 0:
                    raise Error(located(spec, top, "max(...) over a set with no members has no value"))
                value = Value.none()
            summary.bound = format_value(bound)
            if value.kind == .BOOL or (best is None and kind == .MAX):
                holds = True
                value_text = "none"
            else:
                value_text = format_value(value)
                if value.kind == .QERR or bound.kind == .QERR:
                    holds = qerr_compare(op, value, bound)
                else:
                    var c = compare_values(value, bound)
                    holds = (c == 0) if op == .EQ else holds_order(op, c)
        summary.value = value_text.copy()
        result.mode = "sampled" if sampled else "exhaustive"
        if holds:
            result.passed = 1
        else:
            result.failed = 1
            result.failing_inputs = 1
            var cx = Counterexample()
            var how = String("a seeded sample of ", evaluated + skipped, " of") if sampled else String("every member of")
            cx.input_names.append(comp.text.copy())
            cx.input_values.append(String(how, " ", source_text(spec, iterable), " (", total, " members)"))
            cx.observation = String(kind, " = ", value_text, ", against the bound ", summary.bound)
            cx.seed = Int(options.seed)
            cx.reproduce = String("seed=", options.seed, " decl=", spec.fns[f].decl_id, " clause=", cl.id)
            result.counterexample = cx^
        result.aggregate = summary^
    except err:
        if host.take_timeout():
            result.inconclusive = 1
        else:
            result.spec_error = 1
            result.spec_errors.append(String(err))
    result.duration = Float64(perf_counter_ns() - started) / 1e9
    return result^
