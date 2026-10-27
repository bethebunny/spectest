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

from numeric.formats import FloatFormat

comptime ANY: UInt8 = 0
comptime BOOL: UInt8 = 1
comptime INT: UInt8 = 2
comptime FIXED_INT: UInt8 = 3
comptime FLOAT: UInt8 = 4
comptime REAL: UInt8 = 5
comptime STRING: UInt8 = 6
comptime BYTES: UInt8 = 7
comptime UNIT: UInt8 = 8
comptime QERR: UInt8 = 9
comptime LIST: UInt8 = 10
comptime MAP: UInt8 = 11
comptime TUPLE: UInt8 = 12
comptime OPTION: UInt8 = 13
comptime SET: UInt8 = 14
comptime LITERAL: UInt8 = 15
comptime ENUM: UInt8 = 16
comptime RECORD: UInt8 = 17
comptime MODEL: UInt8 = 18
comptime TYPEVAR: UInt8 = 19
comptime FN: UInt8 = 20
comptime CHOICE: UInt8 = 21

comptime ANY_TYPE = 0
"""The id of ANY."""


@fieldwise_init
struct TypeInfo(Copyable, Movable):
    var kind: UInt8
    var bits: Int
    var signed: Bool
    var name: String
    var args: List[Int]
    var names: List[String]


def _float_name(format_id: Int) -> StaticString:
    return FloatFormat(UInt8(format_id), 0, 0).name()


def _info(kind: UInt8) -> TypeInfo:
    return TypeInfo(kind, 0, False, String(), [], [])


struct Types(Movable):
    var infos: List[TypeInfo]
    var index: Dict[String, Int]

    def __init__(out self):
        self.infos = []
        self.index = {}
        _ = self.intern(_info(ANY))

    # Interning

    def intern(mut self, var info: TypeInfo) -> Int:
        var key = _key(info)
        var found = self.index.get(key)
        if found is not None:
            return found.value()
        self.infos.append(info^)
        self.index[key] = len(self.infos) - 1
        return len(self.infos) - 1

    # Constructors

    def bool_(mut self) -> Int:
        return self.intern(_info(BOOL))

    def int_(mut self) -> Int:
        return self.intern(_info(INT))

    def fixed(mut self, bits: Int, signed: Bool) -> Int:
        var info = _info(FIXED_INT)
        info.bits = bits
        info.signed = signed
        return self.intern(info^)

    def float_(mut self, format_id: UInt8) -> Int:
        var info = _info(FLOAT)
        info.bits = Int(format_id)
        return self.intern(info^)

    def real(mut self) -> Int:
        return self.intern(_info(REAL))

    def string(mut self) -> Int:
        return self.intern(_info(STRING))

    def bytes(mut self) -> Int:
        return self.intern(_info(BYTES))

    def unit(mut self) -> Int:
        return self.intern(_info(UNIT))

    def qerr(mut self) -> Int:
        return self.intern(_info(QERR))

    def _wrap(mut self, kind: UInt8, var args: List[Int]) -> Int:
        var info = _info(kind)
        info.args = args^
        return self.intern(info^)

    def list_of(mut self, elem: Int) -> Int:
        return self._wrap(LIST, [elem])

    def map_of(mut self, key: Int, value: Int) -> Int:
        return self._wrap(MAP, [key, value])

    def tuple_of(mut self, elems: List[Int]) -> Int:
        return self._wrap(TUPLE, elems.copy())

    def option_of(mut self, elem: Int) -> Int:
        return self._wrap(OPTION, [elem])

    def set_of(mut self, elem: Int) -> Int:
        return self._wrap(SET, [elem])

    def literal(mut self, values: List[String]) -> Int:
        var info = _info(LITERAL)
        info.names = values.copy()
        return self.intern(info^)

    def enum_(mut self, var name: String, members: List[String]) -> Int:
        var info = _info(ENUM)
        info.name = name^
        info.names = members.copy()
        return self.intern(info^)

    def record(
        mut self, var name: String, fields: List[String], field_types: List[Int]
    ) -> Int:
        var info = _info(RECORD)
        info.name = name^
        info.names = fields.copy()
        info.args = field_types.copy()
        return self.intern(info^)

    def model(
        mut self, var name: String, args: List[Int], is_interface: Bool
    ) -> Int:
        var info = _info(MODEL)
        info.name = name^
        info.args = args.copy()
        info.signed = is_interface
        return self.intern(info^)

    def typevar(mut self, var name: String, bound: String) -> Int:
        """`bound` is "Eq", "Ord" or "" for none."""
        var info = _info(TYPEVAR)
        info.name = name^
        if bound:
            info.names.append(bound)
        return self.intern(info^)

    def fn_(mut self, params: List[Int], names: List[String], result: Int) -> Int:
        var info = _info(FN)
        info.args = params.copy()
        info.args.append(result)
        info.names = names.copy()
        return self.intern(info^)

    def choice(mut self, constants: List[String], elem: Int) -> Int:
        var info = _info(CHOICE)
        info.names = constants.copy()
        info.args = [elem]
        return self.intern(info^)

    def scalar(mut self, name: StringSlice) -> Optional[Int]:
        """The built-in type a one-word name denotes: bool, int, i8..i64, u8..u64,
        f16, bf16, f32, f64, real, string, bytes."""
        if name == "bool":
            return self.bool_()
        if name == "int":
            return self.int_()
        if name == "real":
            return self.real()
        if name == "string":
            return self.string()
        if name == "bytes":
            return self.bytes()
        for format_id in range(1, 5):
            if name == _float_name(format_id):
                return self.float_(UInt8(format_id))
        for bits in [8, 16, 32, 64]:
            if name == String("i", bits):
                return self.fixed(bits, True)
            if name == String("u", bits):
                return self.fixed(bits, False)
        return None

    # Queries

    def kind(self, t: Int) -> UInt8:
        return self.infos[t].kind

    def info(self, t: Int) -> ref [self.infos[0]] TypeInfo:
        return self.infos[t]

    def text(self, t: Int) -> String:
        """The type as a spec writes it: `list<f64>`, `(int, string)`, `"a" | "b"`."""
        ref i = self.infos[t]
        var k = i.kind
        if k == ANY:
            return "?"
        if k == BOOL:
            return "bool"
        if k == INT:
            return "int"
        if k == FIXED_INT:
            return String("i" if i.signed else "u", i.bits)
        if k == FLOAT:
            return String(_float_name(i.bits))
        if k == REAL:
            return "real"
        if k == STRING:
            return "string"
        if k == BYTES:
            return "bytes"
        if k == UNIT:
            return "unit"
        if k == QERR:
            return "qerr"
        if k == LIST:
            return String(t"list<{self.text(i.args[0])}>")
        if k == MAP:
            return String(t"map<{self.text(i.args[0])}, {self.text(i.args[1])}>")
        if k == OPTION:
            return String(t"option<{self.text(i.args[0])}>")
        if k == SET:
            return String(t"set<{self.text(i.args[0])}>")
        if k == TUPLE:
            return String(t"({self._texts(i.args)})")
        if k == LITERAL:
            return " | ".join([String(t"\"{n}\"") for n in i.names])
        if k == CHOICE:
            return " | ".join(i.names)
        if k == MODEL and i.args:
            return String(t"{i.name}<{self._texts(i.args)}>")
        if k == FN:
            var result = len(i.args) - 1
            return String(t"({self._texts(i.args[:result])}) -> {self.text(i.args[result])}")
        return i.name

    def _texts(self, types: Span[Int, _]) -> String:
        return ", ".join([self.text(t) for t in types])

    def is_integer(self, t: Int) -> Bool:
        var k = self.kind(t)
        return k == INT or k == FIXED_INT

    def is_numeric(self, t: Int) -> Bool:
        var k = self.kind(t)
        return k == INT or k == FIXED_INT or k == FLOAT or k == REAL

    def is_fixed_width(self, t: Int) -> Bool:
        """Types whose values are finite sets of bit patterns, where partition sets apply."""
        var k = self.kind(t)
        return k == FIXED_INT or k == FLOAT or k == BOOL

    def has_canonical_eq(self, t: Int) -> Bool:
        """The equality rule: may `==`, `!=` and `in` be used on values of type t?"""
        ref i = self.infos[t]
        var k = i.kind
        if (
            k == BOOL or k == INT or k == FIXED_INT or k == REAL or k == STRING
            or k == BYTES or k == LITERAL or k == ENUM or k == UNIT or k == QERR
        ):
            return True
        if k == LIST or k == OPTION or k == MAP or k == TUPLE or k == RECORD:
            for a in i.args:
                if not self.has_canonical_eq(a):
                    return False
            return True
        if k == TYPEVAR:
            return len(i.names) > 0
        return False

    def has_total_order(self, t: Int) -> Bool:
        """May `<`, `sorted` and `is_sorted` be used on values of type t? Floats only
        after promotion to real; qerr's componentwise order is partial."""
        ref i = self.infos[t]
        var k = i.kind
        if k == INT or k == FIXED_INT or k == REAL or k == STRING or k == BYTES or k == BOOL:
            return True
        if k == TYPEVAR:
            return len(i.names) > 0 and i.names[0] == "Ord"
        if k == TUPLE or k == LIST:
            for a in i.args:
                if not self.has_total_order(a):
                    return False
            return True
        return False

    def substitute(
        mut self, t: Int, vars: List[String], values: List[Int]
    ) -> Int:
        """Replaces the type variables named in `vars` by the types in `values`."""
        var info = self.infos[t].copy()
        if info.kind == TYPEVAR:
            for var_name, value in zip(vars, values):
                if var_name == info.name:
                    return value
            return t
        if not info.args or info.kind == RECORD:
            return t
        var changed = False
        for j in range(len(info.args)):
            var a = self.substitute(info.args[j], vars, values)
            if a != info.args[j]:
                info.args[j] = a
                changed = True
        if not changed:
            return t
        return self.intern(info^)


def _key(info: TypeInfo) -> String:
    var out = String(Int(info.kind), ":", info.bits, ":", Int(info.signed), ":")
    var k = info.kind
    if k == ENUM or k == RECORD:
        return out + info.name
    out += info.name + ":"
    for a in info.args:
        out += String(a, ",")
    out += ":"
    for n in info.names:
        out += n + "\x1f"
    return out
