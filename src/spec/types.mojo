"""Static types of the spec language, interned in a table.

A type is an `Int`, its index in `Types`. Constructors intern, so two types are the
same type exactly when their ids are equal. Id 0 is `ANY`, the placeholder for a type
that could not be inferred; the checker reports an error wherever it would decide
something.

`TypeInfo` fields by kind:

| kind      | bits / signed            | name              | args                       | names                 |
| --------- | ------------------------ | ----------------- | -------------------------- | --------------------- |
| FIXED_INT | width (8..64), signed    |                   |                            |                       |
| FLOAT     | bits = format id (1..4)  |                   |                            |                       |
| LIST      |                          |                   | [elem]                     |                       |
| MAP       |                          |                   | [key, value]               |                       |
| TUPLE     |                          |                   | elems                      |                       |
| OPTION    |                          |                   | [elem]                     |                       |
| SET       |                          |                   | [elem]                     |                       |
| LITERAL   |                          |                   |                            | the strings, in order |
| ENUM      |                          | qualified name    |                            | members               |
| RECORD    |                          | qualified name    | field types                | field names           |
| MODEL     | signed = is an interface | qualified name    | type arguments             |                       |
| TYPEVAR   |                          | name              |                            | [bound] or []         |
| FN        |                          |                   | params, then the result    | parameter names       |
| CHOICE    |                          |                   | [type of the constants]    | the constants' names  |

ENUM, RECORD and MODEL are nominal: interned by name, so declare each once.
"""

from std.hash import Hasher

from value.float_formats import FORMATS, FloatFormat

comptime ANY_TYPE = 0
"""The id of ANY."""

comptime _KIND_NAMES: Array[StaticString, 22] = [
    "any", "bool", "int", "fixed_int", "float", "real", "string", "bytes", "unit", "qerr",
    "list", "map", "tuple", "option", "set", "literal", "enum", "record", "model", "typevar",
    "fn", "choice",
]


__enum TypeKind(Equatable, Hashable, ImplicitlyCopyable, Intable, Writable):
    """A type's kind. Writes as its lowercase name, which for a kind of one type, eg.
    `bool` or `qerr`, is how a spec writes the type."""

    case Any
    case Bool
    case Int
    case FixedInt
    case Float
    case Real
    case String
    case Bytes
    case Unit
    case Qerr
    case List
    case Map
    case Tuple
    case Option
    case Set
    case Literal
    case Enum
    case Record
    case Model
    case TypeVar
    case Fn
    case Choice

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()

    def __hash__(self, mut hasher: Some[Hasher]):
        self._get_enum_discriminant().__hash__(hasher)

    def __int__(self) -> Int:
        return Int(self._get_enum_discriminant())

    def write_to(self, mut writer: Some[Writer]):
        writer.write(materialize[_KIND_NAMES]()[Int(self)])

    def has_components(self) -> Bool:
        """Whether the `args` of its types are types that their values hold."""
        match self:
            case .List | .Option | .Set | .Map | .Tuple | .Record | .Model:
                return True
            case _:
                return False


struct TypeInfo(Copyable, Equatable, Hashable):
    var kind: TypeKind
    var bits: Int
    var signed: Bool
    var name: String
    var args: List[Int]
    var names: List[String]

    def __init__(
        out self,
        kind: TypeKind,
        *,
        bits: Int = 0,
        signed: Bool = False,
        var name: String = "",
        var args: List[Int] = [],
        var names: List[String] = [],
    ):
        self.kind = kind
        self.bits = bits
        self.signed = signed
        self.name = name^
        self.args = args^
        self.names = names^

    def key(self) -> Self:
        """What it is interned under: itself, or only kind and name for an enum or record."""
        if self.kind == .Enum or self.kind == .Record:
            return Self(self.kind, name=self.name.copy())
        return self.copy()


struct Types(Movable):
    var infos: List[TypeInfo]
    var index: Dict[TypeInfo, Int]
    """Interning keys to type ids."""

    def __init__(out self):
        self.infos = []
        self.index = {}
        _ = self.intern(TypeInfo(.Any))

    # Interning

    def intern(mut self, var info: TypeInfo) -> Int:
        var key = info.key()
        if case .Some(found) = self.index.get(key):
            return found
        self.infos.append(info^)
        self.index[key^] = len(self.infos) - 1
        return len(self.infos) - 1

    # Constructors

    def bool_(mut self) -> Int:
        return self.intern(TypeInfo(.Bool))

    def int_(mut self) -> Int:
        return self.intern(TypeInfo(.Int))

    def fixed(mut self, bits: Int, signed: Bool) -> Int:
        return self.intern(TypeInfo(.FixedInt, bits=bits, signed=signed))

    def float_(mut self, format_id: UInt8) -> Int:
        return self.intern(TypeInfo(.Float, bits=Int(format_id)))

    def real(mut self) -> Int:
        return self.intern(TypeInfo(.Real))

    def string(mut self) -> Int:
        return self.intern(TypeInfo(.String))

    def bytes(mut self) -> Int:
        return self.intern(TypeInfo(.Bytes))

    def unit(mut self) -> Int:
        return self.intern(TypeInfo(.Unit))

    def qerr(mut self) -> Int:
        return self.intern(TypeInfo(.Qerr))

    def list_of(mut self, elem: Int) -> Int:
        return self.intern(TypeInfo(.List, args=[elem]))

    def map_of(mut self, key: Int, value: Int) -> Int:
        return self.intern(TypeInfo(.Map, args=[key, value]))

    def tuple_of(mut self, elems: List[Int]) -> Int:
        return self.intern(TypeInfo(.Tuple, args=elems.copy()))

    def option_of(mut self, elem: Int) -> Int:
        return self.intern(TypeInfo(.Option, args=[elem]))

    def set_of(mut self, elem: Int) -> Int:
        return self.intern(TypeInfo(.Set, args=[elem]))

    def literal(mut self, values: List[String]) -> Int:
        return self.intern(TypeInfo(.Literal, names=values.copy()))

    def enum_(mut self, var name: String, members: List[String]) -> Int:
        return self.intern(TypeInfo(.Enum, name=name^, names=members.copy()))

    def record(mut self, var name: String, fields: List[String], field_types: List[Int]) -> Int:
        return self.intern(TypeInfo(.Record, name=name^, args=field_types.copy(), names=fields.copy()))

    def model(mut self, var name: String, args: List[Int], is_interface: Bool) -> Int:
        return self.intern(TypeInfo(.Model, signed=is_interface, name=name^, args=args.copy()))

    def typevar(mut self, var name: String, bound: String) -> Int:
        """`bound` is "Eq", "Ord" or "" for none."""
        var info = TypeInfo(.TypeVar, name=name^)
        if bound:
            info.names.append(bound)
        return self.intern(info^)

    def typevars(mut self, names: List[String], bounds: List[String]) -> List[Int]:
        return [self.typevar(name, bound) for name, bound in zip(names, bounds)]

    def fn_(mut self, params: List[Int], names: List[String], result: Int) -> Int:
        return self.intern(TypeInfo(.Fn, args=params + [result], names=names.copy()))

    def choice(mut self, constants: List[String], elem: Int) -> Int:
        return self.intern(TypeInfo(.Choice, args=[elem], names=constants.copy()))

    def scalar(mut self, name: StringSlice) -> Optional[Int]:
        """The built-in type a one-word name denotes: bool, int, i8..i64, u8..u64,
        f16, bf16, f32, f64, real, string, bytes."""
        match name:
            case "bool":
                return self.bool_()
            case "int":
                return self.int_()
            case "real":
                return self.real()
            case "string":
                return self.string()
            case "bytes":
                return self.bytes()
            case _:
                pass
        for format in materialize[FORMATS]():
            if name == format.name():
                return self.float_(format.id)
        for bits in [8, 16, 32, 64]:
            for signed in [True, False]:
                if name == _fixed_text(bits, signed):
                    return self.fixed(bits, signed)
        return None

    # Queries

    def kind(self, t: Int) -> TypeKind:
        return self.infos[t].kind

    def info(self, t: Int) -> ref [self.infos[0]] TypeInfo:
        return self.infos[t]

    def format(self, t: Int) -> FloatFormat:
        """The format of a FLOAT type."""
        return materialize[FORMATS]()[self.infos[t].bits - 1]

    def text(self, t: Int) -> String:
        """The type as a spec writes it: `list<f64>`, `(int, string)`, `"a" | "b"`."""
        ref i = self.infos[t]
        match i.kind:
            case .Any:
                return "?"
            case .Bool | .Int | .Real | .String | .Bytes | .Unit | .Qerr:
                return String(i.kind)
            case .FixedInt:
                return _fixed_text(i.bits, i.signed)
            case .Float:
                return String(self.format(t))
            case .List | .Option | .Set:
                return String(t"{i.kind}<{self.text(i.args[0])}>")
            case .Map:
                return String(t"map<{self.text(i.args[0])}, {self.text(i.args[1])}>")
            case .Tuple:
                return String(t"({self._texts(i.args)})")
            case .Literal:
                return " | ".join([String(t"\"{n}\"") for n in i.names])
            case .Choice:
                return " | ".join(i.names)
            case .Model if i.args:
                return String(t"{i.name}<{self._texts(i.args)}>")
            case .Fn:
                var result = len(i.args) - 1
                return String(t"({self._texts(i.args[:result])}) -> {self.text(i.args[result])}")
            case _:
                return i.name

    def _texts(self, types: Span[Int, _]) -> String:
        return ", ".join([self.text(t) for t in types])

    def is_integer(self, t: Int) -> Bool:
        var k = self.kind(t)
        return k == .Int or k == .FixedInt

    def is_numeric(self, t: Int) -> Bool:
        match self.kind(t):
            case .Int | .FixedInt | .Float | .Real:
                return True
            case _:
                return False

    def is_fixed_width(self, t: Int) -> Bool:
        """Types whose values are finite sets of bit patterns, where partition sets apply."""
        match self.kind(t):
            case .FixedInt | .Float | .Bool:
                return True
            case _:
                return False

    def components(self, t: Int) -> List[Int]:
        """The types that values of type t hold: elements, fields or type arguments."""
        ref i = self.infos[t]
        return i.args.copy() if i.kind.has_components() else []

    def contains_kind(self, t: Int, kind: TypeKind) -> Bool:
        """Whether t is a `kind` type or holds one, at any depth."""
        return self.kind(t) == kind or any([self.contains_kind(c, kind) for c in self.components(t)])

    def has_canonical_eq(self, t: Int) -> Bool:
        """The equality rule: may `==`, `!=` and `in` be used on values of type t?"""
        ref i = self.infos[t]
        match i.kind:
            case .Bool | .Int | .FixedInt | .Real | .String | .Bytes | .Literal | .Enum | .Unit | .Qerr:
                return True
            case .List | .Option | .Map | .Tuple | .Record:
                return all([self.has_canonical_eq(a) for a in i.args])
            case .TypeVar:
                return Bool(i.names)
            case _:
                return False

    def has_total_order(self, t: Int) -> Bool:
        """May `<`, `sorted` and `is_sorted` be used on values of type t? Floats only
        after promotion to real; qerr's componentwise order is partial."""
        ref i = self.infos[t]
        match i.kind:
            case .Int | .FixedInt | .Real | .String | .Bytes | .Bool:
                return True
            case .TypeVar:
                return Bool(i.names) and i.names[0] == "Ord"
            case .Tuple | .List:
                return all([self.has_total_order(a) for a in i.args])
            case _:
                return False

    def substitute(mut self, t: Int, vars: List[String], values: List[Int]) -> Int:
        """Replaces the type variables named in `vars` by the types in `values`."""
        var info = self.infos[t].copy()
        if info.kind == .TypeVar:
            var at = vars.try_index(info.name)
            return values[at.value()] if at is not None else t
        if not info.args or info.kind == .Record:
            return t
        var args = [self.substitute(a, vars, values) for a in info.args]
        if args == info.args:
            return t
        info.args = args^
        return self.intern(info^)


def _fixed_text(bits: Int, signed: Bool) -> String:
    return String("i" if signed else "u", bits)
