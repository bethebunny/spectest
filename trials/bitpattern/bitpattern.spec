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

# ---------------------------------------------------------------------------
# 1. IntSet: set algebra

# a op b on two IntSets: x in a | b iff x in a or x in b; & is "and", - is "and not" and ^ is
# "exactly one". The width is the larger of the two and the type that of the left operand.
fn combine(op: Op, cls_a: Cls, a: list<u8>, wa: i8, cls_b: Cls, b: list<u8>, wb: i8) -> IntSet
  ensures members: result.members == filter(x in range(0, 256):
    if op == "&" then x in a and x in b
    else if op == "|" then x in a or x in b
    else if op == "-" then x in a and not (x in b)
    else (x in a) != (x in b))
  ensures width: result.width == max(v in [wa, wb,
    count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in a: x >= p)),
    count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in b: x >= p))]: v)
  ensures kind: result.kind == cls_a
  relates commutative: op != "-" implies combine(op, cls_b, b, wb, cls_a, a, wa).members == result.members
  relates inclusion_exclusion: op == "|" implies
    result.size + combine("&", cls_a, a, wa, cls_b, b, wb).size ==
    count(x in range(0, 256): x in a) + count(x in range(0, 256): x in b)

# a op container(b): a right operand that is not an IntSet is first converted as IntSet(other).
fn combine_iterable(op: Op, cls: Cls, a: list<u8>, wa: i8, b: list<u8>, container: Builtin) -> IntSet
  ensures members: result.members == filter(x in range(0, 256):
    if op == "&" then x in a and x in b
    else if op == "|" then x in a or x in b
    else if op == "-" then x in a and not (x in b)
    else (x in a) != (x in b))
  ensures width: result.width == max(v in [wa,
    count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in a: x >= p)),
    count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in b: x >= p))]: v)
  ensures kind: result.kind == cls

# container(a) op s: built-in iterables also work on the left. |, & and ^ give type(s), while -
# gives a plain IntSet.
fn combine_reflected(op: Op, container: Builtin, a: list<u8>, cls: Cls, b: list<u8>, wb: i8) -> IntSet
  ensures members: result.members == filter(x in range(0, 256):
    if op == "&" then x in a and x in b
    else if op == "|" then x in a or x in b
    else if op == "-" then x in a and not (x in b)
    else (x in a) != (x in b))
  ensures width: result.width == max(v in [wb,
    count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in a: x >= p)),
    count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in b: x >= p))]: v)
  ensures kind: result.kind == (if op == "-" then "IntSet" else cls)

# The conversion raises as the constructor does: ValueError for a negative item.
fn combine_ints(op: Op, cls: Cls, a: list<u8>, wa: i8, b: list<int>) -> IntSet
  partition b
    naturals = all(x in b: x >= 0)
    with_negative = exists(x in b: x < 0)
  raises ValueError when exists(x in b: x < 0)
  ensures members:
    all(m in result.members: (m in a or m in b) and
      (if op == "&" then m in a and m in b
       else if op == "|" then m in a or m in b
       else if op == "-" then m in a and not (m in b)
       else (m in a) != (m in b))) and
    all(x in a + b:
      (if op == "&" then x in a and x in b
       else if op == "|" then x in a or x in b
       else if op == "-" then x in a and not (x in b)
       else (x in a) != (x in b)) implies x in result.members)

# A right operand that is not an iterable of ints raises TypeError: the binding passes 5, 1.5,
# None, [1.5] or ["1"].
fn combine_bad(op: Op, cls: Cls, a: list<u8>, wa: i8, bad: "int" | "float" | "none" | "floats" | "strings") -> IntSet
  raises TypeError when true

# ~s: the complement within s's own universe, with the same width and type.
fn complement(cls: Cls, iterable: list<u8>, width: i8) -> IntSet
  requires width <= 10
  partition width
    negative = i8.range(none, 0)
    narrow = i8.range(0, 9)
    wider = i8.range(9, 11)
  ensures members:
    let w = max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) in
    result.members == filter(x in range(0, [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024][w]): not (x in iterable))
  ensures width: result.width == max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v)
  ensures kind: result.kind == cls
  relates involution: result.width <= 8 implies
    complement(cls, result.members, result.width).members == filter(x in range(0, 256): x in iterable)

# <=, <, >= and > mean subset and superset, ignoring width.
fn compare(op: Cmp, cls_a: Cls, a: list<u8>, wa: i8, cls_b: Cls, b: list<u8>, wb: i8) -> bool
  ensures order: let sub = all(x in a: x in b) in let sup = all(x in b: x in a) in
    result == (if op == "<=" then sub else if op == "<" then sub and not sup
               else if op == ">=" then sup else sup and not sub)
  relates difference: op == "<=" implies result == (combine("-", cls_a, a, wa, cls_b, b, wb).size == 0)

# Comparisons accept only IntSet operands: anything else raises TypeError, built-in sets included,
# on either side.
fn compare_other(op: Cmp, cls: Cls, a: list<u8>, wa: i8, b: list<u8>, container: Builtin, side: Side) -> bool
  raises TypeError when true

# a == b (or a != b) exactly when both are IntSets with the same members, whatever their widths.
fn equality(op: "==" | "!=", cls_a: Cls, a: list<u8>, wa: i8, cls_b: Cls, b: list<u8>, wb: i8) -> bool
  ensures members: let same = all(x in a: x in b) and all(x in b: x in a) in
    result == (if op == "==" then same else not same)

# An IntSet never equals a non-IntSet, and the comparison returns without raising.
fn equality_other(op: "==" | "!=", cls: Cls, a: list<u8>, wa: i8, b: list<u8>, container: Builtin, side: Side) -> bool
  ensures never_equal: result == (op == "!=")

# The same items built twice, at other widths or classes: (a == b, hash(a) == hash(b)).
fn rebuilt(cls_a: Cls, a: list<u8>, wa: i8, cls_b: Cls, wb: i8) -> (bool, bool)
  ensures equal: result.0
  ensures equal_hash: result.1

# s.isdisjoint(other) takes any iterable of ints.
fn isdisjoint(cls: Cls, a: list<u8>, wa: i8, b: list<u8>, container: "list" | "set" | "IntSet") -> bool
  ensures disjoint: result == (not exists(x in b: x in a))

# ---------------------------------------------------------------------------
# 1. IntSet: repr

# repr(IntSet(iterable, width=width)): IntSet([m1, m2, ...], width=W) with at most 10 members;
# with more, the first four and the last two, then the size.
fn intset_repr(iterable: list<u16>, width: i8) -> string
  ensures prefix: len(result) >= 9 and result[0:8] == "IntSet(["
  ensures suffix: len(result) >= 1 and codepoints(result)[len(result) - 1] == 41
  ensures elided: let n = count(i in range(0, len(iterable)): not (iterable[i] in iterable[0:i])) in
    (", ..., " in result) == (n > 10) and ("], size=" in result) == (n > 10)
  ensures documented:
    (len(iterable) == 0 and width <= 0 implies result == "IntSet([], width=0)") and
    (iterable == [1, 3] and width == 2 implies result == "IntSet([1, 3], width=2)") and
    (iterable == range(0, 20) and width <= 5 implies
      result == "IntSet([0, 1, 2, 3, ..., 18, 19], size=20, width=5)")

# With at most 10 members the repr evaluates back to the set: eval(repr(s)).
fn intset_repr_eval(iterable: list<u16>, width: i8) -> IntSet
  requires count(i in range(0, len(iterable)): not (iterable[i] in iterable[0:i])) <= 10
  ensures members: all(x in iterable: x in result.members) and all(m in result.members: m in iterable)
  ensures width: result.width == max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512,
    1024, 2048, 4096, 8192, 16384, 32768]: exists(x in iterable: x >= p))]: v)

# repr(IntSet.range(start, stop)): sizes in a repr use count_repr.
fn range_repr(start: int, stop: int) -> string
  requires start >= 0
  ensures prefix: len(result) >= 9 and result[0:8] == "IntSet(["
  ensures elided: (", ..., " in result) == (stop - start > 10)
  ensures documented: start == 0 and stop == 0x10000000000000000 implies
    result == "IntSet([0, 1, 2, 3, ..., 18446744073709551614, 18446744073709551615], size=2**64, width=64)"

# bdd.count_repr(total): decimal, except that an exact power of two 2**k with k >= 10 is "2**k".
# total >= 1024 is a power of two exactly when it equals 2**52 * ulp<f64>(total).
fn count_repr(total: u64) -> string
  partition total
    small = u64.range(0, 1024)
    medium = u64.range(1024, 0x100000000)
    large = u64.range(0x100000000, none)
  ensures decimal: not (total >= 1024 and real(total) == ulp<f64>(total) * 0x1p52) implies
    (let d = codepoints(result) in
     len(d) >= 1 and len(d) <= 20 and all(c in d: c >= 48 and c <= 57) and (len(d) == 1 or d[0] != 48) and
     sum(i in range(0, len(d)): (d[i] - 48) * [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10,
       1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19][len(d) - 1 - i]) == total)
  ensures power: total >= 1024 and real(total) == ulp<f64>(total) * 0x1p52 implies
    (let k = count(p in [0x1p0, 0x1p1, 0x1p2, 0x1p3, 0x1p4, 0x1p5, 0x1p6, 0x1p7, 0x1p8, 0x1p9, 0x1p10,
       0x1p11, 0x1p12, 0x1p13, 0x1p14, 0x1p15, 0x1p16, 0x1p17, 0x1p18, 0x1p19, 0x1p20, 0x1p21, 0x1p22,
       0x1p23, 0x1p24, 0x1p25, 0x1p26, 0x1p27, 0x1p28, 0x1p29, 0x1p30, 0x1p31, 0x1p32, 0x1p33, 0x1p34,
       0x1p35, 0x1p36, 0x1p37, 0x1p38, 0x1p39, 0x1p40, 0x1p41, 0x1p42, 0x1p43, 0x1p44, 0x1p45, 0x1p46,
       0x1p47, 0x1p48, 0x1p49, 0x1p50, 0x1p51, 0x1p52, 0x1p53, 0x1p54, 0x1p55, 0x1p56, 0x1p57, 0x1p58,
       0x1p59, 0x1p60, 0x1p61, 0x1p62, 0x1p63]: p <= total) - 1 in
     let d = codepoints(result) in
     len(d) == 5 and result[0:3] == "2**" and d[3] >= 48 and d[3] <= 57 and d[4] >= 48 and d[4] <= 57 and
     (d[3] - 48) * 10 + (d[4] - 48) == k)
  ensures documented: (total == 512 implies result == "512") and (total == 1024 implies result == "2**10")
    and (total == 0xffffffffffffffff implies result == "18446744073709551615")

# ---------------------------------------------------------------------------
# 2. Pattern
#
# Pattern(text) with text = ".".join("".join(q) for q in quartets). The text is valid when there is
# at least one quartet, each quartet has 1 to 4 characters and at most one *, and every quartet but
# the first has exactly 4 bits once its * is expanded (a * becomes the ? that bring its quartet
# to 4 characters). Written out, valid is:
#   len(quartets) >= 1 and all(j in range(0, len(quartets)):
#     count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
#     (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
# the width is sum(q in quartets: if "*" in q then 4 else len(q)), and the number of ? after
# expansion is sum(q in quartets: count(c in q: c == "?") + (if "*" in q then 5 - len(q) else 0)).

# The members are the ints below 2**width whose bits match, so size == 2**(number of ?).
fn pattern(quartets: list<list<Q>>) -> IntSet
  requires not (len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4)))
    or sum(q in quartets: if "*" in q then 4 else len(q)) <= 8
  partition quartets
    valid = len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
    invalid = not (len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4)))
  raises syntax: ValueError when not (len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4)))
  ensures width: result.width == sum(q in quartets: if "*" in q then 4 else len(q))
  ensures size: result.size == [1, 2, 4, 8, 16, 32, 64, 128, 256][
    sum(q in quartets: count(c in q: c == "?") + (if "*" in q then 5 - len(q) else 0))]
  ensures members: result.members == filter(x in range(0,
      [1, 2, 4, 8, 16, 32, 64, 128, 256][sum(q in quartets: if "*" in q then 4 else len(q))]):
    all(j in range(0, len(quartets)):
      let q = quartets[j] in
      let after = sum(k in range(j + 1, len(quartets)): if "*" in quartets[k] then 4 else len(quartets[k])) in
      all(i in range(0, len(q)): q[i] == "?" or q[i] == "*" or
        (x // [1, 2, 4, 8, 16, 32, 64, 128][after +
            (if "*" in q and i < index_of(q, "*") then 3 - i else len(q) - 1 - i)]) % 2
          == (if q[i] == "1" then 1 else 0))))
  ensures kind: result.kind == "Pattern"

# Surrounding whitespace is stripped (observed).
fn pattern_padded(quartets: list<list<Q>>, before: list<" " | "\t" | "\n" | "\r">, after: list<" " | "\t" | "\n" | "\r">) -> IntSet
  requires len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
    and sum(q in quartets: if "*" in q then 4 else len(q)) <= 8
  partition quartets
    valid = len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
  relates stripped: let p = pattern(quartets) in p.members == result.members and p.width == result.width

# Pattern(text) on any string: a character other than 0 1 ? * . and whitespace raises ValueError
# ("|" included), and so does text that is empty once stripped. Other malformed text also raises
# ValueError, which pattern judges in full.
fn pattern_text(text: string) -> IntSet
  raises bad_character: ValueError when exists(c in codepoints(text): not (c in [48, 49, 63, 42, 46] or
    c in [9, 10, 11, 12, 13, 28, 29, 30, 31, 32, 133, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197,
          8198, 8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, 12288]))
  raises empty: ValueError when all(c in codepoints(text): c in [9, 10, 11, 12, 13, 28, 29, 30, 31, 32,
    133, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8232, 8233,
    8239, 8287, 12288])
  may_raise ValueError

# (p.width, p.size) at any width: Pattern("*1.*.*.0000.1111.?01?").size == 8192, width 24.
fn pattern_shape(quartets: list<list<Q>>) -> (int, int)
  requires len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
    and sum(q in quartets: if "*" in q then 4 else len(q)) <= 64
  partition quartets
    valid = len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
  ensures width: result.0 == sum(q in quartets: if "*" in q then 4 else len(q))
  ensures size: result.1 == [0x1p0, 0x1p1, 0x1p2, 0x1p3, 0x1p4, 0x1p5, 0x1p6, 0x1p7, 0x1p8, 0x1p9,
    0x1p10, 0x1p11, 0x1p12, 0x1p13, 0x1p14, 0x1p15, 0x1p16, 0x1p17, 0x1p18, 0x1p19, 0x1p20, 0x1p21,
    0x1p22, 0x1p23, 0x1p24, 0x1p25, 0x1p26, 0x1p27, 0x1p28, 0x1p29, 0x1p30, 0x1p31, 0x1p32, 0x1p33,
    0x1p34, 0x1p35, 0x1p36, 0x1p37, 0x1p38, 0x1p39, 0x1p40, 0x1p41, 0x1p42, 0x1p43, 0x1p44, 0x1p45,
    0x1p46, 0x1p47, 0x1p48, 0x1p49, 0x1p50, 0x1p51, 0x1p52, 0x1p53, 0x1p54, 0x1p55, 0x1p56, 0x1p57,
    0x1p58, 0x1p59, 0x1p60, 0x1p61, 0x1p62, 0x1p63, 0x1p64][
    sum(q in quartets: count(c in q: c == "?") + (if "*" in q then 5 - len(q) else 0))]

record PatternView { bits: string, free: int, branches: list<string>, text: string, shown: string }

# A pattern made from text has one branch, its dotted text with every * expanded:
# p.bits is that text without dots, p.free its number of ?, str(p) the dotted text, p.branches
# the tuple of it, and repr(p) Pattern('<dotted text>') (Pattern("1.*") is Pattern('1.????')).
fn pattern_view(quartets: list<list<Q>>) -> PatternView
  requires len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
    and sum(q in quartets: if "*" in q then 4 else len(q)) <= 64
  partition quartets
    valid = len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
  ensures bits: len(result.bits) == sum(q in quartets: if "*" in q then 4 else len(q)) and
    all(j in range(0, len(quartets)):
      let q = quartets[j] in
      let off = sum(k in range(0, j): if "*" in quartets[k] then 4 else len(quartets[k])) in
      let cs = map(c in q: if c == "0" then 48 else if c == "1" then 49 else 63) in
      if "*" in q then codepoints(result.bits)[off:off + 4] ==
        cs[0:index_of(q, "*")] + [63, 63, 63, 63][0:5 - len(q)] + cs[index_of(q, "*") + 1:len(q)]
      else codepoints(result.bits)[off:off + len(q)] == cs)
  ensures free: result.free == sum(q in quartets: count(c in q: c == "?") + (if "*" in q then 5 - len(q) else 0))
  ensures text: len(result.text) == sum(q in quartets: if "*" in q then 4 else len(q)) + len(quartets) - 1 and
    all(j in range(0, len(quartets)):
      let q = quartets[j] in
      let off = sum(k in range(0, j): if "*" in quartets[k] then 4 else len(quartets[k])) + j in
      let cs = map(c in q: if c == "0" then 48 else if c == "1" then 49 else 63) in
      (if "*" in q then codepoints(result.text)[off:off + 4] ==
         cs[0:index_of(q, "*")] + [63, 63, 63, 63][0:5 - len(q)] + cs[index_of(q, "*") + 1:len(q)]
       else codepoints(result.text)[off:off + len(q)] == cs) and
      (j == len(quartets) - 1 or
       codepoints(result.text)[off + (if "*" in q then 4 else len(q))] == 46))
  ensures branches: result.branches == [result.text]
  ensures shown: result.shown == "Pattern('" + result.text + "')"

# p.branches for any set (p = Pattern.from_bdd(IntSet(iterable, width=width).bdd, W)): dotted
# single-branch patterns of width W, pairwise disjoint, whose union is p, ordered by smallest
# member (observed). The empty pattern has none. Disjoint and covering follows from every member
# being matched and the branch sizes adding up to the size.
fn branches(iterable: list<u8>, width: i8) -> list<string>
  requires width <= 8
  ensures dotted: let w = max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) in
    w >= 1 implies all(b in result:
      let cp = codepoints(b) in
      let r = (w - 1) % 4 + 1 in
      len(cp) == w + (w - 1) // 4 and all(i in range(0, len(cp)):
        if i >= r and (i - r) % 5 == 0 then cp[i] == 46 else cp[i] == 48 or cp[i] == 49 or cp[i] == 63))
  ensures cover: all(x in iterable: exists(b in result:
    let d = filter(c in codepoints(b): c != 46) in
    all(i in range(0, len(d)): d[i] == 63 or (x // [1, 2, 4, 8, 16, 32, 64, 128][len(d) - 1 - i]) % 2 == d[i] - 48)))
  ensures exact: sum(b in result: [1, 2, 4, 8, 16, 32, 64, 128, 256][count(c in codepoints(b): c == 63)])
    == count(x in range(0, 256): x in iterable)
  ensures ordered: all(i in range(1, len(result)):
    (let d = filter(c in codepoints(result[i - 1]): c != 46) in
     sum(k in range(0, len(d)): if d[k] == 49 then [1, 2, 4, 8, 16, 32, 64, 128][len(d) - 1 - k] else 0)) <
    (let d = filter(c in codepoints(result[i]): c != 46) in
     sum(k in range(0, len(d)): if d[k] == 49 then [1, 2, 4, 8, 16, 32, 64, 128][len(d) - 1 - k] else 0)))
  ensures documented:
    (len(iterable) == 0 implies result == []) and
    (iterable == [2, 3, 5, 6, 7] and width == 3 implies result == ["01?", "101", "11?"]) and
    (iterable == [5, 7] and width == 5 implies result == ["0.01?1"]) and
    (iterable == [0, 1] and width == 4 implies result == ["000?"]) and
    (iterable == range(4, 16) and width == 4 implies result == ["01??", "1???"])

record PatternParts { branches: list<string>, bits: option<string>, free: option<int>, error: option<string> }

# p.bits and p.free raise ValueError ("pattern has N branches, not 1") unless p has one branch.
# The binding records None for a ValueError, and the message of the one p.bits raised.
fn pattern_parts(iterable: list<u8>, width: i8) -> PatternParts
  requires width <= 8
  ensures single: is_some(result.bits) == (len(result.branches) == 1) and
    is_some(result.free) == (len(result.branches) == 1) and is_none(result.error) == (len(result.branches) == 1)
  ensures bits: len(result.branches) == 1 and is_some(result.bits) implies
    codepoints(unwrap(result.bits)) == filter(c in codepoints(result.branches[0]): c != 46)
  ensures free: len(result.branches) == 1 and is_some(result.free) implies
    unwrap(result.free) == count(c in codepoints(result.branches[0]): c == 63)
  ensures message: len(result.branches) != 1 and len(result.branches) <= 9 implies
    result.error == some("pattern has " + ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"][len(result.branches)] + " branches, not 1")

record PatternTexts { branches: list<string>, text: string, shown: string }

# str(p) is " | ".join(p.branches). repr(p) is <Pattern: width=0, size=N> at width 0,
# ~Pattern('<all-? dotted>') when empty, Pattern('b1') | Pattern('b2') | ... for 1 to 8 branches
# (whose text stays under 200 characters at these widths), and <Pattern: K branches, width=W,
# size=S> otherwise.
fn pattern_texts(iterable: list<u8>, width: i8) -> PatternTexts
  requires width <= 8
  ensures text: let br = result.branches in
    (len(br) == 0 implies result.text == "") and
    (len(br) >= 1 implies len(result.text) == sum(b in br: len(b)) + 3 * (len(br) - 1) and
      all(i in range(0, len(br)):
        let off = sum(j in range(0, i): len(br[j]) + 3) in
        result.text[off:off + len(br[i])] == br[i] and (i == 0 or result.text[off - 3:off] == " | ")))
  ensures shown:
    let w = max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) in
    let n = count(x in range(0, 256): x in iterable) in
    let br = result.branches in
    let s = result.shown in
    if w == 0 then s == (if n == 0 then "<Pattern: width=0, size=0>" else "<Pattern: width=0, size=1>")
    else if n == 0 then len(s) >= 12 and s[0:10] == "~Pattern('" and s[len(s) - 2:len(s)] == "')" and
      (let cp = codepoints(s[10:len(s) - 2]) in
       let r = (w - 1) % 4 + 1 in
       len(cp) == w + (w - 1) // 4 and
       all(i in range(0, len(cp)): if i >= r and (i - r) % 5 == 0 then cp[i] == 46 else cp[i] == 63))
    else if len(br) <= 8 then
      len(s) == sum(b in br: len(b) + 11) + 3 * (len(br) - 1) and
      all(i in range(0, len(br)):
        let off = sum(j in range(0, i): len(br[j]) + 14) in
        s[off:off + len(br[i]) + 11] == "Pattern('" + br[i] + "')" and (i == 0 or s[off - 3:off] == " | "))
    else len(s) >= 10 and s[0:10] == "<Pattern: " and " branches, width=" in s
  ensures documented:
    (iterable == [2, 3, 5, 6, 7] and width == 3 implies
      result.shown == "Pattern('01?') | Pattern('101') | Pattern('11?')") and
    (iterable == range(4, 16) and width == 4 implies result.shown == "Pattern('01??') | Pattern('1???')") and
    (len(iterable) == 0 and width == 4 implies result.shown == "~Pattern('????')") and
    (iterable == [5, 7] and width == 5 implies result.shown == "Pattern('0.01?1')")

# In the third form eval(repr(p)) equals p and has the same width (observed). The binding
# evaluates the repr when it starts with Pattern( and returns None otherwise.
fn pattern_repr_eval(iterable: list<u8>, width: i8) -> option<IntSet>
  requires width <= 8
  ensures applies: (let w = max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) in
    let n = count(x in range(0, 256): x in iterable) in w > 0 and n >= 1 and n <= 8) implies is_some(result)
  ensures roundtrip: is_some(result) implies
    unwrap(result).members == filter(x in range(0, 256): x in iterable) and
    unwrap(result).width == max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) and
    unwrap(result).kind == "Pattern"
