spec tuples

# Formal spec of bitpattern 0.3.0's Tuple codec, product and project (section 3.12), for
# tuples of two Int fields. A BDDSet is the record (codec, storage), so a set is given as
# its codec and its storage IntSet (support.py rebuilds it).

prelude "tuples.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)
  observe head(n: int): list<int> = builtins.list(itertools.islice(self, n))
  build bitpattern.IntSet(items: list<u8>)
  build bitpattern.IntSet.range(start: u8, stop: u8, width: option<i8>)

record Int { width: u8, name: string, signed: bool }
record Tuple { width: int, name: string, fields: list<Int> }
record BDDSet { codec: Tuple, storage: bitpattern.intset.IntSet }

# Tuple(*fields): the width is the sum of the field widths, the name "tuple[f1, f2, ...]",
# and fields the tuple of field codecs. Tuple() has width 0.
fn variant.Tuple_new(a: Int, b: Int) -> Tuple
  requires a.width >= 1 and b.width >= 1
  ensures width: result.width == a.width + b.width
  ensures name: result.name == "tuple[" + a.name + ", " + b.name + "]"
  ensures fields: len(result.fields) == 2 and result.fields[0] == a and result.fields[1] == b

fn variant.Tuple_empty() -> Tuple
  ensures width: result.width == 0
  ensures fields: len(result.fields) == 0
  ensures name: result.name == "tuple[]"

# The first field takes the most significant bits; each item is encoded by its field and
# that field's errors propagate. Lists are not tuples, and a tuple of the wrong length is a
# ValueError.
fn variant.Tuple_encode(a: Int, b: Int, x: int, y: int) -> int
  requires a.width >= 1 and b.width >= 1
  raises ValueError when not int_encodable(a, x) or not int_encodable(b, y)
  ensures lexicographic: result == (x % 2 ** a.width) * 2 ** b.width + y % 2 ** b.width

fn variant.Tuple_encode_list(a: Int, b: Int, x: int, y: int) -> int
  requires a.width >= 1 and b.width >= 1
  raises TypeError when true

fn variant.Tuple_encode_length(a: Int, b: Int, x: int) -> int
  requires a.width >= 1 and b.width >= 1
  raises ValueError when true

fn variant.Tuple_decode(a: Int, b: Int, bits: int) -> (int, int)
  requires a.width >= 1 and b.width >= 1 and 0 <= bits and bits < 2 ** (a.width + b.width)
  ensures fields: result.0 == int_decode(a, bits // 2 ** b.width) and result.1 == int_decode(b, bits % 2 ** b.width)

# product(*sets): all tuples (a, b) with a in the first set and b in the second; its size is
# the product of the sizes, and it is empty if any set is empty. product() is {()}.
fn variant.Tuple_product(ca: Int, a: bitpattern.intset.IntSet, cb: Int, b: bitpattern.intset.IntSet) -> BDDSet
  requires set_fits(ca, a, cb, b)
  ensures size: result.storage.size == a.size * b.size
  ensures width: result.storage.width == ca.width + cb.width and result.codec.width == ca.width + cb.width
  ensures codec: len(result.codec.fields) == 2 and result.codec.fields[0] == ca and result.codec.fields[1] == cb
  ensures pairs: all(x in range(0, 8): all(y in range(0, 8): x < 2 ** ca.width and y < 2 ** cb.width implies result.storage.has(x * 2 ** cb.width + y) == (a.has(x) and b.has(y))))
  ensures empty: (a.size == 0 or b.size == 0) implies result.storage.size == 0

fn variant.Tuple_product_nothing() -> BDDSet
  ensures unit_tuple: result.storage.size == 1 and result.storage.width == 0

# a * b is product(a, b); a right operand that is not a BDDSet raises TypeError.
fn variant.Tuple_mul(ca: Int, a: bitpattern.intset.IntSet, cb: Int, b: bitpattern.intset.IntSet) -> BDDSet
  requires set_fits(ca, a, cb, b)
  ensures like_product: result.storage.size == variant.Tuple_product(ca, a, cb, b).storage.size
  ensures same_pairs: all(x in range(0, 8): all(y in range(0, 8): x < 2 ** ca.width and y < 2 ** cb.width implies result.storage.has(x * 2 ** cb.width + y) == variant.Tuple_product(ca, a, cb, b).storage.has(x * 2 ** cb.width + y)))

fn variant.Tuple_mul_foreign(ca: Int, a: bitpattern.intset.IntSet, other: list<u8>) -> BDDSet
  requires ca.width >= 1 and a.width <= ca.width
  raises TypeError when true

# project(source, index): the values at position index; negative counts from the end. Its
# result is the storage and the name of the codec of the field.
fn variant.Tuple_project(ca: Int, a: bitpattern.intset.IntSet, cb: Int, b: bitpattern.intset.IntSet, index: i8) -> (bitpattern.intset.IntSet, string)
  requires set_fits(ca, a, cb, b)
  raises IndexError when index < -2 or index > 1
  ensures field_codec: result.1 == (if index == 0 or index == -2 then ca.name else cb.name)
  ensures project_first: (index == 0 or index == -2) and b.size > 0 implies result.0.size == a.size and all(x in range(0, 16): result.0.has(x) == a.has(x))
  ensures project_second: (index == 1 or index == -1) and a.size > 0 implies result.0.size == b.size and all(y in range(0, 16): result.0.has(y) == b.has(y))
  ensures empty_other_side: ((index == 0 or index == -2) and b.size == 0) or ((index == 1 or index == -1) and a.size == 0) implies result.0.size == 0

fn variant.Tuple_project_non_tuple(ca: Int, a: bitpattern.intset.IntSet, index: i8) -> (bitpattern.intset.IntSet, string)
  requires ca.width >= 1 and a.width <= ca.width
  raises TypeError when true
