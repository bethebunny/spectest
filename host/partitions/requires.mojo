"""`requires` clauses read as sets of one parameter's values."""

from std.collections import Dict

import check.types as ty
import syntax.ast as sx
from check.spec import Spec
from numeric.bigint import BigInt
from numeric.real import Real
from sets import BitSet, SetContext
from syntax.ast import Ast

from .compile import Elem, SetCompiler, alias_elems, elem_of
from .ranges import float_equal, float_range


@fieldwise_init
struct Verdicts(Copyable, TrivialRegisterPassable):
    """The values where a predicate is true and where it is false. Values in neither
    make evaluation fail (a NaN promoted to a real)."""

    var true: BitSet
    var false: BitSet


def _not_a_set() -> Error:
    return Error("not a set")


struct Predicate(Movable):
    """A predicate over one parameter as sets, in v1's analysis."""

    var comp: SetCompiler
    var param: String
    var everything: BitSet
    var nothing: BitSet

    def __init__(
        out self,
        mut ctx: SetContext,
        param: String,
        elem: Elem,
        var aliases: Dict[String, Elem],
    ):
        self.comp = SetCompiler(elem, aliases^, Dict[String, BitSet]())
        self.param = param
        self.everything = ctx.full(elem.width)
        self.nothing = ctx.empty(elem.width)

    def compile(
        mut self, mut ctx: SetContext, ast: Ast, e: Int
    ) -> Optional[Verdicts]:
        try:
            return self.pred(ctx, ast, e)
        except:
            return None

    def admitted(mut self, mut ctx: SetContext, ast: Ast, e: Int) -> List[BitSet]:
        """Sets that contain every value the clause admits, splitting top-level
        `and`."""
        var v = self.compile(ctx, ast, e)
        if v:
            return [v.value().true]
        ref n = ast.nodes[e]
        if n.kind == sx.BINARY and n.op == sx.AND:
            var out = self.admitted(ctx, ast, n.kids[0])
            out.extend(self.admitted(ctx, ast, n.kids[1]))
            return out^
        return List[BitSet]()

    def is_param(self, ast: Ast, e: Int) -> Bool:
        ref n = ast.nodes[e]
        if n.kind == sx.NAME:
            return n.text == self.param
        if n.kind == sx.CALL and len(n.kids) == 3:
            ref callee = ast.nodes[n.kids[0]]
            if (
                callee.kind == sx.NAME
                and callee.text == "real"
                and len(ast.nodes[n.kids[1]].kids) == 0
                and ast.nodes[n.kids[2]].text == ""
            ):
                return self.is_param(ast, ast.kid(n.kids[2], 0))
        return False

    def _complement(mut self, mut ctx: SetContext, true: BitSet) -> Verdicts:
        return Verdicts(true, ctx.difference(self.everything, true))

    def pred(mut self, mut ctx: SetContext, ast: Ast, e: Int) raises -> Verdicts:
        ref n = ast.nodes[e]
        var elem = self.comp.elem
        if n.kind == sx.BOOL:
            if n.op == sx.TRUE:
                return Verdicts(self.everything, self.nothing)
            return Verdicts(self.nothing, self.everything)
        if n.kind == sx.NAME and elem.kind == ty.BOOL and self.is_param(ast, e):
            return self._complement(ctx, ctx.exactly([UInt64(1)], 1))
        if n.kind == sx.UNARY and n.op == sx.NOT:
            var v = self.pred(ctx, ast, n.kids[0])
            return Verdicts(v.false, v.true)
        if n.kind == sx.BINARY and (
            n.op == sx.AND or n.op == sx.OR or n.op == sx.IMPLIES
        ):
            var a = self.pred(ctx, ast, n.kids[0])
            var b = self.pred(ctx, ast, n.kids[1])
            if n.op == sx.AND:
                return Verdicts(
                    ctx.intersection(a.true, b.true),
                    ctx.union(a.false, ctx.intersection(a.true, b.false)),
                )
            if n.op == sx.OR:
                return Verdicts(
                    ctx.union(a.true, ctx.intersection(a.false, b.true)),
                    ctx.intersection(a.false, b.false),
                )
            return Verdicts(
                ctx.union(a.false, ctx.intersection(a.true, b.true)),
                ctx.intersection(a.true, b.false),
            )
        if n.kind == sx.IF:
            var c = self.pred(ctx, ast, n.kids[0])
            var a = self.pred(ctx, ast, n.kids[1])
            var b = self.pred(ctx, ast, n.kids[2])
            return Verdicts(
                ctx.union(
                    ctx.intersection(c.true, a.true), ctx.intersection(c.false, b.true)
                ),
                ctx.union(
                    ctx.intersection(c.true, a.false),
                    ctx.intersection(c.false, b.false),
                ),
            )
        if n.kind == sx.CALL:
            ref callee = ast.nodes[n.kids[0]]
            if (
                callee.kind == sx.NAME
                and len(n.kids) == 3
                and ast.nodes[n.kids[2]].text == ""
                and self.is_param(ast, ast.kid(n.kids[2], 0))
            ):
                return self._complement(ctx, self.test(ctx, ast, callee.text, e))
            raise _not_a_set()
        if n.kind == sx.BINARY and n.op == sx.IN:
            ref right = ast.nodes[n.kids[1]]
            if right.kind != sx.LIST and right.kind != sx.SET:
                raise _not_a_set()
            if not self.is_param(ast, n.kids[0]) or not elem.is_int():
                raise _not_a_set()
            var true = self.nothing
            for x in right.kids:
                true = ctx.union(
                    true, self.int_compare(ctx, sx.EQ, self.comp.const(ast, x))
                )
            return self._complement(ctx, true)
        if n.kind == sx.BINARY and n.op >= sx.EQ and n.op <= sx.GE:
            if self.is_param(ast, n.kids[0]):
                return self.compare(ctx, n.op, self.comp.const(ast, n.kids[1]))
            if self.is_param(ast, n.kids[1]):
                return self.compare(
                    ctx, _flipped(n.op), self.comp.const(ast, n.kids[0])
                )
        raise _not_a_set()

    def test(
        mut self, mut ctx: SetContext, ast: Ast, name_of_fn: String, call: Int
    ) raises -> BitSet:
        var elem = self.comp.elem
        ref typeargs = ast.nodes[ast.kid(call, 1)]
        if elem.is_float() and len(typeargs.kids) == 0:
            var name = String()
            if name_of_fn == "is_nan":
                name = "nan"
            elif name_of_fn == "is_inf":
                name = "inf"
            elif name_of_fn == "is_finite":
                name = "finite"
            elif name_of_fn == "is_zero":
                name = "zero"
            elif name_of_fn == "is_subnormal":
                name = "subnormal"
            elif name_of_fn == "signbit":
                name = "negative"
            if name != "":
                return ctx.float_named(elem.format(), name)
        if elem.is_int() and name_of_fn == "fits" and len(typeargs.kids) == 1:
            ref texpr = ast.nodes[typeargs.kids[0]]
            if texpr.kind == sx.TYPE and len(texpr.kids) == 0:
                var t = self.comp.type_named(texpr.text)
                if t and t.value().is_int():
                    var target = t.value()
                    return ctx.int_range(
                        elem.width,
                        elem.signed,
                        Optional[BigInt](target.int_min()),
                        Optional[BigInt](target.int_max() + BigInt(1)),
                    )
        raise _not_a_set()

    def compare(
        mut self, mut ctx: SetContext, op: UInt8, c: Real
    ) raises -> Verdicts:
        var elem = self.comp.elem
        if elem.is_int():
            return self._complement(ctx, self.int_compare(ctx, op, c))
        if not elem.is_float() or op == sx.EQ or op == sx.NE:
            raise _not_a_set()
        var f = elem.format()
        var ordered = ctx.difference(self.everything, ctx.float_named(f, "nan"))
        var below = float_range(ctx, f, None, Optional[Real](c.copy()))
        var at_most = ctx.union(below, float_equal(ctx, f, c))
        var true: BitSet
        if op == sx.LT:
            true = below
        elif op == sx.LE:
            true = at_most
        elif op == sx.GT:
            true = ctx.difference(ordered, at_most)
        else:
            true = ctx.difference(ordered, below)
        return Verdicts(true, ctx.difference(ordered, true))

    def int_compare(
        mut self, mut ctx: SetContext, op: UInt8, c: Real
    ) raises -> BitSet:
        var elem = self.comp.elem
        var below = ctx.int_range(
            elem.width, elem.signed, None, Optional[BigInt](c.ceil())
        )
        var at_most = ctx.int_range(
            elem.width, elem.signed, None, Optional[BigInt](c.floor() + BigInt(1))
        )
        if op == sx.LT:
            return below
        if op == sx.LE:
            return at_most
        if op == sx.GT:
            return ctx.difference(self.everything, at_most)
        if op == sx.GE:
            return ctx.difference(self.everything, below)
        var equal = ctx.difference(at_most, below)
        if op == sx.EQ:
            return equal
        return ctx.difference(self.everything, equal)


def _flipped(op: UInt8) -> UInt8:
    if op == sx.LT:
        return sx.GT
    if op == sx.LE:
        return sx.GE
    if op == sx.GT:
        return sx.LT
    if op == sx.GE:
        return sx.LE
    return op


def admitted(
    mut ctx: SetContext, spec: Spec, fn_pos: Int, param: Int
) raises -> Optional[BitSet]:
    """The values of a fixed-width parameter that the function's `requires` clauses
    admit, when they can be read as sets, else None. A clause (or top-level conjunct)
    that is a predicate on the parameter alone narrows the set; the others are
    ignored."""
    ref f = spec.fns[fn_pos]
    ref p = f.params[param]
    var elem = elem_of(spec.types, p.type)
    if not elem:
        return None
    var pred = Predicate(
        ctx, p.name, elem.value(), alias_elems(spec.types, spec.aliases)
    )
    var target: Optional[BitSet] = None
    for ci in f.clauses:
        ref clause = spec.clauses[ci]
        if clause.kind != sx.REQUIRES or clause.expr == 0:
            continue
        for s in pred.admitted(ctx, spec.ast, clause.expr):
            if target:
                target = ctx.intersection(target.value(), s)
            else:
                target = s
    return target
