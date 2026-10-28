"""Set expressions of the syntax tree as sets of an element type's bit patterns.

The compiler reads the tree directly: `T.nan`, `T.range(a, b)`, `T.pattern("...")`,
`{v, ...}`, earlier classes by name, and `|`, `&`, `-`. It needs no name resolution (a
type name is one of the scalar names or an alias of the spec).
"""

import spec.types as ty
import spec.ast as sx
from spec.spec import Spec
from value.bigint import BigInt
from value.fixed import int_max, int_min, pattern_of
from value.floats import exactly, to_real
from value.float_formats import FORMATS, FloatFormat, format_by_id
from value.literal import parse_number
from value.real import Real
from sets import BitSet, SetContext
from spec.ast import Ast, Node

from .ranges import float_range

comptime NO_FORMAT = FloatFormat(0, 0, 0)


@fieldwise_init
struct Elem(Equatable, ImplicitlyCopyable):
    """A fixed-width element type: bool, a fixed integer or a float."""

    var kind: ty.TypeKind
    """BOOL, FIXED_INT or FLOAT."""
    var width: Int
    var signed: Bool
    var format: FloatFormat
    """A float's format, else NO_FORMAT."""

    @staticmethod
    def bool() -> Self:
        return Self(.BOOL, 1, False, NO_FORMAT)

    @staticmethod
    def int(width: Int, *, signed: Bool) -> Self:
        return Self(.FIXED_INT, width, signed, NO_FORMAT)

    @staticmethod
    def float(format: FloatFormat) -> Self:
        return Self(.FLOAT, format.width(), True, format)

    def is_bool(self) -> Bool:
        return self.kind == .BOOL

    def is_int(self) -> Bool:
        return self.kind == .FIXED_INT

    def is_float(self) -> Bool:
        return self.kind == .FLOAT

    def name(self) -> String:
        if self.is_int():
            return String("i" if self.signed else "u", self.width)
        return "bool" if self.is_bool() else String(self.format.name())

    def int_min(self) -> BigInt:
        return int_min(self.width, self.signed)

    def int_max(self) -> BigInt:
        return int_max(self.width, self.signed)


def elem_of(types: ty.Types, t: Int) -> Optional[Elem]:
    """The element type for type id `t`, or None when it is not fixed-width."""
    ref info = types.info(t)
    match info.kind:
        case .BOOL:
            return Elem.bool()
        case .FIXED_INT:
            return Elem.int(info.bits, signed=info.signed)
        case .FLOAT:
            try:
                return Elem.float(format_by_id(UInt8(info.bits)))
            except:
                return None
        case _:
            return None


def scalar_elem(name: StringSlice) -> Optional[Elem]:
    """The fixed-width type a scalar name denotes."""
    var scalars: List[Elem] = [Elem.bool()]
    scalars += [Elem.int(bits, signed=signed) for bits in [8, 16, 32, 64] for signed in [True, False]]
    scalars += [Elem.float(format) for format in materialize[FORMATS]()]
    for elem in scalars:
        if elem.name() == name:
            return elem
    return None


def alias_elems(types: ty.Types, aliases: Dict[String, Int]) -> Dict[String, Elem]:
    var out: Dict[String, Elem] = {}
    for alias in aliases.items():
        if case .Some(elem) = elem_of(types, alias.value):
            out[alias.key] = elem
    return out^


def describe(ast: Ast, e: Int) -> String:
    """What a node is, for a message: `the operator ==`, `a call to f`, `x`."""
    ref n = ast.nodes[e]
    match n.kind:
        case .BINARY:
            return String("the operator ", n.op)
        case .UNARY:
            return String("the operator ", "-" if n.op == .NEG else String(n.op))
        case .CALL if ast.nodes[n.children[0]].kind in [sx.NodeKind.NAME, sx.NodeKind.ATTR]:
            return String("a call to ", ast.nodes[n.children[0]].text)
        case .NUM:
            return String("the number ", n.text)
        case .ATTR:
            return String(".", n.text)
        case .NAME:
            return n.text.copy()
        case _:
            return String(n.kind)


def positional_args(ast: Ast, call: Int) -> Optional[List[Int]]:
    """The argument values of a CALL node (`[callee, TYPEARGS, ARG...]`), or None when
    an argument is named."""
    var args = ast.nodes[call].children[2:]
    if any([ast.nodes[arg].text != "" for arg in args]):
        return None
    var values = [ast.child(arg, 0) for arg in args]
    return values^


def only_arg(ast: Ast, call: Int) -> Optional[Int]:
    """The value of a call's argument, when it has exactly one and it is positional."""
    var args = positional_args(ast, call)
    if args is None or len(args.value()) != 1:
        return None
    return args.value()[0]


def _numerator(bound: Optional[Real]) -> Optional[BigInt]:
    if bound is None:
        return None
    return bound.value().numerator.copy()


def _written(n: Node, value: Real) -> String:
    """A constant as written when it is a number, else its value."""
    return n.text.copy() if n.kind == .NUM else String(value)


def _arithmetic(op: sx.Op, a: Real, b: Real) raises -> Real:
    match op:
        case .ADD:
            return a + b
        case .SUB:
            return a - b
        case .MUL:
            return a * b
        case _:
            return a / b


struct SetError(Copyable, Writable):
    """A set expression that doesn't compile: the node at fault and why."""

    var node: Int
    var message: String

    def __init__(out self, node: Int, message: Some[Writable]):
        self.node = node
        self.message = String(message)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.message)


@fieldwise_init
struct SetCompiler(Movable):
    """Compiles set expressions of one element type."""

    var elem: Elem
    var aliases: Dict[String, Elem]
    var classes: Dict[String, BitSet]

    def type_named(self, name: String) -> Optional[Elem]:
        var scalar = scalar_elem(name)
        return scalar if scalar is not None else self.aliases.get(name)

    def compile(self, mut ctx: SetContext, ast: Ast, e: Int) raises SetError -> BitSet:
        ref n = ast.nodes[e]
        match n.kind:
            case .BINARY if n.op in [sx.Op.BITOR, sx.Op.BITAND, sx.Op.SUB]:
                var a = self.compile(ctx, ast, n.children[0])
                var b = self.compile(ctx, ast, n.children[1])
                match n.op:
                    case .BITOR:
                        return ctx.union(a, b)
                    case .BITAND:
                        return ctx.intersection(a, b)
                    case _:
                        return ctx.difference(a, b)
            case .NAME:
                if case .Some(cls) = self.classes.get(n.text):
                    if Int(cls.width) != self.elem.width:
                        raise SetError(e, t"class {n.text} is a set of {cls.width}-bit values")
                    return cls
                if self.type_named(n.text) is not None:
                    raise SetError(e, t"{n.text} is a type; write {n.text}.all for all of it")
                raise SetError(
                    e, t"unknown class {n.text} (a class can only use classes defined before it)"
                )
            case .ATTR:
                var tname = self.owner(ast, n.children[0], n.text, e)
                if n.text in ["min", "max"]:
                    raise SetError(e, t"{tname}.{n.text} is a value, not a set; write {{{tname}.{n.text}}}")
                var named = self.named_set(ctx, n.text)
                if named is None:
                    raise SetError(e, t"{tname} has no set {n.text} (its sets are {self.set_names()})")
                return named.value()
            case .CALL:
                ref callee = ast.nodes[n.children[0]]
                if callee.kind == .ATTR and callee.text in ["range", "pattern"]:
                    var tname = self.owner(ast, callee.children[0], callee.text, e)
                    if callee.text == "range":
                        return self.range(ctx, ast, e, tname)
                    return self.pattern(ctx, ast, e, tname)
            case .SET:
                return ctx.exactly([self.member_bits(ast, k) for k in n.children], self.elem.width)
            case _:
                pass
        var name = self.elem.name()
        raise SetError(
            e,
            t"expected a set expression, got {describe(ast, e)}. Classes of a {name}"
            t" parameter are sets: {name}.nan, {name}.range(a, b),"
            t' {name}.pattern("..."), {{v, ...}} or earlier classes, combined with |, & and -',
        )

    def owner(self, ast: Ast, value: Int, member: String, whole: Int) raises SetError -> String:
        """The type name `value` writes, checked to be the partition's own type."""
        ref v = ast.nodes[value]
        var found = self.type_named(v.text) if v.kind == .NAME else None
        if found is None:
            raise SetError(whole, t"{describe(ast, value)}.{member} is not a partition set")
        if found.value() != self.elem:
            raise SetError(
                whole,
                t"{v.text}.{member} is a set of {found.value().name()} values, but this"
                t" partition is of {self.elem.name()}",
            )
        return v.text.copy()

    def set_names(self) -> String:
        if self.elem.is_float():
            return "nan, inf, zero, subnormal, normal, finite, positive, negative, all"
        return "zero, positive, negative, all" if self.elem.is_int() else "all"

    def named_set(self, mut ctx: SetContext, name: String) -> Optional[BitSet]:
        var width = self.elem.width
        if name == "all":
            return ctx.full(width)
        if self.elem.is_float():
            try:
                return ctx.float_named(self.elem.format, name)
            except:
                return None
        if not self.elem.is_int():
            return None
        match name:
            case "zero":
                return ctx.exactly([UInt64(0)], width)
            case "positive":
                return ctx.int_range(width, self.elem.signed, BigInt(), None)
            case "negative":
                return ctx.int_range(width, self.elem.signed, None, BigInt())
            case _:
                return None

    def range(
        self, mut ctx: SetContext, ast: Ast, call: Int, tname: String
    ) raises SetError -> BitSet:
        if not (self.elem.is_float() or self.elem.is_int()):
            raise SetError(call, t"{tname} has no range")
        var args = positional_args(ast, call)
        if args is None or len(args.value()) != 2 or ast.nodes[ast.child(call, 1)].children:
            raise SetError(call, t"{tname}.range takes two bounds: {tname}.range(start, stop)")
        var lo = self.bound(ast, args.value()[0], tname)
        var hi = self.bound(ast, args.value()[1], tname)
        if self.elem.is_float():
            return float_range(ctx, self.elem.format, lo, hi)
        return ctx.int_range(self.elem.width, self.elem.signed, _numerator(lo), _numerator(hi))

    def bound(self, ast: Ast, e: Int, tname: String) raises SetError -> Optional[Real]:
        if ast.nodes[e].kind == .NONE:
            return None
        var v = self.const(ast, e)
        var text = _written(ast.nodes[e], v)
        if self.elem.is_float():
            if exactly(self.elem.format, v) is None:
                raise SetError(
                    e,
                    t"{tname}.range bound {text} is not exactly representable in {self.elem.name()}",
                )
        elif self.elem.is_int():
            if not v.is_integer():
                raise SetError(e, t"{tname}.range bound {text} is not an integer")
            if v.numerator < self.elem.int_min() or self.elem.int_max() + 1 < v.numerator:
                raise SetError(
                    e,
                    t"{tname}.range bound {text} is outside {self.elem.name()}: bounds lie"
                    t" in [{tname}.min, {tname}.max + 1]",
                )
        return v^

    def pattern(
        self, mut ctx: SetContext, ast: Ast, call: Int, tname: String
    ) raises SetError -> BitSet:
        var arg = only_arg(ast, call)
        if arg is None or ast.nodes[arg.value()].kind != .STR:
            raise SetError(call, t'{tname}.pattern takes one string: {tname}.pattern("...")')
        try:
            return ctx.pattern(ast.nodes[arg.value()].text, self.elem.width)
        except err:
            raise SetError(arg.value(), t"{tname}.pattern: {err}")

    def member_bits(self, ast: Ast, e: Int) raises SetError -> UInt64:
        ref n = ast.nodes[e]
        var name = self.elem.name()
        if self.elem.is_bool():
            if n.kind != .BOOL:
                raise SetError(e, t"a bool set holds true and false, not {describe(ast, e)}")
            return UInt64(1) if n.op == .TRUE else UInt64(0)
        var v = self.const(ast, e)
        var text = _written(n, v)
        if self.elem.is_int():
            if (
                not v.is_integer()
                or v.numerator < self.elem.int_min()
                or self.elem.int_max() < v.numerator
            ):
                raise SetError(e, t"{text} is not a {name} value")
            return pattern_of(v.numerator, self.elem.width)
        if n.kind == .UNARY and n.op == .NEG and v.is_zero():
            raise SetError(
                e,
                t"-0 is the number 0, which is +0.0 as a {name}; write {name}.zero &"
                t" {name}.negative for -0.0, or 0 for +0.0",
            )
        var bits = exactly(self.elem.format, v)
        if bits is None:
            raise SetError(e, t"{text} is not exactly representable in {name}")
        return bits.value()

    def const(self, ast: Ast, e: Int) raises SetError -> Real:
        ref n = ast.nodes[e]
        match n.kind:
            case .NUM:
                try:
                    return parse_number(n.text)
                except err:
                    raise SetError(e, err)
            case .UNARY if n.op == .NEG:
                return -self.const(ast, n.children[0])
            case .BINARY if n.op in [sx.Op.ADD, sx.Op.SUB, sx.Op.MUL, sx.Op.DIV]:
                var a = self.const(ast, n.children[0])
                var b = self.const(ast, n.children[1])
                try:
                    return _arithmetic(n.op, a, b)
                except err:
                    raise SetError(e, err)
            case .ATTR if n.text in ["min", "max"]:
                ref owner = ast.nodes[n.children[0]]
                var found = self.type_named(owner.text) if owner.kind == .NAME else None
                if found is not None:
                    var elem = found.value()
                    var is_min = n.text == "min"
                    if elem.is_int():
                        return Real(elem.int_min() if is_min else elem.int_max())
                    if not elem.is_float():
                        raise SetError(e, t"{owner.text} has no {n.text}")
                    try:
                        var top = to_real(elem.format, elem.format.max_finite())
                        return -top if is_min else top^
                    except err:
                        raise SetError(e, err)
            case _:
                pass
        raise SetError(
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
    except err:
        raise Error(String(ast.diagnostic(err.node, err.message)))


def compiled_set(mut ctx: SetContext, spec: Spec, node: Int) raises -> Tuple[Int, BitSet]:
    """The element type of the set expression at `node`, and its set."""
    var elem = spec.types.info(spec.node_types[node]).args[0]
    return (elem, compile_set_aliased(ctx, spec.ast, spec.types, elem, node, {}, spec.aliases))
