"""The checked form of a spec: what the checker builds and every later stage reads.

A `Spec` owns the syntax tree it was checked from and the type table. Expression
types and name resolutions are tables indexed by node id, so the evaluator and the
generator never re-derive a name or a type.

Declarations keep source order. Lists of declarations refer to each other by position
(`Fn.owner` is a position in `Spec.models`, `Fn.clauses` positions in `Spec.clauses`).
"""

from numeric.literal import parse_number
from numeric.real import Real
from syntax.ast import Ast, NodeKind, Op

from check.types import ANY_TYPE, Types


comptime _RESOLUTION_NAMES: Array[StaticString, 18] = [
    "param", "result", "self", "local", "field", "prelude", "def", "type_const", "set_ctor",
    "spec_fn", "observer", "record_field", "old", "class", "enum_member", "const", "qerr_part",
    "extern",
]


__enum ResolutionKind(Equatable, ImplicitlyCopyable, Intable, Writable):
    """What a NAME, ATTR or CALL node refers to. Writes as its lowercase name.

    By kind, what it is, and its Resolution's `index`, `owner` and `name`:
      - PARAM: a parameter; index its position in the enclosing callable's params
      - RESULT: the return value, or in a constructor the new handle
      - SELF: the receiver of a method, or the model's handle inside its own invariants
      - LOCAL: a `let` or comprehension variable; index the LET or COMPREHENSION node
      - FIELD: a bare zero-argument observer inside a model's own clauses; index the
        observer's position, owner the model's
      - PRELUDE: a system prelude function; index its id in prelude.names
      - DEF: a single-expression definition; index its position in Spec.defs
      - TYPE_CONST: `i32.max`, `f64.nan`; index the scalar type, name the attribute
      - SET_CTOR: `f64.range(a, b)`, `u8.pattern("...")`; index the scalar type, name
        "range" or "pattern"
      - SPEC_FN: a call of a declared library function, made as a planned call; index
        its position in Spec.fns
      - OBSERVER: `h.width`, `df.cell(i, n)`; index the observer's position, owner the
        model's
      - RECORD_FIELD: `r.f` on a record; index the field's position, owner the record type
      - OLD: `old(e)`
      - CLASS: an earlier partition class; index the CLASS node
      - ENUM_MEMBER: `Color.Red` or a bare member; index the member's position, owner the
        enum type
      - CONST: a declared library constant; index its position in Spec.consts
      - QERR_PART: `e.steps` or `e.nans` on a qerr; name the part
      - EXTERN: a call of a qualified callable the spec doesn't declare, in an observer's
        reading expression (`= builtins.list(self)`), which has the observer's declared
        type; name the callable
    """

    case PARAM
    case RESULT
    case SELF
    case LOCAL
    case FIELD
    case PRELUDE
    case DEF
    case TYPE_CONST
    case SET_CTOR
    case SPEC_FN
    case OBSERVER
    case RECORD_FIELD
    case OLD
    case CLASS
    case ENUM_MEMBER
    case CONST
    case QERR_PART
    case EXTERN

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()

    def __int__(self) -> Int:
        return Int(self._get_enum_discriminant())

    def write_to(self, mut writer: Some[Writer]):
        writer.write(materialize[_RESOLUTION_NAMES]()[Int(self)])


@fieldwise_init
struct Resolution(Copyable):
    var kind: ResolutionKind
    var index: Int
    var owner: Int
    var name: String


@fieldwise_init
struct Param(Copyable):
    var name: String
    var type: Int
    var default: Int
    """Node id of the default expression, or 0."""
    var node: Int


@fieldwise_init
struct Clause(Copyable):
    var id: String
    """`<decl>.<label>` or `<decl>#<n>`, as verdicts name it."""
    var kind: Op
    """The clause kind, an op of syntax.ast (REQUIRES, ENSURES, ...)."""
    var label: String
    var node: Int
    var expr: Int
    """Node id of the condition (the `when` of raises and may_raise), or 0."""
    var error: String
    """The qualified exception class of raises and may_raise."""
    var names: List[String]
    """The parameter names of modifies, or the freedom of unspecified and impl_defined."""
    var owner_fn: Int
    """Position in Spec.fns, or -1 for a model's or interface's own clause."""
    var owner_model: Int
    """Position in Spec.models of the enclosing model or interface, or -1."""


@fieldwise_init
struct PartitionClass(Copyable):
    var name: String
    var node: Int
    var expr: Int


@fieldwise_init
struct Partition(Copyable):
    var param: Int
    """Position of the partitioned parameter."""
    var node: Int
    var classes: List[PartitionClass]


@fieldwise_init
struct Observer(Copyable):
    var name: String
    var params: List[Param]
    var type: Int
    var expr: Int
    """Node id of the reading expression (`= builtins.list(self)`), or 0 to read the
    attribute of the same name."""
    var node: Int


@fieldwise_init
struct Build(Copyable):
    var target: String
    """The qualified callable that makes a value of the model."""
    var params: List[Param]
    var node: Int


@fieldwise_init
struct Fn(Copyable):
    var name: String
    """The qualified name of the callable it tests, or a constructor's or method's own
    name inside an interface."""
    var target: String
    """The qualified name the driver resolves: `name`, or `<interface>.<name>` for an
    interface's constructors and methods."""
    var decl_id: String
    """The prefix of its clause ids: `cos`, `Deque.pop`."""
    var kind: NodeKind
    """FN, CTOR or METHOD (node kinds of syntax.ast)."""
    var node: Int
    var owner: Int
    """Position in Spec.models of the enclosing interface, or of the model a qualified
    function's `self` belongs to; -1 otherwise."""
    var tparams: List[String]
    var bounds: List[String]
    """Each type parameter's bound: "Eq", "Ord" or ""."""
    var params: List[Param]
    var receiver: Bool
    """Whether params[0] is `self`."""
    var result: Int
    """The return type; UNIT when the function returns nothing."""
    var partitions: List[Partition]
    var clauses: List[Int]
    """Positions in Spec.clauses."""


@fieldwise_init
struct Model(Copyable):
    var name: String
    var node: Int
    var is_interface: Bool
    var type: Int
    """Its handle type, over its own type parameters."""
    var tparams: List[String]
    var bounds: List[String]
    var observers: List[Observer]
    var builds: List[Build]
    var ctors: List[Int]
    """Positions in Spec.fns."""
    var methods: List[Int]
    """Positions in Spec.fns."""
    var clauses: List[Int]
    """Positions in Spec.clauses: invariants and freedoms."""

    def fields(self) -> List[Int]:
        """The positions of its observers that take no arguments."""
        return [i for i, o in enumerate(self.observers) if not o.params]


@fieldwise_init
struct Def(Copyable):
    var name: String
    var node: Int
    var tparams: List[String]
    var bounds: List[String]
    var params: List[Param]
    var result: Int
    var body: Int
    """Node id of the body expression."""


@fieldwise_init
struct Const(Copyable):
    var name: String
    var type: Int
    var node: Int


struct Spec(Movable):
    var name: String
    var ast: Ast
    var types: Types
    var fns: List[Fn]
    var models: List[Model]
    var defs: List[Def]
    var consts: List[Const]
    var clauses: List[Clause]
    var errors: List[String]
    """Error classes declared with `error`."""
    var enums: List[Int]
    """Enum types, in declaration order."""
    var records: List[Int]
    """Record types, in declaration order."""
    var aliases: Dict[String, Int]
    var node_types: List[Int]
    """The type of each expression node, by node id; ANY_TYPE for other nodes."""
    var resolutions: Dict[Int, Resolution]
    """What each NAME, ATTR and CALL node that names something refers to."""

    def __init__(out self, var name: String, var ast: Ast, var types: Types):
        self.name = name^
        var n = len(ast.nodes)
        self.ast = ast^
        self.types = types^
        self.fns = []
        self.models = []
        self.defs = []
        self.consts = []
        self.clauses = []
        self.errors = []
        self.enums = []
        self.records = []
        self.aliases = {}
        self.node_types = List[Int](length=n, fill=ANY_TYPE)
        self.resolutions = {}

    def resolution(self, node: Int) -> Optional[Resolution]:
        return self.resolutions.get(node)

    def fn_named(self, name: StringSlice) -> Optional[Int]:
        for i, f in enumerate(self.fns):
            if f.name == name:
                return i
        return None

    def model_named(self, name: StringSlice) -> Optional[Int]:
        for i, m in enumerate(self.models):
            if m.name == name:
                return i
        return None

    def clause_named(self, id: StringSlice) -> Optional[Int]:
        for i, clause in enumerate(self.clauses):
            if clause.id == id:
                return i
        return None


def literal_value(ast: Ast, n: Int) -> Optional[Real]:
    """The value of a numeric literal, possibly negated."""
    ref node = ast.nodes[n]
    match node.kind:
        case .NUM:
            try:
                return parse_number(node.text)
            except:
                return None
        case .UNARY if node.op == .NEG:
            if case .Some(inner) = literal_value(ast, node.children[0]):
                return -inner
            return None
        case _:
            return None


comptime _AGGREGATE_SHAPES = (
    "an aggregate clause has one of the shapes sum(v in S: e) <= c, sum(v in S: e) <"
    " c, sum(v in S: e) == 0, max(v in S: e) <= c, max(v in S: e) < c or all(v in S:"
    " p), with S a set such as f16.all or a list, and c a constant"
)
comptime _SUM_EQUALS_ZERO = (
    "sum(...) == c is an aggregate shape only for c = 0, where it demands that every"
    " term is 0; bound the total with sum(...) <= c instead"
)


@fieldwise_init
struct AggregateShape(Copyable):
    """The parts of an aggregate clause's condition."""

    var top: Int
    """The top comprehension, which ranges over the input set, or 0."""
    var bound: Int
    """The bound a sum or max is compared with, or 0."""
    var problem: String
    """What is wrong with the shape, or ""."""


def aggregate_shape(ast: Ast, e: Int) -> AggregateShape:
    """The shape of the condition `e` of an aggregate clause."""
    ref node = ast.nodes[e]
    match node.kind:
        case .COMPREHENSION:
            return AggregateShape(e, 0, "" if node.op == .ALL else _AGGREGATE_SHAPES)
        case .BINARY:
            var left = node.children[0]
            var right = node.children[1]
            if ast.nodes[left].kind != .COMPREHENSION:
                var top = right if ast.nodes[right].kind == .COMPREHENSION else 0
                return AggregateShape(top, 0, _AGGREGATE_SHAPES)
            var op = node.op
            var allowed: Bool
            match ast.nodes[left].op:
                case .SUM:
                    allowed = op == .LE or op == .LT or op == .EQ
                case .MAX:
                    allowed = op == .LE or op == .LT
                case _:
                    allowed = False
            if not allowed:
                return AggregateShape(left, 0, _AGGREGATE_SHAPES)
            if op == .EQ:
                var v = literal_value(ast, right)
                if v is None or not (v.value() == Real(0)):
                    return AggregateShape(left, 0, _SUM_EQUALS_ZERO)
            return AggregateShape(left, right, "")
        case _:
            return AggregateShape(0, 0, _AGGREGATE_SHAPES)
