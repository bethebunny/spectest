# bitpattern 0.3.0: informal API specification

bitpattern provides immutable sets of fixed-width values (integers, floats, characters,
addresses, dates, UUIDs, enums, tuples) that can be far too large to list. Every set is
stored as the set of the non-negative integer *encodings* of its values.

This document says what a caller can rely on. Statements marked **observed** come from
experiments on 0.3.0, not from documentation; treat them as current behaviour that is
likely but not promised. Exception *types* are part of the contract; message text is
not, unless quoted as a rule.

## 0. Conventions

- **Width** `w` is a number of bits, `w >= 0`. The *universe* of width `w` is
  `[0, 2**w)`.
- Bit 0 is the least significant. Patterns and bit strings are written most
  significant bit first.
- "Encoding order" is ascending order of encodings. It is the iteration and index
  order of every set in the library. It is not always the order of the values.
- All sets are immutable and hashable. Operations return new sets.
- Sizes are exact Python ints of any magnitude (`2**128` and more).

### Public surface

| Module | Public names |
| --- | --- |
| `bitpattern` | `BDD`, `BDDSet`, `Codec`, `IntSet`, `OrderedCodec`, `Pattern`, `__version__` |
| `bitpattern.bdd` | `BDD`, `__version__`, and the functions in section 4 |
| `bitpattern.codecs` | `Codec`, `OrderedCodec`, `BDDSet`, `Tuple`, `product`, `project`, `DType`, `Int` and `int8` `int16` `int32` `int64` `int128` `uint8` `uint16` `uint32` `uint64` `uint128`, `Float`, `FloatFN` and `float16` `bfloat16` `float32` `float64` `float8_e5m2` `float8_e4m3fn`, `Char` and `char`, `IP` and `ipv4` `ipv6`, `MAC` and `mac`, `Date` `DateTime` and `dates` `datetimes` `naive_datetimes`, `UUIDCodec` and `uuid128`, `Members`, `Flags` |
| `bitpattern.dlpack` | `DType` (also the `__dlpack__` protocol on sets, section 6) |
| `bitpattern.strategies` | `from_set` (needs an optional extra, section 5) |

The names exported from `bitpattern` are the same objects as in their home modules
(for example `bitpattern.BDDSet is bitpattern.codecs.BDDSet`).
`bitpattern.__version__ == "0.3.0"`.

---

## 1. `IntSet`

`IntSet` is an immutable set of non-negative integers, all below `2**width`. It is a
`collections.abc.Set` and a `collections.abc.Sequence` of its members in ascending
order. Its abstract value is the set of members. `width` is extra data that affects
`~`, the width of results and export, but **not** equality.

Attributes: `width: int` and `bdd: BDD` (the diagram, section 4). Callers must not
assign to them. Assignment is not blocked (**observed**), and what happens afterwards
is unspecified. Setting any other attribute raises `AttributeError`.

### Construction

- `IntSet(iterable=(), *, width=0)`: the set of the given integers. Duplicates and
  order do not matter. Each item must be an `int` (including `bool`) or support
  `__index__` (numpy integers work, **observed**). Otherwise `TypeError` (floats,
  strings). Any negative item raises `ValueError`. The result's width is
  `max(width, largest.bit_length())`, so a `width` that is too small is widened, not
  an error (**observed**). A negative `width` acts as 0 (**observed**).
  - `IntSet()` -> empty, width 0. `IntSet([0])` -> `{0}`, width 0.
    `IntSet([5, 1, 3])` -> width 3. `IntSet([300], width=2).width == 9`.
- `IntSet.range(start, stop, *, width=None)`: the integers in `[start, stop)` that
  also lie in the universe. `start < 0` raises `ValueError`. When `width` is `None` it
  is `max(stop - 1, 0).bit_length()`. If `stop <= start` the set is empty. An explicit
  `width` clips the range: `IntSet.range(3, 17, width=3)` -> `{3..7}`. Non-int bounds
  raise `TypeError` and a negative explicit width raises `ValueError` (**observed**).
  - `IntSet.range(0, 0).width == 0`, `IntSet.range(0, 2).width == 1`,
    `IntSet.range(5, 3)` is empty with width 2,
    `IntSet.range(0, 2**100, width=128).size == 2**100`.
- `IntSet.from_bdd(bdd, width)`: wraps a diagram. The set is the values below
  `2**width` that the diagram accepts. Raises `ValueError` if the diagram tests a bit
  `>= width`, that is if `bdd.bit >= width`. Leaves have `bit == -1`, so they need
  `width >= 0`. Called on a subclass, it returns that subclass.

### Size, membership, order

- `s.size`: the exact member count, of any size.
- `len(s) == s.size`, but `len` raises `OverflowError` once the size is `>= 2**63`
  (**observed** for `2**64`). Prefer `size`.
- `bool(s)` is `s.size > 0`.
- `x in s` is `True` only when `x` is an `int` (or `bool`) and a member. It never
  raises. Negative ints, ints too wide for the set, and every non-int give `False`. In
  particular `1.0 in IntSet([1])` is `False`, unlike a built-in `set`.
- `iter(s)` is strictly ascending. `reversed(s)` is strictly descending. Both work at
  any size (for example `next(reversed(...))` on a `2**64`-member set).
- `s[i]` is the `i`-th smallest member. A negative `i` counts from the end. Raises
  `IndexError` when `i` is outside `[-size, size)`, and `TypeError` for an index that
  is not an integer (`bool` counts as an integer). Works for `i` far past `2**63`.
- `s[a:b:c]` is the set of members at positions `range(size)[a:b:c]`. Because the
  result is a set, a negative step does not reverse it: `IntSet(range(10))[::-1]` is
  the whole set. The result has the same type and width as `s` (**observed**).
  `IntSet(range(10))[2:5]` -> `IntSet([2, 3, 4], width=4)`.
- `s.index(value, start=0, stop=None)`: the position of `value`. Raises `ValueError`
  when `value` is not a member (any type) or its position is outside
  `range(size)[start:stop]`.
- `s.count(value)`: `1` if `value in s`, else `0`.
- `s.choice(*, rng=None)`: a uniformly random member, using `rng` (a
  `random.Random`) or the `random` module when `rng` is omitted. Raises `IndexError`
  on an empty set. Two rngs seeded the same give the same result (**observed**).
- `s.widened(width)`: the same members at width `max(s.width, width)`, with the same
  type.

### Set algebra

`a & b`, `a | b`, `a - b` and `a ^ b` accept any iterable of ints on the right. A
non-`IntSet` operand is first converted as `IntSet(other)` and raises as the
constructor does (`ValueError` for negatives, `TypeError` for non-ints). A
non-iterable raises `TypeError`. The result's width is the larger of the two widths.
The result has the type of the left operand when it is an `IntSet` (so `Pattern &
IntSet` is a `Pattern` and `IntSet & Pattern` is an `IntSet`). Built-in iterables also
work on the left: `{7} | s`, `[7] & s` and `{7} ^ s` give `type(s)`, while
`{7, 1} - s` gives a plain `IntSet`.

`~s` is the complement within `s`'s own universe, with the same width and type:
`~IntSet([1, 3], width=2)` -> `IntSet([0, 2], width=2)`. `~IntSet()` ->
`IntSet([0], width=0)`.

Comparisons `<=`, `<`, `>=` and `>` mean subset and superset. They ignore width and
accept only `IntSet` operands. Anything else raises `TypeError`, including built-in
sets.

`a == b` is true exactly when both are `IntSet`s with the same members, whatever their
widths: `IntSet([1], width=1) == IntSet([1], width=8)`, and
`IntSet() == IntSet(width=9)`. An `IntSet` is never equal to a non-`IntSet` (`{1}`,
`frozenset`, list), and that comparison returns `False` without raising. Equal sets
have equal hashes, across widths and across `Pattern`/`IntSet`.

`s.isdisjoint(iterable)` takes any iterable of ints.

**Laws** (any `IntSet`s `a`, `b`, `c`, any int `x`):
- `x in a | b` iff `x in a or x in b`. Likewise `&` is "and", `-` is "and not" and `^`
  is "exactly one".
- `(a op b).width == max(a.width, b.width)` for `op` in `& | - ^`.
- `~~a == a`. `(~a).width == a.width`. `a & ~a` is empty. `(a | ~a).size == 2**a.width`.
- `(a | b).size + (a & b).size == a.size + b.size`.
- `a <= b` iff `a - b` is empty iff `a & b == a`. `a < b` iff `a <= b and a != b`.
- `&`, `|` and `^` are commutative and associative, and `&` distributes over `|`. The
  usual De Morgan laws hold at a common width.
- `list(a)` is sorted with no repeats and has length `a.size`. `a[i] == list(a)[i]` and
  `a.index(a[i]) == i`.
- `IntSet(list(a), width=a.width) == a`, with the same width.
- `IntSet.range(lo, hi).size == max(0, hi - lo)` for `lo >= 0`.

### repr

- With at most 10 members: `IntSet([m1, m2, ...], width=W)`, ascending.
- With more: the first four and the last two, then the size:
  `IntSet([0, 1, 2, 3, ..., 18, 19], size=20, width=5)`.
- Sizes in a repr use `count_repr` (section 4): decimal, except that an exact power of
  two `2**k` with `k >= 10` is written `2**k`, as in
  `IntSet([0, 1, 2, 3, ..., 18446744073709551614, 18446744073709551615], size=2**64, width=64)`.
- A member too long for Python's decimal conversion limit is written in hex
  (**observed**: `IntSet([2**20000])` reprs as `IntSet([0x1000...`).

---

## 2. `Pattern`

`Pattern` is an `IntSet` subclass written as a bit pattern. Everything in section 1
applies.

### Syntax: `Pattern(text)`

- Surrounding whitespace is stripped (**observed**). The text is split on `.` into
  quartets, most significant first.
- A quartet holds the characters `0` (bit clear), `1` (bit set) and `?` (either), and
  at most one `*`. A `*` expands to however many `?` bring that quartet to 4
  characters: `*` -> `????`, `1*` -> `1???`, `*1` -> `???1`, `1*1` -> `1??1`.
- After expansion every quartet but the first has exactly 4 bits. The first has 1 to 4
  bits, and exactly 4 if it uses `*`.
- `width` is the total number of bits. The members are the ints below `2**width` whose
  bits match. `size == 2**(number of ?)`.
- Raises `ValueError` for: any `|` (the message suggests `Pattern(a) | Pattern(b)`);
  empty text or an empty quartet (`""`, `".1111"`, `"1111."`); an over-long quartet
  (`"11111"`); a short quartet that is not the first (`"1.1"`); two `*` in one quartet;
  or any other character.

Examples: `Pattern("*1.0000")` -> width 8, size 8, repr `Pattern('???1.0000')`.
`Pattern("*1.*.*.0000.1111.?01?").size == 8192` (width 24).
`Pattern("1.*")` -> `Pattern('1.????')`.

### Members

- `p.branches`: a tuple of single-branch pattern strings in dotted form. They are
  pairwise disjoint and their union is `p`. They are ordered by smallest member
  (**observed**) and depend only on the set and the width (**observed**). The empty
  pattern has `()`.
  `(Pattern("1?1") | Pattern("?1?")).branches == ('01?', '101', '11?')`.
- `p.bits`: the expanded bits (no dots) of a single-branch pattern:
  `Pattern("1?1").bits == "1?1"`. Raises `ValueError` ("pattern has N branches, not 1")
  when there are 0 or several branches.
- `p.free`: the number of `?` in `p.bits`. Raises as `bits` does.
- `str(p)` is `" | ".join(p.branches)`. It is `""` when `p` is empty.
- `repr(p)`:
  - width 0: `<Pattern: width=0, size=N>`
  - empty: `~Pattern('<all-? dotted>')`, for example `~Pattern('????')`
  - 1 to 8 branches, when the joined text is at most 200 characters:
    `Pattern('01?') | Pattern('101') | Pattern('11?')`
  - otherwise: `<Pattern: K branches, width=W, size=S>`
- In the third case `eval(repr(p))` equals `p` and has the same width (**observed**).
- Results stay `Pattern`s when the left operand is a `Pattern` (and for `~p`, slices
  and `widened`). The dotted form uses the new width:
  `Pattern("1?1").widened(5)` -> `Pattern('0.01?1')`.
  `Pattern("0000") | Pattern("0001")` -> `Pattern('000?')`.
  `~Pattern("00??")` -> `Pattern('01??') | Pattern('1???')`.
- Equality ignores width: `Pattern("0?1") == Pattern("?1") == IntSet([1, 3])`.

---

## 3. Codecs and `BDDSet` (`bitpattern.codecs`)

### 3.1 `Codec[T]`

A `Codec` is a frozen dataclass with fields `width: int` and `name: str`
(subclasses add fields). It encodes values of type `T` as ints in `[0, 2**width)`.
`repr(codec)` is its `name`. Codecs compare and hash by class and field values: two
separately built codecs with the same class and fields are equal, and their sets
combine (**observed**). Codecs of different classes are never equal. Assigning a field
raises `dataclasses.FrozenInstanceError`. Built-in codecs and their sets survive a
pickle round trip (**observed**).

- `encode(value) -> int`: raises `TypeError` for a value of the wrong type and
  `ValueError` for a value of the right type that the codec cannot represent. The base
  class raises `NotImplementedError`.
- `decode(bits) -> T`: the value with that encoding. It may raise `IndexError` for
  bits outside `all`, but it is not required to check. Codecs that do check are noted
  below.
- `dtype() -> DType`: how sets export (section 6). The default is the narrowest
  unsigned type: `UINT8` for `w <= 8`, `UINT16` for `w <= 16`, `UINT32` for
  `w <= 32`, `UINT64` for `w <= 64`, and `UINT8` rows of bytes above 64 bits.
- `all`: the set of every legal encoding. The default is the full universe. Codecs
  with illegal encodings narrow it. Repeated access returns an equal set.
- `none`: the empty set.
- `set(values=())`: the set of the given values. Each value goes through `encode` and
  raises as it does.
- `pattern(text)`: the values whose encodings match `Pattern(text)`, intersected with
  `all`. Raises `ValueError` when the pattern's width differs from the codec's
  ("pattern is N bits, not W"), plus any `ValueError` from `Pattern`.

Laws for every codec `c` below, unless an exception is listed:
- For each value `v` that `c.encode` accepts, `0 <= c.encode(v) < 2**c.width`.
- For each `b` in `c.all.storage`, `c.encode(c.decode(b)) == b`, and so
  `c.decode(c.encode(v)) == v` for each decoded value `v`.
- `encode` may also accept inputs that are not themselves decoded values and normalise
  them: floats it rounds, address and UUID strings, upper-case MACs, aware datetimes
  from other zones. For these `c.decode(c.encode(v))` is the canonical value, not `v`.
- NaN is the one listed exception (section 3.5).

### 3.2 `OrderedCodec[T]`

An `OrderedCodec` is a codec whose values are ordered. It adds:

- `min` and `max`: the smallest and largest value.
- `range(start=None, stop=None)`: the values in `[start, stop)`. `None` leaves that
  end unbounded. The result is always a subset of `all`.

By default `min == all[0]`, `max == all[-1]`, and `range` encodes both bounds, so a
bound that `encode` rejects raises as `encode` does. `Int` and `Float` override all
three (see below).

### 3.3 `BDDSet[T]`

A `BDDSet` is an immutable, frozen-dataclass set of one codec's values. It is a
`collections.abc.Set` and `Sequence`, ordered by encoding.

- `BDDSet(codec, storage)`: `storage` is an `IntSet` of encodings. Raises `ValueError`
  unless `storage.width == codec.width`. The fields `codec` and `storage` are
  read-only. Building one directly with encodings outside `codec.all` is unspecified.
- `size`, `len`, `bool`, `choice(*, rng=None)` (`IndexError` when empty), `s[i]`
  (`IndexError` when out of range), `s[slice]` (a `BDDSet`), `iter` and `reversed`
  behave as for `IntSet`, with decoded values in encoding order.
- `v in s`: `True` iff `codec.encode(v)` succeeds and the encoding is in `storage`. A
  `TypeError` or `ValueError` from `encode` gives `False`. So `"10.1.2.3"` can be
  tested against an `ipv4` set, and `1.0 in uint8.all` is `False`.
- `index(value, start=0, stop=None)`: raises `ValueError` when the value is not a
  member, has the wrong type, or cannot be encoded. `count(value)` returns 0 or 1.
- `&`, `|`, `-` and `^` (with their reflected forms), and `<=`, `<`, `>=`, `>` and
  `isdisjoint`, accept only a `BDDSet` whose codec equals this one. Anything else
  raises `TypeError` ("<codec> sets only combine with each other"). That includes
  built-in sets on either side, lists given to `isdisjoint`, `IntSet`s, and sets of
  another codec, even one of the same width.
- `~s == s.codec.all - s`: complement within the legal values, not the whole universe.
- `a == b` is true iff both are `BDDSet`s with equal codecs and the same encodings. It
  never raises. A set is never equal to a set of another codec (`uint8.set([1]) !=
  int8.set([1])`), to a built-in set or to an `IntSet`. Equal sets hash equal.
- `a * b == product(a, b)` (section 3.12). A right operand that is not a `BDDSet`
  raises `TypeError`.
- `repr`: `BDDSet(<codec name>, [v1, v2, ...])` with at most 10 values. With more:
  `BDDSet(uint8, [0, 1, 2, 3, ..., 254, 255], size=256)`, which shows the first four
  and last two in encoding order and formats the size as in `IntSet`.

### 3.4 `Int` and `int8` ... `uint128`

`Int(width, name, signed)` (an `OrderedCodec[int]`) encodes fixed-width integers in two's
complement.

| codec | width | signed | min | max | dtype |
| --- | --- | --- | --- | --- | --- |
| `int8` `int16` `int32` `int64` | 8/16/32/64 | yes | `-2**(w-1)` | `2**(w-1)-1` | `INT8`/`INT16`/`INT32`/`INT64` |
| `int128` | 128 | yes | `-2**127` | `2**127-1` | `UINT8` rows |
| `uint8` `uint16` `uint32` `uint64` | 8/16/32/64 | no | 0 | `2**w-1` | `UINT8`/.../`UINT64` |
| `uint128` | 128 | no | 0 | `2**128-1` | `UINT8` rows |

A custom signed `Int` up to 64 bits exports as the narrowest signed type that fits
(`Int(5, "i5", signed=True)`: min -16, max 15, dtype `INT8`). Any other `Int` uses the
unsigned default. The name is the variable name.

- `encode(v)`: `v` must be an `int` (`bool` included) or support `__index__`, or
  `TypeError` is raised (floats and strings are rejected). Values outside `[min, max]`
  raise `ValueError`. Returns `v mod 2**width`: `int8.encode(-1) == 255`.
- `decode(b)`: `b - 2**width` if `b > max`, else `b`. `int8.decode(128) == -128`. It
  does no range check, and its result for `b` outside the universe is unspecified.
- `all` is the full universe. Iteration is in encoding order, so a signed set runs
  from 0 up to `max`, then from `min` up to -1:
  `list(int8.set([-1, 0, 1, -128, 127])) == [0, 1, 127, -128, -1]`. For a signed
  codec, `s[0]` and `s[-1]` are not the extremes.
- `range(start=None, stop=None)`: the integers in `[start, stop)`. Bounds are clamped
  to `[min, max + 1]` rather than encoded, so `int8.range(-200, 200) == int8.all`.
  `int8.range(5, 3)` is empty. Non-int bounds raise `TypeError` (**observed**).

### 3.5 `Float`, `FloatFN` and the float codecs

`Float(width, name, exponent, format)` (an `OrderedCodec[float]`) is an IEEE 754 binary
format laid out as sign :: exponent :: mantissa, with `mantissa == width - 1 -
exponent`. `format` is a `struct` format string used for packing. `FloatFN` is the
variant with no infinities. The encoding is the format's own raw bits.

| codec | class | width | exponent | mantissa | max | dtype |
| --- | --- | --- | --- | --- | --- | --- |
| `float64` | Float | 64 | 11 | 52 | 1.7976931348623157e308 | `FLOAT64` |
| `float32` | Float | 32 | 8 | 23 | 3.4028234663852886e38 | `FLOAT32` |
| `float16` | Float | 16 | 5 | 10 | 65504.0 | `FLOAT16` |
| `bfloat16` | Float | 16 | 8 | 7 | 3.3895313892515355e38 | `BFLOAT16` |
| `float8_e5m2` | Float | 8 | 5 | 2 | 57344.0 | `FLOAT8_E5M2` |
| `float8_e4m3fn` | FloatFN | 8 | 4 | 3 | 448.0 | `FLOAT8_E4M3FN` |

`min == -max` for each of them. `min` and `max` are the most negative and largest
*finite* values. A custom format that matches none of these dtypes exports with the
unsigned default.

**encode(v)**
- Accepts `float`, `int` (and `bool`) and other real numbers that convert to float
  (**observed**: `Fraction`, `Decimal`, numpy scalars). Strings, `None` and similar
  raise `TypeError`. An int too large for a double raises `ValueError`.
- Rounds to the nearest representable value, ties to even:
  `float16.decode(float16.encode(1 + 2**-11)) == 1.0` and
  `float16.decode(float16.encode(1 + 3 * 2**-11)) == 1.001953125`. Tiny values round
  to a subnormal or to a zero of the same sign (**observed**:
  `float16.encode(-1e-10) == 0x8000`).
- A finite value that rounds beyond `max` raises `ValueError`. **Observed**:
  `float16.encode(65520.0)` raises while `65504.0` encodes, and `float8_e4m3fn`
  encodes `464.0` (a tie) as 448.0 but raises on `465.0`. `inf` and `-inf` encode as the matching
  infinity where the format has one. `FloatFN` raises `ValueError` on infinities.
- `0.0` encodes to `0` and `-0.0` to the sign bit alone. NaN encodes to a NaN with
  the input's sign (**observed**: `float16` gives `0x7e00`/`0xfe00`, and
  `float8_e4m3fn` gives `0x7f`/`0xff`).

**decode(b)** returns a Python float. `Float` raises `IndexError` for `b < 0` or
`b >= 2**width`. `FloatFN` does not check, so its result outside the universe is
unspecified.

**Round trips** (**observed**, exhaustive for the 8- and 16-bit formats, sampled for
float64): `decode(encode(v)) == v` for every non-NaN value of the format.
`encode(decode(b)) == b` for every non-NaN encoding. For a NaN encoding the result is
still in `nan` and keeps the sign, but the payload may change (float16, bfloat16,
float32 and float8_e5m2 quiet or canonicalise NaNs). float64 kept payloads in samples.

**Named sets** (attributes, each a `BDDSet`):
- `sign_clear` / `sign_set`: sign bit 0 / 1, with `2**(w-1)` encodings each.
- `zeros`: `{0.0, -0.0}`.
- `positive`: values `> 0`, **including** `+inf`. `negative`: values `< 0`, including
  `-inf`. Neither contains zeros or NaN.
- `nonnegative`: `positive | zeros`. It includes `-0.0`.
- `subnormal`: exponent all zeros and mantissa non-zero, both signs, so
  `2 * (2**mantissa - 1)` members.
- `infinities`: `{inf, -inf}`. It is empty for `FloatFN`.
- `nan`: every NaN encoding, all payloads and both signs.
- `finite`: `all - infinities - nan`.
- Laws: `finite`, `infinities` and `nan` partition `all`. `positive`, `negative`,
  `zeros` and `nan` partition `all`. `positive & negative` is empty.
- float16 sizes: all 65536, nan 2046, subnormal 2046, finite 63488, positive 31744,
  nonnegative 31746. For float8_e4m3fn, finite has 254 members and nan is
  `{0x7f, 0xff}`. For float8_e5m2, nan has 6 members.

**Iteration order** is encoding order: `+0.0` up to `+inf`, then the sign-clear NaNs,
then `-0.0` down to `-inf`, then the sign-set NaNs.

**range(start=None, stop=None)**: the non-NaN values `v` with `start <= v < stop` in
numeric order, where `-0.0` counts as just below `0.0`. A `start` of `None` includes
`-inf`. A `stop` of `None` includes `+inf`. The result never contains NaN. A NaN bound
raises `ValueError`. Bounds do not have to be representable or in range, since the
result is the representable values in that real interval (**observed** for the
out-of-range examples below). Int bounds are accepted.
- `float16.range(1.0, 2.0).size == 1024` (`2**mantissa`).
  `float32.range(1.0, 2.0).size == 2**23`.
- `float16.range() == float16.all - float16.nan`.
- `inf in float16.range(0.0, None)`, but `inf not in float16.range(0.0, math.inf)`.
- `float16.range(0.0)` excludes `-0.0`. `float16.range(-0.0)` includes both zeros.
  `float16.range(-0.0, 0.0)` is `{-0.0}`. `float16.range(None, 0.0)` contains `-0.0`.
- `list(float16.range(1.00001, 1.002)) == [1.0009765625, 1.001953125]`.
- **Observed**: `float16.range(1e10)` is `{inf}` and `float16.range(-1e10, -65504.0)`
  is empty.
- The result still iterates in encoding order:
  `float16.range(-1.0, 1.0)[0] == 0.0` and `[-1] == -1.0`.

**FloatFN** (`FloatFN(width, name, exponent)`) has no infinities. Only the patterns
with every exponent and mantissa bit set are NaN, one per sign. Other patterns with an
all-ones exponent are normal numbers (`float8_e4m3fn.decode(0x7e) == 448.0`). A range
with no lower bound starts at `min`. The dtype is `FLOAT8_E4M3FN` only when width is 8
and exponent is 4. Every other `FloatFN` uses the unsigned default.
**Observed**: `list(float8_e4m3fn.range(1.0, 2.0)) == [1.0, 1.125, ..., 1.875]` (8
values) and `float8_e4m3fn.decode(float8_e4m3fn.encode(0.3)) == 0.3125`.

### 3.6 `Char` and `char`

`Char(width, name)` (an `OrderedCodec[str]`) encodes one-character strings as their
code points. `char = Char(21, "char")`.

- `encode(s)`: non-strings raise `TypeError`. Raises `ValueError` when `len(s) != 1`,
  when `s` is a surrogate (U+D800 to U+DFFF), or when the code point is
  `>= 2**width`.
- `decode(b)` is `chr(b)`, and raises `IndexError` above U+10FFFF. **Observed**: it does
  not reject surrogate code points.
- `all`: every code point from 0 to 0x10FFFF that is not a surrogate and fits the
  width. `char.all.size == 1112064`. `Char(7, "ascii").all` is `[0, 128)`.
- `min == "\x00"`. `max == "\U0010ffff"` for `char`.
- `range(start, stop)`: code points in `[ord(start), ord(stop))`, without surrogates.
  The bounds must be encodable (`char.range("a", "ab")` raises `ValueError`).
  `char.range("\ud7ff", "\ue001")` -> `['\ud7ff', '\ue000']` (the surrogates between are skipped).
- `category(name)`: the characters in a Unicode general category (`"Lu"`) or major
  class (`"L"`), from the running Python's `unicodedata`, restricted to `all`. Names
  are case-sensitive and an unknown name raises `ValueError` (`"lu"`, `"Xx"`).
  `category("Cs")` is empty. `category("L") >= category("Lu")`.
  `"".join(char.category("Sm") & char.range("\0", "\x80")) == "+<=>|~"`. The first
  call can take a moment.

### 3.7 `IP`, `ipv4` and `ipv6`

`IP(width, name, address_type, network_type)` (an `OrderedCodec`).
`ipv4 = IP(32, "ipv4", IPv4Address, IPv4Network)` and `ipv6 = IP(128, "ipv6", ...)`.
Values decode to the family's address class.

- `encode(v)` accepts an address of the family's own class, a `str` or an `int`, and
  returns `int(address)`. Other types raise `TypeError`: floats, bytes, and the other
  family's addresses. Malformed strings, strings with a `/`, out-of-range ints, and
  interface objects carrying a prefix raise `ValueError` (from `ipaddress`, for example
  `AddressValueError`, a `ValueError` subclass).
- `decode(b)` raises `IndexError` outside `[0, 2**width)`. `ipv6.decode(1)` is
  `IPv6Address('::1')`, never an IPv4 address.
- `min`/`max`: `0.0.0.0` and `255.255.255.255`, and `::` and `ffff:...:ffff`.
- `range(start=None, stop=None)`: bounds may be addresses, strings, ints or `None`.
- `cidr(network)`: every address of the block, given as a network object or string.
  Host bits are allowed and ignored: `ipv4.cidr("10.1.2.3/8")[0] ==
  IPv4Address("10.0.0.0")`. A bare address is a single-address block. A bad prefix or
  address raises `ValueError`. `ipv4.cidr("0.0.0.0/0") == ipv4.all`.
- `networks(source)`: a **generator** of the fewest CIDR networks that exactly cover
  `source`, in ascending order. If `source.codec != self` it raises `TypeError`, but
  only when iteration starts. Laws: the networks are disjoint, their union is
  `source`, and the empty set gives none.
  `list(ipv4.networks(ipv4.range("10.0.0.1", "10.0.0.9")))` ->
  `[10.0.0.1/32, 10.0.0.2/31, 10.0.0.4/30, 10.0.0.8/32]`.
  `list(ipv4.networks(ipv4.all)) == [IPv4Network("0.0.0.0/0")]`.

### 3.8 `MAC` and `mac`

`MAC(width, name)` (an `OrderedCodec[str]`). `mac = MAC(48, "mac")`.

- `encode(s)`: non-strings raise `TypeError`. `s` must be exactly one of
  `01:23:45:67:89:ab`, `01-23-45-67-89-ab` or `0123.4567.89ab`. Hex digits may be
  either case. Mixed separators, bare hex, and surrounding whitespace or newlines
  raise `ValueError`.
- `decode(b)` is always lowercase and colon-separated, and raises `IndexError` outside
  48 bits. Set order matches the order of these strings.
- `multicast` and `unicast` (I/G bit, bit 0 of the first octet, set or clear), and
  `local` and `universal` (U/L bit, bit 1 of the first octet, set or clear), each hold
  `2**47` addresses. `broadcast == {"ff:ff:ff:ff:ff:ff"}`, which lies in
  `multicast & local`.
- `oui(prefix)`: the `2**24` addresses under a three-octet prefix written with `:` or
  `-` (either case). Any other form raises `ValueError` (`"001a.2b"`, `"00:1a"`).
  `mac.oui("00:1a:2b") == mac.range("00:1a:2b:00:00:00", "00:1a:2c:00:00:00")`.

### 3.9 `Date`, `DateTime`, `dates`, `datetimes` and `naive_datetimes`

`Date(width, name)` (an `OrderedCodec[date]`). `dates = Date(22, "dates")` encodes
`date.toordinal()`, so `date(1, 1, 1)` encodes to 1.
- `encode`: a `datetime.datetime` raises `TypeError` (it refuses to drop the time
  silently). Any other non-date also raises `TypeError`.
- `decode` raises `IndexError` for 0 and for anything past `date.max`.
- `all` is ordinals 1 to 3652059. `min == date(1, 1, 1)`, `max == date(9999, 12, 31)`.
- `dates.range(date(2024, 1, 1), date(2025, 1, 1)).size == 366`.

`DateTime(tz)` (an `OrderedCodec[datetime]`, where `tz` is a `tzinfo` or `None`) encodes
microseconds since 0001-01-01 00:00: UTC for aware codecs, wall time for the naive one.
The width is 59. The name is `"naive_datetimes"` when `tz` is `None`, else
`f"datetimes[{tz}]"` (for example `datetimes[UTC]`, `datetimes[UTC+05:00]`,
`datetimes[America/New_York]`). `datetimes = DateTime(datetime.UTC)` and
`naive_datetimes = DateTime(None)`. `DateTime(timezone.utc) == datetimes`.
- `encode`: non-datetimes (including plain dates) raise `TypeError`. An aware codec
  raises `ValueError` for naive input, and the naive codec raises `ValueError` for
  aware input. A datetime whose tzinfo gives a `None` offset counts as naive. Aware
  input from any zone is accepted and identified by instant, so 07:00-05:00 and 12:00
  UTC encode equal. An instant that cannot be represented in `tz` raises `ValueError`
  (`datetimes.encode(datetime(1, 1, 1, tzinfo=timezone(timedelta(hours=1))))`).
- `decode(b)` returns that instant in `tz` (a naive datetime for the naive codec) and
  raises `IndexError` past the end.
- `all` is every microsecond representable in `tz`. Instants at either end that would
  overflow `datetime` in `tz` are left out. `datetimes.all.size ==
  315537897600000000`. For a fixed `+01:00` zone the size is `3600 * 10**6` smaller
  and `min` is `0001-01-01 01:00+01:00` (**observed**).
- `datetimes.range(datetime(2024, 1, 1, tzinfo=UTC), datetime(2024, 1, 2, tzinfo=UTC)).size == 86_400_000_000`.
- Daylight saving (documented): local times that never occur are never produced by
  `decode`. Repeated local times decode, from distinct members, to datetimes with
  `fold=0` and `fold=1`, and these compare equal to each other. **Observed**: `encode`
  accepts a non-existent local time (2024-03-10 02:30 in New York) and maps it to an
  instant that decodes as 03:30. Round trips are therefore not guaranteed for such
  inputs.

### 3.10 `UUIDCodec` and `uuid128`

`UUIDCodec(width, name)` (an `OrderedCodec[UUID]`). `uuid128 = UUIDCodec(128, "uuid128")`
encodes `UUID.int`, so the order is Python's UUID order.
- `encode` accepts a `uuid.UUID`, or a string in any form `uuid.UUID()` parses
  (**observed**: with or without hyphens, braces, `urn:uuid:`). A malformed string
  raises `ValueError`. Other types, including `int` and `bytes`, raise `TypeError`.
- `decode` raises `IndexError` outside `[0, 2**128)`.
- `rfc9562`: the RFC 9562 variant, where the variant bits are `10` (hex digit N is
  8, 9, a or b). Size `2**126`.
- `version(n)`: the RFC 9562-variant UUIDs with version digit `n`, for `1 <= n <= 8`.
  Other `n` raise `ValueError`. Size `2**122`. `uuid.uuid4() in uuid128.version(4)`.
  Every member `u` has `u.version == n`.
- Patterns have one quartet per hex digit (32 quartets).

### 3.11 `Members` and `Flags`

These are plain `Codec`s: neither has `min`, `max` or `range`. Each codec's name is
the enum's `__name__`.

`Members(enum_cls)`: each member is encoded as its 0-based definition index. Aliases
are not separate members, and an alias encodes to its canonical member's index.
- `width == max(len(enum_cls) - 1, 0).bit_length()`, so 0 for an enum with 0 or 1
  members. `all` is the indices `[0, len)`. Sets iterate in definition order.
- `encode`: a value that is not an instance of the enum raises `TypeError`. That
  includes the member's raw value, and an `IntEnum`'s plain int. A `Flag` combination
  that is not a member raises `ValueError`.
- `decode(i)` raises `IndexError` past the last member.
- Sets export the indices, not the values, even for `IntEnum`.
- `~Members(Color).set([Color.GREEN])` -> `{RED, BLUE}`.

`Flags(flag_cls)`: a combination is encoded as its own integer value.
- `width` is the bit length of the largest member value, multi-bit members included.
- `all`: every value that is a union of members, including the empty value. Sets
  iterate in order of value. For `R=4, W=2, X=1` all 8 combinations are legal. For
  `LEAF=4, CHAIN=12, LOW=1`, `all` is `{0, 1, 4, 5, 12, 13}` (**observed**), since 8
  alone is not a union of members.
- `encode`: a non-instance raises `TypeError` (a plain int does too). An instance that
  is not a union of members raises `ValueError`.
- `decode(b)` returns `flag_cls(b)`, and raises `IndexError` when the class refuses
  the bits (for example a `STRICT` boundary).
- `having(flags)`: the members of `all` with every bit of `flags` set. `lacking(flags)`:
  those with none of them set. The argument goes through `encode`.
  `having(F(0)) == lacking(F(0)) == all`.
  `Flags(Perm).having(Perm.W) == Flags(Perm).pattern("?1?")`.

### 3.12 `Tuple`, `product` and `project`

`Tuple(*fields)` is a codec of tuples with one codec per field. Its `width` is the sum
of the field widths, and the first field takes the most significant bits. Its `name`
is `"tuple[f1, f2, ...]"`, and `fields` is the tuple of field codecs. `Tuple()` has
width 0 and `all == {()}`. It is a plain `Codec` with no `range`. Its dtype is the
unsigned default.
- `encode(v)`: non-tuples (lists included) raise `TypeError`. A tuple of the wrong
  length raises `ValueError`. Each item is encoded by its field, and that field's
  errors propagate.
- `decode` returns a tuple of decoded fields. `all == product(*(f.all for f in fields))`.
- Sets are ordered lexicographically by field encodings:
  `Tuple(uint8, int8).set([(2, 0), (1, 5), (1, -1)])` iterates
  `(1, 5), (1, -1), (2, 0)`.

`product(*sets)`: the `BDDSet` of all tuples `(a, b, ...)` with `a` in `sets[0]`, and
so on, with codec `Tuple(*(s.codec for s in sets))`. Its size is the product of the
sizes, it is empty if any set is empty, and `product()` is `{()}`. `a * b` is
`product(a, b)`, so `a * b * c` nests as `((x, y), z)`.
`product(ipv4.cidr("10.0.0.0/8"), uint16.range(1024, 65536)).size == 1082331758592`.
Membership takes tuples whose items each codec can encode:
`("10.1.2.3", 8080) in product(ipv4.all, uint16.all)`.

`project(source, index)`: the set of values at position `index` across the tuples in
`source`, as a `BDDSet` of that field's codec. A negative index counts from the end.
Raises `TypeError` when `source`'s codec is not a `Tuple`, and `IndexError` when
`index` is out of range. Laws: `project(product(A, B), 0) == A` when `B` is non-empty,
and `project(product(A, B), 1) == B` when `A` is non-empty. In general `source <=
product(project(source, 0), project(source, 1), ...)`, and the two need not be equal.

---

## 4. `bitpattern.bdd` (diagrams)

A `BDD` is a reduced, ordered binary decision diagram. Each node is a boolean function
on the bits of a non-negative integer. It tests bits from high to low, and bits it
never tests are unconstrained. A node does not record a width. Restricting it to a
universe is the caller's job.

### `BDD`

- `BDD.ACCEPT` (true for every value) and `BDD.REJECT` (true for none) are the leaves.
  Both have `bit == -1` and `leaf == True`.
- `BDD(bit, left, right)`: when bit `bit` of `x` is 0, follow `left`, otherwise
  `right`. Raises `ValueError` if `bit < 0` or a child is not a leaf and tests a bit
  `>= bit`. Raises `TypeError` for children that are not BDDs.
- Diagrams are canonical (**observed**): building the same function twice gives the
  identical object, and `BDD(b, x, x) is x`.
- Properties: `bit`, `left`, `right` (on a leaf, `left` and `right` return the leaf
  itself, **observed**), `leaf`, and `size`, the number of accepted values below
  `2**(bit + 1)` (`ACCEPT.size == 1`, `REJECT.size == 0`).
  `__match_args__ == ("bit", "left", "right")`.
- `bool(node)` is `False` only for `REJECT`. `==` and `hash` follow the function, and
  `==` against a non-BDD is `False`.
- `~`, `&`, `|`, `-` and `^` are pointwise boolean operations on functions. A non-BDD
  operand raises `TypeError`. `~BDD.ACCEPT is BDD.REJECT`.
- `copy.copy`, `copy.deepcopy` and a pickle round trip return the same object
  (**observed**).
- `repr`: `BDD.ACCEPT`, `BDD.REJECT`, or `<BDD bit=B, N nodes, S members>` (S is `size`
  formatted by `count_repr`).

### Functions

`width` is always keyword-only. The functions that take both a `node` and a `width`
(`count`, `nth`, `rank`, `members`, `blocks`, `paths`, `tensor`) raise `ValueError` when
`width < 0` or `node.bit >= width` (**observed** for each). `narrowed` and `interval`
raise only for `width < 0`. `exactly_these` treats a negative width as 0
(**observed**).

| function | result |
| --- | --- |
| `accepts(node, value)` | whether `value` satisfies the diagram. Untested bits are free, so `accepts(ACCEPT, 999)` is `True` |
| `count(node, *, width)` | the number of accepted values below `2**width` |
| `nth(node, n, *, width)` | the `n`-th accepted value below `2**width`, ascending. A negative `n` counts from the end. `IndexError` when out of range |
| `rank(node, value, *, width)` | the number of accepted values below `value`, which is a member's index (**observed**: values past the universe give the full count) |
| `members(node, *, width)` | an ascending iterator of accepted values below `2**width` |
| `blocks(node, *, width)` | an ascending iterator of `(start, free)` pairs. Each is an aligned block `[start, start + 2**free)`. The blocks are disjoint, cover the set exactly, and are as few as possible. `interval(3, 17, width=5)` -> `(3,0), (4,2), (8,3), (16,0)` |
| `paths(node, *, width)` | an iterator of width-length strings over `0 1 ?`, most significant first. The strings are disjoint and cover the set. `REJECT` gives none. `ACCEPT` at width 3 gives `"???"`, and at width 0 gives `""` |
| `path_count(node)` | the number of paths, equal to `len(list(paths(node, width=w)))` for any valid `w` |
| `node_count(node)` | the number of internal nodes. Leaves count 0. `node_count(diagram("1?0")) == 2` |
| `diagram(bits)` | the diagram for a pattern string over `0 1 ?`. With `len(bits) == L`, character `i` tests bit `L-1-i`. Bits at `L` and above are free. `diagram("")` is `ACCEPT`. Any other character raises `ValueError` (`*` and `.` included) |
| `exactly_these(values, *, width)` | `(node, w)`, where `w = max(width, largest bit length)` and `node` accepts exactly `values` below `2**w`. Raises as `IntSet()` does |
| `interval(start, stop, *, width)` | accepts `[max(start, 0), min(stop, 2**width))` within the width. An empty range gives `REJECT` and the full universe gives `ACCEPT` |
| `lshift(node, by)` | moves every tested bit up by `by` (down if negative). `accepts(lshift(n, k), x) == accepts(n, x >> k)` for `k >= 0`. Raises `ValueError` if a tested bit would go below 0 |
| `freed_between(node, *, low_bit, high_bit)` | existential: accepts `x` iff some `x'` that differs from `x` only in bits `[low_bit, high_bit)` is accepted. An empty bit range leaves the diagram unchanged |
| `subset(a, b)` / `disjoint(a, b)` | every value `a` accepts is accepted by `b` / no value is accepted by both |
| `narrowed(node, *, width)` | a diagram testing no bit `>= width` that agrees with `node` on every `x < 2**width` |
| `count_repr(total)` | a string: decimal, except an exact power of two `2**k` with `k >= 10` is written `"2**k"` (`512` -> `"512"`, `1024` -> `"2**10"`, `2**64 - 1` in decimal) |
| `tensor(node, *, width, code, bits, version)` | the low-level DLPack capsule used by `__dlpack__`. Callers should use the protocol instead |
| `collect()` | frees unreferenced nodes and returns an `int` (**observed**: about the number freed). Diagnostic only |
| `stats()` | a `dict[str, int]` with keys `nodes`, `free`, `wrapped`, `room`, `memo` and `memo_room` (**observed**). Diagnostic only |

---

## 5. `bitpattern.strategies.from_set(source)`

`from_set(source)` takes an `IntSet` or a `BDDSet` and returns a search strategy of
the optional `hypothesis` dependency. The strategy generates members of `source`
without enumerating it, so it works at any size. Every generated value is a member,
and every member can be generated. Values come out as `source[i]` for a drawn index
`i`, so simplification moves toward `source[0]` (**observed**: the minimal example is
the first member). An empty `source` gives a strategy that generates nothing. Any
other argument type is unspecified (a list raises `AttributeError`, **observed**).

## 6. DLPack export and `DType`

`DType` is an `Enum` whose values are DLPack `(code, bits)` pairs. Its properties are
`code` and `bits`. The members are `INT8 (0,8)`, `INT16 (0,16)`, `INT32 (0,32)`,
`INT64 (0,64)`, `UINT8 (1,8)`, `UINT16 (1,16)`, `UINT32 (1,32)`, `UINT64 (1,64)`,
`FLOAT16 (2,16)`, `FLOAT32 (2,32)`, `FLOAT64 (2,64)`, `BFLOAT16 (4,16)`,
`FLOAT8_E4M3FN (10,8)` and `FLOAT8_E5M2 (12,8)`.

Both `IntSet` and `BDDSet` implement `__dlpack__(*, stream=None, max_version=None,
dl_device=None, copy=None)` and `__dlpack_device__()`, which returns `(1, 0)` (host
memory). The export is a fresh copy holding every member in iteration (encoding) order.
- An `IntSet` exports as a 1-D array of the narrowest unsigned type that holds its
  width (`UINT8` up to 8 bits, width 0 included, then 16, 32 and 64). Above 64 bits it
  exports as a 2-D `uint8` array of shape `(size, ceil(width / 8))`, one big-endian
  row per member. `numpy.from_dlpack(IntSet([300, 1, 20]))` ->
  `array([1, 20, 300], dtype=uint16)`. The empty set gives an empty `uint8` array.
- A `BDDSet` exports with `codec.dtype()`. Signed ints come out as signed values and
  floats as floats, in encoding order:
  `from_dlpack(int8.set([-1, 0, 1, -128]))` -> `[0, 1, -128, -1]` (`int8`). 128-bit
  codecs come out as rows of 16 big-endian bytes, two's complement for `int128`.
  `Members` sets export indices.
- Errors: a `stream` that is not `None` raises `ValueError`. A `dl_device` other than
  `None` or `(1, 0)` raises `BufferError`. `copy=False` raises `BufferError`, because
  nothing can be shared.
- With `max_version` of `None` or below `(1, 0)` the capsule is a legacy unversioned
  tensor. With `(1, 0)` or above it is versioned, and float8 dtypes are labelled
  version 1.1. Whether a given consumer accepts float8 dtypes is up to the consumer.

## 7. Unspecified

- Error message text, except where a rule above quotes it.
- `decode` of bits outside `all` for codecs that do not check (`Int`, `FloatFN`,
  `Char` surrogates), and `BDDSet`s built directly from encodings outside `all`.
- What happens after assigning to `IntSet.width` or `IntSet.bdd`.
- The exact random sequence of `choice`, beyond uniformity and reproducibility with a
  seeded `rng`. The values of `hash`.
- NaN payloads after a round trip, beyond "a NaN with the same sign".
- The numbers returned by `collect()` and `stats()`. Performance: the documentation
  promises most operations in O(width), whatever the size, and `&`, `|`, `-` and `^`
  in O(|a| * |b|) diagram nodes.
- The non-underscore module helpers outside every `__all__`
  (`pattern.expanded`/`dotted`, `intset.written`/`described`/`listed`,
  `dlpack.unsigned`/`signed`/`exported` and module constants) are implementation
  details.
