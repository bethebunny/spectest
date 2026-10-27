"""Set expressions of the syntax tree as sets of an element type's bit patterns.

The compiler reads the tree directly: `T.nan`, `T.range(a, b)`, `T.pattern("...")`,
`{v, ...}`, earlier classes by name, and `|`, `&`, `-`. It needs no name resolution; a
type name is one of the scalar names or an alias of the spec.
"""

from std.collections import Dict

import check.types as ty
import syntax.ast as sx
from bigint import BigUInt
from numeric.bigint import BigInt
from numeric.floats import exactly, to_real
from numeric.formats import FloatFormat, format_by_id
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

    def name(self) -> String:
        if self.kind == ty.BOOL:
            return "bool"
        if self.kind == ty.FIXED_INT:
            return String("i" if self.signed else "u", self.width)
        if self.format_id == 1:
            return "f16"
        if self.format_id == 2:
            return "bf16"
        if self.format_id == 3:
            return "f32"
        return "f64"

    def int_min(self) -> BigInt:
        if not self.signed:
            return BigInt()
        return -BigInt(negative=False, magnitude=BigUInt(1) << (self.width - 1))

    def int_max(self) -> BigInt:
        var bits = self.width - 1 if self.signed else self.width
        return BigInt(negative=False, magnitude=BigUInt(1) << bits) - BigInt(1)


def elem_of(types: ty.Types, t: Int) -> Optional[Elem]:
    """The element type for type id `t`, or None when it is not fixed-width."""
    var k = types.kind(t)
    if k == ty.BOOL:
        return Elem(ty.BOOL, 1, False, 0)
    if k == ty.FIXED_INT:
        return Elem(ty.FIXED_INT, types.info(t).bits, types.info(t).signed, 0)
    if k == ty.FLOAT:
        try:
            var f = format_by_id(UInt8(types.info(t).bits))
            return Elem(ty.FLOAT, f.width(), True, f.id)
        except:
            return None
    return None


def scalar_elem(name: StringSlice) -> Optional[Elem]:
    """The fixed-width type a scalar name denotes."""
    if name == "bool":
        return Elem(ty.BOOL, 1, False, 0)
    if name == "f16":
        return Elem(ty.FLOAT, 16, True, 1)
    if name == "bf16":
        return Elem(ty.FLOAT, 16, True, 2)
    if name == "f32":
        return Elem(ty.FLOAT, 32, True, 3)
    if name == "f64":
        return Elem(ty.FLOAT, 64, True, 4)
    for bits in [8, 16, 32, 64]:
        if name == String("i", bits):
            return Elem(ty.FIXED_INT, bits, True, 0)
        if name == String("u", bits):
            return Elem(ty.FIXED_INT, bits, False, 0)
    return None


def alias_elems(types: ty.Types, aliases: Dict[String, Int]) -> Dict[String, Elem]:
    var out = Dict[String, Elem]()
    for item in aliases.items():
        var e = elem_of(types, item.value)
        if e:
            out[item.key] = e.value()
    return out^


def real_text(v: Real) -> String:
    if v.is_integer():
        return String(v.numerator)
    return String(v.numerator, "/", v.denominator)


def describe(ast: Ast, e: Int) -> String:
    """What a node is, for a message: `the operator ==`, `a call to f`, `x`."""
    ref n = ast.nodes[e]
    if n.kind == sx.BINARY:
        return "the operator " + String(sx.op_name(n.op))
    if n.kind == sx.UNARY:
        return "the operator " + ("-" if n.op == sx.NEG else String(sx.op_name(n.op)))
    if n.kind == sx.CALL:
        ref callee = ast.nodes[n.kids[0]]
        if callee.kind == sx.NAME or callee.kind == sx.ATTR:
            return "a call to " + callee.text
        return String(sx.kind_name(n.kind))
    if n.kind == sx.NUM:
        return "the number " + n.text
    if n.kind == sx.ATTR:
        return "." + n.text
    if n.kind == sx.NAME:
        return n.text
    return String(sx.kind_name(n.kind))


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

    def fail(mut self, node: Int, var message: String) -> Error:
        self.error_node = node
        self.error_message = message^
        return Error(self.error_message)

    def diagnostic(self, ast: Ast, prefix: String = "") -> String:
        ref span = ast.nodes[self.error_node].span
        return String(ast.path, ":", span, ": ", prefix, self.error_message)

    def type_named(self, name: String) -> Optional[Elem]:
        var found = scalar_elem(name)
        if found:
            return found
        var alias = self.aliases.get(name)
        if alias:
            return alias.value()
        return None

    # Set expressions

    def compile(mut self, mut ctx: SetContext, ast: Ast, e: Int) raises -> BitSet:
        ref n = ast.nodes[e]
        if n.kind == sx.BINARY and (
            n.op == sx.BITOR or n.op == sx.BITAND or n.op == sx.SUB
        ):
            var a = self.compile(ctx, ast, n.kids[0])
            var b = self.compile(ctx, ast, n.kids[1])
            if n.op == sx.BITOR:
                return ctx.union(a, b)
            if n.op == sx.BITAND:
                return ctx.intersection(a, b)
            return ctx.difference(a, b)
        if n.kind == sx.NAME:
            var cls = self.classes.get(n.text)
            if cls:
                var s = cls.value()
                if Int(s.width) != self.elem.width:
                    raise self.fail(
                        e,
                        String(
                            "class ", n.text, " is a set of ", s.width, "-bit values"
                        ),
                    )
                return s
            if self.type_named(n.text):
                raise self.fail(
                    e,
                    String(n.text, " is a type; write ", n.text, ".all for all of it"),
                )
            raise self.fail(
                e,
                String(
                    "unknown class ",
                    n.text,
                    " (a class can only use classes defined before it)",
                ),
            )
        if n.kind == sx.ATTR:
            var tname = self.owner(ast, n.kids[0], n.text, e)
            if n.text == "min" or n.text == "max":
                raise self.fail(
                    e,
                    String(
                        tname, ".", n.text, " is a value, not a set; write {", tname,
                        ".", n.text, "}",
                    ),
                )
            var named = self.named_set(ctx, n.text)
            if not named:
                raise self.fail(
                    e,
                    String(
                        tname, " has no set ", n.text, " (its sets are ",
                        self.set_names(), ")",
                    ),
                )
            return named.value()
        if n.kind == sx.CALL:
            ref callee = ast.nodes[n.kids[0]]
            if callee.kind == sx.ATTR and (
                callee.text == "range" or callee.text == "pattern"
            ):
                var tname = self.owner(ast, callee.kids[0], callee.text, e)
                if callee.text == "range":
                    return self.range(ctx, ast, e, tname)
                return self.pattern(ctx, ast, e, tname)
        if n.kind == sx.SET:
            var bits = List[UInt64]()
            for k in n.kids:
                bits.append(self.member_bits(ast, k))
            return ctx.exactly(bits^, self.elem.width)
        raise self.fail(
            e,
            String(
                "expected a set expression, got ",
                describe(ast, e),
                ". Classes of a ",
                self.elem.name(),
                " parameter are sets: ",
                self.elem.name(),
                ".nan, ",
                self.elem.name(),
                ".range(a, b), ",
                self.elem.name(),
                '.pattern("..."), {v, ...} or earlier classes, combined with |, & and -',
            ),
        )

    def owner(
        mut self, ast: Ast, value: Int, member: String, whole: Int
    ) raises -> String:
        """The type name `value` writes, checked to be the partition's own type."""
        ref v = ast.nodes[value]
        var found: Optional[Elem] = None
        if v.kind == sx.NAME:
            found = self.type_named(v.text)
        if not found:
            raise self.fail(
                whole,
                String(describe(ast, value), ".", member, " is not a partition set"),
            )
        if found.value() != self.elem:
            raise self.fail(
                whole,
                String(
                    v.text, ".", member, " is a set of ", found.value().name(),
                    " values, but this partition is of ", self.elem.name(),
                ),
            )
        return v.text

    def set_names(self) -> String:
        if self.elem.is_float():
            return "nan, inf, zero, subnormal, normal, finite, positive, negative, all"
        if self.elem.is_int():
            return "zero, positive, negative, all"
        return "all"

    def named_set(mut self, mut ctx: SetContext, name: String) raises -> Optional[BitSet]:
        if name == "all":
            return ctx.full(self.elem.width)
        if self.elem.is_float():
            if name == "nan" or name == "inf" or name == "zero" or name == "subnormal" or name == "normal" or name == "finite" or name == "positive" or name == "negative":
                return ctx.float_named(self.elem.format(), name)
            return None
        if self.elem.is_int():
            if name == "zero":
                return ctx.exactly([UInt64(0)], self.elem.width)
            if name == "positive":
                return ctx.int_range(
                    self.elem.width, self.elem.signed, Optional[BigInt](BigInt()), None
                )
            if name == "negative":
                return ctx.int_range(
                    self.elem.width, self.elem.signed, None, Optional[BigInt](BigInt())
                )
        return None

    # range and pattern

    def range(
        mut self, mut ctx: SetContext, ast: Ast, call: Int, tname: String
    ) raises -> BitSet:
        if not (self.elem.is_float() or self.elem.is_int()):
            raise self.fail(call, String(tname, " has no range"))
        ref n = ast.nodes[call]
        var ok = len(n.kids) == 4 and len(ast.nodes[n.kids[1]].kids) == 0
        if ok:
            for i in range(2, 4):
                if ast.nodes[n.kids[i]].text != "":
                    ok = False
        if not ok:
            raise self.fail(
                call,
                String(tname, ".range takes two bounds: ", tname, ".range(start, stop)"),
            )
        var lo = self.bound(ast, ast.kid(n.kids[2], 0), tname)
        var hi = self.bound(ast, ast.kid(n.kids[3], 0), tname)
        if self.elem.is_float():
            var lo_r: Optional[Real] = None
            var hi_r: Optional[Real] = None
            if lo:
                lo_r = lo.value().copy()
            if hi:
                hi_r = hi.value().copy()
            return float_range(ctx, self.elem.format(), lo_r, hi_r)
        var lo_i: Optional[BigInt] = None
        var hi_i: Optional[BigInt] = None
        if lo:
            lo_i = lo.value().numerator.copy()
        if hi:
            hi_i = hi.value().numerator.copy()
        return ctx.int_range(self.elem.width, self.elem.signed, lo_i, hi_i)

    def bound(mut self, ast: Ast, e: Int, tname: String) raises -> Optional[Real]:
        if ast.nodes[e].kind == sx.NONE:
            return None
        var v = self.const(ast, e)
        var text = ast.nodes[e].text if ast.nodes[e].kind == sx.NUM else real_text(v)
        if self.elem.is_float():
            if not exactly(self.elem.format(), v):
                raise self.fail(
                    e,
                    String(
                        tname, ".range bound ", text,
                        " is not exactly representable in ", self.elem.name(),
                    ),
                )
        elif self.elem.is_int():
            if not v.is_integer():
                raise self.fail(
                    e, String(tname, ".range bound ", text, " is not an integer")
                )
            var past = self.elem.int_max() + BigInt(1)
            if v.numerator < self.elem.int_min() or past < v.numerator:
                raise self.fail(
                    e,
                    String(
                        tname, ".range bound ", text, " is outside ", self.elem.name(),
                        ": bounds lie in [", tname, ".min, ", tname, ".max + 1]",
                    ),
                )
        return Optional[Real](v^)

    def pattern(
        mut self, mut ctx: SetContext, ast: Ast, call: Int, tname: String
    ) raises -> BitSet:
        ref n = ast.nodes[call]
        var ok = len(n.kids) == 3
        if ok:
            ok = (
                ast.nodes[n.kids[2]].text == ""
                and ast.nodes[ast.kid(n.kids[2], 0)].kind == sx.STR
            )
        if not ok:
            raise self.fail(
                call,
                String(tname, '.pattern takes one string: ', tname, '.pattern("...")'),
            )
        var arg = ast.kid(n.kids[2], 0)
        try:
            return ctx.pattern(ast.nodes[arg].text, self.elem.width)
        except err:
            raise self.fail(arg, String(tname, ".pattern: ", err))

    # Members and constants

    def member_bits(mut self, ast: Ast, e: Int) raises -> UInt64:
        ref n = ast.nodes[e]
        if self.elem.kind == ty.BOOL:
            if n.kind != sx.BOOL:
                raise self.fail(
                    e,
                    String("a bool set holds true and false, not ", describe(ast, e)),
                )
            return UInt64(1) if n.op == sx.TRUE else UInt64(0)
        var v = self.const(ast, e)
        var text = n.text if n.kind == sx.NUM else real_text(v)
        if self.elem.is_int():
            if (
                not v.is_integer()
                or v.numerator < self.elem.int_min()
                or self.elem.int_max() < v.numerator
            ):
                raise self.fail(
                    e, String(text, " is not a ", self.elem.name(), " value")
                )
            var wrapped = v.numerator.copy()
            if wrapped.negative:
                wrapped = wrapped + BigInt(
                    negative=False, magnitude=BigUInt(1) << self.elem.width
                )
            return wrapped.magnitude.uint64_or_none().value()
        var f = self.elem.format()
        if n.kind == sx.UNARY and n.op == sx.NEG and v.is_zero():
            raise self.fail(
                e,
                String(
                    "-0 is the number 0, which is +0.0 as a ", self.elem.name(),
                    "; write ", self.elem.name(), ".zero & ", self.elem.name(),
                    ".negative for -0.0, or 0 for +0.0",
                ),
            )
        var bits = exactly(f, v)
        if not bits:
            raise self.fail(
                e,
                String(text, " is not exactly representable in ", self.elem.name()),
            )
        return bits.value()

    def const(mut self, ast: Ast, e: Int) raises -> Real:
        ref n = ast.nodes[e]
        if n.kind == sx.NUM:
            try:
                return parse_number(n.text)
            except err:
                raise self.fail(e, String(err))
        if n.kind == sx.UNARY and n.op == sx.NEG:
            return -self.const(ast, n.kids[0])
        if n.kind == sx.BINARY and (
            n.op == sx.ADD or n.op == sx.SUB or n.op == sx.MUL or n.op == sx.DIV
        ):
            var a = self.const(ast, n.kids[0])
            var b = self.const(ast, n.kids[1])
            if n.op == sx.ADD:
                return a + b
            if n.op == sx.SUB:
                return a - b
            if n.op == sx.MUL:
                return a * b
            if b.is_zero():
                raise self.fail(e, "division by zero")
            return a / b
        if n.kind == sx.ATTR and (n.text == "min" or n.text == "max"):
            ref owner = ast.nodes[n.kids[0]]
            if owner.kind == sx.NAME:
                var t = self.type_named(owner.text)
                if t:
                    var found = t.value()
                    var is_min = n.text == "min"
                    if found.is_int():
                        return Real(
                            found.int_min() if is_min else found.int_max()
                        )
                    if found.is_float():
                        var f = found.format()
                        var top = to_real(f, f.exponent_mask() - 1)
                        return -top if is_min else top^
                    raise self.fail(e, String(owner.text, " has no ", n.text))
        raise self.fail(
            e,
            String(
                "expected a constant, got ",
                describe(ast, e),
                ": bounds and members are numbers combined with +, -, * and /, or"
                " T.min and T.max",
            ),
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
    """`compile_set` that also knows the spec's type aliases (name to type id)."""
    var elem = elem_of(types, elem_type)
    if not elem:
        raise Error(
            "partition sets are over bool, fixed integers and floats, not "
            + types.text(elem_type)
        )
    var c = SetCompiler(elem.value(), alias_elems(types, aliases), classes.copy())
    try:
        return c.compile(ctx, ast, node)
    except:
        raise Error(c.diagnostic(ast))


def compile_set(
    mut ctx: SetContext,
    ast: Ast,
    mut types: ty.Types,
    elem_type: Int,
    node: Int,
    classes: Dict[String, BitSet],
) raises -> BitSet:
    """The set expression at `node` as a set of `elem_type`'s bit patterns. `classes`
    names the earlier classes of the partition. Errors read `path:line:col: message`."""
    return compile_set_aliased(
        ctx, ast, types, elem_type, node, classes, Dict[String, Int]()
    )
