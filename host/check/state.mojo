"""The checker's working state: diagnostics, name tables, the current clause context,
and the type relations (join, equality and order rules) the expression rules use.
"""

from std.collections import Dict

from numeric.literal import parse_number
from numeric.real import Real
from prelude.names import NAMES
from syntax import ast
from syntax.ast import Diagnostic

from check import types as ty
from check.psig import PreludeSig, make_sig
from check.spec import Resolution, Spec


comptime NO_TYPE = -1
"""The "no such type" answer of `join` and `non_eq_part`."""

# Context kinds that are not clause kinds (clause kinds are the ops of syntax.ast).
comptime K_PARTITION = 100
comptime K_PARTITION_SET = 101
comptime K_DEFAULT = 102
comptime K_DEF = 103
comptime K_OBSERVER = 104

comptime BUILTIN_TYPE_NAMES = (
    "f16 bf16 f32 f64 i8 i16 i32 i64 u8 u16 u32 u64 bool int real string bytes unit"
    " set list map option"
)
comptime FLOAT_SET_NAMES = "nan inf zero subnormal normal finite positive negative all"


def index_of(names: List[String], name: StringSlice) -> Int:
    """The first position of `name` in `names`, or -1."""
    for i in range(len(names)):
        if names[i] == name:
            return i
    return -1


def is_word_in(name: StringSlice, words: StringSlice) -> Bool:
    """Whether `name` is one of the space-separated `words`."""
    for word in words.split(" "):
        if word == name:
            return True
    return False


def is_reserved(name: StringSlice) -> Bool:
    return is_word_in(name, "old result self mp cr")


def is_builtin_type_name(name: StringSlice) -> Bool:
    return is_word_in(name, BUILTIN_TYPE_NAMES)


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


def float_set_name(name: StringSlice) -> Bool:
    return is_word_in(name, FLOAT_SET_NAMES)


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


struct Ctx(Copyable, Movable):
    """Where an expression is checked: what names, result, old and calls it may use."""

    var kind: Int
    var decl: String
    var tv_names: List[String]
    var tv_types: List[Int]
    var param_names: List[String]
    var param_types: List[Int]
    var has_result: Bool
    var result: Int
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
    var allow_spec_fn: Bool
    var class_names: List[String]
    var class_nodes: List[Int]
    var class_types: List[Int]
    var only_param: String
    var loc_names: List[String]
    var loc_types: List[Int]
    var loc_binders: List[Int]
    var in_old: Bool
    var old_scope: Int
    var hidden_names: List[String]
    var hidden_msgs: List[String]
    var aggregate_top: Int
    var extern_result: Int
    """In an observer's reading expression: the declared type, which a call of an
    undeclared qualified callable takes. -1 elsewhere."""

    def __init__(out self):
        self.kind = 0
        self.decl = String()
        self.tv_names = []
        self.tv_types = []
        self.param_names = []
        self.param_types = []
        self.has_result = False
        self.result = 0
        self.no_result = "result is not available here"
        self.self_t = -1
        self.self_model = -1
        self.no_self = "self is only available in methods and interface invariants"
        self.fields_of = -1
        self.allow_old = False
        self.no_old = "old(...) is only allowed in ensures"
        self.allow_spec_fn = False
        self.class_names = []
        self.class_nodes = []
        self.class_types = []
        self.only_param = String()
        self.loc_names = []
        self.loc_types = []
        self.loc_binders = []
        self.in_old = False
        self.old_scope = 0
        self.hidden_names = []
        self.hidden_msgs = []
        self.aggregate_top = 0
        self.extern_result = -1

    def tv_index(self, name: String) -> Int:
        return index_of(self.tv_names, name)

    def param_index(self, name: String) -> Int:
        return index_of(self.param_names, name)

    def class_index(self, name: String) -> Int:
        return index_of(self.class_names, name)

    def hidden_index(self, name: String) -> Int:
        return index_of(self.hidden_names, name)

    def local_index(self, name: String) -> Int:
        """The innermost binding of `name`."""
        for i in reversed(range(len(self.loc_names))):
            if self.loc_names[i] == name:
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
    var prelude_ids: Dict[String, Int]
    var prelude_sigs: List[PreludeSig]
    var scalars: Dict[String, Int]
    var fn_modifies: List[Bool]
    var decl_pos: List[Int]
    """By node id: the position of a declaration in Spec.fns, models or defs."""
    var clause_ids: Dict[String, Int]
    var def_edges: List[List[Int]]
    var def_nodes: List[Int]
    var cur_def: Int
    var sig_msg: String
    var sig_arg: Int
    var sig_key: String
    var unit: Int
    var bool_: Int
    var int_: Int
    var real_: Int
    var string_: Int
    var bytes_: Int
    var qerr_: Int

    def __init__(out self, var spec: Spec):
        self.decls = []
        self.spec = spec^
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
        self.scalars = {}
        self.fn_modifies = []
        self.decl_pos = List[Int](length=len(self.spec.ast.nodes), fill=-1)
        self.clause_ids = {}
        self.def_edges = []
        self.def_nodes = []
        self.cur_def = -1
        self.sig_msg = String()
        self.sig_arg = -1
        self.sig_key = String()
        for k, word in enumerate(NAMES.split(" ")):
            self.prelude_ids[String(word)] = k
            self.prelude_sigs.append(make_sig(String(word)))
        self.poison = self.spec.types.intern(ty.TypeInfo(ty.ANY, 0, False, "poison", [], []))
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

    def kid(self, n: Int, k: Int) -> Int:
        return self.spec.ast.nodes[n].children[k]

    def nkids(self, n: Int) -> Int:
        return len(self.spec.ast.nodes[n].children)

    def kids_of(self, n: Int) -> List[Int]:
        return self.spec.ast.nodes[n].children.copy()

    def line_of(self, n: Int) -> Int:
        return self.spec.ast.nodes[n].span.line

    def decl_nodes(self) -> List[Int]:
        """The declarations to check: those of every file read, or the first file's own
        when none were listed."""
        return self.decls.copy() if self.decls else self.spec.ast.nodes[self.spec.ast.root()].children.copy()

    def source_of(self, n: Int) -> String:
        return self.spec.ast.source_text(n)

    # -- reporting -------------------------------------------------------------

    def error(mut self, node: Int, message: Some[Writable]):
        self.diags.append(self.spec.ast.diagnostic(node, message))

    # -- types -----------------------------------------------------------------

    def tkind(self, t: Int) -> UInt8:
        return self.spec.types.infos[t].kind

    def text(self, t: Int) -> String:
        return self.spec.types.text(t)

    def is_any(self, t: Int) -> Bool:
        return self.spec.types.infos[t].kind == ty.ANY

    def is_poison(self, t: Int) -> Bool:
        return t == self.poison

    def is_integer(self, t: Int) -> Bool:
        return self.spec.types.is_integer(t)

    def is_numeric(self, t: Int) -> Bool:
        return self.spec.types.is_numeric(t)

    def is_stringish(self, t: Int) -> Bool:
        var k = self.tkind(t)
        return k == ty.STRING or k == ty.LITERAL

    def arg(self, t: Int, i: Int) -> Int:
        return self.spec.types.infos[t].args[i]

    def scalar(mut self, name: String) -> Int:
        """The built-in scalar type a one-word name denotes, or -1."""
        var found = self.scalars.get(name)
        if found is not None:
            return found.value()
        var t = self.spec.types.scalar(name)
        var id = t.value() if t is not None else -1
        self.scalars[name] = id
        return id

    def components(self, t: Int) -> List[Int]:
        var shared = self.tkind(t) in (ty.LIST, ty.OPTION, ty.SET, ty.MAP, ty.TUPLE, ty.RECORD, ty.MODEL)
        return self.spec.types.infos[t].args.copy() if shared else []

    def contains_kind(self, t: Int, kind: UInt8) -> Bool:
        if self.tkind(t) == kind:
            return True
        return any([self.contains_kind(c, kind) for c in self.components(t)])

    def contains_model(self, t: Int) -> Bool:
        return self.contains_kind(t, ty.MODEL)

    def contains_real(self, t: Int) -> Bool:
        return self.contains_kind(t, ty.REAL)

    def contains_any(self, t: Int) -> Bool:
        return self.contains_kind(t, ty.ANY)

    def join(mut self, a: Int, b: Int) -> Int:
        """The common type of two values (if-branches, list elements, operands of ==):
        integers of any width join to int, integers and reals to real, a float only
        with itself. -1 when there is none."""
        if self.is_any(a):
            return b
        if self.is_any(b):
            return a
        if a == b:
            return a
        var ka = self.tkind(a)
        var kb = self.tkind(b)
        if ka == ty.FLOAT or kb == ty.FLOAT:
            return NO_TYPE
        if self.is_integer(a) and self.is_integer(b):
            return self.int_
        if self.is_numeric(a) and self.is_numeric(b):
            return self.real_
        if self.is_stringish(a) and self.is_stringish(b):
            return self.string_
        if ka == ty.LIST and kb == ty.LIST:
            var e = self.join(self.arg(a, 0), self.arg(b, 0))
            return NO_TYPE if e < 0 else self.spec.types.list_of(e)
        if ka == ty.OPTION and kb == ty.OPTION:
            var e = self.join(self.arg(a, 0), self.arg(b, 0))
            return NO_TYPE if e < 0 else self.spec.types.option_of(e)
        if ka == ty.MAP and kb == ty.MAP:
            var k = self.join(self.arg(a, 0), self.arg(b, 0))
            var v = self.join(self.arg(a, 1), self.arg(b, 1))
            if k < 0 or v < 0:
                return NO_TYPE
            return self.spec.types.map_of(k, v)
        if ka == ty.TUPLE and kb == ty.TUPLE:
            var xs = self.spec.types.infos[a].args.copy()
            var ys = self.spec.types.infos[b].args.copy()
            if len(xs) != len(ys):
                return NO_TYPE
            var out: List[Int] = []
            for x, y in zip(xs, ys):
                var j = self.join(x, y)
                if j < 0:
                    return NO_TYPE
                out.append(j)
            return self.spec.types.tuple_of(out)
        return NO_TYPE

    def non_eq_part(self, t: Int) -> Int:
        """The component of t that lacks canonical equality, or -1 (unknown parts pass)."""
        var k = self.tkind(t)
        if k == ty.ANY:
            return NO_TYPE
        if k == ty.FLOAT or k == ty.MODEL or k == ty.SET or k == ty.FN:
            return t
        if k == ty.TYPEVAR:
            return t if not self.spec.types.infos[t].names else NO_TYPE
        if k in (ty.LIST, ty.OPTION, ty.MAP, ty.TUPLE, ty.RECORD):
            for c in self.components(t):
                var bad = self.non_eq_part(c)
                if bad >= 0:
                    return bad
        return NO_TYPE

    def ordered(self, t: Int) -> Bool:
        """has_total_order, letting unknown parts (an empty list literal) pass."""
        var k = self.tkind(t)
        if k == ty.ANY:
            return True
        if k == ty.LIST:
            return self.ordered(self.arg(t, 0))
        if k == ty.TUPLE:
            return all([self.ordered(e) for e in self.spec.types.infos[t].args])
        return self.spec.types.has_total_order(t)

    def satisfies(self, t: Int, bound: String) -> Bool:
        if bound == "" or self.is_any(t):
            return True
        if bound == "Eq":
            return self.non_eq_part(t) < 0
        return self.non_eq_part(t) < 0 and self.ordered(t)

    def type_constant(mut self, scalar: Int, attr: String) -> Int:
        """Type of `T.attr` for a scalar type, or -1 if T has no such constant."""
        var k = self.tkind(scalar)
        if k == ty.FLOAT:
            if attr == "min" or attr == "max":
                return scalar
            if float_set_name(attr):
                return self.spec.types.set_of(scalar)
        elif k == ty.FIXED_INT:
            if attr == "min" or attr == "max":
                return self.int_
            if attr == "all":
                return self.spec.types.set_of(scalar)
        elif k == ty.BOOL and attr == "all":
            return self.spec.types.set_of(scalar)
        return NO_TYPE

    def constants_of(self, scalar: Int) -> List[String]:
        var k = self.tkind(scalar)
        var out: List[String] = ["all"] if k == ty.BOOL else []
        if k == ty.FLOAT:
            out = ["min", "max"]
            out.extend([String(w) for w in FLOAT_SET_NAMES.split(" ")])
        elif k == ty.FIXED_INT:
            out = ["min", "max", "all"]
        if k == ty.FLOAT or k == ty.FIXED_INT:
            out.extend(["range(a, b)", 'pattern("...")'])
        return out^

    def has_set_constructor(self, scalar: Int, attr: String) -> Bool:
        return is_word_in(attr, "range pattern") and self.tkind(scalar) in (ty.FLOAT, ty.FIXED_INT)

    def contains_float(mut self, t: Int) -> Bool:
        """Whether values of type t hold floats, looking through model fields."""
        return self._contains_float(t, [])

    def _contains_float(mut self, t: Int, seen: List[Int]) -> Bool:
        var k = self.tkind(t)
        if k == ty.FLOAT:
            return True
        if k == ty.MODEL:
            var pos = self.model_pos_of_type(t)
            if pos < 0:
                return False
            if pos in seen:
                return False
            var inner = seen.copy()
            inner.append(pos)
            for i in range(len(self.spec.models[pos].observers)):
                if not self.spec.models[pos].observers[i].params and self._contains_float(self.observer_type(t, pos, i), inner):
                    return True
            return False
        return any([self._contains_float(c, seen) for c in self.components(t)])

    # -- models ----------------------------------------------------------------

    def model_pos_of_type(self, t: Int) -> Int:
        var found = self.model_index.get(self.spec.types.infos[t].name)
        return found.value() if found is not None else -1

    def observer_pos(self, model: Int, name: String) -> Int:
        for i in range(len(self.spec.models[model].observers)):
            if self.spec.models[model].observers[i].name == name:
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
        var k = self.kind_of(n)
        if k == .NUM:
            try:
                return parse_number(self.spec.ast.nodes[n].text)
            except:
                return None
        if k == .UNARY and self.op_of(n) == .NEG:
            var inner = self.literal_value(self.kid(n, 0))
            if inner is not None:
                return -inner.value()
        return None

    # -- resolutions -----------------------------------------------------------

    def resolve(mut self, node: Int, kind: UInt8, index: Int, owner: Int, name: String):
        self.spec.resolutions[node] = Resolution(kind, index, owner, name)

    def set_type(mut self, node: Int, t: Int):
        self.spec.node_types[node] = t
