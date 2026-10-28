"""The checker's working state: diagnostics, name tables, the current clause context,
and the type relations (join, equality and order rules) the expression rules use.
"""

from numeric.real import Real
from prelude.names import prelude_count, prelude_name
from syntax import ast
from syntax.ast import Diagnostic

from check import types as ty
from check.psig import PreludeSig, prelude_sig
from check.spec import Resolution, ResolutionKind, Spec, literal_value


comptime NO_TYPE = -1
"""The "no such type" answer of `join` and `non_eq_part`."""

comptime FLOAT_SETS: Array[StaticString, 9] = [
    "nan", "inf", "zero", "subnormal", "normal", "finite", "positive", "negative", "all"
]
"""The partition sets `T.<name>` of a float type T."""


__enum Visit(Equatable, ImplicitlyCopyable):
    """Where a depth-first walk is with a node."""

    case UNSEEN
    case ON_PATH
    case DONE

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()


def last_index_of(names: List[String], name: StringSlice) -> Int:
    """The last position of `name` in `names`, or -1."""
    for i in reversed(range(len(names))):
        if names[i] == name:
            return i
    return -1


def is_reserved(name: StringSlice) -> Bool:
    match name:
        case "old" | "result" | "self" | "mp" | "cr":
            return True
        case _:
            return False


def is_builtin_type_name(name: StringSlice) -> Bool:
    match name:
        case "bool" | "int" | "real" | "string" | "bytes" | "unit" | "set" | "list" | "map" | "option":
            return True
        case "f16" | "bf16" | "f32" | "f64" | "i8" | "i16" | "i32" | "i64" | "u8" | "u16" | "u32" | "u64":
            return True
        case _:
            return False


def type_hint(name: StringSlice) -> String:
    match name:
        case "float" | "double":
            return "f64"
        case "str" | "String":
            return "string"
        case "integer" | "Int":
            return "int"
        case "boolean" | "Bool":
            return "bool"
        case "List":
            return "list"
        case "Map" | "dict":
            return "map"
        case "Option":
            return "option"
        case _:
            return String()


def is_float_set(name: StringSlice) -> Bool:
    return any([name == s for s in materialize[FLOAT_SETS]()])


def classifier_hint(name: StringSlice) -> String:
    match name:
        case "nan":
            return "is_nan(x)"
        case "inf":
            return "is_inf(x)"
        case "zero":
            return "is_zero(x)"
        case "subnormal":
            return "is_subnormal(x)"
        case "finite":
            return "is_finite(x)"
        case "negative":
            return "signbit(x)"
        case "positive":
            return "not signbit(x)"
        case _:
            return String()


def qualify_error(name: String) -> String:
    """`ValueError` is `builtins.ValueError`; a dotted name is already qualified."""
    return name.copy() if "." in name else "builtins." + name


@fieldwise_init
struct Var(Copyable):
    """A name in scope: a type variable, parameter, partition class or local."""

    var name: String
    var type: Int
    var node: Int
    """A class's CLASS node, or the LET or COMPREHENSION that binds a local; else 0."""


def _position(vars: List[Var], name: StringSlice) -> Int:
    for i, v in enumerate(vars):
        if v.name == name:
            return i
    return -1


struct Ctx(Copyable):
    """Where an expression is checked: what names, result, old and calls it may use."""

    var tvars: List[Var]
    var params: List[Var]
    """By position; a receiver is named ""."""
    var classes: List[Var]
    """In a partition class: the partition's earlier classes."""
    var locals: List[Var]
    """The `let` and comprehension variables in scope, innermost last."""
    var hidden: Dict[String, String]
    """Names that may not be used here, to the message that says why."""
    var result: Int
    """The type of `result`, or -1 where there is none."""
    var no_result: String
    var self_t: Int
    """The receiver's type, or -1."""
    var self_model: Int
    """Position of the receiver's model, or -1."""
    var no_self: String
    var fields_of: Int
    """Position of the model whose observers are bare names here, or -1."""
    var allow_old: Bool
    var no_old: String
    var in_old: Bool
    var old_scope: Int
    """In old(...): how many of `locals` are bound outside it."""
    var allow_spec_fn: Bool
    var in_partition_set: Bool
    """Whether the expression is a partition set: a class of a fixed-width parameter,
    or the set a top comprehension ranges over."""
    var only_param: String
    """In a partition class: the partitioned parameter, the only one it may name."""
    var aggregate_top: Int
    """In an aggregate clause: the top comprehension, which may range over a set."""
    var extern_result: Int
    """In an observer's reading expression: the declared type, which a call of an
    undeclared qualified callable takes. -1 elsewhere."""

    def __init__(
        out self,
        *,
        var tvars: List[Var] = [],
        var params: List[Var] = [],
        var classes: List[Var] = [],
        result: Int = NO_TYPE,
        var no_result: String = "result is not available here",
        self_t: Int = -1,
        self_model: Int = -1,
        var no_self: String = "self is only available in methods and interface invariants",
        fields_of: Int = -1,
        allow_old: Bool = False,
        var no_old: String = "old(...) is only allowed in ensures",
        allow_spec_fn: Bool = False,
        in_partition_set: Bool = False,
        var only_param: String = "",
        extern_result: Int = -1,
    ):
        self.tvars = tvars^
        self.params = params^
        self.classes = classes^
        self.locals = []
        self.hidden = {}
        self.result = result
        self.no_result = no_result^
        self.self_t = self_t
        self.self_model = self_model
        self.no_self = no_self^
        self.fields_of = fields_of
        self.allow_old = allow_old
        self.no_old = no_old^
        self.in_old = False
        self.old_scope = 0
        self.allow_spec_fn = allow_spec_fn
        self.in_partition_set = in_partition_set
        self.only_param = only_param^
        self.aggregate_top = 0
        self.extern_result = extern_result

    def tvar_index(self, name: String) -> Int:
        return _position(self.tvars, name)

    def param_index(self, name: String) -> Int:
        return _position(self.params, name)

    def class_index(self, name: String) -> Int:
        return _position(self.classes, name)

    def local_index(self, name: String) -> Int:
        """The innermost binding of `name`, or -1."""
        for i in reversed(range(len(self.locals))):
            if self.locals[i].name == name:
                return i
        return -1


struct Checker:
    var spec: Spec
    var decls: List[Int]
    """The declarations to check, over every file: spec files first, then preludes."""
    var diags: List[Diagnostic]
    var poison: Int
    var ctx: Ctx
    var names: Dict[String, Int]
    """Declared top-level names to their declaration nodes."""
    var duplicate: List[Bool]
    """By node id: a declaration that repeats a name; its body is not checked."""
    var fn_index: Dict[String, Int]
    var def_index: Dict[String, Int]
    var model_index: Dict[String, Int]
    var const_index: Dict[String, Int]
    var enum_index: Dict[String, Int]
    var record_nodes: Dict[String, Int]
    var record_types: Dict[String, Int]
    var alias_nodes: Dict[String, Int]
    var active: List[String]
    """The aliases and records being resolved, outermost first."""
    var prelude_ids: Dict[String, Int]
    var prelude_sigs: List[PreludeSig]
    """By prelude id."""
    var scalars: Dict[String, Int]
    """Names looked up with `scalar`, to the scalar type or -1."""
    var decl_pos: List[Int]
    """By node id: the position of a declaration in Spec.fns, models or defs."""
    var clause_ids: Dict[String, Int]
    var def_calls: List[List[Int]]
    """By definition: the definitions its body calls."""
    var current_def: Int
    """The definition whose body is being checked, or -1."""
    var unit: Int
    var bool_: Int
    var int_: Int
    var real_: Int
    var string_: Int
    var bytes_: Int
    var qerr_: Int

    def __init__(out self, var spec: Spec, var decls: List[Int]):
        self.spec = spec^
        self.decls = decls^
        self.diags = []
        self.ctx = Ctx()
        self.names = {}
        self.duplicate = List[Bool](length=len(self.spec.ast.nodes), fill=False)
        self.fn_index = {}
        self.def_index = {}
        self.model_index = {}
        self.const_index = {}
        self.enum_index = {}
        self.record_nodes = {}
        self.record_types = {}
        self.alias_nodes = {}
        self.active = []
        self.prelude_ids = {}
        self.prelude_sigs = []
        for id in range(prelude_count()):
            var name = prelude_name(id)
            self.prelude_sigs.append(prelude_sig(name))
            self.prelude_ids[name^] = id
        self.scalars = {}
        self.decl_pos = List[Int](length=len(self.spec.ast.nodes), fill=-1)
        self.clause_ids = {}
        self.def_calls = []
        self.current_def = -1
        self.poison = self.spec.types.intern(ty.TypeInfo(.ANY, name="poison"))
        self.unit = self.spec.types.unit()
        self.bool_ = self.spec.types.bool_()
        self.int_ = self.spec.types.int_()
        self.real_ = self.spec.types.real()
        self.string_ = self.spec.types.string()
        self.bytes_ = self.spec.types.bytes()
        self.qerr_ = self.spec.types.qerr()

    def into_spec(deinit self) -> Spec:
        return self.spec^

    # -- tree access ----------------------------------------------------------

    def kind_of(self, n: Int) -> ast.NodeKind:
        return self.spec.ast.nodes[n].kind

    def op_of(self, n: Int) -> ast.Op:
        return self.spec.ast.nodes[n].op

    def text_of(self, n: Int) -> String:
        return self.spec.ast.nodes[n].text.copy()

    def child(self, n: Int, k: Int) -> Int:
        return self.spec.ast.nodes[n].children[k]

    def children(self, n: Int) -> List[Int]:
        return self.spec.ast.nodes[n].children.copy()

    def call_args(self, call: Int) -> List[Int]:
        """The ARG nodes of a CALL."""
        return List(self.spec.ast.nodes[call].children[2:])

    def line_of(self, n: Int) -> Int:
        return self.spec.ast.nodes[n].span.line

    def source_of(self, n: Int) -> String:
        return self.spec.ast.source_text(n)

    def has_modifies(self, decl: Int) -> Bool:
        """Whether a declaration has a modifies clause."""
        return any([self.kind_of(k) == .CLAUSE and self.op_of(k) == .MODIFIES for k in self.spec.ast.nodes[decl].children])

    # -- reporting -------------------------------------------------------------

    def error(mut self, node: Int, message: Some[Writable]):
        self.diags.append(self.spec.ast.diagnostic(node, message))

    # -- types -----------------------------------------------------------------

    def tkind(self, t: Int) -> ty.TypeKind:
        return self.spec.types.infos[t].kind

    def text(self, t: Int) -> String:
        return self.spec.types.text(t)

    def is_any(self, t: Int) -> Bool:
        return self.tkind(t) == .ANY

    def is_poison(self, t: Int) -> Bool:
        return t == self.poison

    def is_integer(self, t: Int) -> Bool:
        return self.spec.types.is_integer(t)

    def is_numeric(self, t: Int) -> Bool:
        return self.spec.types.is_numeric(t)

    def is_stringish(self, t: Int) -> Bool:
        var k = self.tkind(t)
        return k == .STRING or k == .LITERAL

    def arg(self, t: Int, i: Int) -> Int:
        return self.spec.types.infos[t].args[i]

    def scalar(mut self, name: String) -> Int:
        """The built-in scalar type a one-word name denotes, or -1."""
        if case .Some(found) = self.scalars.get(name):
            return found
        var t = self.spec.types.scalar(name).or_else(NO_TYPE)
        self.scalars[name] = t
        return t

    def contains_model(self, t: Int) -> Bool:
        return self.spec.types.contains_kind(t, .MODEL)

    def contains_real(self, t: Int) -> Bool:
        return self.spec.types.contains_kind(t, .REAL)

    def contains_any(self, t: Int) -> Bool:
        return self.spec.types.contains_kind(t, .ANY)

    def join(mut self, a: Int, b: Int) -> Int:
        """The common type of two values (if-branches, list elements, operands of ==):
        integers of any width join to int, integers and reals to real, a float only
        with itself. -1 when there is none."""
        if self.is_any(a):
            return b
        if self.is_any(b) or a == b:
            return a
        var ka = self.tkind(a)
        var kb = self.tkind(b)
        if ka == .FLOAT or kb == .FLOAT:
            return NO_TYPE
        if self.is_integer(a) and self.is_integer(b):
            return self.int_
        if self.is_numeric(a) and self.is_numeric(b):
            return self.real_
        if self.is_stringish(a) and self.is_stringish(b):
            return self.string_
        match ka, kb:
            case .LIST, .LIST:
                var e = self.join(self.arg(a, 0), self.arg(b, 0))
                return NO_TYPE if e < 0 else self.spec.types.list_of(e)
            case .OPTION, .OPTION:
                var e = self.join(self.arg(a, 0), self.arg(b, 0))
                return NO_TYPE if e < 0 else self.spec.types.option_of(e)
            case .MAP, .MAP:
                var k = self.join(self.arg(a, 0), self.arg(b, 0))
                var v = self.join(self.arg(a, 1), self.arg(b, 1))
                return NO_TYPE if k < 0 or v < 0 else self.spec.types.map_of(k, v)
            case .TUPLE, .TUPLE:
                var xs = self.spec.types.infos[a].args.copy()
                var ys = self.spec.types.infos[b].args.copy()
                if len(xs) != len(ys):
                    return NO_TYPE
                var joined: List[Int] = []
                for x, y in zip(xs, ys):
                    var j = self.join(x, y)
                    if j < 0:
                        return NO_TYPE
                    joined.append(j)
                return self.spec.types.tuple_of(joined)
            case _:
                return NO_TYPE

    def non_eq_part(self, t: Int) -> Int:
        """The component of t that lacks canonical equality, or -1 (unknown parts pass)."""
        match self.tkind(t):
            case .FLOAT | .MODEL | .SET | .FN:
                return t
            case .TYPEVAR:
                return t if not self.spec.types.infos[t].names else NO_TYPE
            case .LIST | .OPTION | .MAP | .TUPLE | .RECORD:
                for c in self.spec.types.components(t):
                    var bad = self.non_eq_part(c)
                    if bad >= 0:
                        return bad
                return NO_TYPE
            case _:
                return NO_TYPE

    def ordered(self, t: Int) -> Bool:
        """Whether t has a total order, letting unknown parts (an empty list literal) pass."""
        match self.tkind(t):
            case .ANY:
                return True
            case .LIST:
                return self.ordered(self.arg(t, 0))
            case .TUPLE:
                return all([self.ordered(e) for e in self.spec.types.infos[t].args])
            case _:
                return self.spec.types.has_total_order(t)

    def satisfies(self, t: Int, bound: String) -> Bool:
        if bound == "" or self.is_any(t):
            return True
        if bound == "Eq":
            return self.non_eq_part(t) < 0
        return self.non_eq_part(t) < 0 and self.ordered(t)

    def type_constant(mut self, scalar: Int, attr: String) -> Int:
        """Type of `T.attr` for a scalar type, or -1 if T has no such constant."""
        var is_bound = attr == "min" or attr == "max"
        match self.tkind(scalar):
            case .FLOAT if is_bound:
                return scalar
            case .FLOAT if is_float_set(attr):
                return self.spec.types.set_of(scalar)
            case .FIXED_INT if is_bound:
                return self.int_
            case .FIXED_INT | .BOOL if attr == "all":
                return self.spec.types.set_of(scalar)
            case _:
                return NO_TYPE

    def constants_of(self, scalar: Int) -> List[String]:
        match self.tkind(scalar):
            case .BOOL:
                return ["all"]
            case .FLOAT:
                var out: List[String] = ["min", "max"]
                out.extend([String(s) for s in materialize[FLOAT_SETS]()])
                out.extend(["range(a, b)", 'pattern("...")'])
                return out^
            case .FIXED_INT:
                return ["min", "max", "all", "range(a, b)", 'pattern("...")']
            case _:
                return []

    def has_set_constructor(self, scalar: Int, attr: String) -> Bool:
        match self.tkind(scalar):
            case .FLOAT | .FIXED_INT:
                return attr == "range" or attr == "pattern"
            case _:
                return False

    def contains_float(mut self, t: Int) -> Bool:
        """Whether values of type t hold floats, looking through model fields."""
        return self._contains_float(t, [])

    def _contains_float(mut self, t: Int, seen: List[Int]) -> Bool:
        match self.tkind(t):
            case .FLOAT:
                return True
            case .MODEL:
                var pos = self.model_pos_of_type(t)
                if pos < 0 or pos in seen:
                    return False
                var inner = seen + [pos]
                for i in self.spec.models[pos].fields():
                    if self._contains_float(self.observer_type(t, pos, i), inner):
                        return True
                return False
            case _:
                return any([self._contains_float(c, seen) for c in self.spec.types.components(t)])

    # -- models ----------------------------------------------------------------

    def model_pos_of_type(self, t: Int) -> Int:
        return self.model_index.get(self.spec.types.infos[t].name).or_else(-1)

    def observer_pos(self, model: Int, name: String) -> Int:
        for i, o in enumerate(self.spec.models[model].observers):
            if o.name == name:
                return i
        return -1

    def observer_names(self, model: Int) -> String:
        var names = [o.name.copy() for o in self.spec.models[model].observers]
        return ", ".join(names) if names else "none"

    def observer_type(mut self, mt: Int, model: Int, obs: Int) -> Int:
        var declared = self.spec.models[model].observers[obs].type
        var tparams = self.spec.models[model].tparams.copy()
        var args = self.spec.types.infos[mt].args.copy()
        if not tparams or len(args) != len(tparams):
            return declared
        return self.spec.types.substitute(declared, tparams, args)

    # -- literals --------------------------------------------------------------

    def literal_value(self, n: Int) -> Optional[Real]:
        """The value of a numeric literal, possibly negated."""
        return literal_value(self.spec.ast, n)

    # -- resolutions -----------------------------------------------------------

    def resolve(mut self, node: Int, kind: ResolutionKind, name: String, *, index: Int = 0, owner: Int = -1):
        self.spec.resolutions[node] = Resolution(kind, index, owner, name)

    def set_type(mut self, node: Int, t: Int):
        self.spec.node_types[node] = t
