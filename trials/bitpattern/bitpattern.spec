spec bitpattern

# bitpattern 0.3.0, formalized from INFORMAL_SPEC.md (section numbers refer to it).
# TRANSLATION.md lists what is left out or approximated, and what the binding assumes.
#
# The language has no exponentiation, so powers of two are spelled as tables:
#   [1, 2, 4, ..., 65536][k] is 2**k for k <= 16 (an int, usable in range()), and
#   [0x1p0, ..., 0x1p64][k] is 2**k for k <= 64 (an exact real, for sizes).
# Most set functions take their sets as (iterable: list<u8>, width) and build them in the
# binding as IntSet(iterable, width=width). For such a set:
#   its members are filter(x in range(0, 256): x in iterable), in ascending order;
#   the bit length of its largest member is count(p in [1, 2, 4, ..., 128]: exists(x in iterable: x >= p));
#   its width W is the larger of width and that bit length.
# A cls argument "Pattern" builds the same set as a Pattern (Pattern.from_bdd(s.bdd, s.width)).

error TypeError
error ValueError
error IndexError
error OverflowError
error AttributeError
error FrozenInstanceError
error BufferError
error NotImplementedError

type Cls = "IntSet" | "Pattern"
type Op = "&" | "|" | "-" | "^"
type Cmp = "<=" | "<" | ">=" | ">"
type Bit = "0" | "1" | "?"
type Q = "0" | "1" | "?" | "*"
type Builtin = "list" | "tuple" | "set" | "frozenset"
type Side = "left" | "right"

# An IntSet (or Pattern) result: its exact class, width, size and members in iteration order.
model IntSet
  observe kind: Cls
  observe width: int
  observe size: int
  observe members: list<int>
  invariant ascending: is_sorted(members) and distinct(members)
  invariant counted: size == len(members)
  invariant natural: width >= 0 and all(m in members: m >= 0)
  invariant in_universe: width > 16 or all(m in members:
    m < [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536][width])

# A BDDSet result, observed through its storage: the codec's name and width, the storage's
# width, the size, and membership of an encoding.
model CodecSet
  observe codec: string
  observe codec_width: int
  observe width: int
  observe size: int
  observe has(encoding: int): bool
  invariant storage_width: width == codec_width
  invariant natural: size >= 0

# ---------------------------------------------------------------------------
# 0. Public surface

# dir() of each module includes its public names (section 0).
fn module_names(module: "bitpattern" | "bitpattern.bdd" | "bitpattern.codecs" | "bitpattern.dlpack" | "bitpattern.strategies") -> list<string>
  ensures top: module == "bitpattern" implies
    all(n in ["BDD", "BDDSet", "Codec", "IntSet", "OrderedCodec", "Pattern", "__version__"]: n in result)
  ensures bdd: module == "bitpattern.bdd" implies
    all(n in ["BDD", "__version__", "accepts", "count", "nth", "rank", "members", "blocks", "paths",
              "path_count", "node_count", "diagram", "exactly_these", "interval", "lshift",
              "freed_between", "subset", "disjoint", "narrowed", "count_repr", "tensor", "collect",
              "stats"]: n in result)
  ensures codecs: module == "bitpattern.codecs" implies
    all(n in ["Codec", "OrderedCodec", "BDDSet", "Tuple", "product", "project", "DType", "Int",
              "int8", "int16", "int32", "int64", "int128", "uint8", "uint16", "uint32", "uint64",
              "uint128", "Float", "FloatFN", "float16", "bfloat16", "float32", "float64",
              "float8_e5m2", "float8_e4m3fn", "Char", "char", "IP", "ipv4", "ipv6", "MAC", "mac",
              "Date", "DateTime", "dates", "datetimes", "naive_datetimes", "UUIDCodec", "uuid128",
              "Members", "Flags"]: n in result)
  ensures dlpack: module == "bitpattern.dlpack" implies "DType" in result
  ensures strategies: module == "bitpattern.strategies" implies "from_set" in result

# The names exported from bitpattern are the objects of their home modules.
fn reexported(name: "BDD" | "BDDSet" | "Codec" | "OrderedCodec", home: "bitpattern.bdd" | "bitpattern.codecs") -> bool
  requires (name == "BDD") == (home == "bitpattern.bdd")
  ensures identical: result

fn version() -> string
  ensures value: result == "0.3.0"

# ---------------------------------------------------------------------------
# 1. IntSet: construction

# IntSet(iterable, width=width). Duplicates and order do not matter; a width that is too small
# is widened (observed) and a negative one acts as 0 (observed).
fn intset(iterable: list<u16> = [], width: i8 = 0) -> IntSet
  ensures members: all(x in iterable: x in result.members) and all(m in result.members: m in iterable)
  ensures width: result.width == max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512,
    1024, 2048, 4096, 8192, 16384, 32768]: exists(x in iterable: x >= p))]: v)
  ensures kind: result.kind == "IntSet"

# Any negative item raises ValueError.
fn intset_of_ints(iterable: list<int>) -> IntSet
  partition iterable
    naturals = all(x in iterable: x >= 0)
    with_negative = exists(x in iterable: x < 0)
  raises ValueError when exists(x in iterable: x < 0)
  ensures members: all(x in iterable: x in result.members) and all(m in result.members: m in iterable)

# An item that is not an int and has no __index__ raises TypeError: the binding inserts 1.5,
# "1", None or b"1" at position min(at, len(iterable)).
fn intset_with_bad_item(iterable: list<u8>, bad: "float" | "string" | "none" | "bytes", at: u8) -> IntSet
  raises TypeError when true

# bool items count as ints.
fn intset_of_bools(iterable: list<bool>) -> IntSet
  ensures members: result.members == filter(x in [0, 1]: (x == 1) in iterable)
  ensures width: result.width == (if true in iterable then 1 else 0)

# numpy integers work through __index__ (observed): the binding passes numpy.int64 items.
fn intset_of_numpy(iterable: list<u16>) -> IntSet
  ensures members: all(x in iterable: x in result.members) and all(m in result.members: m in iterable)

# Setting any attribute but width and bdd raises AttributeError; assigning those two is not
# blocked (observed). The binding sets the attribute on a fresh IntSet([1]).
fn set_attribute(name: string)
  requires name != "__class__"
  raises AttributeError when not (name in ["width", "bdd"])

# IntSet.range(start, stop, *, width=None): the integers of [start, stop) in the universe. Without
# a width the width is max(stop - 1, 0).bit_length(); an explicit width clips the range.
fn intset_range(start: i8, stop: i16, width: option<i8> = none) -> IntSet
  requires stop <= 1024 and (is_none(width) or unwrap(width) <= 10)
  partition stop
    negative = i16.range(none, 0)
    small = i16.range(0, 1025)
  raises ValueError when start < 0
  raises ValueError when is_some(width) and unwrap(width) < 0
  ensures width: result.width == (if is_some(width) then unwrap(width)
    else count(p in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]: p <= stop - 1))
  ensures members: let w = (if is_some(width) then unwrap(width)
                            else count(p in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]: p <= stop - 1)) in
    result.members == filter(x in range(start, stop): x < [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024][w])
  ensures kind: result.kind == "IntSet"

# Non-int bounds raise TypeError (observed).
fn intset_range_float_stop(start: u8, stop: f64) -> IntSet
  raises TypeError when true

# Sizes are exact at any magnitude, and bool(s) is size > 0.
fn range_size(start: int, stop: int) -> (int, bool)
  partition start
    natural = start >= 0
    negative = start < 0
  raises ValueError when start < 0
  ensures size: result.0 == (if stop > start then stop - start else 0)
  ensures truth: result.1 == (stop > start)

# len(s) == s.size, but len raises OverflowError once the size is >= 2**63 (observed for 2**64).
fn range_len(start: int, stop: int) -> int
  requires start >= 0
  raises OverflowError when stop - start >= 0x8000000000000000
  ensures length: result == (if stop > start then stop - start else 0)

# IntSet.range(start, stop, width=128): an explicit width clips the range at 2**128.
fn range_clipped_size(start: int, stop: int) -> int
  requires start >= 0
  ensures size: let hi = (if stop < 0x100000000000000000000000000000000 then stop
                          else 0x100000000000000000000000000000000) in
    result == (if hi > start then hi - start else 0)

# iter and reversed work at any size: (next(iter(s), None), next(reversed(s), None)).
fn range_ends(start: int, stop: int) -> (option<int>, option<int>)
  requires start >= 0
  ensures first: result.0 == (if stop > start then some(start) else none)
  ensures last: result.1 == (if stop > start then some(stop - 1) else none)

# s[i] works for i far past 2**63.
fn range_at(start: int, stop: int, i: int) -> int
  requires start >= 0
  raises IndexError when let n = (if stop > start then stop - start else 0) in i >= n or i < -n
  ensures value: result == (if i >= 0 then start + i else stop + i)

fn range_index(start: int, stop: int, value: int) -> int
  requires start >= 0
  raises ValueError when not (start <= value and value < stop)
  ensures position: result == value - start

fn range_contains(start: int, stop: int, x: int) -> bool
  requires start >= 0
  ensures member: result == (start <= x and x < stop)

# cls.from_bdd(bdd.diagram(bits), width): the values below 2**width that the diagram accepts.
# Character i of bits tests bit len(bits) - 1 - i; ValueError when a tested bit is >= width.
fn from_diagram(cls: Cls, bits: list<Bit>, width: i8) -> IntSet
  requires len(bits) <= 8 and width <= 8
  partition width
    negative = i8.range(none, 0)
    zero = {0}
    narrow = i8.range(1, 9)
  raises ValueError when exists(i in range(0, len(bits)): bits[i] != "?" and len(bits) - 1 - i >= width)
    or (width < 0)
  ensures members: result.members == filter(x in range(0, [1, 2, 4, 8, 16, 32, 64, 128, 256][width]):
    all(i in range(0, len(bits)): bits[i] == "?" or
      (x // [1, 2, 4, 8, 16, 32, 64, 128][len(bits) - 1 - i]) % 2 == (if bits[i] == "1" then 1 else 0)))
  ensures width: result.width == width
  ensures kind: result.kind == cls

# ---------------------------------------------------------------------------
# 1. IntSet: size, membership, order

# (len(s), bool(s)).
fn measures(cls: Cls, iterable: list<u8>, width: i8) -> (int, bool)
  ensures length: result.0 == count(x in range(0, 256): x in iterable)
  ensures truth: result.1 == (len(iterable) > 0)

# x in s is True only for an int (or bool) member, and never raises.
fn contains(cls: Cls, iterable: list<u8>, width: i8, x: int) -> bool
  ensures member: result == (x in iterable)

fn contains_bool(cls: Cls, iterable: list<u8>, width: i8, x: bool) -> bool
  ensures member: result == ((if x then 1 else 0) in iterable)

fn contains_text(cls: Cls, iterable: list<u8>, width: i8, x: string) -> bool
  ensures never: not result

# (x in s, s.count(x)) for a float x: never a member, unlike a built-in set.
fn float_lookups(cls: Cls, iterable: list<u8>, width: i8, x: f64) -> (bool, int)
  ensures never: not result.0 and result.1 == 0

# ([x in s for x in iterable], [float(x) in s for x in iterable]): 1.0 in IntSet([1]) is False.
fn contains_items(cls: Cls, iterable: list<u8>, width: i8) -> (list<bool>, list<bool>)
  ensures ints: result.0 == map(x in iterable: true)
  ensures floats: result.1 == map(x in iterable: false)

# (list(iter(s)), list(reversed(s))): strictly ascending and strictly descending.
fn iterate(cls: Cls, iterable: list<u8>, width: i8) -> (list<int>, list<int>)
  ensures ascending: result.0 == filter(x in range(0, 256): x in iterable)
  ensures descending: let a = filter(x in range(0, 256): x in iterable) in
    result.1 == map(i in range(0, len(a)): a[len(a) - 1 - i])

# s[i]: the i-th smallest member, a negative i counting from the end.
fn at(cls: Cls, iterable: list<u8>, width: i8, i: i8) -> int
  partition i
    near = i8.range(-9, 9)
    far = i8.all - i8.range(-9, 9)
  raises IndexError when let n = count(x in range(0, 256): x in iterable) in i >= n or i < -n
  ensures value: let a = filter(x in range(0, 256): x in iterable) in
    result == a[if i < 0 then i + len(a) else i]

# bool indexes count as integers.
fn at_bool(cls: Cls, iterable: list<u8>, width: i8, i: bool) -> int
  raises IndexError when (if i then 1 else 0) >= count(x in range(0, 256): x in iterable)
  ensures value: result == filter(x in range(0, 256): x in iterable)[if i then 1 else 0]

# An index that is not an integer raises TypeError (judged where it lies inside [-size, size)).
fn at_float(cls: Cls, iterable: list<u8>, width: i8, i: f64) -> int
  requires is_finite(i) and (let n = count(x in range(0, 256): x in iterable) in real(i) >= -n and real(i) < n)
  raises TypeError when true

# s[start:stop:step]: the set of the members at positions range(size)[start:stop:step], of the same
# type and width (observed), so a negative step does not reverse it. A zero step raises
# ValueError, as range(size)[::0] does.
fn slice(cls: Cls, iterable: list<u8>, width: i8, start: option<i8>, stop: option<i8>, step: i8 = 1) -> IntSet
  partition step
    negative = i8.range(-3, 0)
    zero = {0}
    positive = i8.range(1, 4)
    large = i8.all - i8.range(-3, 4)
  raises ValueError when step == 0
  ensures members:
    let a = filter(x in range(0, 256): x in iterable) in
    let n = len(a) in
    let lower = (if step > 0 then 0 else -1) in
    let upper = (if step > 0 then n else n - 1) in
    let lo = (if is_none(start) then (if step > 0 then lower else upper)
              else if unwrap(start) < 0 then (if unwrap(start) + n < lower then lower else unwrap(start) + n)
              else (if unwrap(start) > upper then upper else unwrap(start))) in
    let hi = (if is_none(stop) then (if step > 0 then upper else lower)
              else if unwrap(stop) < 0 then (if unwrap(stop) + n < lower then lower else unwrap(stop) + n)
              else (if unwrap(stop) > upper then upper else unwrap(stop))) in
    result.members == map(p in filter(p in range(0, n):
        if step > 0 then lo <= p and p < hi and (p - lo) % step == 0
        else hi < p and p <= lo and (lo - p) % (0 - step) == 0): a[p])
  ensures width: result.width == max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v)
  ensures kind: result.kind == cls

# s.index(value, start=0, stop=None): ValueError unless value is a member whose position lies in
# range(size)[start:stop].
fn index_value(cls: Cls, iterable: list<u8>, width: i8, value: u8, start: i8 = 0, stop: option<i8> = none) -> int
  raises ValueError when not (value in iterable) or (
    let a = filter(x in range(0, 256): x in iterable) in
    let n = len(a) in
    let p = index_of(a, value) in
    let lo = (if start < 0 then (if start + n < 0 then 0 else start + n) else (if start > n then n else start)) in
    let hi = (if is_none(stop) then n
              else if unwrap(stop) < 0 then (if unwrap(stop) + n < 0 then 0 else unwrap(stop) + n)
              else (if unwrap(stop) > n then n else unwrap(stop))) in
    not (lo <= p and p < hi))
  ensures position: result == index_of(filter(x in range(0, 256): x in iterable), value)

# ([s.index(x) for x in iterable], [s.count(x) for x in iterable]): a.index(a[i]) == i.
fn positions(cls: Cls, iterable: list<u8>, width: i8) -> (list<int>, list<int>)
  ensures index: result.0 == map(x in iterable: index_of(filter(y in range(0, 256): y in iterable), x))
  ensures count: result.1 == map(x in iterable: 1)

# s.count(value): 1 if value in s, else 0.
fn count_value(cls: Cls, iterable: list<u8>, width: i8, value: int) -> int
  ensures count: result == (if value in iterable then 1 else 0)

# s.index of a non-member of another type raises ValueError.
fn index_float(cls: Cls, iterable: list<u8>, width: i8, value: f64) -> int
  raises ValueError when true

# s.choice(rng=random.Random(seed)), twice with equally seeded generators (observed equal).
fn choice_seeded(cls: Cls, iterable: list<u8>, width: i8, seed: u32) -> (int, int)
  raises IndexError when len(iterable) == 0
  ensures member: result.0 in iterable
  ensures reproducible: result.0 == result.1

# s.choice(), using the random module.
fn choice_default(cls: Cls, iterable: list<u8>, width: i8) -> int
  raises IndexError when len(iterable) == 0
  ensures member: result in iterable

# s.widened(new_width): the same members at width max(s.width, new_width), with the same type.
fn widened(cls: Cls, iterable: list<u8>, width: i8, new_width: i8) -> IntSet
  ensures members: result.members == filter(x in range(0, 256): x in iterable)
  ensures width: result.width == max(v in [width, new_width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v)
  ensures kind: result.kind == cls
