"""`requires` clauses read as sets of one parameter's values."""

import spec.ast as sx
from spec.spec import Spec
from value.real import Real
from partition.sets import BitSet, SetContext
from spec.ast import Ast

from .compile import SetCompiler, alias_elems, elem_of, only_arg
from .ranges import float_equal, float_range


@fieldwise_init
struct Verdicts(Copyable, TrivialRegisterPassable):
    """The values where a predicate is true and where it is false. Values in neither
    make evaluation fail (a NaN promoted to a real)."""

    var true: BitSet
    var false: BitSet

    @staticmethod
    def true_on(mut ctx: SetContext, true: BitSet) -> Self:
        """True on `true` and false everywhere else."""
        return Self(true, ctx.complement(true))

    def negated(self) -> Self:
        return Self(self.false, self.true)


def _not_a_set() -> Error:
    return Error("not a set")


@fieldwise_init
struct Predicate(Movable):
    """A predicate over one parameter as sets."""

    var compiler: SetCompiler
    var param: String

    def as_sets(self, mut ctx: SetContext, ast: Ast, e: Int) -> Optional[Verdicts]:
        try:
            return self.verdicts(ctx, ast, e)
        except:
            return None

    def admitted(self, mut ctx: SetContext, ast: Ast, e: Int) -> List[BitSet]:
        """Sets that contain every value the clause admits, splitting top-level
        `and`."""
        if case .Some(verdicts) = self.as_sets(ctx, ast, e):
            return [verdicts.true]
        ref n = ast.nodes[e]
        if n.kind == .BINARY and n.op == .AND:
            return self.admitted(ctx, ast, n.children[0]) + self.admitted(ctx, ast, n.children[1])
        return []

    def is_param(self, ast: Ast, e: Int) -> Bool:
        """Whether `e` is the parameter, or `real` of it."""
        ref n = ast.nodes[e]
        match n.kind:
            case .NAME:
                return n.text == self.param
            case .CALL:
                ref callee = ast.nodes[n.children[0]]
                var arg = only_arg(ast, e)
                return (
                    callee.kind == .NAME
                    and callee.text == "real"
                    and not ast.nodes[n.children[1]].children
                    and arg is not None
                    and self.is_param(ast, arg.value())
                )
            case _:
                return False

    def verdicts(self, mut ctx: SetContext, ast: Ast, e: Int) raises -> Verdicts:
        ref n = ast.nodes[e]
        var elem = self.compiler.elem
        match n.kind:
            case .BOOL:
                var everything = ctx.full(elem.width)
                var nothing = ctx.empty(elem.width)
                return Verdicts(everything, nothing) if n.op == .TRUE else Verdicts(nothing, everything)
            case .NAME if elem.is_bool() and self.is_param(ast, e):
                return Verdicts.true_on(ctx, ctx.exactly([UInt64(1)], 1))
            case .UNARY if n.op == .NOT:
                return self.verdicts(ctx, ast, n.children[0]).negated()
            case .BINARY if n.op in [sx.Op.AND, sx.Op.OR, sx.Op.IMPLIES]:
                var a = self.verdicts(ctx, ast, n.children[0])
                var b = self.verdicts(ctx, ast, n.children[1])
                match n.op:
                    case .AND:
                        return Verdicts(
                            ctx.intersection(a.true, b.true),
                            ctx.union(a.false, ctx.intersection(a.true, b.false)),
                        )
                    case .OR:
                        return Verdicts(
                            ctx.union(a.true, ctx.intersection(a.false, b.true)),
                            ctx.intersection(a.false, b.false),
                        )
                    case _:
                        return Verdicts(
                            ctx.union(a.false, ctx.intersection(a.true, b.true)),
                            ctx.intersection(a.true, b.false),
                        )
            case .IF:
                var c = self.verdicts(ctx, ast, n.children[0])
                var a = self.verdicts(ctx, ast, n.children[1])
                var b = self.verdicts(ctx, ast, n.children[2])
                return Verdicts(
                    ctx.union(
                        ctx.intersection(c.true, a.true), ctx.intersection(c.false, b.true)
                    ),
                    ctx.union(
                        ctx.intersection(c.true, a.false),
                        ctx.intersection(c.false, b.false),
                    ),
                )
            case .CALL:
                ref callee = ast.nodes[n.children[0]]
                var arg = only_arg(ast, e)
                if callee.kind == .NAME and arg is not None and self.is_param(ast, arg.value()):
                    return Verdicts.true_on(ctx, self.test(ctx, ast, callee.text, e))
            case .BINARY if n.op == .IN:
                ref right = ast.nodes[n.children[1]]
                if (
                    right.kind in [sx.NodeKind.LIST, sx.NodeKind.SET]
                    and self.is_param(ast, n.children[0])
                    and elem.is_int()
                ):
                    var true = ctx.empty(elem.width)
                    for x in right.children:
                        true = ctx.union(true, self.int_compare(ctx, sx.Op.EQ, self.compiler.const(ast, x)))
                    return Verdicts.true_on(ctx, true)
            case .BINARY if sx.Op.EQ <= n.op <= sx.Op.GE:
                if self.is_param(ast, n.children[0]):
                    return self.compare(ctx, n.op, self.compiler.const(ast, n.children[1]))
                if self.is_param(ast, n.children[1]):
                    return self.compare(ctx, _flipped(n.op), self.compiler.const(ast, n.children[0]))
            case _:
                pass
        raise _not_a_set()

    def test(self, mut ctx: SetContext, ast: Ast, name_of_fn: String, call: Int) raises -> BitSet:
        """The values the one-argument predicate `name_of_fn` holds for."""
        var elem = self.compiler.elem
        ref typeargs = ast.nodes[ast.child(call, 1)].children
        if elem.is_float() and not typeargs:
            if case .Some(name) = _float_set_tested_by(name_of_fn):
                return ctx.float_named(elem.format, name)
        if elem.is_int() and name_of_fn == "fits" and len(typeargs) == 1:
            ref texpr = ast.nodes[typeargs[0]]
            if texpr.kind == .TYPE and not texpr.children:
                if case .Some(target) = self.compiler.type_named(texpr.text):
                    if target.is_int():
                        return ctx.int_range(elem.width, elem.signed, target.int_min(), target.int_max() + 1)
        raise _not_a_set()

    def compare(self, mut ctx: SetContext, op: sx.Op, c: Real) raises -> Verdicts:
        var elem = self.compiler.elem
        if elem.is_int():
            return Verdicts.true_on(ctx, self.int_compare(ctx, op, c))
        if not elem.is_float() or op == .EQ or op == .NE:
            raise _not_a_set()
        var f = elem.format
        var ordered = ctx.complement(ctx.float_named(f, "nan"))
        var below = float_range(ctx, f, None, c.copy())
        var at_most = ctx.union(below, float_equal(ctx, f, c))
        var true: BitSet
        match op:
            case .LT:
                true = below
            case .LE:
                true = at_most
            case .GT:
                true = ctx.difference(ordered, at_most)
            case _:
                true = ctx.difference(ordered, below)
        return Verdicts(true, ctx.difference(ordered, true))

    def int_compare(self, mut ctx: SetContext, op: sx.Op, c: Real) raises -> BitSet:
        var elem = self.compiler.elem
        var below = ctx.int_range(elem.width, elem.signed, None, c.ceil())
        var at_most = ctx.int_range(elem.width, elem.signed, None, c.floor() + 1)
        match op:
            case .LT:
                return below
            case .LE:
                return at_most
            case .GT:
                return ctx.complement(at_most)
            case .GE:
                return ctx.complement(below)
            case .EQ:
                return ctx.difference(at_most, below)
            case _:
                return ctx.complement(ctx.difference(at_most, below))


def _float_set_tested_by(fn_name: String) -> Optional[StaticString]:
    match fn_name:
        case "is_nan":
            return StaticString("nan")
        case "is_inf":
            return StaticString("inf")
        case "is_finite":
            return StaticString("finite")
        case "is_zero":
            return StaticString("zero")
        case "is_subnormal":
            return StaticString("subnormal")
        case "signbit":
            return StaticString("negative")
        case _:
            return None


def _flipped(op: sx.Op) -> sx.Op:
    """The comparison with its operands swapped: `a < b` is `b > a`."""
    match op:
        case .LT:
            return .GT
        case .LE:
            return .GE
        case .GT:
            return .LT
        case .GE:
            return .LE
        case _:
            return op


def admitted(mut ctx: SetContext, spec: Spec, fn_pos: Int, param: Int) -> Optional[BitSet]:
    """The values of a fixed-width parameter that the function's `requires` clauses
    admit, when they can be read as sets, else None. A clause (or top-level conjunct)
    that is a predicate on the parameter alone narrows the set; the others are
    ignored."""
    ref f = spec.fns[fn_pos]
    ref p = f.params[param]
    var elem = elem_of(spec.types, p.type)
    if elem is None:
        return None
    var predicate = Predicate(
        SetCompiler(elem.value(), alias_elems(spec.types, spec.aliases), {}), p.name.copy()
    )
    var target: Optional[BitSet] = None
    for c in f.clauses:
        ref clause = spec.clauses[c]
        if clause.kind != .REQUIRES or clause.expr == 0:
            continue
        for s in predicate.admitted(ctx, spec.ast, clause.expr):
            target = s if target is None else ctx.intersection(target.value(), s)
    return target
