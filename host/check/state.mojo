"""The checker's working state: diagnostics, name tables, the current clause context,
and the type relations (join, equality and order rules) the expression rules use.
"""

from std.collections import Dict

from numeric.literal import is_integer_literal, parse_number
from numeric.real import Real
from prelude.names import NAMES
from syntax import ast
from syntax.ast import Ast, Diagnostic, Span

from check import types as ty
from check.psig import PreludeSig, make_sig
from check.spec import Resolution, Spec
from check.types import ANY_TYPE, Types


comptime NO_TYPE = -1
"""The "no such type" answer of `join` and `non_eq_part`."""

# Context kinds that are not clause kinds (clause kinds are the ops of syntax.ast).
comptime K_PARTITION = 100
comptime K_PARTITION_SET = 101
comptime K_DEFAULT = 102
comptime K_DEF = 103
comptime K_OBSERVER = 104

comptime RESERVED = ("old", "result", "self", "mp", "cr")
comptime BUILTIN_TYPE_NAMES = (
    "f16 bf16 f32 f64 i8 i16 i32 i64 u8 u16 u32 u64 bool int real string bytes unit"
    " set list map option"
)


def is_reserved(name: StringSlice) -> Bool:
    return (
        name == "old"
        or name == "result"
        or name == "self"
        or name == "mp"
        or name == "cr"
    )


def is_builtin_type_name(name: StringSlice) -> Bool:
    for word in BUILTIN_TYPE_NAMES.split(" "):
        if word == name:
            return True
    return False


def type_hint(name: StringSlice) -> String:
    if name == "float" or name == "double":
        return "f64"
    if name == "str" or name == "String":
        return "string"
    if name == "integer" or name == "Int":
        return "int"
    if name == "boolean" or name == "Bool":
        return "bool"
    if name == "List":
        return "list"
    if name == "Map" or name == "dict":
        return "map"
    if name == "Option":
        return "option"
    return String()


def float_set_name(name: StringSlice) -> Bool:
    return (
        name == "nan"
        or name == "inf"
        or name == "zero"
        or name == "subnormal"
        or name == "normal"
        or name == "finite"
        or name == "positive"
        or name == "negative"
        or name == "all"
    )


def classifier_hint(name: StringSlice) -> String:
    if name == "nan":
        return "is_nan(x)"
    if name == "inf":
        return "is_inf(x)"
    if name == "zero":
        return "is_zero(x)"
    if name == "subnormal":
        return "is_subnormal(x)"
    if name == "finite":
        return "is_finite(x)"
    if name == "negative":
        return "signbit(x)"
    if name == "positive":
        return "not signbit(x)"
    return String()


def qualify_error(name: String) -> String:
    """`ValueError` is `builtins.ValueError`; a dotted name is already qualified."""
    for b in name.as_bytes():
        if Int(b) == ord("."):
            return name.copy()
    return "builtins." + name


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
        self.tv_names = List[String]()
        self.tv_types = List[Int]()
        self.param_names = List[String]()
        self.param_types = List[Int]()
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
        self.class_names = List[String]()
        self.class_nodes = List[Int]()
        self.class_types = List[Int]()
        self.only_param = String()
        self.loc_names = List[String]()
        self.loc_types = List[Int]()
        self.loc_binders = List[Int]()
        self.in_old = False
        self.old_scope = 0
        self.hidden_names = List[String]()
        self.hidden_msgs = List[String]()
        self.aggregate_top = 0
        self.extern_result = -1

    def tv_index(self, name: String) -> Int:
        for i in range(len(self.tv_names)):
            if self.tv_names[i] == name:
                return i
        return -1

    def param_index(self, name: String) -> Int:
        for i in range(len(self.param_names)):
            if self.param_names[i] == name:
                return i
        return -1

    def class_index(self, name: String) -> Int:
        for i in range(len(self.class_names)):
            if self.class_names[i] == name:
                return i
        return -1

    def local_index(self, name: String) -> Int:
        var i = len(self.loc_names) - 1
        while i >= 0:
            if self.loc_names[i] == name:
                return i
            i -= 1
        return -1

    def hidden_index(self, name: String) -> Int:
        for i in range(len(self.hidden_names)):
            if self.hidden_names[i] == name:
                return i
        return -1


struct Checker:
    var spec: Spec
    var path: String
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
        self.path = spec.ast.path.copy()
        self.spec = spec^
        self.diags = List[Diagnostic]()
        self.ctx = Ctx()
        self.names = Dict[String, Int]()
        self.duplicate = List[Bool](length=len(self.spec.ast.nodes), fill=False)
        self.fn_index = Dict[String, Int]()
        self.def_index = Dict[String, Int]()
        self.model_index = Dict[String, Int]()
        self.const_index = Dict[String, Int]()
        self.enum_index = Dict[String, Int]()
        self.record_nodes = Dict[String, Int]()
        self.record_types = Dict[String, Int]()
        self.alias_nodes = Dict[String, Int]()
        self.active = List[String]()
        self.prelude_ids = Dict[String, Int]()
        self.prelude_sigs = List[PreludeSig]()
        self.scalars = Dict[String, Int]()
        self.fn_modifies = List[Bool]()
        self.decl_pos = List[Int](length=len(self.spec.ast.nodes), fill=-1)
        self.clause_ids = Dict[String, Int]()
        self.def_edges = List[List[Int]]()
        self.def_nodes = List[Int]()
        self.cur_def = -1
        self.sig_msg = String()
        self.sig_arg = -1
        self.sig_key = String()
        var k = 0
        for word in NAMES.split(" "):
            self.prelude_ids[String(word)] = k
            self.prelude_sigs.append(make_sig(String(word)))
            k += 1
        self.poison = self.spec.types.intern(
            ty.TypeInfo(ty.ANY, 0, False, "poison", List[Int](), List[String]())
        )
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

    def kind_of(self, n: Int) -> UInt8:
        return self.spec.ast.nodes[n].kind

    def op_of(self, n: Int) -> UInt8:
        return self.spec.ast.nodes[n].op

    def text_of(self, n: Int) -> String:
        return self.spec.ast.nodes[n].text.copy()

    def kid(self, n: Int, k: Int) -> Int:
        return self.spec.ast.nodes[n].kids[k]

    def nkids(self, n: Int) -> Int:
        return len(self.spec.ast.nodes[n].kids)

    def kids_of(self, n: Int) -> List[Int]:
        return self.spec.ast.nodes[n].kids.copy()

    def line_of(self, n: Int) -> Int:
        return self.spec.ast.nodes[n].span.line

    def source_of(self, n: Int) -> String:
        return self.spec.ast.source_text(n)

    # -- reporting -------------------------------------------------------------

    def error(mut self, node: Int, message: String):
        self.diags.append(
            Diagnostic(self.path.copy(), self.spec.ast.nodes[node].span, message)
        )

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
        if found:
            return found.value()
        var t = self.spec.types.scalar(name)
        var id = t.value() if t else -1
        self.scalars[name] = id
        return id

    def components(self, t: Int) -> List[Int]:
        var k = self.tkind(t)
        if (
            k == ty.LIST
            or k == ty.OPTION
            or k == ty.SET
            or k == ty.MAP
            or k == ty.TUPLE
            or k == ty.RECORD
            or k == ty.MODEL
        ):
            return self.spec.types.infos[t].args.copy()
        return List[Int]()

    def contains_kind(self, t: Int, kind: UInt8) -> Bool:
        if self.tkind(t) == kind:
            return True
        for c in self.components(t):
            if self.contains_kind(c, kind):
                return True
        return False

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
            var out = List[Int]()
            for i in range(len(xs)):
                var j = self.join(xs[i], ys[i])
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
            return NO_TYPE if len(self.spec.types.infos[t].names) > 0 else t
        if (
            k == ty.LIST
            or k == ty.OPTION
            or k == ty.MAP
            or k == ty.TUPLE
            or k == ty.RECORD
        ):
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
            for e in self.spec.types.infos[t].args:
                if not self.ordered(e):
                    return False
            return True
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
        var out = List[String]()
        if k == ty.FLOAT:
            out.append("min")
            out.append("max")
            for w in "nan inf zero subnormal normal finite positive negative all".split(" "):
                out.append(String(w))
            out.append("range(a, b)")
            out.append('pattern("...")')
        elif k == ty.FIXED_INT:
            out.append("min")
            out.append("max")
            out.append("all")
            out.append("range(a, b)")
            out.append('pattern("...")')
        elif k == ty.BOOL:
            out.append("all")
        return out^

    def has_set_constructor(self, scalar: Int, attr: String) -> Bool:
        if attr != "range" and attr != "pattern":
            return False
        var k = self.tkind(scalar)
        return k == ty.FLOAT or k == ty.FIXED_INT

    def contains_float(mut self, t: Int) -> Bool:
        """Whether values of type t hold floats, looking through model fields."""
        return self._contains_float(t, List[Int]())

    def _contains_float(mut self, t: Int, seen: List[Int]) -> Bool:
        var k = self.tkind(t)
        if k == ty.FLOAT:
            return True
        if k == ty.MODEL:
            var pos = self.model_pos_of_type(t)
            if pos < 0:
                return False
            for s in seen:
                if s == pos:
                    return False
            var inner = seen.copy()
            inner.append(pos)
            for i in range(len(self.spec.models[pos].observers)):
                if len(self.spec.models[pos].observers[i].params) > 0:
                    continue
                var ot = self.observer_type(t, pos, i)
                if self._contains_float(ot, inner):
                    return True
            return False
        for c in self.components(t):
            if self._contains_float(c, seen):
                return True
        return False

    # -- models ----------------------------------------------------------------

    def model_pos_of_type(self, t: Int) -> Int:
        var found = self.model_index.get(self.spec.types.infos[t].name)
        return found.value() if found else -1

    def observer_pos(self, model: Int, name: String) -> Int:
        for i in range(len(self.spec.models[model].observers)):
            if self.spec.models[model].observers[i].name == name:
                return i
        return -1

    def observer_names(self, model: Int) -> String:
        var out = String()
        for i in range(len(self.spec.models[model].observers)):
            out += ", " if i else ""
            out += self.spec.models[model].observers[i].name
        return out if len(self.spec.models[model].observers) else String("none")

    def observer_type(mut self, mt: Int, model: Int, obs: Int) -> Int:
        var declared = self.spec.models[model].observers[obs].type
        var tparams = self.spec.models[model].tparams.copy()
        if len(tparams) == 0:
            return declared
        var args = self.spec.types.infos[mt].args.copy()
        if len(args) != len(tparams):
            return declared
        return self.spec.types.substitute(declared, tparams, args)

    # -- literals --------------------------------------------------------------

    def literal_value(self, n: Int) -> Optional[Real]:
        """The value of a numeric literal, possibly negated."""
        var k = self.kind_of(n)
        if k == ast.NUM:
            try:
                return parse_number(self.spec.ast.nodes[n].text)
            except:
                return None
        if k == ast.UNARY and self.op_of(n) == ast.NEG:
            var inner = self.literal_value(self.kid(n, 0))
            if inner:
                return -inner.value()
            return None
        return None

    # -- resolutions -----------------------------------------------------------

    def resolve(mut self, node: Int, kind: UInt8, index: Int, owner: Int, name: String):
        self.spec.resolutions[node] = Resolution(kind, index, owner, name)

    def set_type(mut self, node: Int, t: Int):
        self.spec.node_types[node] = t
