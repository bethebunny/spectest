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

# ---------------------------------------------------------------------------
# 3.1 Codecs
#
# For an integer codec name c, its width is
#   (if "128" in c then 128 else if "64" in c then 64 else if "32" in c then 32 else if "16" in c then 16 else 8),
# its universe size FULL is the matching power of two (0x100, 0x10000, ...), it is signed when
# not ("u" in c), and a value v encodes as v % FULL.

type IntCodec = "int8" | "int16" | "int32" | "int64" | "int128" | "uint8" | "uint16" | "uint32" | "uint64" | "uint128"
type Signed = "int8" | "int16" | "int32" | "int64" | "int128"
type CodecName = "int8" | "int16" | "int32" | "int64" | "int128" | "uint8" | "uint16" | "uint32" | "uint64" | "uint128"
  | "float16" | "bfloat16" | "float32" | "float64" | "float8_e5m2" | "float8_e4m3fn" | "char" | "ipv4" | "ipv6"
  | "mac" | "dates" | "datetimes" | "naive_datetimes" | "uuid128"
type Other = "set" | "frozenset" | "list" | "IntSet"

# Codecs compare and hash by class and field values; codecs of different classes are never
# equal: (x == y, hash(x) == hash(y)) for the built-in codecs.
fn codecs_equal(x: CodecName, y: CodecName) -> (bool, bool)
  ensures equal: result.0 == (x == y)
  ensures equal_hash: result.0 implies result.1

# (repr(c), c.name, c.width): repr(codec) is its name, which is the variable name for the codecs
# whose construction the specification shows (datetimes is DateTime(datetime.UTC), named
# datetimes[UTC]); the float codecs' names are not specified.
fn codec_name(c: CodecName) -> (string, string, int)
  ensures repr: result.0 == result.1
  ensures name: not (c in ["float16", "bfloat16", "float32", "float64", "float8_e5m2", "float8_e4m3fn"]) implies
    result.1 == (if c == "datetimes" then "datetimes[UTC]" else c)
  ensures width: result.2 == (
    if c in ["int8", "uint8", "float8_e5m2", "float8_e4m3fn"] then 8
    else if c in ["int16", "uint16", "float16", "bfloat16"] then 16
    else if c in ["int32", "uint32", "float32", "ipv4"] then 32
    else if c in ["int64", "uint64", "float64"] then 64
    else if c in ["int128", "uint128", "ipv6", "uuid128"] then 128
    else if c == "char" then 21 else if c == "mac" then 48 else if c == "dates" then 22 else 59)

# Assigning a field raises dataclasses.FrozenInstanceError.
fn codec_assign(c: CodecName, field: "width" | "name")
  raises FrozenInstanceError when true

# Built-in codecs and their sets survive a pickle round trip (observed):
# (loads(dumps(c)) == c, loads(dumps(c.all)) == c.all).
fn codec_pickle(c: CodecName) -> (bool, bool)
  ensures codec: result.0
  ensures set: result.1

# The base Codec(width, "base"): (dtype().value, all.size, none.size). The default dtype is the
# narrowest unsigned type, UINT8 rows above 64 bits; all is the full universe; none is empty.
fn base_codec(width: u8) -> ((int, int), int, int)
  requires width <= 128
  ensures dtype: result.0 == (if width <= 8 then (1, 8) else if width <= 16 then (1, 16)
    else if width <= 32 then (1, 32) else if width <= 64 then (1, 64) else (1, 8))
  ensures all: width <= 64 implies result.1 == [0x1p0, 0x1p1, 0x1p2, 0x1p3, 0x1p4, 0x1p5, 0x1p6,
    0x1p7, 0x1p8, 0x1p9, 0x1p10, 0x1p11, 0x1p12, 0x1p13, 0x1p14, 0x1p15, 0x1p16, 0x1p17, 0x1p18,
    0x1p19, 0x1p20, 0x1p21, 0x1p22, 0x1p23, 0x1p24, 0x1p25, 0x1p26, 0x1p27, 0x1p28, 0x1p29, 0x1p30,
    0x1p31, 0x1p32, 0x1p33, 0x1p34, 0x1p35, 0x1p36, 0x1p37, 0x1p38, 0x1p39, 0x1p40, 0x1p41, 0x1p42,
    0x1p43, 0x1p44, 0x1p45, 0x1p46, 0x1p47, 0x1p48, 0x1p49, 0x1p50, 0x1p51, 0x1p52, 0x1p53, 0x1p54,
    0x1p55, 0x1p56, 0x1p57, 0x1p58, 0x1p59, 0x1p60, 0x1p61, 0x1p62, 0x1p63, 0x1p64][width]
  ensures empty: result.2 == 0

# The base class's encode raises NotImplementedError.
fn base_codec_encode(width: u8, value: int) -> int
  raises NotImplementedError when true

# Two separately built Int codecs: (Int(w1, n1, s1) == Int(w2, n2, s2), whether their sets
# combine (observed): the binding tries a.none | b.none).
fn int_codec_fields(w1: u8, n1: "a" | "b", s1: bool, w2: u8, n2: "a" | "b", s2: bool) -> (bool, bool)
  requires w1 >= 1 and w1 <= 16 and w2 >= 1 and w2 <= 16
  partition w1
    byte = {8}
    other = u8.range(1, 8) | u8.range(9, 17)
  partition w2
    byte = {8}
    other = u8.range(1, 8) | u8.range(9, 17)
  ensures equal: result.0 == (w1 == w2 and n1 == n2 and s1 == s2)
  ensures combine: result.1 == result.0

type PatternCodec = "uint8" | "int8" | "uint16" | "int16" | "float16" | "bfloat16" | "float8_e5m2" | "float8_e4m3fn" | "uint32" | "int32" | "float32" | "ipv4" | "char"

# c.pattern(text): the values whose encodings match Pattern(text) (quartets as for pattern),
# intersected with all; ValueError when the pattern's width is not the codec's. The integer,
# float and ipv4 codecs have the whole universe as all.
fn codec_pattern(c: PatternCodec, quartets: list<list<Q>>) -> CodecSet
  requires len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
  partition quartets
    valid = len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
  raises ValueError when sum(q in quartets: if "*" in q then 4 else len(q)) != (
    if c in ["uint8", "int8", "float8_e5m2", "float8_e4m3fn"] then 8
    else if c in ["uint16", "int16", "float16", "bfloat16"] then 16 else if c == "char" then 21 else 32)
  ensures size: (if c == "char" then result.size <= 0x1p21 else result.size == [1, 2, 4, 8, 16, 32, 64, 128, 256, 512,
      1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304,
      8388608, 16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824, 2147483648,
      4294967296][sum(q in quartets: count(c in q: c == "?") + (if "*" in q then 5 - len(q) else 0))])
  ensures codec: result.codec == c

# The message of that ValueError is "pattern is N bits, not W". The binding returns str(e), or ""
# when nothing is raised.
fn codec_pattern_message(c: PatternCodec, quartets: list<list<Q>>) -> string
  requires len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
    and sum(q in quartets: if "*" in q then 4 else len(q)) != (
      if c in ["uint8", "int8", "float8_e5m2", "float8_e4m3fn"] then 8
      else if c in ["uint16", "int16", "float16", "bfloat16"] then 16 else if c == "char" then 21 else 32)
    and sum(q in quartets: if "*" in q then 4 else len(q)) <= 99
  partition quartets
    valid = len(quartets) >= 1 and all(j in range(0, len(quartets)):
      count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and
      (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))
  ensures message:
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] in
    let n = sum(q in quartets: if "*" in q then 4 else len(q)) in
    let w = (if c in ["uint8", "int8", "float8_e5m2", "float8_e4m3fn"] then 8
             else if c in ["uint16", "int16", "float16", "bfloat16"] then 16 else if c == "char" then 21 else 32) in
    result == "pattern is " + (if n < 10 then digits[n] else digits[n // 10] + digits[n % 10]) +
      " bits, not " + digits[w // 10] + digits[w % 10]

# ---------------------------------------------------------------------------
# 3.3 BDDSet
#
# For a signed codec and values: list<i8>, encoding order puts the non-negative values first, so
# the set iterates as filter(v in range(0, 128): v in values) + filter(v in range(-128, 0): v in values).

# BDDSet(c, IntSet(iterable, width=width)): ValueError unless the storage's width is the codec's.
fn bddset_new(c: "int8" | "uint8" | "int16" | "uint16" | "int32" | "uint32" | "int64" | "uint64", iterable: list<u8>, width: i8) -> CodecSet
  partition width
    named = {8, 16, 32, 64}
    other = i8.all - {8, 16, 32, 64}
  raises ValueError when max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v)
    != (if "64" in c then 64 else if "32" in c then 32 else if "16" in c then 16 else 8)
  ensures size: result.size == count(x in range(0, 256): x in iterable)
  ensures members: all(x in iterable: result.has(x))
  ensures codec: result.codec == c

# c.set(values): each value goes through encode.
fn codec_set(c: IntCodec, values: list<i8>) -> CodecSet
  raises ValueError when "u" in c and exists(v in values: v < 0)
  ensures size: result.size == count(v in range(-128, 128): v in values)
  ensures members: let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    all(v in values: result.has(v % full))
  ensures codec: result.codec == c

# (list(s), list(reversed(s))): decoded values in encoding order, and backwards.
fn codec_set_order(c: Signed, values: list<i8>) -> (list<int>, list<int>)
  ensures order: result.0 == filter(v in range(0, 128): v in values) + filter(v in range(-128, 0): v in values)
  ensures reversed: let a = filter(v in range(0, 128): v in values) + filter(v in range(-128, 0): v in values) in
    result.1 == map(i in range(0, len(a)): a[len(a) - 1 - i])

# (s.size, len(s), bool(s)).
fn codec_set_measures(c: Signed, values: list<i8>) -> (int, int, bool)
  ensures size: result.0 == count(v in range(-128, 128): v in values) and result.1 == result.0
  ensures truth: result.2 == (len(values) > 0)

# s[i], in encoding order; IndexError out of range.
fn codec_set_at(c: Signed, values: list<i8>, i: i8) -> int
  partition i
    near = i8.range(-9, 9)
    far = i8.all - i8.range(-9, 9)
  raises IndexError when let n = count(v in range(-128, 128): v in values) in i >= n or i < -n
  ensures value: let a = filter(v in range(0, 128): v in values) + filter(v in range(-128, 0): v in values) in
    result == a[if i < 0 then i + len(a) else i]

# s[start:stop] is a BDDSet of the members at those positions.
fn codec_set_slice(c: Signed, values: list<i8>, start: option<i8>, stop: option<i8>) -> CodecSet
  ensures members:
    let a = filter(v in range(0, 128): v in values) + filter(v in range(-128, 0): v in values) in
    let n = len(a) in
    let lo = (if is_none(start) then 0 else if unwrap(start) < 0 then (if unwrap(start) + n < 0 then 0 else unwrap(start) + n)
              else (if unwrap(start) > n then n else unwrap(start))) in
    let hi = (if is_none(stop) then n else if unwrap(stop) < 0 then (if unwrap(stop) + n < 0 then 0 else unwrap(stop) + n)
              else (if unwrap(stop) > n then n else unwrap(stop))) in
    let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    result.size == (if hi > lo then hi - lo else 0) and
    all(p in range(0, n): result.has(a[p] % full) == (lo <= p and p < hi))
  ensures codec: result.codec == c

# (x in s, s.count(x)): x in s is True iff x encodes and its encoding is stored; an encode error
# gives False.
fn codec_set_lookup(c: Signed, values: list<i8>, x: int) -> (bool, int)
  ensures member: result.0 == (x in values)
  ensures count: result.1 == (if x in values then 1 else 0)

# The same for a value of the wrong type (1.0, "1", None or b"\x01"): 1.0 in int8.all is False.
fn codec_set_lookup_other(c: IntCodec, values: list<i8>, x: "float" | "string" | "none" | "bytes") -> (bool, int)
  requires not ("u" in c) or all(v in values: v >= 0)
  ensures never: not result.0 and result.1 == 0

# s.index(x): the position in encoding order; ValueError for a non-member, a value of the wrong
# type and one that cannot be encoded.
fn codec_set_index(c: Signed, values: list<i8>, x: int) -> int
  raises ValueError when not (x in values)
  ensures position: result == index_of(filter(v in range(0, 128): v in values) + filter(v in range(-128, 0): v in values), x)

fn codec_set_index_other(c: Signed, values: list<i8>, x: "float" | "string" | "none") -> int
  raises ValueError when true

# s.choice(rng=random.Random(seed)) twice: a member, IndexError when empty.
fn codec_set_choice(c: Signed, values: list<i8>, seed: u32) -> (int, int)
  raises IndexError when len(values) == 0
  ensures member: result.0 in values
  ensures reproducible: result.0 == result.1

# c.set(a) op d.set(b): only sets of an equal codec combine; anything else raises TypeError
# ("<codec> sets only combine with each other"), even a codec of the same width.
fn codec_set_combine(op: Op, c: IntCodec, a: list<i8>, d: IntCodec, b: list<i8>) -> CodecSet
  raises ValueError when ("u" in c and exists(x in a: x < 0)) or ("u" in d and exists(x in b: x < 0))
  raises TypeError when c != d
  ensures members: let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    all(x in a + b: result.has(x % full) == (
      if op == "&" then x in a and x in b
      else if op == "|" then x in a or x in b
      else if op == "-" then x in a and not (x in b)
      else (x in a) != (x in b)))
  ensures size: result.size == count(x in range(-128, 128):
      if op == "&" then x in a and x in b
      else if op == "|" then x in a or x in b
      else if op == "-" then x in a and not (x in b)
      else (x in a) != (x in b))
  ensures codec: result.codec == c

# With a built-in set, list or IntSet on either side, the operators raise TypeError.
fn codec_set_combine_other(op: Op, c: Signed, a: list<i8>, other: Other, side: Side) -> CodecSet
  raises TypeError when true

# <=, <, >=, > and isdisjoint, between sets of one codec.
fn codec_set_compare(op: "<=" | "<" | ">=" | ">" | "isdisjoint", c: IntCodec, a: list<i8>, d: IntCodec, b: list<i8>) -> bool
  raises ValueError when ("u" in c and exists(x in a: x < 0)) or ("u" in d and exists(x in b: x < 0))
  raises TypeError when c != d
  ensures order: let sub = all(x in a: x in b) in let sup = all(x in b: x in a) in
    result == (if op == "<=" then sub else if op == "<" then sub and not sup
               else if op == ">=" then sup else if op == ">" then sup and not sub
               else not exists(x in a: x in b))

# The same with a built-in set, list or IntSet: TypeError, lists given to isdisjoint included.
# (other.isdisjoint(s) is the other object's method, so isdisjoint is judged on the right only.)
fn codec_set_compare_other(op: "<=" | "<" | ">=" | ">" | "isdisjoint", c: Signed, a: list<i8>, other: Other, side: Side) -> bool
  requires not (op == "isdisjoint" and side == "left")
  raises TypeError when true

# (a == b, hash(a) == hash(b)): equal iff both codecs are equal and the encodings the same.
fn codec_set_equal(c: IntCodec, a: list<i8>, d: IntCodec, b: list<i8>) -> (bool, bool)
  raises ValueError when ("u" in c and exists(x in a: x < 0)) or ("u" in d and exists(x in b: x < 0))
  ensures equal: result.0 == (c == d and all(x in a: x in b) and all(x in b: x in a))
  ensures equal_hash: result.0 implies result.1

# A BDDSet never equals a built-in set, a list or an IntSet, and == never raises.
fn codec_set_equal_other(c: Signed, a: list<i8>, other: Other, side: Side) -> bool
  ensures never: not result

# ~s == s.codec.all - s.
fn codec_set_complement(c: Signed, values: list<i8>) -> CodecSet
  ensures size: result.size == (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) - count(v in range(-128, 128): v in values)
  ensures members: let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    all(v in range(-128, 128): result.has(v % full) == (not (v in values)))

# ~char.set(characters of text): the complement within the legal values, so no surrogate.
fn char_complement(text: string) -> CodecSet
  ensures size: result.size == 1112064 - count(i in range(0, len(text)): not (codepoints(text)[i] in codepoints(text)[0:i]))
  ensures legal: not result.has(0xd800) and not result.has(0xdfff) and all(c in codepoints(text): not result.has(c))

# repr(c.set(values)): BDDSet(<codec name>, [v1, v2, ...]) with at most 10 values, else the first
# four and last two in encoding order and the size.
fn codec_set_repr(c: Signed, values: list<i8>) -> string
  ensures prefix: len(result) >= len(c) + 10 and result[0:len(c) + 10] == "BDDSet(" + c + ", ["
  ensures elided: let n = count(v in range(-128, 128): v in values) in
    (", ..., " in result) == (n > 10) and ("], size=" in result) == (n > 10)

# repr(c.all): BDDSet(uint8, [0, 1, 2, 3, ..., 254, 255], size=256).
fn all_repr(c: IntCodec) -> string
  ensures prefix: len(result) >= len(c) + 10 and result[0:len(c) + 10] == "BDDSet(" + c + ", ["
  ensures documented: c == "uint8" implies result == "BDDSet(uint8, [0, 1, 2, 3, ..., 254, 255], size=256)"

# ---------------------------------------------------------------------------
# 3.4 Int codecs

record IntInfo { width: int, signed: bool, min: int, max: int, dtype: (int, int), all: int }

# The codec table: width, signedness, min, max, dtype and the size of all (the full universe).
fn int_codec_info(c: IntCodec) -> IntInfo
  ensures width: result.width == (if "128" in c then 128 else if "64" in c then 64 else if "32" in c then 32
    else if "16" in c then 16 else 8)
  ensures bounds: let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    result.signed == (not ("u" in c)) and
    result.min == (if "u" in c then 0 else -(full // 2)) and
    result.max == (if "u" in c then full - 1 else full // 2 - 1) and result.all == full
  ensures dtype: result.dtype == (if "128" in c then (1, 8) else
    (if "u" in c then 1 else 0, if "64" in c then 64 else if "32" in c then 32 else if "16" in c then 16 else 8))

# encode(v): an int (bool included) in [min, max], encoded as v mod 2**width.
fn int_encode(c: IntCodec, v: int) -> int
  raises ValueError when let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    (if "u" in c then v < 0 or v >= full else v < -(full // 2) or v >= full // 2)
  ensures value: result == v % (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100)

fn int_encode_bool(c: IntCodec, v: bool) -> int
  ensures value: result == (if v then 1 else 0)

# Values with __index__ work too (the binding passes numpy.int64).
fn int_encode_numpy(c: IntCodec, v: i64) -> int
  raises ValueError when let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    (if "u" in c then v < 0 or v >= full else v < -(full // 2) or v >= full // 2)
  ensures value: result == v % (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100)

# Floats, strings and None raise TypeError (the binding passes 1.0, "1" or None).
fn int_encode_bad(c: IntCodec, bad: "float" | "string" | "none") -> int
  raises TypeError when true

# decode(b) is b - 2**width when b > max, else b.
fn int_decode(c: IntCodec, b: int) -> int
  requires b >= 0 and b < (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100)
  partition b
    small = b < 0x10000
    large = b >= 0x10000
  ensures value: let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    result == (if not ("u" in c) and b >= full // 2 then b - full else b)
  relates roundtrip: int_encode(c, result) == b

# range(start, stop): the integers of [start, stop), the bounds clamped to [min, max + 1].
fn int_range(c: IntCodec, start: option<int>, stop: option<int>) -> CodecSet
  ensures interval:
    let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    let lowest = (if "u" in c then 0 else -(full // 2)) in
    let top = lowest + full in
    let lo = (if is_none(start) then lowest else if unwrap(start) < lowest then lowest
              else if unwrap(start) > top then top else unwrap(start)) in
    let hi = (if is_none(stop) then top else if unwrap(stop) < lowest then lowest
              else if unwrap(stop) > top then top else unwrap(stop)) in
    result.size == (if hi > lo then hi - lo else 0) and
    (hi > lo implies result.has(lo % full) and result.has((hi - 1) % full) and
      (lo > lowest implies not result.has((lo - 1) % full)) and (hi < top implies not result.has(hi % full)))
  ensures codec: result.codec == c

# list(c.range(start, start + span)), in encoding order.
fn int_range_values(c: IntCodec, start: int, span: u8) -> list<int>
  ensures values:
    let full = (if "128" in c then 0x100000000000000000000000000000000
      else if "64" in c then 0x10000000000000000 else if "32" in c then 0x100000000
      else if "16" in c then 0x10000 else 0x100) in
    let lowest = (if "u" in c then 0 else -(full // 2)) in
    let top = lowest + full in
    let lo = (if start < lowest then lowest else if start > top then top else start) in
    let hi = (if start + span < lowest then lowest else if start + span > top then top else start + span) in
    result == filter(v in range(lo, hi): v >= 0) + filter(v in range(lo, hi): v < 0)

# Non-int bounds raise TypeError (observed).
fn int_range_float(c: IntCodec, bound: f64) -> CodecSet
  raises TypeError when true

# A custom Int(width, "custom", signed): ((min, max), dtype().value). A signed Int up to 64 bits
# exports as the narrowest signed type; any other Int uses the unsigned default.
fn custom_int(width: u8, signed: bool) -> ((int, int), (int, int))
  requires width >= 1 and width <= 128
  partition width
    small = u8.range(1, 65)
    wide = u8.range(65, 129)
  ensures bounds: width <= 64 implies
    (let p = [0x1p0, 0x1p1, 0x1p2, 0x1p3, 0x1p4, 0x1p5, 0x1p6, 0x1p7, 0x1p8, 0x1p9, 0x1p10, 0x1p11,
       0x1p12, 0x1p13, 0x1p14, 0x1p15, 0x1p16, 0x1p17, 0x1p18, 0x1p19, 0x1p20, 0x1p21, 0x1p22, 0x1p23,
       0x1p24, 0x1p25, 0x1p26, 0x1p27, 0x1p28, 0x1p29, 0x1p30, 0x1p31, 0x1p32, 0x1p33, 0x1p34, 0x1p35,
       0x1p36, 0x1p37, 0x1p38, 0x1p39, 0x1p40, 0x1p41, 0x1p42, 0x1p43, 0x1p44, 0x1p45, 0x1p46, 0x1p47,
       0x1p48, 0x1p49, 0x1p50, 0x1p51, 0x1p52, 0x1p53, 0x1p54, 0x1p55, 0x1p56, 0x1p57, 0x1p58, 0x1p59,
       0x1p60, 0x1p61, 0x1p62, 0x1p63, 0x1p64] in
     result.0.0 == (if signed then -p[width - 1] else 0) and
     result.0.1 == (if signed then p[width - 1] - 1 else p[width] - 1))
  ensures dtype: result.1 == (
    if signed and width <= 64 then (0, if width <= 8 then 8 else if width <= 16 then 16 else if width <= 32 then 32 else 64)
    else (1, if width <= 8 then 8 else if width <= 16 then 16 else if width <= 32 then 32 else if width <= 64 then 64 else 8))

# ---------------------------------------------------------------------------
# 3.5 Float codecs
#
# For a float codec the sign bit is SIGN = 2**(width - 1); an encoding b has the magnitude
# b % SIGN, and with the all-ones exponent and zero mantissa INF (0x7c00 for float16, 0x7f80 for
# bfloat16, 0x7f800000 for float32, 0x7ff0000000000000 for float64, 0x7c for float8_e5m2) a Float
# encoding is NaN when its magnitude exceeds INF. float8_e4m3fn (FloatFN) has no infinities and
# its NaNs are the two encodings of magnitude 0x7f.

type FloatCodec = "float16" | "bfloat16" | "float32" | "float64" | "float8_e5m2" | "float8_e4m3fn"
type IeeeCodec = "float16" | "bfloat16" | "float32" | "float64"
type Float8 = "float8_e5m2" | "float8_e4m3fn"

record FloatInfo { kind: string, width: int, exponent: int, max: f64, min: f64, dtype: (int, int) }

# The table: (type(c).__name__, width, exponent, max, min, dtype().value); min == -max, and both
# are the extreme finite values.
fn float_codec_info(c: FloatCodec) -> FloatInfo
  ensures table: (result.kind, result.width, result.exponent, result.dtype) == (
    if c == "float64" then ("Float", 64, 11, (2, 64))
    else if c == "float32" then ("Float", 32, 8, (2, 32))
    else if c == "float16" then ("Float", 16, 5, (2, 16))
    else if c == "bfloat16" then ("Float", 16, 8, (4, 16))
    else if c == "float8_e5m2" then ("Float", 8, 5, (12, 8))
    else ("FloatFN", 8, 4, (10, 8)))
  ensures max: is_finite(result.max) and real(result.max) == (
    if c == "float64" then 0x1.fffffffffffffp1023 else if c == "float32" then 0x1.fffffep127
    else if c == "float16" then 65504 else if c == "bfloat16" then 0x1.fep127
    else if c == "float8_e5m2" then 57344 else 448)
  ensures min: is_finite(result.min) and is_finite(result.max) and real(result.min) == -real(result.max)

# float16.decode over every encoding: a non-NaN encoding gives the float16 value with those
# bits, a NaN encoding a NaN of the same sign.
fn f16_decode(b: u16) -> f16
  ensures decoded: if b % 0x8000 > 0x7c00 then is_nan(result) and signbit(result) == (b >= 0x8000)
    else not is_nan(result) and bits(result) == b
  relates roundtrip: not is_nan(result) implies f16_encode(result) == b

# float16.encode over every float16 value: its own bits, and for a NaN a NaN of the same sign.
fn f16_encode(x: f16) -> u16
  ensures encoded: if is_nan(x) then result % 0x8000 > 0x7c00 and (result >= 0x8000) == signbit(x)
    else result == bits(x)

# encode(x) for a double x rounds to the nearest value, ties to even; tiny values keep their
# sign; a finite value that rounds beyond max raises ValueError; infinities encode as the
# matching infinity, zeros keep their sign, and a NaN gives a NaN of the same sign.
fn float_encode(c: IeeeCodec, x: f64) -> int
  partition x
    nan = f64.nan
    inf = f64.inf
    zero = f64.zero
    tiny = f64.range(-0x1p-14, 0x1p-14) - f64.zero
    half = f64.range(-65520, 65520) - f64.range(-0x1p-14, 0x1p-14)
    single = f64.range(-0x1p128, 0x1p128) - f64.range(-65520, 65520)
    huge = f64.finite - f64.range(-0x1p128, 0x1p128)
  raises ValueError when is_finite(x) and (
    if c == "float16" then is_inf(round<f16>(real(x)))
    else if c == "bfloat16" then is_inf(round<bf16>(real(x)))
    else if c == "float32" then is_inf(round<f32>(real(x))) else false)
  ensures encoded:
    let sign = (if c == "float64" then 0x8000000000000000 else if c == "float32" then 0x80000000 else 0x8000) in
    let inf = (if c == "float64" then 0x7ff0000000000000 else if c == "float32" then 0x7f800000
               else if c == "bfloat16" then 0x7f80 else 0x7c00) in
    if is_nan(x) then result % sign > inf and (result >= sign) == signbit(x)
    else if is_zero(x) then result == (if signbit(x) then sign else 0)
    else result == (if c == "float16" then bits(round<f16>(real(x)))
                    else if c == "bfloat16" then bits(round<bf16>(real(x)))
                    else if c == "float32" then bits(round<f32>(real(x))) else bits(x))

# Ints (exactly representable as doubles here) are accepted and rounded the same way.
fn float_encode_int(c: IeeeCodec, v: int) -> int
  requires v >= -0x20000000000000 and v <= 0x20000000000000
  raises ValueError when if c == "float16" then is_inf(round<f16>(v))
    else if c == "bfloat16" then is_inf(round<bf16>(v)) else false
  ensures encoded: result == (if c == "float16" then bits(round<f16>(v))
    else if c == "bfloat16" then bits(round<bf16>(v))
    else if c == "float32" then bits(round<f32>(v)) else bits(round<f64>(v)))

fn float_encode_bool(c: IeeeCodec, v: bool) -> int
  ensures encoded: result == (if c == "float16" then bits(round<f16>(if v then 1 else 0))
    else if c == "bfloat16" then bits(round<bf16>(if v then 1 else 0))
    else if c == "float32" then bits(round<f32>(if v then 1 else 0)) else bits(round<f64>(if v then 1 else 0)))

# Other real numbers that convert to float work too (observed): the binding passes
# fractions.Fraction(num, den).
fn float_encode_fraction(c: IeeeCodec, num: i16, den: u8) -> int
  requires den > 0
  ensures encoded: result == (if c == "float16" then bits(round<f16>(num / den))
    else if c == "bfloat16" then bits(round<bf16>(num / den))
    else if c == "float32" then bits(round<f32>(num / den)) else bits(round<f64>(num / den)))

# Strings, None and bytes raise TypeError.
fn float_encode_bad(c: FloatCodec, bad: "string" | "none" | "bytes") -> int
  raises TypeError when true

# decode(b) returns a Python float with the encoding's value; a NaN encoding gives a NaN of the
# same sign.
fn float_decode(c: IeeeCodec, b: u64) -> f64
  requires b < (if c == "float64" then 0x10000000000000000 else if c == "float32" then 0x100000000 else 0x10000)
  partition b
    byte = u64.range(0, 0x100)
    half = u64.range(0x100, 0x10000)
    word = u64.range(0x10000, 0x100000000)
    wide = u64.range(0x100000000, none)
  ensures decoded:
    let sign = (if c == "float64" then 0x8000000000000000 else if c == "float32" then 0x80000000 else 0x8000) in
    let inf = (if c == "float64" then 0x7ff0000000000000 else if c == "float32" then 0x7f800000
               else if c == "bfloat16" then 0x7f80 else 0x7c00) in
    if b % sign > inf then is_nan(result) and signbit(result) == (b >= sign)
    else if is_nan(result) then false
    else if c == "float64" then bits(result) == b
    else if is_zero(result) then b == (if signbit(result) then sign else 0)
    else if c == "float16" then fits<f16>(real(result)) and bits(round<f16>(real(result))) == b
    else if c == "bfloat16" then fits<bf16>(real(result)) and bits(round<bf16>(real(result))) == b
    else fits<f32>(real(result)) and bits(round<f32>(real(result))) == b
  relates roundtrip: not is_nan(result) implies float_encode(c, result) == b

# Float.decode raises IndexError for b < 0 or b >= 2**width (FloatFN does not check).
fn float_decode_out_of_range(c: "float16" | "bfloat16" | "float32" | "float64" | "float8_e5m2", b: int) -> f64
  requires b < 0 or b >= (if c == "float64" then 0x10000000000000000 else if c == "float32" then 0x100000000
    else if c == "float8_e5m2" then 0x100 else 0x10000)
  partition b
    negative = b < 0
    beyond = b >= 0
  raises IndexError when true

# The float8 values, from their bit fields: float8_e5m2 has 2 mantissa bits and bias 15,
# float8_e4m3fn 3 mantissa bits and bias 7 (0x7e decodes to 448.0).
fn float8_decode(c: Float8, b: u8) -> f64
  ensures decoded:
    if c == "float8_e5m2" then
      (if b % 128 > 0x7c then is_nan(result) and signbit(result) == (b >= 128)
       else if b % 128 == 0x7c then is_inf(result) and signbit(result) == (b >= 128)
       else not is_nan(result) and signbit(result) == (b >= 128) and
         (let e = (b % 128) // 4 in
          let m = b % 4 in
          let mag = (if e == 0 then m * 0x1p-16 else (4 + m) * [0x1p-16, 0x1p-15, 0x1p-14, 0x1p-13,
            0x1p-12, 0x1p-11, 0x1p-10, 0x1p-9, 0x1p-8, 0x1p-7, 0x1p-6, 0x1p-5, 0x1p-4, 0x1p-3, 0x1p-2,
            0x1p-1, 0x1p0, 0x1p1, 0x1p2, 0x1p3, 0x1p4, 0x1p5, 0x1p6, 0x1p7, 0x1p8, 0x1p9, 0x1p10,
            0x1p11, 0x1p12, 0x1p13][e - 1]) in
          real(result) == (if b >= 128 then -mag else mag)))
    else
      (if b % 128 == 0x7f then is_nan(result) and signbit(result) == (b >= 128)
       else not is_nan(result) and signbit(result) == (b >= 128) and
         (let e = (b % 128) // 8 in
          let m = b % 8 in
          let mag = (if e == 0 then m * 0x1p-9 else (8 + m) * [0x1p-9, 0x1p-8, 0x1p-7, 0x1p-6, 0x1p-5,
            0x1p-4, 0x1p-3, 0x1p-2, 0x1p-1, 0x1p0, 0x1p1, 0x1p2, 0x1p3, 0x1p4, 0x1p5][e - 1]) in
          real(result) == (if b >= 128 then -mag else mag)))
  relates roundtrip: not is_nan(result) implies float8_encode(c, result) == b

# encode(x) for float8: the nearest value, ties to even, with the format's spacing (2**-16 below
# 2**-14 and a quarter of the binade above for e5m2; 2**-9 below 2**-6 and an eighth of the binade
# above for e4m3fn), computed from the float16 spacing ulp<f16>; below 2**16 the quotient v / step
# is under 17, so counting gives its floor. Beyond max raises ValueError (e4m3fn encodes 464.0, a
# tie, as 448.0 and raises on 465.0), and so do infinities for FloatFN.
fn float8_encode(c: Float8, x: f64) -> u8
  partition x
    nan = f64.nan
    inf = f64.inf
    zero = f64.zero
    small = f64.range(-0x1p-6, 0x1p-6) - f64.zero
    normal = f64.range(-512, 512) - f64.range(-0x1p-6, 0x1p-6)
    medium = f64.range(-65536, 65536) - f64.range(-512, 512)
    huge = f64.finite - f64.range(-65536, 65536)
  raises infinite: ValueError when is_inf(x) and c == "float8_e4m3fn"
  raises overflow: ValueError when is_finite(x) and (
    let v = (if real(x) < 0 then -real(x) else real(x)) in
    v >= 0x1p16 or (
      let step = (if c == "float8_e5m2" then (if v >= 0x1p-14 then ulp<f16>(v) * 256 else 0x1p-16)
                  else (if v >= 0x1p-6 then ulp<f16>(v) * 128 else 0x1p-9)) in
      let q = v / step in
      let n = count(i in range(1, 17): i <= q) in
      let k = n + (if q - n > 1/2 or (q - n == 1/2 and n % 2 == 1) then 1 else 0) in
      k * step > (if c == "float8_e5m2" then 57344 else 448)))
  ensures special:
    (is_nan(x) implies (if c == "float8_e5m2" then result % 128 > 0x7c else result % 128 == 0x7f) and
      (result >= 128) == signbit(x)) and
    (is_inf(x) implies result == (if signbit(x) then 0xfc else 0x7c)) and
    (is_zero(x) implies result == (if signbit(x) then 0x80 else 0))
  relates rounded: is_finite(x) and not is_zero(x) and real(x) < 0x1p16 and real(x) > -0x1p16 implies (
    let v = (if real(x) < 0 then -real(x) else real(x)) in
    let step = (if c == "float8_e5m2" then (if v >= 0x1p-14 then ulp<f16>(v) * 256 else 0x1p-16)
                else (if v >= 0x1p-6 then ulp<f16>(v) * 128 else 0x1p-9)) in
    let q = v / step in
    let n = count(i in range(1, 17): i <= q) in
    let k = n + (if q - n > 1/2 or (q - n == 1/2 and n % 2 == 1) then 1 else 0) in
    let d = float8_decode(c, result) in
    not is_nan(d) and signbit(d) == signbit(x) and real(d) == (if signbit(x) then -(k * step) else k * step))

record FloatSets { total: int, sign_clear: int, sign_set: int, zeros: int, positive: int, negative: int, nonnegative: int, subnormal: int, infinities: int, nan: int, finite: int }

# The sizes of the named sets (total is all): with M mantissa bits, subnormal has 2 * (2**M - 1)
# members, a Float has 2 infinities and 2 * (2**M - 1) NaNs, a FloatFN none and 2; finite is all
# minus both; positive and negative split the rest but the zeros; nonnegative adds the zeros.
fn float_set_sizes(c: FloatCodec) -> FloatSets
  ensures counts:
    let total = (if c == "float64" then 0x10000000000000000 else if c == "float32" then 0x100000000
                 else if c == "float16" or c == "bfloat16" then 0x10000 else 0x100) in
    let man = (if c == "float64" then 0x10000000000000 else if c == "float32" then 0x800000
               else if c == "float16" then 0x400 else if c == "bfloat16" then 0x80
               else if c == "float8_e5m2" then 4 else 8) in
    let n_inf = (if c == "float8_e4m3fn" then 0 else 2) in
    let n_nan = (if c == "float8_e4m3fn" then 2 else 2 * (man - 1)) in
    result.total == total and result.sign_clear == total // 2 and result.sign_set == total // 2 and
    result.zeros == 2 and result.subnormal == 2 * (man - 1) and result.infinities == n_inf and
    result.nan == n_nan and result.finite == total - n_inf - n_nan
  ensures signs:
    let total = (if c == "float64" then 0x10000000000000000 else if c == "float32" then 0x100000000
                 else if c == "float16" or c == "bfloat16" then 0x10000 else 0x100) in
    let man = (if c == "float64" then 0x10000000000000 else if c == "float32" then 0x800000
               else if c == "float16" then 0x400 else if c == "bfloat16" then 0x80
               else if c == "float8_e5m2" then 4 else 8) in
    let n_nan = (if c == "float8_e4m3fn" then 2 else 2 * (man - 1)) in
    result.positive == (total - n_nan - 2) // 2 and result.negative == result.positive and
    result.nonnegative == result.positive + 2
  ensures documented: c == "float16" implies result.total == 65536 and result.nan == 2046 and
    result.subnormal == 2046 and result.finite == 63488 and result.positive == 31744 and result.nonnegative == 31746

record FloatClasses { sign_clear: bool, sign_set: bool, zeros: bool, positive: bool, negative: bool, nonnegative: bool, subnormal: bool, infinities: bool, nan: bool, finite: bool }

# Whether encoding b is in each named set: positive and negative include the infinities, neither
# holds zeros or NaN, nonnegative includes -0.0, subnormal has a zero exponent and nonzero mantissa.
# finite, infinities and nan partition all, and so do positive, negative, zeros and nan.
fn float_classes(c: FloatCodec, b: u64) -> FloatClasses
  requires b < (if c == "float64" then 0x10000000000000000 else if c == "float32" then 0x100000000
                else if c == "float16" or c == "bfloat16" then 0x10000 else 0x100)
  partition b
    byte = u64.range(0, 0x100)
    half = u64.range(0x100, 0x10000)
    word = u64.range(0x10000, 0x100000000)
    wide = u64.range(0x100000000, none)
  ensures named:
    let sign = (if c == "float64" then 0x8000000000000000 else if c == "float32" then 0x80000000
                else if c == "float16" or c == "bfloat16" then 0x8000 else 0x80) in
    let inf = (if c == "float64" then 0x7ff0000000000000 else if c == "float32" then 0x7f800000
               else if c == "float16" then 0x7c00 else if c == "bfloat16" then 0x7f80 else 0x7c) in
    let man = (if c == "float64" then 0x10000000000000 else if c == "float32" then 0x800000
               else if c == "float16" then 0x400 else if c == "bfloat16" then 0x80
               else if c == "float8_e5m2" then 4 else 8) in
    let mag = b % sign in
    let s = b >= sign in
    let n = (if c == "float8_e4m3fn" then mag == 0x7f else mag > inf) in
    let i = c != "float8_e4m3fn" and mag == inf in
    let z = mag == 0 in
    result.sign_clear == (not s) and result.sign_set == s and result.zeros == z and result.nan == n and
    result.infinities == i and result.finite == (not n and not i) and
    result.subnormal == (mag > 0 and mag < man) and
    result.positive == (not s and not z and not n) and result.negative == (s and not z and not n) and
    result.nonnegative == ((not s and not n) or z)
  ensures partitions:
    count(p in [result.finite, result.infinities, result.nan]: p) == 1 and
    count(p in [result.positive, result.negative, result.zeros, result.nan]: p) == 1

# list(float16.set(xs)) iterates in encoding order: +0.0 up to +inf, the sign-clear NaNs, then -0.0
# down to -inf and the sign-set NaNs.
fn f16_set_order(xs: list<f16>) -> list<f16>
  ensures order: is_sorted(map(v in result: if is_nan(v) then (if signbit(v) then 0x10000 else 0x7c01) else bits(v)))
  ensures members: all(x in xs: is_nan(x) or exists(v in result: same(v, x))) and
    all(v in result: is_nan(v) or exists(x in xs: same(x, v)))

# x in float16.range(start, stop): the non-NaN values with start <= v < stop, -0.0 counting as
# just below 0.0; None leaves an end open (with its infinity); bounds need not be representable;
# a NaN bound raises ValueError.
fn f16_range_has(start: option<f32>, stop: option<f32>, x: f16) -> bool
  partition x
    nan = f16.nan
    inf = f16.inf
    zero = f16.zero
    subnormal = f16.subnormal
    normal = f16.normal
  raises ValueError when (is_some(start) and is_nan(unwrap(start))) or (is_some(stop) and is_nan(unwrap(stop)))
  ensures member: result == (not is_nan(x) and
    (is_none(start) or (let s = unwrap(start) in
      real(x) > real(s) or (real(x) == real(s) and not (is_zero(x) and signbit(x) and not signbit(s))))) and
    (is_none(stop) or (let t = unwrap(stop) in
      real(x) < real(t) or (real(x) == real(t) and is_zero(x) and signbit(x) and not signbit(t)))))

# c.range(start, stop).size: 2**M for [1, 2), all minus the NaNs with no bounds (for FloatFN too,
# whose range starts at min); observed: float16.range(1e10) is {inf} and
# float16.range(-1e10, -65504.0) is empty.
fn float_range_size(c: FloatCodec, start: option<f64>, stop: option<f64>) -> int
  raises ValueError when (is_some(start) and is_nan(unwrap(start))) or (is_some(stop) and is_nan(unwrap(stop)))
  ensures bounded:
    let total = (if c == "float64" then 0x10000000000000000 else if c == "float32" then 0x100000000
                 else if c == "float16" or c == "bfloat16" then 0x10000 else 0x100) in
    let man = (if c == "float64" then 0x10000000000000 else if c == "float32" then 0x800000
               else if c == "float16" then 0x400 else if c == "bfloat16" then 0x80
               else if c == "float8_e5m2" then 4 else 8) in
    let n_nan = (if c == "float8_e4m3fn" then 2 else 2 * (man - 1)) in
    result >= 0 and result <= total - n_nan and (is_none(start) and is_none(stop) implies result == total - n_nan)
  ensures unit_binade: is_some(start) and is_some(stop) and not is_nan(unwrap(start)) and not is_nan(unwrap(stop)) and
    real(unwrap(start)) == 1 and real(unwrap(stop)) == 2 implies
    result == (if c == "float64" then 0x10000000000000 else if c == "float32" then 0x800000
               else if c == "float16" then 0x400 else if c == "bfloat16" then 0x80
               else if c == "float8_e5m2" then 4 else 8)
  ensures documented: c == "float16" implies
    (is_some(start) and is_none(stop) and not is_nan(unwrap(start)) and real(unwrap(start)) == 1e10 implies result == 1) and
    (is_some(start) and is_some(stop) and not is_nan(unwrap(start)) and not is_nan(unwrap(stop)) and
      real(unwrap(start)) == -1e10 and real(unwrap(stop)) == -65504 implies result == 0)

# (s[0], s[-1]) of float16.range(start, stop), None when empty: still in encoding order, so
# float16.range(-1.0, 1.0) starts with 0.0 and ends with -1.0.
fn f16_range_ends(start: option<f64>, stop: option<f64>) -> option<(f16, f16)>
  raises ValueError when (is_some(start) and is_nan(unwrap(start))) or (is_some(stop) and is_nan(unwrap(stop)))
  ensures within: is_some(result) implies all(x in [unwrap(result).0, unwrap(result).1]: not is_nan(x) and
    (is_none(start) or (let s = unwrap(start) in
      real(x) > real(s) or (real(x) == real(s) and not (is_zero(x) and signbit(x) and not signbit(s))))) and
    (is_none(stop) or (let t = unwrap(stop) in
      real(x) < real(t) or (real(x) == real(t) and is_zero(x) and signbit(x) and not signbit(t)))))
  ensures documented: is_some(start) and is_some(stop) and not is_nan(unwrap(start)) and not is_nan(unwrap(stop)) and
    real(unwrap(start)) == -1 and real(unwrap(stop)) == 1 implies
    is_some(result) and bits(unwrap(result).0) == 0 and not is_nan(unwrap(result).1) and real(unwrap(result).1) == -1

# FloatFN(width, "custom", exponent).dtype(): FLOAT8_E4M3FN only for width 8 and exponent 4.
fn floatfn_dtype(width: u8, exponent: u8) -> (int, int)
  requires width >= 2 and width <= 64 and exponent >= 1 and exponent <= width - 2
  partition width
    byte = {8}
    other = u8.range(2, 8) | u8.range(9, 65)
  ensures dtype: result == (if width == 8 and exponent == 4 then (10, 8)
    else (1, if width <= 8 then 8 else if width <= 16 then 16 else if width <= 32 then 32 else 64))
