spec bitpattern

# A sample in v2 syntax: every form the parser accepts beyond v1.

use "other.spec"
prelude "bitpattern.prelude"

error TypeError
error bitpattern.PatternError

const bitpattern.codecs.int8: bitpattern.Codec
const bitpattern.codecs.uint16: bitpattern.Codec

enum Side { left, right }
record Pair { first: int, second: int = 0 }
type Codecs = bitpattern.codecs.int8 | bitpattern.codecs.uint16
type Mode = "wrap" | "saturate"

model bitpattern.IntSet<T: Ord>
  observe width: int
  observe members: list<int> = builtins.list(self)
  observe has(x: int): bool = x in members
  build bitpattern.IntSet(items: list<int>, width: int = 8)
  build bitpattern.IntSet.range(lo: int, hi: int)
  invariant ascending: is_sorted(members)
  invariant -width ** 2 <= 0 or width >> 1 << 2 >= 0

fn bitpattern.IntSet.__or__(self, other: bitpattern.IntSet) -> bitpattern.IntSet
  partition other
    empty = bitpattern.IntSet.range(0, 0)
    rest = bitpattern.IntSet - empty
  requires self.width == other.width
  ensures members(result) == sorted(members(self) | members(other))
  raises bitpattern.PatternError when self.width != other.width
  may_raise bitpattern.PatternError
  may_raise late: bitpattern.PatternError when other.width > 64
  modifies self, other
  perf O(n log n) in the
    size of the sets

fn bitpattern.encode(x: int, codec: bitpattern.codecs.int8 | bitpattern.codecs.uint16) -> bytes
  ensures x ** 2 >= 0

fn cos(x: f64) -> f64
  unspecified rounding
  impl_defined payload

fn double(x: int) -> int = x * 2
fn clamp<T: Ord>(x: T, lo: T, hi: T) -> T =
  if x < lo then lo else if x > hi then hi else x

interface bitpattern.Stack<T>
  observe items: list<T>
  new empty() -> bitpattern.Stack<T>
  method push(self, x: T)
    ensures items(self) == items(old) | [x]
  method pop(self) -> T
    raises IndexError when len(items(self)) == 0
  invariant bounded: len(items) <= 10
