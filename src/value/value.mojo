"""Every value the host computes with.

The wire kinds (bool to error) are the values that cross between host and driver.
`real` and `qerr` exist only inside clauses. A value is immutable once built: its
heap part is shared between copies, so copying is cheap.

`==` here is structural identity: same kind, same bits, same text, same items in the
same order. It is what `Dict` and `Set` keys need. The spec language's own equalities
(canonical `==`, `same`, `ieee_eq`, key-order-free maps) are in other modules of this
package, built on the accessors below.

Layout by kind:

| kind     | word                  | heap                                            |
| -------- | --------------------- | ----------------------------------------------- |
| Bool     | 0 or 1                | none                                            |
| Int      | the value, if it fits | `big` when it doesn't fit an Int64              |
|          | an Int64              |                                                 |
| Float    | bit pattern           | none; `sub` is the format id (float_formats)    |
| String   |                       | `text`                                          |
| Bytes    |                       | `data`                                          |
| List     |                       | `items`                                         |
| Tuple    |                       | `items`                                         |
| Map      |                       | `items`: key, value, key, value... in order     |
| Option   |                       | `items`: empty for none, one item for some      |
| Record   |                       | `name`: qualified type; `items`: String field   |
|          |                       | name, value, field name, value...               |
| Enum     |                       | `name`: qualified type ("" for a literal union) |
|          |                       | `text`: the member                              |
| Handle   | the driver's id       | `name`: the object's qualified class            |
| Error    |                       | `name`: qualified class; `text`: message;       |
|          |                       | `items`: String bases, nearest first            |
| Real     |                       | `items`: Int numerator, Int denominator. The    |
|          |                       | fraction is in lowest terms with a positive     |
|          |                       | denominator; +inf and -inf are 1/0 and -1/0     |
| Qerr     |                       | `items`: Int steps, Int nans                    |

A value with no heap part has `heap` empty. Constructors keep every form canonical, so
structural identity is never fooled by two spellings of one value.
"""

from std.hash import Hasher
from std.memory import ArcPointer, bitcast

from value.bigint import BigInt
from value.float_formats import FORMATS, FloatFormat
from value.real import Real


__enum Kind(Equatable, Hashable, ImplicitlyCopyable, Writable):
    """What a value is. `Invalid` is no value: it marks a slot, eg. an argument left to
    its default."""

    case Invalid
    case Bool
    case Int
    case Float
    case String
    case Bytes
    case List
    case Tuple
    case Map
    case Option
    case Record
    case Enum
    case Handle
    case Error
    case Real
    case Qerr

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()

    def __hash__(self, mut hasher: Some[Hasher]):
        self._get_enum_discriminant().__hash__(hasher)

    def write_to(self, mut writer: Some[Writer]):
        """The name messages use, eg. `a float`."""
        comptime NAMES: Array[StaticString, 16] = [
            "invalid", "bool", "int", "float", "string", "bytes", "list", "tuple",
            "map", "option", "record", "enum", "handle", "error", "real", "qerr",
        ]
        writer.write(materialize[NAMES]()[Int(self._get_enum_discriminant())])

    def holds_pairs(self) -> Bool:
        """Map and Record items are key and value (or field name and value) pairs."""
        return self in [Kind.Map, Kind.Record]


@fieldwise_init
struct Payload(Movable):
    """A value's heap part. Never changed after the value is built."""

    var name: String
    var text: String
    var data: List[UInt8]
    var big: BigInt
    var items: List[ArcPointer[Value]]
    """Each item behind its own ArcPointer: Mojo 1.2 rejects a List[Value] here once
    this module is imported (a recursive type through another struct), but accepts
    ArcPointer[Value]."""


struct Value(Copyable, Equatable, Hashable, Movable, Writable):
    var kind: Kind
    var sub: UInt8
    """Float: the format id. Otherwise 0."""
    var word: UInt64
    var heap: Optional[ArcPointer[Payload]]

    def __init__(out self, kind: Kind, *, sub: UInt8 = 0, word: UInt64 = 0):
        self.kind = kind
        self.sub = sub
        self.word = word
        self.heap = None

    def __init__(
        out self,
        kind: Kind,
        *,
        var name: String = "",
        var text: String = "",
        var data: List[UInt8] = [],
        var big: BigInt = BigInt(),
        var items: List[Value] = List[Value](),
        word: UInt64 = 0,
    ):
        """A value with a heap part."""
        self.kind = kind
        self.sub = 0
        self.word = word
        var shared = [ArcPointer(item.copy()) for item in items]
        self.heap = ArcPointer(Payload(name^, text^, data^, big^, shared^))

    # Constructors

    @staticmethod
    def bool(value: Bool) -> Self:
        return Self(.Bool, word=UInt64(value))

    @staticmethod
    def int(value: Int) -> Self:
        return Self(.Int, word=bitcast[DType.uint64](Int64(value)))

    @staticmethod
    def int(var value: BigInt) -> Self:
        if case .Some(small) = value.int64_or_none():
            return Self(.Int, word=bitcast[DType.uint64](small))
        return Self(.Int, big=value^)

    @staticmethod
    def float(format: FloatFormat, bits: UInt64) -> Self:
        return Self(.Float, sub=format.id, word=bits)

    @staticmethod
    def string(var text: String) -> Self:
        return Self(.String, text=text^)

    @staticmethod
    def bytes(var data: List[UInt8]) -> Self:
        return Self(.Bytes, data=data^)

    @staticmethod
    def list(var items: List[Value]) -> Self:
        return Self(.List, items=items^)

    @staticmethod
    def tuple(var items: List[Value]) -> Self:
        return Self(.Tuple, items=items^)

    @staticmethod
    def map(var keys: List[Value], var values: List[Value]) raises -> Self:
        """Pairs in the order given. Keys must be distinct by structural identity."""
        if len(keys) != len(values):
            raise Error("map: keys and values differ in length")
        var items: List[Value] = []
        for i, (key, value) in enumerate(zip(keys, values)):
            if key in keys[:i]:
                raise Error("map: duplicate key")
            items += [key.copy(), value.copy()]
        return Self(.Map, items=items^)

    @staticmethod
    def none() -> Self:
        return Self(.Option)

    @staticmethod
    def some(var value: Value) -> Self:
        return Self(.Option, items=[value^])

    @staticmethod
    def record(
        var type_name: String, fields: List[String], var values: List[Value]
    ) raises -> Self:
        if len(fields) != len(values):
            raise Error("record: fields and values differ in length")
        var items: List[Value] = []
        for field, value in zip(fields, values):
            items += [Value.string(field), value.copy()]
        return Self(.Record, name=type_name^, items=items^)

    @staticmethod
    def enum(var type_name: String, var member: String) -> Self:
        return Self(.Enum, name=type_name^, text=member^)

    @staticmethod
    def handle(id: UInt64, var class_name: String) -> Self:
        return Self(.Handle, name=class_name^, word=id)

    @staticmethod
    def error(
        var class_name: String, bases: List[String], var message: String
    ) -> Self:
        var items = [Value.string(base) for base in bases]
        return Self(.Error, name=class_name^, text=message^, items=items^)

    @staticmethod
    def real(var numerator: BigInt, var denominator: BigInt) -> Self:
        """The caller keeps the form canonical: lowest terms, positive denominator,
        or a denominator of 0 with a numerator of 1 or -1 for the infinities."""
        return Self(.Real, items=[Value.int(numerator^), Value.int(denominator^)])

    @staticmethod
    def qerr(var steps: BigInt, var nans: BigInt) -> Self:
        return Self(.Qerr, items=[Value.int(steps^), Value.int(nans^)])

    # Accessors. Each one expects the kinds it names.

    def as_bool(self) -> Bool:
        return self.word != 0

    def small_int(self) -> Optional[Int]:
        """Int: the value when it fits an Int64, else None."""
        if self.heap is not None:
            return None
        return Int(bitcast[DType.int64](self.word))

    def as_bigint(self) -> BigInt:
        """Int: the value, at any size."""
        if self.heap is not None:
            return self.heap.value()[].big.copy()
        return BigInt(Int(bitcast[DType.int64](self.word)))

    def as_real(self) -> Real:
        """Int or Real: the value as a `Real`."""
        if self.kind == .Int:
            return Real(self.as_bigint())
        return Real(
            lowest_numerator=self.item(0).as_bigint(),
            lowest_denominator=self.item(1).as_bigint(),
        )

    def float_bits(self) -> UInt64:
        return self.word

    def float_format_id(self) -> UInt8:
        return self.sub

    def float_format(self) -> FloatFormat:
        return materialize[FORMATS]()[Int(self.sub) - 1]

    def handle_id(self) -> UInt64:
        return self.word

    def name(self) -> ref [self.heap.value()[].name] String:
        """Record, Enum, Handle, Error: the qualified type or class."""
        return self.heap.value()[].name

    def text(self) -> ref [self.heap.value()[].text] String:
        """String: the string. Enum: the member. Error: the message."""
        return self.heap.value()[].text

    def data(self) -> ref [self.heap.value()[].data] List[UInt8]:
        """Bytes: the bytes."""
        return self.heap.value()[].data

    def error_text(self) -> String:
        """Error: `Class: message`."""
        return String(self.name(), ": ", self.text())

    def item(self, i: Int) -> Value:
        """Item `i` in the layout of the table above (a Map or Record has keys or field
        names at even positions and values at odd ones). A copy costs a reference count."""
        return self.heap.value()[].items[i][].copy()

    def items(self) -> List[Value]:
        """Every heap item, counting Map and Record pairs as two each."""
        return [item[].copy() for item in self.heap.value()[].items] if self.heap is not None else []

    def pairs(self) -> List[Tuple[Value, Value]]:
        """Map: (key, value) pairs. Record: (field name, value) pairs."""
        return [(self.item(i), self.item(i + 1)) for i in range(0, self.item_count(), 2)]

    def keys(self) -> List[Value]:
        """MAP: the keys."""
        return [self.item(2 * i) for i in range(self.count())]

    def values(self) -> List[Value]:
        """MAP: the values."""
        return [self.item(2 * i + 1) for i in range(self.count())]

    def field(self, name: StringSlice) -> Optional[Value]:
        """Record: the value of the field `name`, if it has one."""
        for field_name, value in self.pairs():
            if field_name.text() == name:
                return value.copy()
        return None

    def item_count(self) -> Int:
        """How many heap items, counting Map and Record pairs as two each."""
        return len(self.heap.value()[].items) if self.heap is not None else 0

    def count(self) -> Int:
        """How many elements, or pairs for Map and fields for Record."""
        return self.item_count() // 2 if self.kind.holds_pairs() else self.item_count()

    # Structural identity

    def has_equal_parts(self, other: Self) -> Bool:
        """Same kind, bits, name, text, data, big number and item count (the items
        themselves are not compared)."""
        if self.kind != other.kind or self.sub != other.sub or self.word != other.word:
            return False
        if self.heap is None or other.heap is None:
            return self.heap is None and other.heap is None
        ref a = self.heap.value()[]
        ref b = other.heap.value()[]
        return (
            a.name == b.name
            and a.text == b.text
            and a.data == b.data
            and a.big == b.big
            and len(a.items) == len(b.items)
        )

    def hash_parts(self, mut hasher: Some[Hasher]):
        """Hashes what `has_equal_parts` compares, except the item count."""
        self.kind.__hash__(hasher)
        self.sub.__hash__(hasher)
        self.word.__hash__(hasher)
        if self.heap is not None:
            ref p = self.heap.value()[]
            p.name.__hash__(hasher)
            p.text.__hash__(hasher)
            for b in p.data:
                b.__hash__(hasher)
            p.big.__hash__(hasher)

    def __eq__(self, other: Self) -> Bool:
        if not self.has_equal_parts(other):
            return False
        if self.heap is None:
            return True
        for a, b in zip(self.heap.value()[].items, other.heap.value()[].items):
            if a[] != b[]:
                return False
        return True

    def __hash__(self, mut hasher: Some[Hasher]):
        self.hash_parts(hasher)
        for item in self.items():
            item.__hash__(hasher)

    def write_to(self, mut writer: Some[Writer]):
        """A debugging form, `kind(...)`. Reports use `value.text.format_value`."""
        writer.write(self.kind, "(")
        match self.kind:
            case .Bool:
                writer.write("true" if self.as_bool() else "false")
            case .Int:
                writer.write(self.as_bigint())
            case .Float:
                writer.write(self.sub, ", ", hex(self.word))
            case .Handle:
                writer.write(self.word)
            case _:
                pass
        if self.heap is not None:
            ref p = self.heap.value()[]
            if self.kind in [Kind.String, Kind.Enum, Kind.Error]:
                writer.write(repr(p.text))
            if p.name:
                writer.write(" name=", repr(p.name))
            if self.kind == .Bytes:
                writer.write(len(p.data), " bytes")
            for i, item in enumerate(p.items):
                writer.write(", " if i else "", item[])
        writer.write(")")
