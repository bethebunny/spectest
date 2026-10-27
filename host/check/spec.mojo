"""The checked form of a spec: what the checker builds and every later stage reads.

A `Spec` owns the syntax tree it was checked from and the type table. Expression
types and name resolutions are tables indexed by node id, so the evaluator and the
generator never re-derive a name or a type.

Declarations keep source order. Lists of declarations refer to each other by position
(`Fn.owner` is a position in `Spec.models`, `Fn.clauses` positions in `Spec.clauses`).
"""

from syntax.ast import Ast

from check.types import ANY_TYPE, Types


# What a NAME, ATTR or CALL node refers to. `index` and `owner` by kind:
comptime R_PARAM: UInt8 = 1
"""A parameter: index = its position in the enclosing callable's params."""
comptime R_RESULT: UInt8 = 2
"""The return value (in a constructor, the new handle)."""
comptime R_SELF: UInt8 = 3
"""The receiver of a method, or the model's handle inside its own invariants."""
comptime R_LOCAL: UInt8 = 4
"""A `let` or comprehension variable: index = node id of the LET or COMPREHENSION."""
comptime R_FIELD: UInt8 = 5
"""A bare zero-argument observer inside a model's own clauses: index = observer
position, owner = model position."""
comptime R_PRELUDE: UInt8 = 6
"""A system prelude function: index = its id in prelude.names."""
comptime R_DEF: UInt8 = 7
"""A single-expression definition: index = position in Spec.defs."""
comptime R_TYPE_CONST: UInt8 = 8
"""`i32.max`, `f64.nan`: index = the scalar type, name = the attribute."""
comptime R_SET_CTOR: UInt8 = 9
"""`f64.range(a, b)`, `u8.pattern("...")`: index = the scalar type, name = "range" or
"pattern"."""
comptime R_SPEC_FN: UInt8 = 10
"""A call of a declared library function, made as a planned call: index = position in
Spec.fns."""
comptime R_OBSERVER: UInt8 = 11
"""`h.width`, `df.cell(i, n)`: index = observer position, owner = model position."""
comptime R_RECORD_FIELD: UInt8 = 12
"""`r.f` on a record: index = field position, owner = the record type."""
comptime R_OLD: UInt8 = 13
"""`old(e)`."""
comptime R_CLASS: UInt8 = 14
"""A reference to an earlier partition class: index = node id of the CLASS."""
comptime R_ENUM_MEMBER: UInt8 = 15
"""`Color.Red` or a bare member: index = member position, owner = the enum type."""
comptime R_CONST: UInt8 = 16
"""A declared library constant: index = position in Spec.consts."""
comptime R_QERR_PART: UInt8 = 17
"""`e.steps` or `e.nans` on a qerr: name = the part."""
comptime R_EXTERN: UInt8 = 18
"""A call of a qualified callable the spec doesn't declare, in an observer's reading
expression (`= builtins.list(self)`): name = the qualified callable. The call has the
observer's declared type."""


@fieldwise_init
struct Resolution(Copyable, Movable):
    var kind: UInt8
    var index: Int
    var owner: Int
    var name: String


@fieldwise_init
struct Param(Copyable, Movable):
    var name: String
    var type: Int
    var default: Int
    """Node id of the default expression, or 0."""
    var node: Int


@fieldwise_init
struct Clause(Copyable, Movable):
    var id: String
    """`<decl>.<label>` or `<decl>#<n>`, as verdicts name it."""
    var kind: UInt8
    """The clause kind, an op of syntax.ast (REQUIRES, ENSURES, ...)."""
    var label: String
    var node: Int
    var expr: Int
    """Node id of the condition (the `when` of raises and may_raise), or 0."""
    var error: String
    """raises and may_raise: the qualified exception class."""
    var names: List[String]
    """modifies: the parameter names; unspecified and impl_defined: the freedom."""
    var owner_fn: Int
    """Position in Spec.fns, or -1 for a model's or interface's own clause."""
    var owner_model: Int
    """Position in Spec.models of the enclosing model or interface, or -1."""


@fieldwise_init
struct PartitionClass(Copyable, Movable):
    var name: String
    var node: Int
    var expr: Int


@fieldwise_init
struct Partition(Copyable, Movable):
    var param: Int
    """Position of the partitioned parameter."""
    var node: Int
    var classes: List[PartitionClass]


@fieldwise_init
struct Observer(Copyable, Movable):
    var name: String
    var params: List[Param]
    var type: Int
    var expr: Int
    """Node id of the reading expression (`= builtins.list(self)`), or 0 to read the
    attribute of the same name."""
    var node: Int


@fieldwise_init
struct Build(Copyable, Movable):
    var target: String
    """The qualified callable that makes a value of the model."""
    var params: List[Param]
    var node: Int


@fieldwise_init
struct Fn(Copyable, Movable):
    var name: String
    """The qualified name of the callable it tests, or a constructor's or method's own
    name inside an interface."""
    var target: String
    """The qualified name the driver resolves: `name`, or `<interface>.<name>` for an
    interface's constructors and methods."""
    var decl_id: String
    """The prefix of its clause ids: `cos`, `Deque.pop`."""
    var kind: UInt8
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
struct Model(Copyable, Movable):
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


@fieldwise_init
struct Def(Copyable, Movable):
    var name: String
    var node: Int
    var tparams: List[String]
    var bounds: List[String]
    var params: List[Param]
    var result: Int
    var body: Int
    """Node id of the body expression."""


@fieldwise_init
struct Const(Copyable, Movable):
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
        for i in range(len(self.fns)):
            if self.fns[i].name == name:
                return i
        return None

    def model_named(self, name: StringSlice) -> Optional[Int]:
        for i in range(len(self.models)):
            if self.models[i].name == name:
                return i
        return None

    def clause_named(self, id: StringSlice) -> Optional[Int]:
        for i in range(len(self.clauses)):
            if self.clauses[i].id == id:
                return i
        return None
