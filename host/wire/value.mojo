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
| BOOL     | 0 or 1                | none                                            |
| INT      | the value, if it fits | `big` when it doesn't fit an Int64              |
|          | an Int64              |                                                 |
| FLOAT    | bit pattern           | none; `sub` is the format id (numeric.formats)  |
| STRING   |                       | `text`                                          |
| BYTES    |                       | `data`                                          |
| LIST     |                       | `items`                                         |
| TUPLE    |                       | `items`                                         |
| MAP      |                       | `items`: key, value, key, value... in order     |
| OPTION   |                       | `items`: empty for none, one item for some      |
| RECORD   |                       | `name`: qualified type; `items`: STRING field   |
|          |                       | name, value, field name, value...               |
| ENUM     |                       | `name`: qualified type ("" for a literal union) |
|          |                       | `text`: the member                              |
| HANDLE   | the driver's id       | `name`: the object's qualified class            |
| ERROR    |                       | `name`: qualified class; `text`: message;       |
|          |                       | `items`: STRING bases, nearest first            |
| REAL     |                       | `items`: INT numerator, INT denominator. The    |
|          |                       | fraction is in lowest terms with a positive     |
|          |                       | denominator; +inf and -inf are 1/0 and -1/0     |
| QERR     |                       | `items`: INT steps, INT nans                    |

A value with no heap part has `heap` empty. Constructors keep every form canonical, so
structural identity is never fooled by two spellings of one value.
"""

from std.hash import Hasher
from std.memory import ArcPointer, bitcast

from numeric.bigint import BigInt
from numeric.formats import FloatFormat
from numeric.real import Real


@fieldwise_init
struct Kind(Equatable, Hashable, TrivialRegisterPassable, Writable):
    var id: UInt8

    def __eq__(self, other: Self) -> Bool:
        return self.id == other.id

    def __hash__(self, mut hasher: Some[Hasher]):
        self.id.__hash__(hasher)

    def name(self) -> StaticString:
        comptime NAMES = (
            "invalid bool int float string bytes list tuple map option record enum"
            " handle error real qerr"
        )
        for k, name in enumerate(NAMES.split(" ")):
            if k == Int(self.id):
                return name
        return "invalid"

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.name())


comptime BOOL = Kind(1)
comptime INT = Kind(2)
comptime FLOAT = Kind(3)
comptime STRING = Kind(4)
comptime BYTES = Kind(5)
comptime LIST = Kind(6)
comptime TUPLE = Kind(7)
comptime MAP = Kind(8)
comptime OPTION = Kind(9)
comptime RECORD = Kind(10)
comptime ENUM = Kind(11)
comptime HANDLE = Kind(12)
comptime ERROR = Kind(13)
comptime REAL = Kind(14)
comptime QERR = Kind(15)


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

    def __init__(
        out self,
        var name: String,
        var text: String,
        var data: List[UInt8],
        var big: BigInt,
        var items: List[ArcPointer[Value]],
    ):
        self.name = name^
        self.text = text^
        self.data = data^
        self.big = big^
        self.items = items^


struct Value(Copyable, Equatable, Hashable, Movable, Writable):
    var kind: Kind
    var sub: UInt8
    """FLOAT: the format id. Otherwise 0."""
    var word: UInt64
    var heap: Optional[ArcPointer[Payload]]

    def __init__(
        out self, kind: Kind, *, sub: UInt8 = 0, word: UInt64 = 0
    ):
        self.kind = kind
        self.sub = sub
        self.word = word
        self.heap = None

    def __init__(
        out self,
        kind: Kind,
        *,
        var name: String = String(),
        var text: String = String(),
        var data: List[UInt8] = List[UInt8](),
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
        return Self(BOOL, word=UInt64(1) if value else UInt64(0))

    @staticmethod
    def int(value: Int) -> Self:
        return Self(INT, word=UInt64(bitcast[DType.uint64](Int64(value))))

    @staticmethod
    def int(var value: BigInt) -> Self:
        var small = value.int64_or_none()
        if small:
            return Self(INT, word=bitcast[DType.uint64](small.value()))
        return Self(INT, big=value^)

    @staticmethod
    def float(format: FloatFormat, bits: UInt64) -> Self:
        return Self(FLOAT, sub=format.id, word=bits)

    @staticmethod
    def string(var text: String) -> Self:
        return Self(STRING, text=text^)

    @staticmethod
    def bytes(var data: List[UInt8]) -> Self:
        return Self(BYTES, data=data^)

    @staticmethod
    def list(var items: List[Value]) -> Self:
        return Self(LIST, items=items^)

    @staticmethod
    def tuple(var items: List[Value]) -> Self:
        return Self(TUPLE, items=items^)

    @staticmethod
    def map(var keys: List[Value], var values: List[Value]) raises -> Self:
        """Pairs in the order given. Keys must be distinct by structural identity."""
        if len(keys) != len(values):
            raise Error("map: keys and values differ in length")
        var items: List[Value] = []
        for i, (key, value) in enumerate(zip(keys, values)):
            if key in keys[:i]:
                raise Error("map: duplicate key")
            items.append(key.copy())
            items.append(value.copy())
        return Self(MAP, items=items^)

    @staticmethod
    def none() -> Self:
        return Self(OPTION)

    @staticmethod
    def some(var value: Value) -> Self:
        var items: List[Value] = [value^]
        return Self(OPTION, items=items^)

    @staticmethod
    def record(
        var type_name: String, fields: List[String], var values: List[Value]
    ) raises -> Self:
        if len(fields) != len(values):
            raise Error("record: fields and values differ in length")
        var items: List[Value] = []
        for field, value in zip(fields, values):
            items.append(Value.string(field))
            items.append(value.copy())
        return Self(RECORD, name=type_name^, items=items^)

    @staticmethod
    def enum(var type_name: String, var member: String) -> Self:
        return Self(ENUM, name=type_name^, text=member^)

    @staticmethod
    def handle(id: UInt64, var class_name: String) -> Self:
        return Self(HANDLE, name=class_name^, word=id)

    @staticmethod
    def error(
        var class_name: String, bases: List[String], var message: String
    ) -> Self:
        var items = [Value.string(base) for base in bases]
        return Self(ERROR, name=class_name^, text=message^, items=items^)

    @staticmethod
    def real(var numerator: BigInt, var denominator: BigInt) -> Self:
        """The caller keeps the form canonical: lowest terms, positive denominator,
        or a denominator of 0 with a numerator of 1 or -1 for the infinities."""
        var items: List[Value] = [Value.int(numerator^), Value.int(denominator^)]
        return Self(REAL, items=items^)

    @staticmethod
    def qerr(var steps: BigInt, var nans: BigInt) -> Self:
        var items: List[Value] = [Value.int(steps^), Value.int(nans^)]
        return Self(QERR, items=items^)

    # Accessors. Each one expects the kinds it names.

    def is_(self, kind: Kind) -> Bool:
        return self.kind == kind

    def as_bool(self) -> Bool:
        return self.word != 0

    def small_int(self) -> Optional[Int]:
        """INT: the value when it fits an Int64, else None."""
        if self.heap:
            return None
        return Int(bitcast[DType.int64](self.word))

    def as_bigint(self) -> BigInt:
        """INT: the value, at any size."""
        if self.heap:
            return self.heap.value()[].big.copy()
        return BigInt(Int(bitcast[DType.int64](self.word)))

    def as_real(self) -> Real:
        """INT or REAL: the value as a `Real`."""
        if self.kind == INT:
            return Real(self.as_bigint())
        return Real(
            lowest_numerator=self.item(0).as_bigint(),
            lowest_denominator=self.item(1).as_bigint(),
        )

    def float_bits(self) -> UInt64:
        return self.word

    def float_format_id(self) -> UInt8:
        return self.sub

    def handle_id(self) -> UInt64:
        return self.word

    def name(self) -> ref [self.heap.value()[].name] String:
        """RECORD, ENUM, HANDLE, ERROR: the qualified type or class."""
        return self.heap.value()[].name

    def text(self) -> ref [self.heap.value()[].text] String:
        """STRING: the string. ENUM: the member. ERROR: the message."""
        return self.heap.value()[].text

    def data(self) -> ref [self.heap.value()[].data] List[UInt8]:
        """BYTES: the bytes."""
        return self.heap.value()[].data

    def item(self, i: Int) -> Value:
        """Item `i` in the layout of the table above (a MAP or RECORD has keys or field
        names at even positions and values at odd ones). A copy costs a reference count."""
        return self.heap.value()[].items[i][].copy()

    def items(self) -> List[Value]:
        """Every heap item, counting MAP and RECORD pairs as two each."""
        return [item[].copy() for item in self.heap.value()[].items] if self.heap else []

    def pairs(self) -> List[Tuple[Value, Value]]:
        """MAP: (key, value) pairs. RECORD: (field name, value) pairs."""
        var items = self.items()
        return [(items[i].copy(), items[i + 1].copy()) for i in range(0, len(items), 2)]

    def item_count(self) -> Int:
        """How many heap items, counting MAP and RECORD pairs as two each."""
        return len(self.heap.value()[].items) if self.heap else 0

    def count(self) -> Int:
        """How many elements, or pairs for MAP and fields for RECORD."""
        var paired = self.kind == MAP or self.kind == RECORD
        return self.item_count() // 2 if paired else self.item_count()

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
        """A debugging form, `kind(...)`. Reports use the wire package's formatter."""
        writer.write(self.kind, "(")
        if self.kind == BOOL:
            writer.write("true" if self.as_bool() else "false")
        elif self.kind == INT:
            writer.write(self.as_bigint())
        elif self.kind == FLOAT:
            writer.write(self.sub, ", ", hex(self.word))
        elif self.kind == HANDLE:
            writer.write(self.word)
        if self.heap:
            ref p = self.heap.value()[]
            if self.kind == STRING or self.kind == ENUM or self.kind == ERROR:
                writer.write(repr(p.text))
            if p.name:
                writer.write(" name=", repr(p.name))
            if self.kind == BYTES:
                writer.write(len(p.data), " bytes")
            for i, item in enumerate(p.items):
                writer.write(", " if i else "", item[])
        writer.write(")")
