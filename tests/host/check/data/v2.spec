spec v2sample

# Every v2 form: qualified names, planned calls, host operators, errors, constants,
# builds, observers with reading expressions and definitions.

error bitpattern.PatternError
error ValueError

const bitpattern.codecs.int8: bitpattern.Codec
const bitpattern.codecs.uint16: bitpattern.Codec

model bitpattern.Codec
  observe width: int

model bitpattern.IntSet
  observe width: int
  observe members: list<int> = builtins.list(self)
  observe size: int = len(members)
  observe has(x: int): bool = x in members
  build bitpattern.IntSet.range(start: int, stop: int)
  build bitpattern.IntSet(items: list<int>, width: int = 0)
  invariant ascending: is_sorted(members)
  invariant counted: size == bitpattern.IntSet.__len__(self)

fn bitpattern.IntSet.range(start: int, stop: int) -> bitpattern.IntSet
  requires start <= stop
  raises ValueError when start < 0
  may_raise bitpattern.PatternError when stop > 1 << 20
  ensures members: result.members == range(start, stop)

fn bitpattern.IntSet.__len__(self) -> int
  ensures size: result == self.size

fn bitpattern.IntSet.__contains__(self, x: int) -> bool
  ensures member: result == (x in self.members)

fn bitpattern.IntSet.__or__(self, other: bitpattern.IntSet) -> bitpattern.IntSet
  ensures union: result.size <= self.size + other.size
  ensures has: bitpattern.IntSet.__contains__(self, 3) implies bitpattern.IntSet.__contains__(result, 3)
  relates commutes: bitpattern.IntSet.__or__(other, self).members == result.members

fn bitpattern.IntSet.add(self, x: int)
  modifies self
  ensures grew: bitpattern.IntSet.__contains__(self, x)

fn bitpattern.encode(codec: bitpattern.codecs.int8 | bitpattern.codecs.uint16, x: int) -> int
  requires pow2(8) == 256 and mask(4) == 15
  ensures kind: codec == bitpattern.codecs.int8 implies result >= 0
  ensures width: bitpattern.codecs.int8.width == 8 and bitpattern.codecs.uint16.width == 16

fn pow2(k: int) -> int = 2 ** k
fn mask(width: int) -> int = pow2(width) - 1
fn low_bits(x: int, w: int) -> int = x & mask(w)
fn set_bit(x: int, i: int) -> int = x | (1 << i)
fn shifted(x: int, i: int) -> int = (x >> i) << i

fn bitpattern.popcount(x: u64) -> int
  ensures bounded: result <= bit_length(x)
  ensures masked: bitpattern.popcount(x & 4294967295) <= 32
  ensures defs: low_bits(x, 8) == shifted(low_bits(x, 8), 0) and set_bit(0, 3) == 8

fn text_roundtrip(cps: list<int>) -> string
  ensures length: len(result) == len(cps)
  ensures back: result == from_codepoints(cps)

fn near(x: f64, y: f64) -> bool
  ensures close: result implies qe(x, y).steps <= 1 and qe(x, y).nans == 0
  ensures parts: steps(qe(x, y)) == qe(x, y).steps and nans(qe(x, y)) == qe(x, y).nans

interface pkg.Deque<T: Eq>
  observe items: list<T>
  new empty() -> pkg.Deque
    ensures len(result.items) == 0
  method push(self, x: T)
    modifies self
    ensures self.items == old(self.items) + [x]
