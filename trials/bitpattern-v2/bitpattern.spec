spec bitpattern

# Formal spec of bitpattern 0.3.0, translated from its informal API specification.
#
# Models are the library's classes, named by the module that defines them. Calls are
# positional in v2, so a few names are mapped in test_bitpattern.py: keyword-only
# parameters go through support.py, and a `variant.` name is another argument shape of
# a library callable, one signature per spec name.

prelude "bitpattern.prelude"

# -- Models ------------------------------------------------------------------------

model random.Random
  build random.Random(seed: int)

model bitpattern.bdd.BDD
  observe bit: int
  observe leaf: bool
  observe size: int
  observe left: bitpattern.bdd.BDD
  observe right: bitpattern.bdd.BDD
  # How many values below 2 ** width the diagram accepts.
  observe total(width: int): int = support.bdd_count(self, width)
  build variant.diagram_cells(cells: list<"0" | "1" | "?">)
  build bitpattern.bdd.interval(start: u8, stop: u8, width: i8)
  build bitpattern.bdd.BDD.__or__(a: bitpattern.bdd.BDD, b: bitpattern.bdd.BDD)
  build bitpattern.bdd.BDD.__and__(a: bitpattern.bdd.BDD, b: bitpattern.bdd.BDD)
  build bitpattern.bdd.BDD.__sub__(a: bitpattern.bdd.BDD, b: bitpattern.bdd.BDD)
  build bitpattern.bdd.BDD.__invert__(a: bitpattern.bdd.BDD)
  build bitpattern.bdd.lshift(node: bitpattern.bdd.BDD, by: i8)

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe bdd: bitpattern.bdd.BDD
  # The first n members ascending, and the last n descending. Both walk the iterator,
  # so they work at any size.
  observe head(n: int): list<int> = builtins.list(itertools.islice(self, n))
  observe last(n: int): list<int> = builtins.list(itertools.islice(builtins.reversed(self), n))
  observe has(x: int): bool = operator.contains(self, x)
  observe rank(x: int): int = support.bdd_rank(bdd, x, width)
  build bitpattern.IntSet(items: list<u8>)
  build variant.IntSet_with_width(items: list<u16>, width: i8)
  build bitpattern.IntSet.range(start: u8, stop: u8, width: option<i8>)
  build support.scaled_range(start: u8, stop: u8, shift: i8)
  build bitpattern.intset.IntSet.__or__(a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet)
  build bitpattern.intset.IntSet.__and__(a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet)
  build bitpattern.intset.IntSet.__sub__(a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet)
  build bitpattern.intset.IntSet.__xor__(a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet)
  build bitpattern.intset.IntSet.__invert__(a: bitpattern.intset.IntSet)
  build bitpattern.intset.IntSet.widened(a: bitpattern.intset.IntSet, width: i8)
  build bitpattern.IntSet.from_bdd(node: bitpattern.bdd.BDD, width: i8)
  # Section 1: the set is the members below 2 ** width, ascending, with no repeats.
  invariant bounded: size <= 2 ** width
  invariant ascending: size <= 512 implies is_sorted(head(size)) and distinct(head(size))
  invariant below_universe: size <= 512 implies all(x in head(size): 0 <= x and x < 2 ** width)
  invariant reversed: size >= 3 and size <= 512 implies last(3) == [head(size)[size - 1], head(size)[size - 2], head(size)[size - 3]]

# -- 1. IntSet: construction -------------------------------------------------------

fn variant.IntSet_new(items: list<int>) -> bitpattern.intset.IntSet
  raises ValueError when exists(x in items: x < 0)
  ensures members: small(result) implies same_members(elems(result), items)
  ensures width: result.width == (if len(items) == 0 then 0 else bit_length(max(x in items: x)))
  ensures round_trip: small(result) implies bitpattern.intset.IntSet.__eq__(variant.IntSet_with_width(elems(result), result.width), result) and variant.IntSet_with_width(elems(result), result.width).width == result.width

fn variant.IntSet_floats(items: list<f64>) -> bitpattern.intset.IntSet
  raises TypeError when len(items) > 0
  ensures empty: result.size == 0

fn variant.IntSet_with_width(items: list<int>, width: int) -> bitpattern.intset.IntSet
  requires width <= 200
  raises ValueError when exists(x in items: x < 0)
  ensures members: small(result) implies same_members(elems(result), items)
  ensures width: result.width == imax(imax(width, 0), if len(items) == 0 then 0 else bit_length(max(x in items: x)))

fn bitpattern.IntSet.range(start: int, stop: int, width: option<i16>) -> bitpattern.intset.IntSet
  requires is_none(width) or unwrap(width) <= 200
  raises ValueError when start < 0 or (is_some(width) and unwrap(width) < 0)
  ensures default_width: is_none(width) implies result.width == bit_length(imax(stop - 1, 0))
  ensures size: result.size == imax(0, imin(stop, 2 ** (if is_some(width) then unwrap(width) else bit_length(imax(stop - 1, 0)))) - start)
  ensures members: small(result) implies elems(result) == range(start, start + result.size)

# Bounds that are not ints raise TypeError.
fn variant.IntSet_range_floats(start: f64, stop: f64, width: option<i8>) -> bitpattern.intset.IntSet
  raises TypeError when true

fn bitpattern.IntSet.from_bdd(bdd: bitpattern.bdd.BDD, width: i16) -> bitpattern.intset.IntSet
  requires width <= 200
  raises ValueError when bdd.bit >= width
  ensures width: result.width == width
  ensures size: width >= 0 and width <= 127 implies result.size == bitpattern.bdd.count(bdd, width)
  ensures members: width <= 8 implies elems(result) == filter(x in range(0, 2 ** width): bitpattern.bdd.accepts(bdd, x))

# -- 1. IntSet: size, membership, order --------------------------------------------

fn bitpattern.intset.IntSet.size(self) -> int
  ensures count: small(self) implies result == len(elems(self))
  ensures universe: result <= 2 ** self.width

fn builtins.len(s: bitpattern.intset.IntSet) -> int
  raises OverflowError when s.size >= 2 ** 63
  ensures size: result == s.size

fn builtins.bool(s: bitpattern.intset.IntSet) -> bool
  ensures nonempty: result == (s.size > 0)

fn bitpattern.intset.IntSet.__contains__(self, x: int) -> bool
  ensures members: small(self) implies result == (x in elems(self))
  ensures negative: x < 0 implies not result
  ensures too_wide: x >= 2 ** self.width implies not result

fn variant.IntSet_contains_float(s: bitpattern.intset.IntSet, x: f64) -> bool
  ensures never: not result

fn variant.IntSet_contains_string(s: bitpattern.intset.IntSet, x: string) -> bool
  ensures never: not result

fn bitpattern.intset.IntSet.__getitem__(self, i: int) -> int
  raises IndexError when i < -self.size or i >= self.size
  ensures nth: small(self) implies result == elems(self)[wrap_index(i, self.size)]
  ensures position: bitpattern.intset.IntSet.index(self, result, 0, none) == wrap_index(i, self.size)
  ensures member: bitpattern.intset.IntSet.__contains__(self, result)
  ensures reversed_end: i == -1 implies self.last(1) == [result]
  ensures first: i == 0 implies self.head(1) == [result]

fn variant.IntSet_getitem_float(s: bitpattern.intset.IntSet, i: f64) -> int
  raises TypeError when true

# s[a:b:c] is the set of members at positions range(size)[a:b:c]; a negative step does
# not reverse it.
fn variant.IntSet_slice(s: bitpattern.intset.IntSet, start: option<int>, stop: option<int>, step: option<int>) -> bitpattern.intset.IntSet
  may_raise ValueError when is_some(step) and unwrap(step) == 0
  ensures members: small(s) and (is_none(step) or unwrap(step) != 0) implies same_members(elems(result), map(i in slice_positions(start, stop, if is_none(step) then 1 else unwrap(step), s.size): elems(s)[i]))
  ensures unit_step: is_none(step) implies result.size == imax(0, slice_hi(stop, s.size, 1) - slice_lo(start, s.size, 1))
  ensures width: result.width == s.width
  ensures subset: bitpattern.intset.IntSet.__le__(result, s)

fn bitpattern.intset.IntSet.index(self, value: int, start: int = 0, stop: option<int> = none) -> int
  raises ValueError when not self.has(value) or self.rank(value) < slice_lo(some(start), self.size, 1) or self.rank(value) >= slice_hi(stop, self.size, 1)
  ensures roundtrip: bitpattern.intset.IntSet.__getitem__(self, result) == value
  ensures rank: result == bitpattern.bdd.rank(self.bdd, value, self.width)
  ensures window: slice_lo(some(start), self.size, 1) <= result and result < slice_hi(stop, self.size, 1)

fn bitpattern.intset.IntSet.count(self, value: int) -> int
  ensures zero_or_one: result == (if bitpattern.intset.IntSet.__contains__(self, value) then 1 else 0)

# index raises ValueError when the value is not a member, of any type.
fn variant.IntSet_index_float(s: bitpattern.intset.IntSet, value: f64, start: i8 = 0) -> int
  raises ValueError when true

fn variant.IntSet_count_float(s: bitpattern.intset.IntSet, value: f64) -> int
  ensures zero: result == 0

fn bitpattern.intset.IntSet.choice(self, rng: random.Random) -> int
  raises IndexError when self.size == 0
  ensures member: bitpattern.intset.IntSet.__contains__(self, result)

fn variant.IntSet_choice_default(s: bitpattern.intset.IntSet) -> int
  raises IndexError when s.size == 0
  ensures member: bitpattern.intset.IntSet.__contains__(s, result)

# Two rngs seeded alike give the same member.
fn variant.IntSet_choice_seeded(s: bitpattern.intset.IntSet, seed: int) -> (int, int)
  raises IndexError when s.size == 0
  ensures reproducible: result.0 == result.1
  ensures member: bitpattern.intset.IntSet.__contains__(s, result.0)

fn bitpattern.intset.IntSet.widened(self, width: int) -> bitpattern.intset.IntSet
  requires width <= 200
  ensures width: result.width == imax(self.width, width)
  ensures members: result.size == self.size
  relates same_set: bitpattern.intset.IntSet.__eq__(result, self)

# -- 1. IntSet: set algebra --------------------------------------------------------

fn bitpattern.intset.IntSet.__and__(self, other: bitpattern.intset.IntSet) -> bitpattern.intset.IntSet
  ensures members: small(self) and small(other) implies same_members(elems(result), inter_of(elems(self), elems(other)))
  ensures width: result.width == imax(self.width, other.width)
  ensures size: result.size + bitpattern.intset.IntSet.__or__(self, other).size == self.size + other.size
  ensures within: result.size <= imin(self.size, other.size)
  relates commutes: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__and__(other, self), result)
  relates subset: bitpattern.intset.IntSet.__le__(result, self) and bitpattern.intset.IntSet.__le__(result, other)
  relates idempotent: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__and__(self, self), self)
  relates absorbs_or: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__and__(self, bitpattern.intset.IntSet.__or__(self, other)), self)

fn bitpattern.intset.IntSet.__or__(self, other: bitpattern.intset.IntSet) -> bitpattern.intset.IntSet
  ensures members: small(self) and small(other) implies same_members(elems(result), elems(self) + elems(other))
  ensures width: result.width == imax(self.width, other.width)
  ensures size: result.size == self.size + other.size - bitpattern.intset.IntSet.__and__(self, other).size
  ensures covers: result.size >= imax(self.size, other.size)
  relates commutes: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__or__(other, self), result)
  relates superset: bitpattern.intset.IntSet.__ge__(result, self) and bitpattern.intset.IntSet.__ge__(result, other)
  relates idempotent: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__or__(self, self), self)
  relates absorbs_and: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__or__(self, bitpattern.intset.IntSet.__and__(self, other)), self)
  relates de_morgan: self.width == other.width implies bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__invert__(result), bitpattern.intset.IntSet.__and__(bitpattern.intset.IntSet.__invert__(self), bitpattern.intset.IntSet.__invert__(other)))

fn bitpattern.intset.IntSet.__sub__(self, other: bitpattern.intset.IntSet) -> bitpattern.intset.IntSet
  ensures members: small(self) and small(other) implies same_members(elems(result), minus_of(elems(self), elems(other)))
  ensures width: result.width == imax(self.width, other.width)
  ensures size: result.size == self.size - bitpattern.intset.IntSet.__and__(self, other).size
  relates disjoint: bitpattern.intset.IntSet.__and__(result, other).size == 0
  relates subset: bitpattern.intset.IntSet.__le__(result, self)
  relates self_empty: bitpattern.intset.IntSet.__sub__(self, self).size == 0

fn bitpattern.intset.IntSet.__xor__(self, other: bitpattern.intset.IntSet) -> bitpattern.intset.IntSet
  ensures members: small(self) and small(other) implies same_members(elems(result), xor_of(elems(self), elems(other)))
  ensures width: result.width == imax(self.width, other.width)
  ensures size: result.size == self.size + other.size - 2 * bitpattern.intset.IntSet.__and__(self, other).size
  relates commutes: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__xor__(other, self), result)
  relates self_empty: bitpattern.intset.IntSet.__xor__(self, self).size == 0

fn bitpattern.intset.IntSet.__invert__(self) -> bitpattern.intset.IntSet
  ensures width: result.width == self.width
  ensures size: result.size == 2 ** self.width - self.size
  ensures members: self.width <= 9 implies elems(result) == filter(x in range(0, 2 ** self.width): not (x in elems(self)))
  relates involution: bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__invert__(result), self)
  relates involution_width: bitpattern.intset.IntSet.__invert__(result).width == self.width
  relates excluded_middle: bitpattern.intset.IntSet.__and__(self, result).size == 0 and bitpattern.intset.IntSet.__or__(self, result).size == 2 ** self.width

# The right operand of & | - ^ may be any iterable of ints: it is first made an IntSet.
fn variant.IntSet_and_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), filter(x in elems(s): x in other))
  ensures width: result.width == imax(s.width, if len(other) == 0 then 0 else bit_length(max(x in other: x)))

fn variant.IntSet_or_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), elems(s) + other)
  ensures width: result.width == imax(s.width, if len(other) == 0 then 0 else bit_length(max(x in other: x)))

fn variant.IntSet_sub_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), filter(x in elems(s): not (x in other)))
  ensures width: result.width == imax(s.width, if len(other) == 0 then 0 else bit_length(max(x in other: x)))

fn variant.IntSet_xor_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), filter(x in elems(s) + other: (x in elems(s)) != (x in other)))
  ensures width: result.width == imax(s.width, if len(other) == 0 then 0 else bit_length(max(x in other: x)))

# Built-in iterables also work on the left: the result has the type of the right operand,
# except for `-`, which gives a plain IntSet.
fn variant.IntSet_rand_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), filter(x in elems(s): x in other))

fn variant.IntSet_ror_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), elems(s) + other)

fn variant.IntSet_rsub_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), filter(x in other: not (x in elems(s))))

fn variant.IntSet_rxor_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: small(s) implies same_members(elems(result), filter(x in elems(s) + other: (x in elems(s)) != (x in other)))

# Items that are not ints raise TypeError, negative items ValueError, a non-iterable
# operand TypeError.
fn variant.IntSet_and_negative(s: bitpattern.intset.IntSet, other: list<int>) -> bitpattern.intset.IntSet
  raises ValueError when exists(x in other: x < 0)

fn variant.IntSet_or_negative(s: bitpattern.intset.IntSet, other: list<int>) -> bitpattern.intset.IntSet
  raises ValueError when exists(x in other: x < 0)

fn variant.IntSet_sub_negative(s: bitpattern.intset.IntSet, other: list<int>) -> bitpattern.intset.IntSet
  raises ValueError when exists(x in other: x < 0)

fn variant.IntSet_xor_negative(s: bitpattern.intset.IntSet, other: list<int>) -> bitpattern.intset.IntSet
  raises ValueError when exists(x in other: x < 0)

fn variant.IntSet_and_floats(s: bitpattern.intset.IntSet, other: list<f64>) -> bitpattern.intset.IntSet
  raises TypeError when len(other) > 0

fn variant.IntSet_or_floats(s: bitpattern.intset.IntSet, other: list<f64>) -> bitpattern.intset.IntSet
  raises TypeError when len(other) > 0

fn variant.IntSet_sub_floats(s: bitpattern.intset.IntSet, other: list<f64>) -> bitpattern.intset.IntSet
  raises TypeError when len(other) > 0

fn variant.IntSet_xor_floats(s: bitpattern.intset.IntSet, other: list<f64>) -> bitpattern.intset.IntSet
  raises TypeError when len(other) > 0

fn variant.IntSet_and_int(s: bitpattern.intset.IntSet, other: i64) -> bitpattern.intset.IntSet
  raises TypeError when true

fn variant.IntSet_or_int(s: bitpattern.intset.IntSet, other: i64) -> bitpattern.intset.IntSet
  raises TypeError when true

fn variant.IntSet_sub_int(s: bitpattern.intset.IntSet, other: i64) -> bitpattern.intset.IntSet
  raises TypeError when true

fn variant.IntSet_xor_int(s: bitpattern.intset.IntSet, other: i64) -> bitpattern.intset.IntSet
  raises TypeError when true

# The result has the type of the left operand: IntSet & Pattern is an IntSet.
fn variant.IntSet_and_pattern(s: bitpattern.intset.IntSet, p: bitpattern.pattern.Pattern) -> bitpattern.intset.IntSet
  ensures members: small(s) and p.size <= 512 implies same_members(elems(result), inter_of(elems(s), elems_p(p)))
  ensures width: result.width == imax(s.width, p.width)

fn variant.IntSet_or_pattern(s: bitpattern.intset.IntSet, p: bitpattern.pattern.Pattern) -> bitpattern.intset.IntSet
  ensures members: small(s) and p.size <= 512 implies same_members(elems(result), elems(s) + elems_p(p))
  ensures width: result.width == imax(s.width, p.width)

fn variant.IntSet_sub_pattern(s: bitpattern.intset.IntSet, p: bitpattern.pattern.Pattern) -> bitpattern.intset.IntSet
  ensures members: small(s) and p.size <= 512 implies same_members(elems(result), minus_of(elems(s), elems_p(p)))

fn variant.IntSet_xor_pattern(s: bitpattern.intset.IntSet, p: bitpattern.pattern.Pattern) -> bitpattern.intset.IntSet
  ensures members: small(s) and p.size <= 512 implies same_members(elems(result), xor_of(elems(s), elems_p(p)))

# -- 1. IntSet: comparisons, equality, hash ----------------------------------------

fn bitpattern.intset.IntSet.__le__(self, other: bitpattern.intset.IntSet) -> bool
  ensures subset: small(self) and small(other) implies result == subset_of(elems(self), elems(other))
  ensures by_difference: result == (bitpattern.intset.IntSet.__sub__(self, other).size == 0)
  ensures by_intersection: result == bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.__and__(self, other), self)
  ensures widths_ignored: result == bitpattern.intset.IntSet.__le__(bitpattern.intset.IntSet.widened(self, 130), other)

fn bitpattern.intset.IntSet.__lt__(self, other: bitpattern.intset.IntSet) -> bool
  ensures proper: result == (bitpattern.intset.IntSet.__le__(self, other) and not bitpattern.intset.IntSet.__eq__(self, other))
  ensures irreflexive: not bitpattern.intset.IntSet.__lt__(self, self)

fn bitpattern.intset.IntSet.__ge__(self, other: bitpattern.intset.IntSet) -> bool
  ensures superset: small(self) and small(other) implies result == subset_of(elems(other), elems(self))
  ensures mirrored: result == bitpattern.intset.IntSet.__le__(other, self)

fn bitpattern.intset.IntSet.__gt__(self, other: bitpattern.intset.IntSet) -> bool
  ensures proper: result == (bitpattern.intset.IntSet.__ge__(self, other) and not bitpattern.intset.IntSet.__eq__(self, other))
  ensures mirrored: result == bitpattern.intset.IntSet.__lt__(other, self)

# Comparisons accept only IntSet operands; anything else, built-in sets included, raises.
fn variant.IntSet_le_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bool
  raises TypeError when true

fn variant.IntSet_lt_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bool
  raises TypeError when true

fn variant.IntSet_ge_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bool
  raises TypeError when true

fn variant.IntSet_gt_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bool
  raises TypeError when true

# Equal when both are IntSets with the same members, whatever the widths.
fn bitpattern.intset.IntSet.__eq__(self, other: bitpattern.intset.IntSet) -> bool
  ensures members: small(self) and small(other) implies result == same_members(elems(self), elems(other))
  ensures sizes: result implies self.size == other.size
  ensures widths_ignored: result == bitpattern.intset.IntSet.__eq__(bitpattern.intset.IntSet.widened(self, 130), other)
  ensures reflexive: bitpattern.intset.IntSet.__eq__(self, self)
  ensures mutual_subset: result == (bitpattern.intset.IntSet.__le__(self, other) and bitpattern.intset.IntSet.__le__(other, self))

# Never equal to a non-IntSet, and the comparison does not raise.
fn variant.IntSet_eq_list(s: bitpattern.intset.IntSet, other: list<u8>) -> bool
  ensures never: not result

fn builtins.hash(s: bitpattern.intset.IntSet) -> int
  relates across_widths: builtins.hash(bitpattern.intset.IntSet.widened(s, 130)) == result
  relates across_construction: builtins.hash(bitpattern.IntSet.from_bdd(s.bdd, s.width)) == result

fn bitpattern.intset.IntSet.isdisjoint(self, other: list<u8>) -> bool
  ensures members: small(self) implies result == (len(inter_of(elems(self), other)) == 0)

fn variant.IntSet_isdisjoint_set(s: bitpattern.intset.IntSet, other: bitpattern.intset.IntSet) -> bool
  ensures by_intersection: result == (bitpattern.intset.IntSet.__and__(s, other).size == 0)

# Attributes other than width and bdd cannot be set.
fn builtins.setattr(s: bitpattern.intset.IntSet, name: "extra" | "size" | "members", value: int)
  raises AttributeError when true

# -- 4. bitpattern.bdd: nodes ------------------------------------------------------

const bitpattern.bdd.BDD.ACCEPT: bitpattern.bdd.BDD
const bitpattern.bdd.BDD.REJECT: bitpattern.bdd.BDD
const bitpattern.bdd.BDD.__match_args__: (string, string, string)

# Classes, as objects: a model without a dotted name accepts any object.
model Class

const bitpattern.__version__: string
const bitpattern.bdd.__version__: string
const bitpattern.IntSet: Class
const bitpattern.Pattern: Class
const bitpattern.BDD: Class
const bitpattern.BDDSet: Class
const bitpattern.Codec: Class
const bitpattern.OrderedCodec: Class
const bitpattern.codecs.BDDSet: Class
const bitpattern.codecs.Codec: Class
const bitpattern.codecs.OrderedCodec: Class

fn variant.BDD_new(bit: i16, left: bitpattern.bdd.BDD, right: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  raises ValueError when bit < 0 or (not left.leaf and left.bit >= bit) or (not right.leaf and right.bit >= bit)
  ensures node: not same_object(left, right) implies result.bit == bit and same_object(result.left, left) and same_object(result.right, right)
  ensures collapses: same_object(left, right) implies same_object(result, left)
  ensures canonical: not result.leaf implies same_object(variant.BDD_new(result.bit, result.left, result.right), result)

fn variant.BDD_bad_children(bit: u8, left: i64, right: i64) -> bitpattern.bdd.BDD
  raises TypeError when true

fn bitpattern.bdd.BDD.bit(self) -> int
  ensures leaf: self.leaf implies result == -1
  ensures node: not self.leaf implies result >= 0

fn bitpattern.bdd.BDD.leaf(self) -> bool
  ensures leaves: result == (self.bit == -1)

fn bitpattern.bdd.BDD.left(self) -> bitpattern.bdd.BDD
  ensures leaf_children: self.leaf implies same_object(result, self)
  ensures ordered: not self.leaf implies result.bit < self.bit
  ensures follows_zero: not self.leaf implies all(x in range(0, 64): (x >> self.bit) & 1 == 0 implies bitpattern.bdd.accepts(self, x) == bitpattern.bdd.accepts(result, x))

fn bitpattern.bdd.BDD.right(self) -> bitpattern.bdd.BDD
  ensures leaf_children: self.leaf implies same_object(result, self)
  ensures ordered: not self.leaf implies result.bit < self.bit
  ensures follows_one: not self.leaf implies all(x in range(0, 64): (x >> self.bit) & 1 == 1 implies bitpattern.bdd.accepts(self, x) == bitpattern.bdd.accepts(result, x))
  ensures high_bit: not self.leaf and self.bit >= 6 implies all(x in range(0, 64): bitpattern.bdd.accepts(self, x + 2 ** self.bit) == bitpattern.bdd.accepts(result, x + 2 ** self.bit))

# The number of accepted values below 2 ** (bit + 1); ACCEPT.size == 1, REJECT.size == 0.
fn bitpattern.bdd.BDD.size(self) -> int
  ensures count: result == bitpattern.bdd.count(self, self.bit + 1)
  ensures leaves: self.leaf implies result <= 1

fn variant.BDD_bool(node: bitpattern.bdd.BDD) -> bool
  ensures only_reject_is_false: result == (not (node.leaf and node.size == 0))

fn bitpattern.bdd.BDD.__invert__(self) -> bitpattern.bdd.BDD
  ensures pointwise: all(x in range(0, 128): bitpattern.bdd.accepts(result, x) == (not bitpattern.bdd.accepts(self, x)))
  ensures leaves: self.leaf implies result.leaf and result.size == 1 - self.size
  ensures counts: bitpattern.bdd.count(result, imax(self.bit + 1, 0)) + bitpattern.bdd.count(self, imax(self.bit + 1, 0)) == 2 ** imax(self.bit + 1, 0)
  relates involution: same_object(bitpattern.bdd.BDD.__invert__(result), self)

fn bitpattern.bdd.BDD.__and__(self, other: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  ensures pointwise: all(x in range(0, 128): bitpattern.bdd.accepts(result, x) == (bitpattern.bdd.accepts(self, x) and bitpattern.bdd.accepts(other, x)))
  ensures inclusion_exclusion: bitpattern.bdd.count(result, imax(imax(self.bit, other.bit) + 1, 0)) + bitpattern.bdd.count(bitpattern.bdd.BDD.__or__(self, other), imax(imax(self.bit, other.bit) + 1, 0)) == bitpattern.bdd.count(self, imax(imax(self.bit, other.bit) + 1, 0)) + bitpattern.bdd.count(other, imax(imax(self.bit, other.bit) + 1, 0))
  relates commutes: same_object(bitpattern.bdd.BDD.__and__(other, self), result)
  relates idempotent: same_object(bitpattern.bdd.BDD.__and__(self, self), self)

fn bitpattern.bdd.BDD.__or__(self, other: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  ensures pointwise: all(x in range(0, 128): bitpattern.bdd.accepts(result, x) == (bitpattern.bdd.accepts(self, x) or bitpattern.bdd.accepts(other, x)))
  relates commutes: same_object(bitpattern.bdd.BDD.__or__(other, self), result)
  relates idempotent: same_object(bitpattern.bdd.BDD.__or__(self, self), self)
  relates de_morgan: same_object(bitpattern.bdd.BDD.__invert__(result), bitpattern.bdd.BDD.__and__(bitpattern.bdd.BDD.__invert__(self), bitpattern.bdd.BDD.__invert__(other)))

fn bitpattern.bdd.BDD.__sub__(self, other: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  ensures pointwise: all(x in range(0, 128): bitpattern.bdd.accepts(result, x) == (bitpattern.bdd.accepts(self, x) and not bitpattern.bdd.accepts(other, x)))
  relates as_and_not: same_object(bitpattern.bdd.BDD.__and__(self, bitpattern.bdd.BDD.__invert__(other)), result)

fn bitpattern.bdd.BDD.__xor__(self, other: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  ensures pointwise: all(x in range(0, 128): bitpattern.bdd.accepts(result, x) == (bitpattern.bdd.accepts(self, x) != bitpattern.bdd.accepts(other, x)))
  relates commutes: same_object(bitpattern.bdd.BDD.__xor__(other, self), result)

# A non-BDD operand raises TypeError.
fn variant.BDD_and_int(a: bitpattern.bdd.BDD, b: i64) -> bitpattern.bdd.BDD
  raises TypeError when true

fn variant.BDD_or_int(a: bitpattern.bdd.BDD, b: i64) -> bitpattern.bdd.BDD
  raises TypeError when true

fn variant.BDD_sub_int(a: bitpattern.bdd.BDD, b: i64) -> bitpattern.bdd.BDD
  raises TypeError when true

fn variant.BDD_xor_int(a: bitpattern.bdd.BDD, b: i64) -> bitpattern.bdd.BDD
  raises TypeError when true

# == and hash follow the function; == against a non-BDD is False.
fn bitpattern.bdd.BDD.__eq__(self, other: bitpattern.bdd.BDD) -> bool
  ensures by_function: result == (bitpattern.bdd.subset(self, other) and bitpattern.bdd.subset(other, self))
  ensures canonical: result == same_object(self, other)

fn variant.BDD_eq_int(a: bitpattern.bdd.BDD, b: i64) -> bool
  ensures never: not result

fn variant.BDD_hash(node: bitpattern.bdd.BDD) -> int
  relates same_function: variant.BDD_hash(bitpattern.bdd.BDD.__or__(node, node)) == result
  relates double_negation: variant.BDD_hash(bitpattern.bdd.BDD.__invert__(bitpattern.bdd.BDD.__invert__(node))) == result

# copy.copy, copy.deepcopy and a pickle round trip return the same object.
fn copy.copy(node: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  ensures same: same_object(result, node)

fn copy.deepcopy(node: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  ensures same: same_object(result, node)

fn support.pickle_roundtrip(node: bitpattern.bdd.BDD) -> bitpattern.bdd.BDD
  ensures same: same_object(result, node)

fn variant.BDD_repr(node: bitpattern.bdd.BDD) -> string
  ensures accept: node.leaf and node.size == 1 implies result == "BDD.ACCEPT"
  ensures reject: node.leaf and node.size == 0 implies result == "BDD.REJECT"
  ensures node: not node.leaf implies result == "<BDD bit=" + dec(node.bit) + ", " + dec(bitpattern.bdd.node_count(node)) + " nodes, " + count_repr_text(node.size) + " members>"

# -- 4. bitpattern.bdd: functions --------------------------------------------------

# Untested bits are unconstrained, so accepts(ACCEPT, 999) is True. The Shannon
# expansion defines accepts for every other node.
fn bitpattern.bdd.accepts(node: bitpattern.bdd.BDD, value: int) -> bool
  requires value >= 0
  ensures leaf: node.leaf implies result == (node.size == 1)
  ensures shannon: not node.leaf implies result == (if (value >> node.bit) & 1 == 0 then bitpattern.bdd.accepts(node.left, value) else bitpattern.bdd.accepts(node.right, value))
  ensures leaves_are_constants: bitpattern.bdd.accepts(bitpattern.bdd.BDD.ACCEPT, value) and not bitpattern.bdd.accepts(bitpattern.bdd.BDD.REJECT, value)
  ensures leaf_fields: bitpattern.bdd.BDD.ACCEPT.bit == -1 and bitpattern.bdd.BDD.ACCEPT.leaf and bitpattern.bdd.BDD.REJECT.bit == -1 and bitpattern.bdd.BDD.REJECT.leaf
  ensures leaf_sizes: bitpattern.bdd.BDD.ACCEPT.size == 1 and bitpattern.bdd.BDD.REJECT.size == 0
  ensures negation_of_leaves: same_object(bitpattern.bdd.BDD.__invert__(bitpattern.bdd.BDD.ACCEPT), bitpattern.bdd.BDD.REJECT)

fn bitpattern.bdd.count(node: bitpattern.bdd.BDD, width: i16) -> int
  requires width <= 200
  raises ValueError when width < 0 or node.bit >= width
  ensures leaf: node.leaf implies result == (if node.size == 1 then 2 ** width else 0)
  ensures split: not node.leaf implies 2 * result == bitpattern.bdd.count(node.left, width) + bitpattern.bdd.count(node.right, width)
  ensures bounded: 0 <= result and result <= 2 ** width
  ensures size: result == node.size * 2 ** (width - node.bit - 1)

fn bitpattern.bdd.nth(node: bitpattern.bdd.BDD, n: int, width: i16) -> int
  requires width <= 200
  raises ValueError when width < 0 or node.bit >= width
  raises IndexError when width >= 0 and node.bit < width and (n < -node.total(width) or n >= node.total(width))
  ensures accepted: bitpattern.bdd.accepts(node, result) and 0 <= result and result < 2 ** width
  ensures position: bitpattern.bdd.rank(node, result, width) == (if n < 0 then n + node.total(width) else n)

fn bitpattern.bdd.rank(node: bitpattern.bdd.BDD, value: int, width: i16) -> int
  requires width <= 200
  requires width < 0 or (0 <= value and value <= 2 ** width)
  raises ValueError when width < 0 or node.bit >= width
  ensures counted: width <= 8 implies result == len(filter(x in range(0, value): bitpattern.bdd.accepts(node, x)))
  ensures step: value >= 1 implies result == bitpattern.bdd.rank(node, value - 1, width) + (if bitpattern.bdd.accepts(node, value - 1) then 1 else 0)
  ensures full: bitpattern.bdd.rank(node, 2 ** width, width) == node.total(width)
  ensures zero: bitpattern.bdd.rank(node, 0, width) == 0

# Iterators cross as lists of their first 513 items (support.py).
fn bitpattern.bdd.members(node: bitpattern.bdd.BDD, width: i16) -> list<int>
  requires width <= 200
  raises ValueError when width < 0 or node.bit >= width
  ensures count: len(result) == imin(node.total(width), 513)
  ensures ascending: is_sorted(result) and distinct(result)
  ensures accepted: all(x in result[0:imin(len(result), 16)]: bitpattern.bdd.accepts(node, x) and 0 <= x and x < 2 ** width)
  ensures complete: width <= 8 implies result == filter(x in range(0, 2 ** width): bitpattern.bdd.accepts(node, x))
  ensures nth: all(i in range(0, imin(len(result), 8)): result[i] == bitpattern.bdd.nth(node, i, width))

# An ascending iterator of aligned blocks (start, free), disjoint, covering the set, as few as possible.
fn bitpattern.bdd.blocks(node: bitpattern.bdd.BDD, width: i16) -> list<(int, int)>
  requires width <= 200
  raises ValueError when width < 0 or node.bit >= width
  ensures aligned: all(b in result: b.0 % 2 ** b.1 == 0 and b.0 + 2 ** b.1 <= 2 ** width)
  ensures ascending_disjoint: all(i in range(0, imax(len(result) - 1, 0)): result[i].0 + 2 ** result[i].1 <= result[i + 1].0)
  ensures covers: len(result) <= 512 implies sum(b in result: 2 ** b.1) == node.total(width)
  ensures accepted: all(b in result[0:imin(len(result), 8)]: bitpattern.bdd.accepts(node, b.0) and bitpattern.bdd.accepts(node, b.0 + 2 ** b.1 - 1))
  ensures no_buddies: all(i in range(0, imax(len(result) - 1, 0)): not (result[i].1 == result[i + 1].1 and result[i + 1].0 == result[i].0 + 2 ** result[i].1 and result[i].0 % 2 ** (result[i].1 + 1) == 0))
  ensures maximal: all(b in result[0:imin(len(result), 8)]: let bs = (if (b.0 >> b.1) % 2 == 0 then b.0 + 2 ** b.1 else b.0 - 2 ** b.1) in bs + 2 ** b.1 > 2 ** width or bitpattern.bdd.rank(node, bs + 2 ** b.1, width) - bitpattern.bdd.rank(node, bs, width) < 2 ** b.1)

# Strings of width characters over 0 1 ?, most significant bit first; disjoint, covering.
fn bitpattern.bdd.paths(node: bitpattern.bdd.BDD, width: i16) -> list<string>
  requires width <= 200
  raises ValueError when width < 0 or node.bit >= width
  ensures shape: all(p in result: len(p) == width and all(c in codepoints(p): c == 48 or c == 49 or c == 63))
  ensures reject_has_none: node.leaf and node.size == 0 implies len(result) == 0
  ensures accept_is_wild: node.leaf and node.size == 1 implies result == [from_codepoints(map(i in range(0, width): 63))]
  ensures exact_cover: width <= 6 and len(result) <= 512 implies all(x in range(0, 2 ** width): count(p in result: path_matches(p, x)) == (if bitpattern.bdd.accepts(node, x) then 1 else 0))
  ensures total: len(result) <= 512 implies sum(p in result: 2 ** count(c in codepoints(p): c == 63)) == node.total(width)

fn bitpattern.bdd.path_count(node: bitpattern.bdd.BDD) -> int
  ensures counted: result <= 512 implies result == len(bitpattern.bdd.paths(node, imax(node.bit + 1, 0)))
  ensures any_width: result <= 512 implies result == len(bitpattern.bdd.paths(node, imax(node.bit + 1, 0) + 3))
  ensures reject: node.leaf and node.size == 0 implies result == 0

fn bitpattern.bdd.node_count(node: bitpattern.bdd.BDD) -> int
  ensures leaves: node.leaf implies result == 0
  ensures internal: not node.leaf implies result >= 1 and bitpattern.bdd.node_count(node.left) < result and bitpattern.bdd.node_count(node.right) < result

# `bits` over 0 1 ?: character i tests bit L - 1 - i; bits at L and above are free.
fn bitpattern.bdd.diagram(bits: string) -> bitpattern.bdd.BDD
  raises ValueError when exists(c in codepoints(bits): c != 48 and c != 49 and c != 63)
  ensures empty_is_accept: len(bits) == 0 implies result.leaf and result.size == 1

fn variant.diagram_cells(cells: list<"0" | "1" | "?">) -> bitpattern.bdd.BDD
  ensures cube: all(x in range(0, 256): bitpattern.bdd.accepts(result, x) == cells_match(cells, x))
  ensures nodes: bitpattern.bdd.node_count(result) == count(c in cells: c != "?")
  ensures top: len(cells) > 0 and cells[0] != "?" implies result.bit == len(cells) - 1
  ensures canonical: not result.leaf implies same_object(variant.BDD_new(result.bit, result.left, result.right), result)
  ensures free_above: len(cells) <= 8 implies all(x in range(0, 256): bitpattern.bdd.accepts(result, x) == bitpattern.bdd.accepts(result, x % 2 ** len(cells)))
  ensures size: bitpattern.bdd.count(result, len(cells) + 2) == 4 * 2 ** count(c in cells: c == "?")

fn bitpattern.bdd.exactly_these(values: list<int>, width: i16) -> (bitpattern.bdd.BDD, int)
  requires width <= 200
  raises ValueError when exists(x in values: x < 0)
  ensures width: result.1 == imax(imax(width, 0), if len(values) == 0 then 0 else bit_length(max(x in values: x)))
  ensures accepts_values: all(x in values: bitpattern.bdd.accepts(result.0, x))
  ensures exact: result.1 <= 8 implies bitpattern.bdd.members(result.0, result.1) == sorted(filter(i in range(0, 2 ** result.1): i in values))
  ensures count: bitpattern.bdd.count(result.0, result.1) == len(filter(i in range(0, len(values)): not (values[i] in values[0:i])))

fn bitpattern.bdd.interval(start: int, stop: int, width: i16) -> bitpattern.bdd.BDD
  requires width <= 200
  raises ValueError when width < 0
  ensures count: bitpattern.bdd.count(result, width) == imax(0, imin(stop, 2 ** width) - imax(start, 0))
  ensures pointwise: width <= 8 implies all(x in range(0, 2 ** width): bitpattern.bdd.accepts(result, x) == (imax(start, 0) <= x and x < imin(stop, 2 ** width)))
  ensures empty_is_reject: imin(stop, 2 ** width) <= imax(start, 0) implies result.leaf and result.size == 0
  ensures full_is_accept: start <= 0 and stop >= 2 ** width implies result.leaf and result.size == 1
  ensures blocks_example: start == 3 and stop == 17 and width == 5 implies bitpattern.bdd.blocks(result, 5) == [(3, 0), (4, 2), (8, 3), (16, 0)]

fn bitpattern.bdd.lshift(node: bitpattern.bdd.BDD, by: i16) -> bitpattern.bdd.BDD
  requires by <= 200
  may_raise ValueError when by < 0
  ensures shifted: all(x in range(0, 128): bitpattern.bdd.accepts(result, x) == bitpattern.bdd.accepts(node, if by >= 0 then x >> by else x << (-by)))
  ensures bit: not node.leaf and by >= 0 implies result.bit == node.bit + by
  ensures leaves: node.leaf implies same_object(result, node)

fn bitpattern.bdd.freed_between(node: bitpattern.bdd.BDD, low_bit: u8, high_bit: u8) -> bitpattern.bdd.BDD
  requires high_bit <= 6
  ensures existential: low_bit < high_bit implies all(x in range(0, 64): bitpattern.bdd.accepts(result, x) == exists(y in range(0, 64): x >> high_bit == y >> high_bit and x % 2 ** low_bit == y % 2 ** low_bit and bitpattern.bdd.accepts(node, y)))
  ensures empty_range: low_bit >= high_bit implies same_object(result, node)
  ensures weaker: bitpattern.bdd.subset(node, result)

fn bitpattern.bdd.subset(a: bitpattern.bdd.BDD, b: bitpattern.bdd.BDD) -> bool
  ensures by_difference: result == (bitpattern.bdd.count(bitpattern.bdd.BDD.__sub__(a, b), imax(imax(a.bit, b.bit) + 1, 0)) == 0)
  ensures reflexive: bitpattern.bdd.subset(a, a)
  ensures pointwise: result implies all(x in range(0, 128): bitpattern.bdd.accepts(a, x) implies bitpattern.bdd.accepts(b, x))

fn bitpattern.bdd.disjoint(a: bitpattern.bdd.BDD, b: bitpattern.bdd.BDD) -> bool
  ensures by_intersection: result == (bitpattern.bdd.count(bitpattern.bdd.BDD.__and__(a, b), imax(imax(a.bit, b.bit) + 1, 0)) == 0)
  ensures complement: bitpattern.bdd.disjoint(a, bitpattern.bdd.BDD.__invert__(a))
  ensures pointwise: result implies all(x in range(0, 128): not (bitpattern.bdd.accepts(a, x) and bitpattern.bdd.accepts(b, x)))

# A diagram that tests no bit at or above width and agrees with node below 2 ** width.
fn bitpattern.bdd.narrowed(node: bitpattern.bdd.BDD, width: i16) -> bitpattern.bdd.BDD
  requires width <= 200
  raises ValueError when width < 0
  ensures narrow: result.bit < width
  ensures agrees: width <= 8 implies all(x in range(0, 2 ** width): bitpattern.bdd.accepts(result, x) == bitpattern.bdd.accepts(node, x))

# Decimal, except an exact power of two 2 ** k with k >= 10, written "2**k".
fn bitpattern.bdd.count_repr(total: int) -> string
  requires total >= 0
  ensures text: result == count_repr_text(total)
  ensures small: total < 1024 implies result == dec(total)

fn bitpattern.bdd.collect() -> int
  ensures nonnegative: result >= 0
  ensures version: bitpattern.__version__ == "0.3.0" and bitpattern.bdd.__version__ == "0.3.0"
  ensures match_args: bitpattern.bdd.BDD.__match_args__ == ("bit", "left", "right")
  ensures exports: same_object(bitpattern.BDDSet, bitpattern.codecs.BDDSet) and same_object(bitpattern.Codec, bitpattern.codecs.Codec) and same_object(bitpattern.OrderedCodec, bitpattern.codecs.OrderedCodec)

fn bitpattern.bdd.stats() -> map<string, int>
  ensures keys: sorted(keys(result)) == ["free", "memo", "memo_room", "nodes", "room", "wrapped"]
  ensures nonnegative: all(v in values(result): v >= 0)

# -- 1. IntSet: repr and export ----------------------------------------------------

# At most ten members: all of them. More: the first four and the last two, then the size.
fn variant.IntSet_repr(s: bitpattern.intset.IntSet) -> string
  ensures listed: s.size <= 10 implies result == "IntSet([" + join_ints(s.head(10)) + "], width=" + dec(s.width) + ")"
  ensures abbreviated: s.size > 10 implies result == "IntSet([" + join_ints(s.head(4)) + ", ..., " + dec(s.last(2)[1]) + ", " + dec(s.last(2)[0]) + "], size=" + count_repr_text(s.size) + ", width=" + dec(s.width) + ")"

fn bitpattern.intset.IntSet.__dlpack_device__(self) -> (int, int)
  ensures host_memory: result == (1, 0)

# numpy.from_dlpack(s) -> its dtype name, shape and flattened items.
fn numpy.from_dlpack(s: bitpattern.intset.IntSet) -> (string, list<int>, list<int>)
  requires s.size <= 512
  ensures dtype: result.0 == (if s.size == 0 then "uint8" else if s.width <= 8 then "uint8" else if s.width <= 16 then "uint16" else if s.width <= 32 then "uint32" else if s.width <= 64 then "uint64" else "uint8")
  ensures narrow_values: s.size > 0 and s.width <= 64 implies result.1 == [s.size] and result.2 == s.head(s.size)
  ensures wide_rows: s.size > 0 and s.width > 64 implies result.1 == [s.size, (s.width + 7) // 8]
  ensures big_endian: s.size > 0 and s.width > 64 implies result.2 == map(i in range(0, s.size * ((s.width + 7) // 8)): (s.head(s.size)[i // ((s.width + 7) // 8)] >> (8 * ((s.width + 7) // 8 - 1 - i % ((s.width + 7) // 8)))) % 256)
  ensures empty: s.size == 0 implies len(result.2) == 0

# __dlpack__(stream, max_version, dl_device, copy): a stream raises ValueError, another
# device or copy=False raises BufferError.
fn bitpattern.intset.IntSet.__dlpack__(self, stream: option<i64>, max_version: option<(int, int)>, dl_device: option<(int, int)>, copy: option<bool>)
  requires self.size <= 512
  raises ValueError when is_some(stream)
  raises BufferError when is_none(stream) and ((is_some(dl_device) and unwrap(dl_device) != (1, 0)) or (is_some(copy) and not unwrap(copy)))

# -- 2. Pattern --------------------------------------------------------------------

model bitpattern.pattern.Pattern
  observe width: int
  observe size: int
  observe bdd: bitpattern.bdd.BDD
  observe head(n: int): list<int> = builtins.list(itertools.islice(self, n))
  observe last(n: int): list<int> = builtins.list(itertools.islice(builtins.reversed(self), n))
  observe has(x: int): bool = operator.contains(self, x)
  observe branch_list(n: int): list<string> = builtins.list(itertools.islice(builtins.getattr(self, "branches"), n))
  build variant.Pattern_cells(cells: list<"0" | "1" | "?">)
  build bitpattern.pattern.Pattern.__or__(a: bitpattern.pattern.Pattern, b: bitpattern.intset.IntSet)
  build bitpattern.pattern.Pattern.__and__(a: bitpattern.pattern.Pattern, b: bitpattern.intset.IntSet)
  build bitpattern.pattern.Pattern.__invert__(a: bitpattern.pattern.Pattern)
  build bitpattern.pattern.Pattern.widened(a: bitpattern.pattern.Pattern, width: i8)
  build bitpattern.pattern.Pattern.from_bdd(node: bitpattern.bdd.BDD, width: i8)
  invariant bounded: size <= 2 ** width
  invariant ascending: size <= 512 implies is_sorted(head(size)) and distinct(head(size))
  invariant below_universe: size <= 512 implies all(x in head(size): 0 <= x and x < 2 ** width)

# Pattern(text) over the tokens of the syntax: quartets of 0 1 ? with at most one * each,
# split on dots, the first quartet of one to four bits.
fn variant.Pattern_new(tokens: list<"0" | "1" | "?" | "*" | "." | "|">) -> bitpattern.pattern.Pattern
  raises ValueError when pat_invalid(tokens)
  may_raise ValueError when pat_ambiguous(tokens)
  ensures width: pat_width(tokens) == result.width
  ensures size: result.size == 2 ** pat_free(tokens)
  ensures single_branch: len(result.branch_list(2)) == 1
  ensures bits: not pat_has_star(tokens) implies bitpattern.pattern.Pattern.bits(result) == pat_bits(tokens)
  ensures dotted_branch: not pat_has_star(tokens) implies result.branch_list(2) == [dotted(pat_bits(tokens))]
  ensures free: not pat_has_star(tokens) implies bitpattern.pattern.Pattern.free(result) == pat_free(tokens)
  ensures members: not pat_has_star(tokens) and result.width <= 9 implies elems_p(result) == filter(x in range(0, 2 ** result.width): path_matches(pat_bits(tokens), x))

fn variant.Pattern_cells(cells: list<"0" | "1" | "?">) -> bitpattern.pattern.Pattern
  requires len(cells) > 0
  ensures width: result.width == len(cells)
  ensures size: result.size == 2 ** count(c in cells: c == "?")
  ensures bits: bitpattern.pattern.Pattern.bits(result) == from_codepoints(map(c in cells: if c == "0" then 48 else if c == "1" then 49 else 63))
  ensures free: bitpattern.pattern.Pattern.free(result) == count(c in cells: c == "?")
  ensures str: variant.Pattern_str(result) == dotted(bitpattern.pattern.Pattern.bits(result))
  ensures matches: result.width <= 9 implies elems_p(result) == filter(x in range(0, 2 ** result.width): cells_match(cells, x))

# The expanded bits of a single-branch pattern; ValueError for none or several branches.
fn bitpattern.pattern.Pattern.bits(self) -> string
  raises ValueError when len(self.branch_list(2)) != 1
  ensures expanded: result == undot(self.branch_list(1)[0])
  ensures width: len(result) == self.width

fn bitpattern.pattern.Pattern.free(self) -> int
  raises ValueError when len(self.branch_list(2)) != 1
  ensures question_marks: result == free_count(self.branch_list(1)[0])
  ensures size: self.size == 2 ** result

# Branches: single-branch patterns in dotted form, disjoint, covering, ordered by their
# smallest member, determined by the set and the width.
fn bitpattern.pattern.Pattern.branches(self) -> list<string>
  ensures empty: (self.size == 0) == (len(result) == 0)
  ensures dotted_form: all(b in result: dotted(undot(b)) == b and len(undot(b)) == self.width)
  ensures exact_cover: self.width >= 1 and self.width <= 9 implies all(x in range(0, 2 ** self.width): count(b in result: bmatch(b, x)) == (if x in elems_p(self) then 1 else 0))
  ensures by_smallest: self.width >= 1 and self.width <= 40 implies is_sorted(map(b in result: smallest(b))) and distinct(map(b in result: smallest(b)))
  ensures sizes: self.width >= 1 and self.width <= 40 and len(result) <= 512 implies sum(b in result: 2 ** free_count(b)) == self.size
  relates set_and_width_only: result == bitpattern.pattern.Pattern.branches(bitpattern.pattern.Pattern.from_bdd(self.bdd, self.width))

fn variant.Pattern_str(p: bitpattern.pattern.Pattern) -> string
  ensures empty: p.size == 0 implies result == ""
  ensures one: len(p.branch_list(9)) == 1 implies result == p.branch_list(1)[0]
  ensures two: len(p.branch_list(9)) == 2 implies result == p.branch_list(2)[0] + " | " + p.branch_list(2)[1]
  ensures three: len(p.branch_list(9)) == 3 implies result == p.branch_list(3)[0] + " | " + p.branch_list(3)[1] + " | " + p.branch_list(3)[2]

fn variant.Pattern_repr(p: bitpattern.pattern.Pattern) -> string
  ensures zero_width: p.width == 0 and not is_big_pow2(p.size) implies result == "<Pattern: width=0, size=" + dec(p.size) + ">"
  ensures empty: p.width >= 1 and p.size == 0 implies result == "~Pattern('" + dotted(from_codepoints(map(i in range(0, p.width): 63))) + "')"
  ensures one: p.width >= 1 and p.width <= 40 and len(p.branch_list(9)) == 1 implies result == "Pattern('" + p.branch_list(1)[0] + "')"
  ensures two: p.width >= 1 and p.width <= 40 and len(p.branch_list(9)) == 2 implies result == "Pattern('" + p.branch_list(2)[0] + "') | Pattern('" + p.branch_list(2)[1] + "')"
  ensures three: p.width >= 1 and p.width <= 40 and len(p.branch_list(9)) == 3 implies result == "Pattern('" + p.branch_list(3)[0] + "') | Pattern('" + p.branch_list(3)[1] + "') | Pattern('" + p.branch_list(3)[2] + "')"
  ensures summary: p.width >= 1 and len(p.branch_list(9)) > 8 and not is_big_pow2(p.size) implies result == "<Pattern: " + dec(len(p.branch_list(100000))) + " branches, width=" + dec(p.width) + ", size=" + dec(p.size) + ">"

fn bitpattern.pattern.Pattern.from_bdd(bdd: bitpattern.bdd.BDD, width: i16) -> bitpattern.pattern.Pattern
  requires width <= 200
  raises ValueError when bdd.bit >= width
  ensures width: result.width == width
  ensures size: width >= 0 and width <= 127 implies result.size == bitpattern.bdd.count(bdd, width)
  ensures members: width <= 8 implies elems_p(result) == filter(x in range(0, 2 ** width): bitpattern.bdd.accepts(bdd, x))

# Operators keep the type of the left operand.
fn bitpattern.pattern.Pattern.__or__(self, other: bitpattern.intset.IntSet) -> bitpattern.pattern.Pattern
  ensures members: self.size <= 512 and other.size <= 512 implies same_members(elems_p(result), elems_p(self) + elems(other))
  ensures width: result.width == imax(self.width, other.width)

fn bitpattern.pattern.Pattern.__and__(self, other: bitpattern.intset.IntSet) -> bitpattern.pattern.Pattern
  ensures members: self.size <= 512 and other.size <= 512 implies same_members(elems_p(result), inter_of(elems_p(self), elems(other)))
  ensures width: result.width == imax(self.width, other.width)

fn bitpattern.pattern.Pattern.__invert__(self) -> bitpattern.pattern.Pattern
  ensures width: result.width == self.width
  ensures size: result.size == 2 ** self.width - self.size
  ensures members: self.width <= 9 implies elems_p(result) == filter(x in range(0, 2 ** self.width): not (x in elems_p(self)))

fn bitpattern.pattern.Pattern.widened(self, width: int) -> bitpattern.pattern.Pattern
  requires width <= 200
  ensures width: result.width == imax(self.width, width)
  ensures same_size: result.size == self.size
  ensures single_branch_dotted: width <= 64 and len(self.branch_list(2)) == 1 implies result.branch_list(2) == [dotted(from_codepoints(map(i in range(0, imax(width - self.width, 0)): 48)) + undot(self.branch_list(1)[0]))]
  relates equal_to_original: variant.Pattern_eq_pattern(result, self)

fn bitpattern.pattern.Pattern.__sub__(self, other: bitpattern.intset.IntSet) -> bitpattern.pattern.Pattern
  ensures members: self.size <= 512 and other.size <= 512 implies same_members(elems_p(result), minus_of(elems_p(self), elems(other)))
  ensures width: result.width == imax(self.width, other.width)

fn bitpattern.pattern.Pattern.__xor__(self, other: bitpattern.intset.IntSet) -> bitpattern.pattern.Pattern
  ensures members: self.size <= 512 and other.size <= 512 implies same_members(elems_p(result), xor_of(elems_p(self), elems(other)))
  ensures width: result.width == imax(self.width, other.width)

# A built-in iterable on the left gives the right operand's type, except for `-`, a plain IntSet.
fn variant.Pattern_ror_list(p: bitpattern.pattern.Pattern, other: list<u8>) -> bitpattern.pattern.Pattern
  ensures members: p.size <= 512 implies same_members(elems_p(result), elems_p(p) + other)

fn variant.Pattern_rsub_list(p: bitpattern.pattern.Pattern, other: list<u8>) -> bitpattern.intset.IntSet
  ensures members: p.size <= 512 implies same_members(elems(result), filter(x in other: not (x in elems_p(p))))

# Slices stay Patterns.
fn variant.Pattern_slice(p: bitpattern.pattern.Pattern, start: option<int>, stop: option<int>, step: option<int>) -> bitpattern.pattern.Pattern
  may_raise ValueError when is_some(step) and unwrap(step) == 0
  ensures members: p.size <= 512 and (is_none(step) or unwrap(step) != 0) implies same_members(elems_p(result), map(i in slice_positions(start, stop, if is_none(step) then 1 else unwrap(step), p.size): elems_p(p)[i]))
  ensures width: result.width == p.width

# Equality ignores width, across Pattern and IntSet.
fn bitpattern.pattern.Pattern.__eq__(self, other: bitpattern.intset.IntSet) -> bool
  ensures members: self.size <= 512 and other.size <= 512 implies result == same_members(elems_p(self), elems(other))
  ensures same_set: bitpattern.pattern.Pattern.__eq__(self, bitpattern.IntSet.from_bdd(self.bdd, self.width))

fn variant.Pattern_eq_pattern(a: bitpattern.pattern.Pattern, b: bitpattern.pattern.Pattern) -> bool
  ensures members: a.size <= 512 and b.size <= 512 implies result == same_members(elems_p(a), elems_p(b))
  ensures symmetric: result == variant.Pattern_eq_pattern(b, a)

fn variant.Pattern_hash(p: bitpattern.pattern.Pattern) -> int
  relates widths_and_types: builtins.hash(bitpattern.intset.IntSet.widened(bitpattern.IntSet.from_bdd(p.bdd, p.width), 200)) == result


# -- 3. Codecs: Codec and Int ------------------------------------------------------
#
# A frozen dataclass crosses as a record of its fields, and a record cannot hold an object
# the host builds, so a BDDSet is the record (codec, storage) and a function of a set takes
# the codec and the storage IntSet separately, with the storage widened to the codec's
# width (support.py). Record names are unqualified; test_bitpattern.py maps them to the
# classes. One spec file can hold the BDDSet of one codec class, so Int is here and the
# other codecs are in their own files.

record Codec { width: u8, name: string }
record Int { width: u8, name: string, signed: bool }
record BDDSet { codec: Int, storage: bitpattern.intset.IntSet }

const bitpattern.codecs.int8: Int
const bitpattern.codecs.int16: Int
const bitpattern.codecs.int32: Int
const bitpattern.codecs.int64: Int
const bitpattern.codecs.int128: Int
const bitpattern.codecs.uint8: Int
const bitpattern.codecs.uint16: Int
const bitpattern.codecs.uint32: Int
const bitpattern.codecs.uint64: Int
const bitpattern.codecs.uint128: Int

# The codecs of the table: int8 ... int128 and uint8 ... uint128.
fn variant.Int_named(kind: "int8" | "int16" | "int32" | "int64" | "int128" | "uint8" | "uint16" | "uint32" | "uint64" | "uint128") -> Int
  ensures name: result.name == kind
  ensures width: result.width == (if kind == "int8" or kind == "uint8" then 8 else if kind == "int16" or kind == "uint16" then 16 else if kind == "int32" or kind == "uint32" then 32 else if kind == "int64" or kind == "uint64" then 64 else 128)
  ensures signed: result.signed == (kind == "int8" or kind == "int16" or kind == "int32" or kind == "int64" or kind == "int128")
  ensures min: bitpattern.codecs.Int.min(result) == int_min(result)
  ensures max: bitpattern.codecs.Int.max(result) == int_max(result)
  ensures dtype: bitpattern.codecs.Int.dtype(result) == int_dtype(result)
  ensures dtype_table: (kind == "int8" implies bitpattern.codecs.Int.dtype(result) == "INT8") and (kind == "int64" implies bitpattern.codecs.Int.dtype(result) == "INT64") and (kind == "uint16" implies bitpattern.codecs.Int.dtype(result) == "UINT16") and (kind == "int128" implies bitpattern.codecs.Int.dtype(result) == "UINT8") and (kind == "uint128" implies bitpattern.codecs.Int.dtype(result) == "UINT8")
  ensures wrap_around: kind == "int8" implies bitpattern.codecs.Int.decode(result, 128) == -128 and bitpattern.codecs.Int.encode(result, -1) == 255

fn variant.Int_new(width: u8, name: string, signed: bool) -> Int
  ensures fields: result.width == width and result.name == name and result.signed == signed

# repr(codec) is its name.
fn variant.Codec_repr(c: Int) -> string
  ensures name: result == c.name

# Codecs compare and hash by class and field values.
fn variant.Int_eq(a: Int, b: Int) -> bool
  ensures by_fields: result == (a.width == b.width and a.name == b.name and a.signed == b.signed)

fn variant.Int_hash(c: Int) -> int
  relates equal_codecs: variant.Int_hash(variant.Int_new(c.width, c.name, c.signed)) == result

# Assigning a field of a frozen dataclass raises FrozenInstanceError.
fn variant.Int_setattr(c: Int, name: "width" | "name" | "signed", value: i8)
  raises dataclasses.FrozenInstanceError when true

fn bitpattern.codecs.Codec.encode(c: Codec, value: int) -> int
  raises NotImplementedError when true

fn bitpattern.codecs.Codec.dtype(c: Codec) -> "UINT8" | "UINT16" | "UINT32" | "UINT64"
  ensures narrowest_unsigned: result == unsigned_dtype(c.width)

fn bitpattern.codecs.Int.encode(codec: Int, value: int) -> int
  requires codec.width >= 1
  raises ValueError when not int_encodable(codec, value)
  ensures twos_complement: result == value % 2 ** codec.width
  ensures in_universe: 0 <= result and result < 2 ** codec.width

fn variant.Int_encode_float(codec: Int, value: f64) -> int
  requires codec.width >= 1
  raises TypeError when true

fn variant.Int_encode_string(codec: Int, value: string) -> int
  requires codec.width >= 1
  raises TypeError when true

fn bitpattern.codecs.Int.decode(codec: Int, b: int) -> int
  requires codec.width >= 1 and 0 <= b and b < 2 ** codec.width
  ensures wraps: result == int_decode(codec, b)
  ensures roundtrip: bitpattern.codecs.Int.encode(codec, result) == b
  ensures encodable: int_encodable(codec, result)

fn bitpattern.codecs.Int.min(codec: Int) -> int
  requires codec.width >= 1
  ensures smallest: result == int_min(codec)

fn bitpattern.codecs.Int.max(codec: Int) -> int
  requires codec.width >= 1
  ensures largest: result == int_max(codec)

fn bitpattern.codecs.Int.dtype(codec: Int) -> "INT8" | "INT16" | "INT32" | "INT64" | "UINT8" | "UINT16" | "UINT32" | "UINT64"
  requires codec.width >= 1
  ensures narrowest: result == int_dtype(codec)

# The sets a codec makes. A BDDSet holds the storage of its codec's width.
fn bitpattern.codecs.Int.all(codec: Int) -> BDDSet
  requires codec.width >= 1
  ensures universe: result.storage.size == 2 ** codec.width and result.storage.width == codec.width
  ensures codec: result.codec == codec

fn bitpattern.codecs.Int.none(codec: Int) -> BDDSet
  requires codec.width >= 1
  ensures empty: result.storage.size == 0 and result.storage.width == codec.width

fn bitpattern.codecs.Int.set(codec: Int, values: list<int>) -> BDDSet
  requires codec.width >= 1
  raises ValueError when exists(v in values: not int_encodable(codec, v))
  ensures codec: result.codec == codec
  ensures width: result.storage.width == codec.width
  ensures encodings: codec.width <= 9 and result.storage.size <= 512 implies same_members(elems(result.storage), map(v in values: v % 2 ** codec.width))
  ensures members: codec.width <= 9 implies all(v in values: result.storage.has(v % 2 ** codec.width))

# Bounds are clamped to [min, max + 1] rather than encoded.
fn bitpattern.codecs.Int.range(codec: Int, start: option<int>, stop: option<int>) -> BDDSet
  requires codec.width >= 1
  ensures codec: result.codec == codec
  ensures width: result.storage.width == codec.width
  ensures size: result.storage.size == imax(0, imin(if is_none(stop) then int_max(codec) + 1 else unwrap(stop), int_max(codec) + 1) - imax(if is_none(start) then int_min(codec) else unwrap(start), int_min(codec)))
  ensures encodings: codec.width <= 9 implies same_members(elems(result.storage), map(v in range(imax(if is_none(start) then int_min(codec) else unwrap(start), int_min(codec)), imin(if is_none(stop) then int_max(codec) + 1 else unwrap(stop), int_max(codec) + 1)): v % 2 ** codec.width))
  ensures all_when_unbounded: is_none(start) and is_none(stop) implies result.storage.size == 2 ** codec.width

fn variant.Int_range_floats(codec: Int, start: f64, stop: f64) -> BDDSet
  requires codec.width >= 1
  raises TypeError when true

# pattern(text) is the values whose encodings match the pattern: ValueError unless it is
# valid and as wide as the codec.
fn variant.Int_pattern(codec: Int, tokens: list<"0" | "1" | "?" | "*" | "." | "|">) -> BDDSet
  requires codec.width >= 1
  raises ValueError when pat_invalid(tokens) or (not pat_ambiguous(tokens) and pat_width(tokens) != codec.width)
  may_raise ValueError when pat_ambiguous(tokens)
  ensures width: result.storage.width == codec.width
  ensures size: result.storage.size == 2 ** pat_free(tokens)
  ensures members: not pat_has_star(tokens) and codec.width <= 9 implies elems(result.storage) == filter(x in range(0, 2 ** codec.width): path_matches(pat_bits(tokens), x))

# -- 3. BDDSet over Int ------------------------------------------------------------

# BDDSet(codec, storage): ValueError unless the storage has the codec's width; the fields
# are read-only.
fn variant.BDDSet_new(codec: Int, storage: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1
  raises ValueError when storage.width != codec.width
  ensures fields: result.codec == codec and bitpattern.intset.IntSet.__eq__(result.storage, storage)

fn variant.BDDSet_setattr(codec: Int, storage: bitpattern.intset.IntSet, name: "codec" | "storage") -> int
  requires codec.width >= 1 and storage.width <= codec.width
  raises dataclasses.FrozenInstanceError when true

# Equal sets hash alike.
fn variant.BDDSet_hash(codec: Int, storage: bitpattern.intset.IntSet) -> int
  requires codec.width >= 1 and storage.width <= codec.width
  relates widths_do_not_matter: variant.BDDSet_hash(codec, bitpattern.intset.IntSet.widened(storage, codec.width)) == result

fn bitpattern.codecs.BDDSet.size(codec: Int, storage: bitpattern.intset.IntSet) -> int
  requires codec.width >= 1 and storage.width <= codec.width
  ensures storage_size: result == storage.size

fn bitpattern.codecs.BDDSet.__contains__(codec: Int, storage: bitpattern.intset.IntSet, v: int) -> bool
  requires codec.width >= 1 and storage.width <= codec.width
  ensures encoded_and_stored: result == (int_encodable(codec, v) and storage.has(v % 2 ** codec.width))

fn variant.BDDSet_contains_float(codec: Int, storage: bitpattern.intset.IntSet, v: f64) -> bool
  requires codec.width >= 1 and storage.width <= codec.width
  ensures never: not result

fn bitpattern.codecs.BDDSet.__getitem__(codec: Int, storage: bitpattern.intset.IntSet, i: int) -> int
  requires codec.width >= 1 and storage.width <= codec.width
  raises IndexError when i < -storage.size or i >= storage.size
  ensures decoded: result == int_decode(codec, bitpattern.intset.IntSet.__getitem__(storage, i))
  ensures encodes_back: bitpattern.codecs.Int.encode(codec, result) == bitpattern.intset.IntSet.__getitem__(storage, i)

fn variant.BDDSet_slice(codec: Int, storage: bitpattern.intset.IntSet, start: option<int>, stop: option<int>, step: option<int>) -> BDDSet
  requires codec.width >= 1 and storage.width <= codec.width
  may_raise ValueError when is_some(step) and unwrap(step) == 0
  ensures codec: result.codec == codec
  ensures storage_slice: bitpattern.intset.IntSet.__eq__(result.storage, variant.IntSet_slice(storage, start, stop, step))

fn bitpattern.codecs.BDDSet.index(codec: Int, storage: bitpattern.intset.IntSet, v: int, start: int = 0, stop: option<int> = none) -> int
  requires codec.width >= 1 and storage.width <= codec.width
  raises ValueError when not int_encodable(codec, v) or not storage.has(v % 2 ** codec.width) or storage.rank(v % 2 ** codec.width) < slice_lo(some(start), storage.size, 1) or storage.rank(v % 2 ** codec.width) >= slice_hi(stop, storage.size, 1)
  ensures position: result == bitpattern.intset.IntSet.index(storage, v % 2 ** codec.width, start, stop)

fn bitpattern.codecs.BDDSet.count(codec: Int, storage: bitpattern.intset.IntSet, v: int) -> int
  requires codec.width >= 1 and storage.width <= codec.width
  ensures zero_or_one: result == (if int_encodable(codec, v) and storage.has(v % 2 ** codec.width) then 1 else 0)

# ~s == s.codec.all - s.
fn bitpattern.codecs.BDDSet.__invert__(codec: Int, storage: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1 and storage.width <= codec.width
  ensures codec: result.codec == codec
  ensures complement: bitpattern.intset.IntSet.__eq__(result.storage, bitpattern.intset.IntSet.__invert__(bitpattern.intset.IntSet.widened(storage, codec.width)))
  ensures size: result.storage.size == 2 ** codec.width - storage.size

fn bitpattern.codecs.BDDSet.__or__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures codec: result.codec == codec
  ensures union: bitpattern.intset.IntSet.__eq__(result.storage, bitpattern.intset.IntSet.__or__(a, b))

fn bitpattern.codecs.BDDSet.__and__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures codec: result.codec == codec
  ensures intersection: bitpattern.intset.IntSet.__eq__(result.storage, bitpattern.intset.IntSet.__and__(a, b))

fn bitpattern.codecs.BDDSet.__sub__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures codec: result.codec == codec
  ensures difference: bitpattern.intset.IntSet.__eq__(result.storage, bitpattern.intset.IntSet.__sub__(a, b))

fn bitpattern.codecs.BDDSet.__xor__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures codec: result.codec == codec
  ensures symmetric_difference: bitpattern.intset.IntSet.__eq__(result.storage, bitpattern.intset.IntSet.__xor__(a, b))

fn bitpattern.codecs.BDDSet.__le__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures subset: result == bitpattern.intset.IntSet.__le__(a, b)

fn bitpattern.codecs.BDDSet.__lt__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures proper_subset: result == bitpattern.intset.IntSet.__lt__(a, b)

fn bitpattern.codecs.BDDSet.__ge__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures superset: result == bitpattern.intset.IntSet.__ge__(a, b)

fn bitpattern.codecs.BDDSet.__gt__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures proper_superset: result == bitpattern.intset.IntSet.__gt__(a, b)

fn bitpattern.codecs.BDDSet.isdisjoint(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures disjoint: result == (bitpattern.intset.IntSet.__and__(a, b).size == 0)

# Equal iff both are BDDSets with equal codecs and the same encodings.
fn bitpattern.codecs.BDDSet.__eq__(codec: Int, a: bitpattern.intset.IntSet, b: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width and b.width <= codec.width
  ensures same_encodings: result == bitpattern.intset.IntSet.__eq__(a, b)

# Only sets of an equal codec combine: another codec, a built-in set, a list or an IntSet
# raise TypeError; == never raises.
fn variant.BDDSet_or_other_codec(codec: Int, a: bitpattern.intset.IntSet, other_codec: Int, b: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1 and other_codec.width >= 1 and a.width <= codec.width and b.width <= other_codec.width
  raises TypeError when codec.width != other_codec.width or codec.name != other_codec.name or codec.signed != other_codec.signed

fn variant.BDDSet_or_list(codec: Int, a: bitpattern.intset.IntSet, other: list<u8>) -> BDDSet
  requires codec.width >= 1 and a.width <= codec.width
  raises TypeError when true

fn variant.BDDSet_or_intset(codec: Int, a: bitpattern.intset.IntSet, other: bitpattern.intset.IntSet) -> BDDSet
  requires codec.width >= 1 and a.width <= codec.width
  raises TypeError when true

fn variant.BDDSet_le_intset(codec: Int, a: bitpattern.intset.IntSet, other: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width
  raises TypeError when true

fn variant.BDDSet_isdisjoint_list(codec: Int, a: bitpattern.intset.IntSet, other: list<u8>) -> bool
  requires codec.width >= 1 and a.width <= codec.width
  raises TypeError when true

fn variant.BDDSet_eq_intset(codec: Int, a: bitpattern.intset.IntSet, other: bitpattern.intset.IntSet) -> bool
  requires codec.width >= 1 and a.width <= codec.width
  ensures never: not result

fn variant.BDDSet_eq_list(codec: Int, a: bitpattern.intset.IntSet, other: list<u8>) -> bool
  requires codec.width >= 1 and a.width <= codec.width
  ensures never: not result

fn bitpattern.codecs.BDDSet.choice(codec: Int, storage: bitpattern.intset.IntSet, rng: random.Random) -> int
  requires codec.width >= 1 and storage.width <= codec.width
  raises IndexError when storage.size == 0
  ensures member: bitpattern.codecs.BDDSet.__contains__(codec, storage, result)

# repr: BDDSet(<codec name>, [v1, v2, ...]) with at most ten values, else the first four and
# the last two in encoding order and the size.
fn variant.BDDSet_repr(codec: Int, storage: bitpattern.intset.IntSet) -> string
  requires codec.width >= 1 and storage.width <= codec.width
  ensures listed: storage.size <= 10 implies result == "BDDSet(" + codec.name + ", [" + join_ints(map(b in storage.head(10): int_decode(codec, b))) + "])"
  ensures abbreviated: storage.size > 10 implies result == "BDDSet(" + codec.name + ", [" + join_ints(map(b in storage.head(4): int_decode(codec, b))) + ", ..., " + sdec(int_decode(codec, storage.last(2)[1])) + ", " + sdec(int_decode(codec, storage.last(2)[0])) + "], size=" + count_repr_text(storage.size) + ")"

# DLPack export of a BDDSet is in encoding order, with the codec's dtype.
fn variant.BDDSet_exported(codec: Int, storage: bitpattern.intset.IntSet) -> (string, list<int>, list<int>)
  requires codec.width >= 1 and codec.width <= 64 and storage.width <= codec.width and storage.size <= 512
  ensures dtype: storage.size > 0 implies result.0 == (if int_dtype(codec) == "INT8" then "int8" else if int_dtype(codec) == "INT16" then "int16" else if int_dtype(codec) == "INT32" then "int32" else if int_dtype(codec) == "INT64" then "int64" else if int_dtype(codec) == "UINT8" then "uint8" else if int_dtype(codec) == "UINT16" then "uint16" else if int_dtype(codec) == "UINT32" then "uint32" else "uint64")
  ensures values: storage.size > 0 implies result.2 == map(b in storage.head(storage.size): int_decode(codec, b))

# -- 6. DLPack: DType --------------------------------------------------------------

# DType.value is the DLPack (code, bits) pair; the properties are code and bits.
fn variant.DType_value(name: "INT8" | "INT16" | "INT32" | "INT64" | "UINT8" | "UINT16" | "UINT32" | "UINT64" | "FLOAT16" | "FLOAT32" | "FLOAT64" | "BFLOAT16" | "FLOAT8_E4M3FN" | "FLOAT8_E5M2") -> (int, int)
  ensures table: result == (if name == "INT8" then (0, 8) else if name == "INT16" then (0, 16) else if name == "INT32" then (0, 32) else if name == "INT64" then (0, 64) else if name == "UINT8" then (1, 8) else if name == "UINT16" then (1, 16) else if name == "UINT32" then (1, 32) else if name == "UINT64" then (1, 64) else if name == "FLOAT16" then (2, 16) else if name == "FLOAT32" then (2, 32) else if name == "FLOAT64" then (2, 64) else if name == "BFLOAT16" then (4, 16) else if name == "FLOAT8_E4M3FN" then (10, 8) else (12, 8))

# -- 5. strategies -----------------------------------------------------------------

# from_set(source) generates members only, and every member is reachable; its minimal
# example is the first member. The strategy cannot cross, so support.py draws examples.
fn bitpattern.strategies.from_set(source: bitpattern.intset.IntSet) -> list<int>
  ensures members: all(x in result: bitpattern.intset.IntSet.__contains__(source, x))
  ensures nothing_from_empty: source.size == 0 implies len(result) == 0
  ensures something_from_nonempty: source.size > 0 implies len(result) > 0

fn variant.from_set_minimal(source: bitpattern.intset.IntSet) -> int
  requires source.size > 0
  ensures first_member: result == source.head(1)[0]
