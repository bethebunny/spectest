"""`requires` clauses read as sets of one parameter's values."""

from std.collections import Dict

import check.types as ty
import syntax.ast as sx
from check.spec import Spec
from numeric.bigint import BigInt
from numeric.real import Real
from sets import BitSet, SetContext
from syntax.ast import Ast

from .compile import Elem, SetCompiler, alias_elems, elem_of, positional_args
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
    """A predicate over one parameter as sets."""

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
        var verdicts = self.compile(ctx, ast, e)
        if verdicts is not None:
            return [verdicts.value().true]
        ref n = ast.nodes[e]
        if n.kind == .BINARY and n.op == .AND:
            var out = self.admitted(ctx, ast, n.children[0])
            out.extend(self.admitted(ctx, ast, n.children[1]))
            return out^
        return List[BitSet]()

    def is_param(self, ast: Ast, e: Int) -> Bool:
        ref n = ast.nodes[e]
        if n.kind == .NAME:
            return n.text == self.param
        if n.kind == .CALL:
            var args = positional_args(ast, e)
            ref callee = ast.nodes[n.children[0]]
            if (
                args is not None
                and len(args.value()) == 1
                and callee.kind == .NAME
                and callee.text == "real"
                and len(ast.nodes[n.children[1]].children) == 0
            ):
                return self.is_param(ast, args.value()[0])
        return False

    def _complement(mut self, mut ctx: SetContext, true: BitSet) -> Verdicts:
        return Verdicts(true, ctx.difference(self.everything, true))

    def pred(mut self, mut ctx: SetContext, ast: Ast, e: Int) raises -> Verdicts:
        ref n = ast.nodes[e]
        var elem = self.comp.elem
        if n.kind == .BOOL:
            if n.op == .TRUE:
                return Verdicts(self.everything, self.nothing)
            return Verdicts(self.nothing, self.everything)
        if n.kind == .NAME and elem.kind == ty.BOOL and self.is_param(ast, e):
            return self._complement(ctx, ctx.exactly([UInt64(1)], 1))
        if n.kind == .UNARY and n.op == .NOT:
            var v = self.pred(ctx, ast, n.children[0])
            return Verdicts(v.false, v.true)
        if n.kind == .BINARY and n.op in [sx.Op.AND, sx.Op.OR, sx.Op.IMPLIES]:
            var a = self.pred(ctx, ast, n.children[0])
            var b = self.pred(ctx, ast, n.children[1])
            if n.op == .AND:
                return Verdicts(
                    ctx.intersection(a.true, b.true),
                    ctx.union(a.false, ctx.intersection(a.true, b.false)),
                )
            if n.op == .OR:
                return Verdicts(
                    ctx.union(a.true, ctx.intersection(a.false, b.true)),
                    ctx.intersection(a.false, b.false),
                )
            return Verdicts(
                ctx.union(a.false, ctx.intersection(a.true, b.true)),
                ctx.intersection(a.true, b.false),
            )
        if n.kind == .IF:
            var c = self.pred(ctx, ast, n.children[0])
            var a = self.pred(ctx, ast, n.children[1])
            var b = self.pred(ctx, ast, n.children[2])
            return Verdicts(
                ctx.union(
                    ctx.intersection(c.true, a.true), ctx.intersection(c.false, b.true)
                ),
                ctx.union(
                    ctx.intersection(c.true, a.false),
                    ctx.intersection(c.false, b.false),
                ),
            )
        if n.kind == .CALL:
            ref callee = ast.nodes[n.children[0]]
            var args = positional_args(ast, e)
            if (
                callee.kind == .NAME
                and args is not None
                and len(args.value()) == 1
                and self.is_param(ast, args.value()[0])
            ):
                return self._complement(ctx, self.test(ctx, ast, callee.text, e))
            raise _not_a_set()
        if n.kind == .BINARY and n.op == .IN:
            ref right = ast.nodes[n.children[1]]
            if right.kind != .LIST and right.kind != .SET:
                raise _not_a_set()
            if not self.is_param(ast, n.children[0]) or not elem.is_int():
                raise _not_a_set()
            var true = self.nothing
            for x in right.children:
                true = ctx.union(true, self.int_compare(ctx, sx.Op.EQ, self.comp.const(ast, x)))
            return self._complement(ctx, true)
        if n.kind == .BINARY and n.op >= sx.Op.EQ and n.op <= sx.Op.GE:
            if self.is_param(ast, n.children[0]):
                return self.compare(ctx, n.op, self.comp.const(ast, n.children[1]))
            if self.is_param(ast, n.children[1]):
                return self.compare(
                    ctx, _flipped(n.op), self.comp.const(ast, n.children[0])
                )
        raise _not_a_set()

    def test(
        mut self, mut ctx: SetContext, ast: Ast, name_of_fn: String, call: Int
    ) raises -> BitSet:
        var elem = self.comp.elem
        ref typeargs = ast.nodes[ast.child(call, 1)]
        if elem.is_float() and len(typeargs.children) == 0:
            var float_set = _float_set_named(name_of_fn)
            if float_set != "":
                return ctx.float_named(elem.format(), float_set)
        if elem.is_int() and name_of_fn == "fits" and len(typeargs.children) == 1:
            ref texpr = ast.nodes[typeargs.children[0]]
            if texpr.kind == .TYPE and len(texpr.children) == 0:
                var target = self.comp.type_named(texpr.text)
                if target is not None and target.value().is_int():
                    return ctx.int_range(
                        elem.width,
                        elem.signed,
                        target.value().int_min(),
                        target.value().int_max() + BigInt(1),
                    )
        raise _not_a_set()

    def compare(
        mut self, mut ctx: SetContext, op: sx.Op, c: Real
    ) raises -> Verdicts:
        var elem = self.comp.elem
        if elem.is_int():
            return self._complement(ctx, self.int_compare(ctx, op, c))
        if not elem.is_float() or op == .EQ or op == .NE:
            raise _not_a_set()
        var f = elem.format()
        var ordered = ctx.difference(self.everything, ctx.float_named(f, "nan"))
        var below = float_range(ctx, f, None, c.copy())
        var at_most = ctx.union(below, float_equal(ctx, f, c))
        var true: BitSet
        if op == .LT:
            true = below
        elif op == .LE:
            true = at_most
        elif op == .GT:
            true = ctx.difference(ordered, at_most)
        else:
            true = ctx.difference(ordered, below)
        return Verdicts(true, ctx.difference(ordered, true))

    def int_compare(
        mut self, mut ctx: SetContext, op: sx.Op, c: Real
    ) raises -> BitSet:
        var elem = self.comp.elem
        var below = ctx.int_range(elem.width, elem.signed, None, c.ceil())
        var at_most = ctx.int_range(elem.width, elem.signed, None, c.floor() + BigInt(1))
        if op == .LT:
            return below
        if op == .LE:
            return at_most
        if op == .GT:
            return ctx.difference(self.everything, at_most)
        if op == .GE:
            return ctx.difference(self.everything, below)
        var equal = ctx.difference(at_most, below)
        if op == .EQ:
            return equal
        return ctx.difference(self.everything, equal)


def _float_set_named(fn_name: String) -> String:
    """The float set that the predicate function `fn_name` tests, or empty."""
    match fn_name:
        case "is_nan":
            return "nan"
        case "is_inf":
            return "inf"
        case "is_finite":
            return "finite"
        case "is_zero":
            return "zero"
        case "is_subnormal":
            return "subnormal"
        case "signbit":
            return "negative"
        case _:
            return ""


def _flipped(op: sx.Op) -> sx.Op:
    if op == .LT:
        return sx.Op.GT
    if op == .LE:
        return sx.Op.GE
    if op == .GT:
        return sx.Op.LT
    if op == .GE:
        return sx.Op.LE
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
    if elem is None:
        return None
    var pred = Predicate(ctx, p.name, elem.value(), alias_elems(spec.types, spec.aliases))
    var target: Optional[BitSet] = None
    for ci in f.clauses:
        ref clause = spec.clauses[ci]
        if clause.kind != .REQUIRES or clause.expr == 0:
            continue
        for s in pred.admitted(ctx, spec.ast, clause.expr):
            target = s if target is None else ctx.intersection(target.value(), s)
    return target
