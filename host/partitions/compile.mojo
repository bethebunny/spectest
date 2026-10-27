"""Set expressions of the syntax tree as sets of an element type's bit patterns.

The compiler reads the tree directly: `T.nan`, `T.range(a, b)`, `T.pattern("...")`,
`{v, ...}`, earlier classes by name, and `|`, `&`, `-`. It needs no name resolution (a
type name is one of the scalar names or an alias of the spec).
"""

from std.collections import Dict

import check.types as ty
import syntax.ast as sx
from numeric.bigint import BigInt
from numeric.fixed import int_max, int_min, pattern_of
from numeric.floats import exactly, to_real
from numeric.formats import BF16, F16, F32, F64, FloatFormat, format_by_id
from numeric.literal import parse_number
from numeric.real import Real
from sets import BitSet, SetContext
from syntax.ast import Ast

from .ranges import float_equal, float_range


@fieldwise_init
struct Elem(Copyable, Equatable, TrivialRegisterPassable):
    """A fixed-width element type: bool, a fixed integer or a float."""

    var kind: UInt8
    """BOOL, FIXED_INT or FLOAT of check.types."""
    var width: Int
    var signed: Bool
    var format_id: UInt8

    def __eq__(self, other: Self) -> Bool:
        return (
            self.kind == other.kind
            and self.width == other.width
            and self.signed == other.signed
            and self.format_id == other.format_id
        )

    def is_float(self) -> Bool:
        return self.kind == ty.FLOAT

    def is_int(self) -> Bool:
        return self.kind == ty.FIXED_INT

    def format(self) raises -> FloatFormat:
        return format_by_id(self.format_id)

    @staticmethod
    def float(format: FloatFormat) -> Self:
        return Self(ty.FLOAT, format.width(), True, format.id)

    def name(self) -> String:
        if self.kind == ty.BOOL:
            return "bool"
        if self.kind == ty.FIXED_INT:
            return String("i" if self.signed else "u", self.width)
        for format in [F16, BF16, F32, F64]:
            if format.id == self.format_id:
                return String(format.name())
        return "none"

    def int_min(self) -> BigInt:
        return int_min(self.width, self.signed)

    def int_max(self) -> BigInt:
        return int_max(self.width, self.signed)


def elem_of(types: ty.Types, t: Int) -> Optional[Elem]:
    """The element type for type id `t`, or None when it is not fixed-width."""
    var k = types.kind(t)
    if k == ty.BOOL:
        return Elem(ty.BOOL, 1, False, 0)
    if k == ty.FIXED_INT:
        return Elem(ty.FIXED_INT, types.info(t).bits, types.info(t).signed, 0)
    if k == ty.FLOAT:
        try:
            return Elem.float(format_by_id(UInt8(types.info(t).bits)))
        except:
            return None
    return None


def scalar_elem(name: StringSlice) -> Optional[Elem]:
    """The fixed-width type a scalar name denotes."""
    if name == "bool":
        return Elem(ty.BOOL, 1, False, 0)
    for format in [F16, BF16, F32, F64]:
        if name == format.name():
            return Elem.float(format)
    for bits in [8, 16, 32, 64]:
        if name == String("i", bits):
            return Elem(ty.FIXED_INT, bits, True, 0)
        if name == String("u", bits):
            return Elem(ty.FIXED_INT, bits, False, 0)
    return None


def alias_elems(types: ty.Types, aliases: Dict[String, Int]) -> Dict[String, Elem]:
    var out = Dict[String, Elem]()
    for item in aliases.items():
        var elem = elem_of(types, item.value)
        if elem is not None:
            out[item.key] = elem.value()
    return out^


def real_text(v: Real) -> String:
    if v.is_integer():
        return String(v.numerator)
    return String(v.numerator, "/", v.denominator)


def describe(ast: Ast, e: Int) -> String:
    """What a node is, for a message: `the operator ==`, `a call to f`, `x`."""
    ref n = ast.nodes[e]
    if n.kind == .BINARY:
        return String("the operator ", n.op)
    if n.kind == .UNARY:
        return String("the operator ", "-" if n.op == .NEG else String(n.op))
    if n.kind == .CALL:
        ref callee = ast.nodes[n.children[0]]
        if callee.kind == .NAME or callee.kind == .ATTR:
            return String("a call to ", callee.text)
    if n.kind == .NUM:
        return String("the number ", n.text)
    if n.kind == .ATTR:
        return String(".", n.text)
    if n.kind == .NAME:
        return n.text.copy()
    return String(n.kind)


def positional_args(ast: Ast, call: Int) -> Optional[List[Int]]:
    """The argument values of a CALL node (`[callee, TYPEARGS, ARG...]`), or None when
    an argument is named."""
    var values = List[Int]()
    for arg in ast.nodes[call].children[2:]:
        if ast.nodes[arg].text != "":
            return None
        values.append(ast.child(arg, 0))
    return values^


def _numerator(bound: Optional[Real]) -> Optional[BigInt]:
    if bound is None:
        return None
    return bound.value().numerator.copy()


struct SetCompiler(Movable):
    """Compiles set expressions of one element type. A failure records the offending
    node and message and raises; `diagnostic` formats them."""

    var elem: Elem
    var aliases: Dict[String, Elem]
    var classes: Dict[String, BitSet]
    var error_node: Int
    var error_message: String

    def __init__(
        out self,
        elem: Elem,
        var aliases: Dict[String, Elem],
        var classes: Dict[String, BitSet],
    ):
        self.elem = elem
        self.aliases = aliases^
        self.classes = classes^
        self.error_node = 0
        self.error_message = String()

    def fail(mut self, node: Int, message: Some[Writable]) -> Error:
        self.error_node = node
        self.error_message = String(message)
        return Error(self.error_message)

    def diagnostic(self, ast: Ast, prefix: String = "") -> String:
        return String(ast.location(self.error_node), ": ", prefix, self.error_message)

    def type_named(self, name: String) -> Optional[Elem]:
        var found = scalar_elem(name)
        if found is not None:
            return found
        var alias = self.aliases.get(name)
        if alias is not None:
            return alias.value()
        return None

    def compile(mut self, mut ctx: SetContext, ast: Ast, e: Int) raises -> BitSet:
        ref n = ast.nodes[e]
        if n.kind == .BINARY and n.op in [sx.Op.BITOR, sx.Op.BITAND, sx.Op.SUB]:
            var a = self.compile(ctx, ast, n.children[0])
            var b = self.compile(ctx, ast, n.children[1])
            if n.op == .BITOR:
                return ctx.union(a, b)
            if n.op == .BITAND:
                return ctx.intersection(a, b)
            return ctx.difference(a, b)
        if n.kind == .NAME:
            var cls = self.classes.get(n.text)
            if cls is not None:
                if Int(cls.value().width) != self.elem.width:
                    raise self.fail(e, t"class {n.text} is a set of {cls.value().width}-bit values")
                return cls.value()
            if self.type_named(n.text) is not None:
                raise self.fail(e, t"{n.text} is a type; write {n.text}.all for all of it")
            raise self.fail(
                e, t"unknown class {n.text} (a class can only use classes defined before it)"
            )
        if n.kind == .ATTR:
            var tname = self.owner(ast, n.children[0], n.text, e)
            if n.text in ["min", "max"]:
                raise self.fail(e, t"{tname}.{n.text} is a value, not a set; write {{{tname}.{n.text}}}")
            var named = self.named_set(ctx, n.text)
            if named is None:
                raise self.fail(e, t"{tname} has no set {n.text} (its sets are {self.set_names()})")
            return named.value()
        if n.kind == .CALL:
            ref callee = ast.nodes[n.children[0]]
            if callee.kind == .ATTR and callee.text in ["range", "pattern"]:
                var tname = self.owner(ast, callee.children[0], callee.text, e)
                if callee.text == "range":
                    return self.range(ctx, ast, e, tname)
                return self.pattern(ctx, ast, e, tname)
        if n.kind == .SET:
            return ctx.exactly([self.member_bits(ast, k) for k in n.children], self.elem.width)
        var name = self.elem.name()
        raise self.fail(
            e,
            t"expected a set expression, got {describe(ast, e)}. Classes of a {name}"
            t" parameter are sets: {name}.nan, {name}.range(a, b),"
            t' {name}.pattern("..."), {{v, ...}} or earlier classes, combined with |, & and -',
        )

    def owner(mut self, ast: Ast, value: Int, member: String, whole: Int) raises -> String:
        """The type name `value` writes, checked to be the partition's own type."""
        ref v = ast.nodes[value]
        var found: Optional[Elem] = None
        if v.kind == .NAME:
            found = self.type_named(v.text)
        if found is None:
            raise self.fail(whole, t"{describe(ast, value)}.{member} is not a partition set")
        if found.value() != self.elem:
            raise self.fail(
                whole,
                t"{v.text}.{member} is a set of {found.value().name()} values, but this"
                t" partition is of {self.elem.name()}",
            )
        return v.text.copy()

    def set_names(self) -> String:
        if self.elem.is_float():
            return "nan, inf, zero, subnormal, normal, finite, positive, negative, all"
        return "zero, positive, negative, all" if self.elem.is_int() else "all"

    def named_set(mut self, mut ctx: SetContext, name: String) raises -> Optional[BitSet]:
        var width = self.elem.width
        if name == "all":
            return ctx.full(width)
        if self.elem.is_float() and name in [
            "nan", "inf", "zero", "subnormal", "normal", "finite", "positive", "negative"
        ]:
            return ctx.float_named(self.elem.format(), name)
        if self.elem.is_int():
            if name == "zero":
                return ctx.exactly([UInt64(0)], width)
            if name == "positive":
                return ctx.int_range(width, self.elem.signed, BigInt(), None)
            if name == "negative":
                return ctx.int_range(width, self.elem.signed, None, BigInt())
        return None

    def range(
        mut self, mut ctx: SetContext, ast: Ast, call: Int, tname: String
    ) raises -> BitSet:
        if not (self.elem.is_float() or self.elem.is_int()):
            raise self.fail(call, t"{tname} has no range")
        var args = positional_args(ast, call)
        if args is None or len(args.value()) != 2 or len(ast.nodes[ast.child(call, 1)].children) > 0:
            raise self.fail(call, t"{tname}.range takes two bounds: {tname}.range(start, stop)")
        var lo = self.bound(ast, args.value()[0], tname)
        var hi = self.bound(ast, args.value()[1], tname)
        if self.elem.is_float():
            return float_range(ctx, self.elem.format(), lo^, hi^)
        return ctx.int_range(self.elem.width, self.elem.signed, _numerator(lo), _numerator(hi))

    def bound(mut self, ast: Ast, e: Int, tname: String) raises -> Optional[Real]:
        if ast.nodes[e].kind == .NONE:
            return None
        var v = self.const(ast, e)
        var text = ast.nodes[e].text if ast.nodes[e].kind == .NUM else real_text(v)
        if self.elem.is_float():
            if exactly(self.elem.format(), v) is None:
                raise self.fail(
                    e,
                    t"{tname}.range bound {text} is not exactly representable in {self.elem.name()}",
                )
        elif self.elem.is_int():
            if not v.is_integer():
                raise self.fail(e, t"{tname}.range bound {text} is not an integer")
            var past = self.elem.int_max() + BigInt(1)
            if v.numerator < self.elem.int_min() or past < v.numerator:
                raise self.fail(
                    e,
                    t"{tname}.range bound {text} is outside {self.elem.name()}: bounds lie"
                    t" in [{tname}.min, {tname}.max + 1]",
                )
        return v^

    def pattern(
        mut self, mut ctx: SetContext, ast: Ast, call: Int, tname: String
    ) raises -> BitSet:
        var args = positional_args(ast, call)
        if args is None or len(args.value()) != 1 or ast.nodes[args.value()[0]].kind != .STR:
            raise self.fail(call, t'{tname}.pattern takes one string: {tname}.pattern("...")')
        var arg = args.value()[0]
        try:
            return ctx.pattern(ast.nodes[arg].text, self.elem.width)
        except err:
            raise self.fail(arg, t"{tname}.pattern: {err}")

    def member_bits(mut self, ast: Ast, e: Int) raises -> UInt64:
        ref n = ast.nodes[e]
        var name = self.elem.name()
        if self.elem.kind == ty.BOOL:
            if n.kind != .BOOL:
                raise self.fail(e, t"a bool set holds true and false, not {describe(ast, e)}")
            return UInt64(1) if n.op == .TRUE else UInt64(0)
        var v = self.const(ast, e)
        var text = n.text if n.kind == .NUM else real_text(v)
        if self.elem.is_int():
            if (
                not v.is_integer()
                or v.numerator < self.elem.int_min()
                or self.elem.int_max() < v.numerator
            ):
                raise self.fail(e, t"{text} is not a {name} value")
            return pattern_of(v.numerator, self.elem.width)
        if n.kind == .UNARY and n.op == .NEG and v.is_zero():
            raise self.fail(
                e,
                t"-0 is the number 0, which is +0.0 as a {name}; write {name}.zero &"
                t" {name}.negative for -0.0, or 0 for +0.0",
            )
        var bits = exactly(self.elem.format(), v)
        if bits is None:
            raise self.fail(e, t"{text} is not exactly representable in {name}")
        return bits.value()

    def const(mut self, ast: Ast, e: Int) raises -> Real:
        ref n = ast.nodes[e]
        if n.kind == .NUM:
            try:
                return parse_number(n.text)
            except err:
                raise self.fail(e, err)
        if n.kind == .UNARY and n.op == .NEG:
            return -self.const(ast, n.children[0])
        if n.kind == .BINARY and n.op in [sx.Op.ADD, sx.Op.SUB, sx.Op.MUL, sx.Op.DIV]:
            var a = self.const(ast, n.children[0])
            var b = self.const(ast, n.children[1])
            if n.op == .ADD:
                return a + b
            if n.op == .SUB:
                return a - b
            if n.op == .MUL:
                return a * b
            if b.is_zero():
                raise self.fail(e, "division by zero")
            return a / b
        if n.kind == .ATTR and n.text in ["min", "max"]:
            ref owner = ast.nodes[n.children[0]]
            var found = self.type_named(owner.text) if owner.kind == .NAME else None
            if found is not None:
                var elem = found.value()
                var is_min = n.text == "min"
                if elem.is_int():
                    return Real(elem.int_min() if is_min else elem.int_max())
                if elem.is_float():
                    var format = elem.format()
                    var top = to_real(format, format.max_finite())
                    return -top if is_min else top^
                raise self.fail(e, t"{owner.text} has no {n.text}")
        raise self.fail(
            e,
            t"expected a constant, got {describe(ast, e)}: bounds and members are numbers"
            t" combined with +, -, * and /, or T.min and T.max",
        )


def compile_set_aliased(
    mut ctx: SetContext,
    ast: Ast,
    types: ty.Types,
    elem_type: Int,
    node: Int,
    classes: Dict[String, BitSet],
    aliases: Dict[String, Int],
) raises -> BitSet:
    """The set expression at `node` as a set of `elem_type`'s bit patterns. `classes`
    names the earlier classes of the partition. Errors read `path:line:col: message`."""
    var elem = elem_of(types, elem_type)
    if elem is None:
        raise Error(
            t"partition sets are over bool, fixed integers and floats, not {types.text(elem_type)}"
        )
    var compiler = SetCompiler(elem.value(), alias_elems(types, aliases), classes.copy())
    try:
        return compiler.compile(ctx, ast, node)
    except:
        raise Error(compiler.diagnostic(ast))
