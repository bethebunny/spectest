# Writing the host in Mojo 1.2

The host builds with the venv's `mojo` (mojo-compiler 1.2.0). Every form below compiled
on 1.2. Much older Mojo material describes a different language, so when in doubt
compile a five-line probe: `uv run mojo run -I host -I host/vendor/bitpattern probe.mojo`.
A cached rerun takes about a second.

## Running code

- There is no `mojo test`. A test file is a program whose `main` runs a `TestSuite`:

  ```mojo
  from std.testing import assert_equal, assert_raises, assert_true, TestSuite

  def test_something() raises:
      assert_equal(1 + 1, 2)

  def main() raises:
      TestSuite.discover_tests[__functions_in_module()]().run()
  ```

  A failing test exits with 1. `tests/host/conftest.py` makes each
  `tests/host/**/test_*.mojo` one pytest item, which builds the file and runs it.
- Run one package or file: `uv run pytest tests/host/<dir or file> -n 0 -q -p no:cacheprovider`.
- Include roots are `-I host -I host/vendor/bitpattern`, plus `-I tests/host/lib` for
  test-only helpers. A package under `host/` needs an `__init__.mojo`. Import by module
  path: `from wire.value import Value`, `from arena import Arena`, `from bigint import BigUInt`.
- A file given to `mojo build` as the top-level module can't use relative imports. Use
  package paths there.
- A cold compile of a small test takes 4 to 10 s, and `mojo run` spends 1 to 3 s even
  when its cache is warm. So the conftest keeps each built test in `.mojo-tests/`,
  keyed by the compiler version, the test file and every module it imports. An
  unchanged test reruns at once. `-O0` is slower, and `-O1` equals `-O3`.
- The compiler's own cache (`~/.modular/cache`) keeps two entries per binary, and both
  cover the whole program. So test binaries share no work, and a cold test costs 6 to
  45 s. Source locations are part of the key: an edit that shifts lines misses for every
  test that reaches code below it. The conftest passes `-strip-file-prefix`, so builds
  of the same sources in different workspaces share entries.
- A Mojo test can scale its sample counts with `getenv("SPECTEST_STRENGTH")`: `dev` in
  the dev loop, `full` under `--ci`.
- The standard library is imported from `std`, eg. `from std.collections import Set`.
  `sort`, `swap`, `divmod`, `Array`, `materialize`, `atol`, `hex` and `Codepoint` need
  no import.

## Types and kinds

- A closed set of kinds is an `__enum`. A value takes one byte and prints as
  `NodeKind.STR`, and a `match` that misses a case gets a warning. An enum derives
  neither `__eq__` nor `__hash__`, so write each over the discriminant.

  ```mojo
  from std.hash import Hasher

  __enum NodeKind(Equatable, Hashable, ImplicitlyCopyable, Writable):
      case NUM
      case STR
      case CALL

      def __eq__(self, other: Self) -> Bool:
          return self._get_enum_discriminant() == other._get_enum_discriminant()

      def __hash__(self, mut hasher: Some[Hasher]):
          self._get_enum_discriminant().__hash__(hasher)
  ```

  `__enum` is undocumented, so a release may change it. Without `ImplicitlyCopyable`
  `NodeKind.NUM` doesn't compile, and without `Writable` it doesn't print. Case names
  can't be keywords (`if`, `in`, `not`), and an enum holds no `var` fields.
- Where the type is known, a case is written `.NUM`:
  `var kinds: List[NodeKind] = [.NUM, .CALL]`, `kind == .STR`,
  `return .NUM if literal else .CALL`.
- A case can carry a payload. Several payloads bind as one tuple.

  ```mojo
  __enum Token(ImplicitlyCopyable, Writable):
      case eof
      case name(String)
      case span(Int, Int)

  match token:
      case .eof:
          return "eof"
      case .name(text):
          return String(text)
      case .span(pair):
          return String(pair[0], "..", pair[1])
  ```
- No constructor builds a case from its integer. Write a `@staticmethod` with a `match`
  or a ternary. `Int(kind._get_enum_discriminant())` gives the integer.
- A code with an order is a newtype struct over an integer. Reflection derives `__eq__`
  and `__hash__`, `Comparable` needs only `__lt__`, and `match` compares the `comptime`
  members by value. Such a `match` isn't checked for missing cases, so it ends with
  `case _:`.

  ```mojo
  @fieldwise_init
  struct Op(Comparable, Hashable, TrivialRegisterPassable, Writable):
      var code: UInt8

      comptime OR = Self(2)
      comptime AND = Self(3)
      comptime EQ = Self(4)
      comptime GE = Self(9)

      def __lt__(self, other: Self) -> Bool:
          return self.code < other.code

  var is_comparison = Op.EQ <= op <= Op.GE
  ```
- An index into a table is a newtype struct too, like the arena's `Id`. Then a node id
  can't be passed where a line number is expected.

  ```mojo
  @fieldwise_init
  struct NodeId(Equatable, Hashable, TrivialRegisterPassable, Writable):
      var value: Int32
  ```
- A table of names is a `comptime` `Array`, materialized once before indexing:

  ```mojo
  comptime OP_NAMES: Array[StaticString, 4] = ["-", "implies", "or", "and"]

  var names = materialize[OP_NAMES]()
  print(names[k], StaticString("or") in names)
  ```
- Text maps to a case through a `match` on the string:

  ```mojo
  def op_named(text: String) -> Optional[Op]:
      match text:
          case "or":
              return Op.OR
          case "and":
              return Op.AND
          case _:
              return None
  ```

## Structs and traits

- Functions and methods are `def` with typed arguments. Constants and aliases are
  `comptime NAME = ...`.
- Declare a trait and write no method. `Equatable`, `Hashable`, `Writable`,
  `Defaultable` and `Copyable` are derived over every field, List, Optional and nested
  struct fields included.

  ```mojo
  @fieldwise_init
  struct Param(Copyable, Equatable, Hashable, Writable):
      var name: String
      var kind: NodeKind
      var default: Optional[Int]

  print(Param("x", .NUM, None))  # Param(name=x, kind=NodeKind.NUM, default=None)
  ```

  Write the method only for other behaviour, eg. `ast.Span` compares `start` and `end`
  and prints `line:col`. A float field holding NaN makes a value unequal to its copy.
- `Comparable` needs only `__lt__`, and `__eq__` is derived. Compare tuples for a
  lexicographic order.

  ```mojo
  def __lt__(self, other: Self) -> Bool:
      return (self.line, self.column) < (other.line, other.column)
  ```
- A struct field has no default. Write the `__init__`, with defaulted keyword-only
  arguments:

  ```mojo
  def __init__(out self, var name: String, *, depth: Int = 3, var tags: List[String] = []):
      self.name = name^
      self.depth = depth
      self.tags = tags^
  ```
- Several arguments of one type are keyword-only: `def span(*, start: Int, end: Int) -> Int`.
  `@fieldwise_init` takes keywords at call sites, `Param(name="y", kind=.STR, default=3)`,
  but can't require them.
- A constructor is `def __init__(out self, ...)`. A `var` argument takes ownership, and
  the caller moves with `^`. A value that isn't `ImplicitlyCopyable` copies only with
  `.copy()`.
- A small struct with no heap fields is `TrivialRegisterPassable` and copies implicitly.
- A trait method with a body is a default, `...` marks a required one, and `pass` gives
  an empty default.

  ```mojo
  trait Named:
      def name(self) -> String:
          ...

      def greeting(self) -> String:
          return String("hello ", self.name())
  ```
- An argument of any conforming type is `Some[Trait]`: `def describe(x: Some[Writable]) -> String`.
- A method returning an element names the element's origin:
  `def node(self, id: Int) -> ref [self.nodes[0]] Node`. `ref [self.nodes]` is rejected.
  Holding the reference across an `append` or `pop` is a compile error.
- A method that ends its struct takes `deinit self`:
  `def into_ast(deinit self) -> Ast: return self.ast^`. Moving a field out of a value
  that is used later fails ("destroyed out of the middle of a value"), so copy the
  field or consume the holder.
- A Span or pointer into a `String` field of `self` is invalidated by any later
  `mut self` call. Pass such bytes down as an argument from a string outside the struct.
- A recursive type keeps its children in flat tables indexed by id (`syntax/ast.mojo`)
  or behind `ArcPointer[Self]` (`wire/value.mojo`). A struct `A` holding `List[B]`,
  where `B` holds `ArcPointer[A]`, compiles alone but fails with "non-'Deinitable'
  type" once another module imports it. A defaulted argument of a recursive type in a
  helper's constructor fails the same way.
- `syntax.ast.Span` hides std's `Span` when imported. Alias one of them:
  `from syntax.ast import Span as SourceSpan`.

## Control flow and patterns

- A `match` replaces an if/elif chain on one value. Cases take alternatives, `as` and
  guards, and don't fall through. Strings match too.

  ```mojo
  match n:
      case 0:
          return "zero"
      case 1 | 2 | 3:
          return "small"
      case 404 as code:
          return String("not found ", code)
      case m if m < 0:
          return "negative"
      case _:
          return "big"
  ```
- A bare name in a case binds a new variable and matches anything, with only a warning.
  Compare with a constant as `case == NUM:` or through a dotted name, `case codes.NUM:`.
- Struct patterns match fields. A bound name is an immutable reference, `var x` copies
  and `ref x` writes through. Each alternative binds the same names.

  ```mojo
  match p:
      case Point(x=0, y=0):
          return "origin"
      case Point(x=var x, y=0) | Point(x=0, y=var x):
          return String("axis ", x)
      case _:
          return "else"
  ```
- Several values match at once: `match a > 0, b > 0:` with `case True, False:`.
- An Optional matches `case .Some(v):` and `case .None:`.
- List patterns match length and elements. They never count as exhaustive, so the
  function needs a trailing `return` or `case _:`.

  ```mojo
  match xs:
      case []:
          return "empty"
      case [x]:
          return String("one ", x)
      case [first, *rest]:
          return String(first, " and ", len(rest), " more")
  return "unreachable"
  ```
- `if case` tests one pattern and `while case` loops while it matches. Neither raises.

  ```mojo
  if case .Some(v) = d.get("a"):
      use(v)
  while case [*_, top] = stack:
      total += top
      _ = stack.pop()
  ```
- `comptime match T:` with `case == Int:` branches on a type or parameter.
- `if xs:` and `if not xs:` test emptiness of a List, String, Dict, Set or Span. Test
  an Optional with `is None` or `is not None`, since `Optional(0)` is true.
- The walrus assigns a variable declared on an earlier line:

  ```mojo
  var at: Int
  while (at := text.find("\n", start)) >= 0:
      start = at + 1
  ```

## Collections and literals

- Annotate a list literal: `var xs: List[Int] = [3, 1, 2]`, `var names: List[String] = []`.
  An unannotated `[1, 2, 3]` is a fixed-size `Array[Int, 3]`. `List[_]` infers the
  element type.
- Dict, Set and tuple literals: `var d: Dict[String, Int] = {"a": 1}`,
  `var s: Set[Int] = {1, 2}` (`from std.collections import Set`), `(1, "two")`,
  `var pairs: List[Tuple[String, Int]] = [("a", 1)]`.
- A list of `n` copies is `List[Int](length=n, fill=0)`.
- Comprehensions build lists, dicts and sets. They allocate, so keep hot sums as loops.

  ```mojo
  var squares = [x * x for x in xs if x > 1]
  var doubled = {x: x * 2 for x in xs}
  var residues = {x % 2 for x in xs}
  var any_big = any([x > 2 for x in xs])
  ```
- Lists take `in`, `count`, `extend` and `+`: `2 in xs`, `xs.count(2)`, `xs + [4]`.
- `xs.try_index(x)` is an `Optional[Int]`, so `xs.try_index(x).or_else(-1)` replaces an
  index-of loop. `xs.index(x)` raises. The value has the element's type:
  `names.try_index(String(name))`.
- The last element is `xs[len(xs) - 1]` when the list can't be empty. When it can,
  `if case [*_, last] = xs:` binds it, and `ref last` writes through.
- `xs[a:b]` is a Span view, and `List(xs[a:b])` copies it. Passing two slices of one
  `var` list to one call is an aliasing error.
- `sort` takes a comparator, a lambda or a nested `def` with a capture list, and
  `[stable=True]` keeps ties in order.

  ```mojo
  sort(xs, lambda (a: Int, b: Int) -> Bool: a > b)

  def by_key(a: Int, b: Int) {imm keys} -> Bool:
      return keys[a] < keys[b]
  sort(order, by_key)

  sort[stable=True](diagnostics, lambda (a: Diagnostic, b: Diagnostic) -> Bool: a.start < b.start)
  ```
- `max(a, b, c)` and `min` take separate values.
- `d.get(k)` is an Optional, and `d.get(k, 0)` and `d.pop(k, -1)` take a default.
  `d.setdefault(k, v)` returns a reference: `groups.setdefault(k, []).append(x)`.
  `d | e` merges, with `e` winning.
- A Dict key is `Hashable` and `Equatable`, and derived methods are enough.
- Sets take `|`, `&`, `-`, `^` and `<=`. `List(Set(words))` drops duplicates, and a
  `sort` then orders them.
- `Counter[String](words)` counts, and `counts[k]` is 0 for a missing key.
  `Deque[Int](1, 2)` has `appendleft` and `popleft`.
- `Array[Int, 4](fill=0)` is a fixed-size value array.
- `swap(a, b)` exchanges two values. It moves a list out of a field:

  ```mojo
  def finished(mut self) -> List[Token]:
      var tokens: List[Token] = []
      swap(tokens, self.tokens)
      return tokens^
  ```
- `Span(sorted_xs).binary_search_by(lambda (x: Int) {imm target} -> Int: x - target)`
  finds an exact match, or gives None.
- A module-level `comptime` list or Array is read through `materialize[NAMES]()`.

## Strings and bytes

- Messages are t-strings: `t"{name} takes {n} arguments"`, in `print`, `String(...)` and
  `Error(...)`. `{{` and `}}` are literal braces. `String(a, b, c)` joins Writables.
- `", ".join(xs)` joins any Writables, eg. Ints or structs with `write_to`.
- `s.byte_length()` counts bytes and `s.count_codepoints()` counts code points.
- `s.find(sub, start)` is a byte offset or -1. Bound the search with a view,
  `s[byte=a:b].find(sub)`, whose offsets count from `a`.
- `s.startswith(prefix, start, end)` tests a prefix at an offset without slicing.
- `s.removeprefix(p)` and `removesuffix` return a view, so wrap the result in
  `String(...)` to own it. Assigning it back to `s` is an aliasing error, so use a new
  name.
- `s.split(sep)`, `s.split(sep, maxsplit)` and `s.split()` (runs of whitespace) give
  StringSlices tied to `s`. Wrap one in `String(...)` to own it or to compare it with
  text from elsewhere. `splitlines()` also breaks at `\r`, `\x0b`, `\x0c` and others,
  so split at `"\n"` for the spec's lines.
- `s.strip(" \t")` strips exactly those bytes. `s.strip()` strips all ASCII whitespace,
  `\n` included.
- `s[byte=a:b]` slices by byte. `s.as_bytes()[i]` is a `UInt8`, compared as
  `Int(b) == ord("x")`.
- `for c in s.codepoints()` walks code points and `for b in s.as_bytes()` walks bytes.
  `for c in s` walks grapheme clusters.
- `Codepoint(b).is_ascii_digit()` and the other `is_ascii_*` predicates classify a byte.
  `Codepoint.from_u32(cp)` is None for a surrogate or past `0x10FFFF`.
- `StringSlice(s).is_codepoint_boundary(i)` tests a cut point.
- `hex(v, prefix="")` drops the `0x`, and `ascii_rjust(width, "0")` pads:
  `hex(10, prefix="").ascii_rjust(4, "0")` is `000a`.
- `chr(cp)` encodes a code point. `\u` in a literal takes four hex digits, `\U` eight.
- `String(unsafe_from_utf8=Span(bytes))` builds a String from a `List[UInt8]`, NULs
  included.
- A function that searches text takes a `StringSpan`, and a String passes as one. Then
  `find`, `lstrip` and the rest apply:

  ```mojo
  def line_end(text: StringSpan, start: Int) -> Int:
      var at = text.find("\n", start)
      return text.byte_length() if at < 0 else at

  var indent = line.byte_length() - line.lstrip(" \t").byte_length()
  ```
- Bytes that may not be UTF-8 get the same searches through a view:
  `StringSlice(unsafe_from_utf8=Span(needle)) in StringSlice(unsafe_from_utf8=Span(hay))`.
  `find`, `rfind`, `count` and `in` compare raw bytes, so they are right on any bytes.
  `UInt8(10) in span` finds one byte.
- `StringSpan(unsafe_from_utf8=src)` on a `Span[Byte, _]` parameter compiles in an
  imported module. In a file with a `main`, a function doing it must come after `main`,
  or the build fails with "recursive reference to declaration 'CStringSpan.__init__'".

## Numbers

- `Int` and `UInt64` arithmetic wraps without trapping. `//` and `%` floor, as Python's
  do. `divmod` is a builtin, and `ceildiv`, `gcd`, `lcm` and `clamp` come from `std.math`.
- `atol(text, base)` parses bases 2 to 36, and base 0 reads a `0x`, `0o` or `0b` prefix.
- `Int(text)` accepts spaces, a sign and underscores. A strict literal needs a guard:

  ```mojo
  if text.byte_length() > 18 or not text.is_ascii_digit():
      return None
  try:
      return Int(text)
  except:
      return None
  ```
- `atof(text)` and `Float64(text)` parse decimal floats, `inf` and `nan`.
- `String(x)` on a Float64 doesn't always print the shortest text that reads back: some
  17-digit values print with 16 digits that parse as a neighbouring float. Float16 and
  BFloat16 print with Float32 digits. Print floats with `numeric.text.float_text`.
- `std.bit` has the bit tricks: `rotate_bits_left[7](x)`, `pop_count(n) == 1` for a power
  of two, `count_trailing_zeros`, `count_leading_zeros` and `bit_width`.
- `bitcast[DType.uint64](x)` (`from std.memory`) gives a float's bits, and back.
- `std.math` has `frexp`, `scalb`, `copysign`, `nextafter`, `isnan` and `sqrt`. Use
  `scalb` for `ldexp`, since `ldexp` and `exp2` are wrong for subnormal results, and
  `sqrt` for `x ** 0.5`, which isn't correctly rounded.
- `hash(x)` is AHash with a fixed key, the same on every run. A key written to disk
  uses FNV-1a, `hash[HasherType=default_comp_time_hasher](text)` (from `std.hash`),
  since AHash may change between releases. A hasher ends with `h.finish()`.
- A `comptime` UInt8 constant in a `List[Int]` literal needs `Int(K)`.

## Errors

- A function that fails is `def ... raises` and raises `Error(t"...")`.
- A typed error is a Writable struct. `except e:` infers its type, and a caller that is
  plain `raises` gets it as an `Error` with its written text.

  ```mojo
  @fieldwise_init
  struct SyntaxError(Copyable, Writable):
      var line: Int
      var message: String

  def parse(n: Int) raises SyntaxError -> Int:
      if n < 0:
          raise SyntaxError(3, "negative")
      return n * 2

  try:
      _ = parse(-1)
  except e:
      print(e.line, e.message)
  ```
- `d[k]` raises `DictKeyError[String]()`, which doesn't name the key. Use `d.get(k)`, or
  test `k in d` and raise a message that names it.
- `o.value()` on None aborts. Read an Optional after `is not None`, through `if case`,
  or with `o.or_else(default)`.
- A sort comparator can't raise. Sort, then check adjacent pairs in a raising loop.

## Resources

- A resource is a context manager, with `__enter__` and `__exit__`:

  ```mojo
  struct Indent:
      var depth: Int

      def __init__(out self):
          self.depth = 0

      def __enter__(mut self) -> Int:
          self.depth += 1
          return self.depth

      def __exit__(mut self):
          self.depth -= 1

  with Indent() as depth:
      ...
  ```

  `with existing as x` copies the manager, so build it in the `with` or move it in with
  `^`.
- `with TemporaryDirectory() as tmp:` (`std.tempfile`) gives a scratch directory.
- `Path(root) / "a" / "notes.spec"` (`std.pathlib`) has `read_text`, `write_text`,
  `exists` and `name()`. `std.os` has `makedirs(path, exist_ok=True)` and
  `getenv(name, default)`. `std.os.path` has `join`, `dirname`, `basename` and
  `split_extension`. `listdir` is unsorted.
- A destructor, `def __deinit__(deinit self)`, frees raw memory (eg. bitpattern's
  `Limbs`). Cleanup tied to a block goes in a context manager.
- A raw pointer is `Pointer[T, MutUntrackedOrigin](unsafe_from_address=a)`, indexed
  with `p[unsafe_offset=i]`.
- A local is destroyed right after its last use. Passing `owner.ptr` to a call can free
  the object before the call runs. Pass the owning struct as a borrowed argument, or
  keep the owner alive past the call (`_ = len(buf)`). `host/bridge` does both.
- Module-level state in the shared library is `std.ffi._Global[name, init_fn]`, whose
  `init_fn` is a non-raising `def() -> T`. `get_or_create_ptr()` raises and returns a
  `MutUntrackedOrigin` pointer.

## Iteration

- `for x in xs` binds an immutable reference. `for ref x in xs` changes elements in
  place and `for var x in xs` gives a mutable copy.
- `enumerate(xs, start=1)`, `zip(a, b)`, `reversed(xs)` and `reversed(range(n))` need no
  import. Keep `range(len(xs))` for writing the list being read or walking parallel
  arrays.
- `for x in xs` needs a Copyable element. Over a list of Movable-only values, use
  `if case` patterns or an index loop.
- `std.iter` has `map[f](xs)`, `chain` and `peekable`, and `std.itertools` has
  `product`, `take`, `drop`, `take_while` and `count`. `map` takes its function as a
  parameter, a capture-free lambda with typed arguments:
  `map[lambda (x: Int) -> Int: x * 2](xs)`. `product(xs, xs)` is an aliasing error, so
  copy one side.
- `for e in d.items():` gives entries with `e.key` and `e.value`. `for k in d:` gives keys.
- A struct works in `for`, `enumerate` and comprehensions as an `Iterator` that is
  `IterableOwned`:

  ```mojo
  from std.iter import Iterator, IterableOwned, StopIteration

  @fieldwise_init
  struct Countdown(Iterator, IterableOwned):
      comptime Element = Int
      comptime IteratorOwnedType = Self
      var n: Int

      def __iter__(var self) -> Self:
          return self^

      def __next__(mut self) raises StopIteration -> Int:
          if self.n == 0:
              raise StopIteration()
          self.n -= 1
          return self.n + 1
  ```

## Not in 1.2

| Missing | Write |
| --- | --- |
| `xs[-1]` (a compile error; a runtime -1 aborts) | `xs[len(xs) - 1]`, or `if case [*_, last] = xs:` |
| `last()`, `back()` | the same |
| `enum` | `__enum` |
| a newtype, `type NodeKind(UInt8)` | `__enum`, or a struct over the integer (`comptime NodeKind = UInt8` is only an alias) |
| derived `__eq__` and `__hash__` on an `__enum` | one line each over `_get_enum_discriminant()` |
| several payload patterns, `case .span(a, b):` | `case .span(pair):` with `pair[0]` and `pair[1]` |
| `match` on a Variant | `v.isa[T]()` and `v[T]`, or an `__enum` |
| struct field defaults | an `__init__` with defaulted keyword arguments |
| named tuple fields | a `@fieldwise_init` struct |
| a struct holding `List[Self]` | flat tables indexed by id, or `ArcPointer[Self]` children |
| f-strings | t-strings |
| generator expressions | a list comprehension, `any([...])`, or `map[f](xs)` |
| `filter` | a comprehension with `if` |
| `sum` | a loop |
| `sorted`, `List.sort`, `key=` | `var ys = xs.copy()` then `sort(ys)`, with a capturing comparator for a key |
| `max(xs)`, `min(xs)` | a loop, or `max(a, b, c)` for separate values |
| `bisect` | `binary_search_by` for an exact match, else a loop |
| `List.remove`, `List.rindex` | `try_index` then `pop(i)`, and a `reversed(range(...))` loop |
| `exchange`, `replace`, a free `take` | `swap`, or `take` from `arena.steps` |
| `Span.find`, `index`, `startswith` | a `StringSpan` view, or `in` for one byte |
| `for k, v in d.items()` | `for e in d.items():` with `e.key` and `e.value` |
| `len(s)` on a String | `s.byte_length()` or `s.count_codepoints()` |
| `b == ord("x")` with a `UInt8` | `Int(b) == ord("x")` |
| `InlineArray` | `Array` |
| `Int(text, base=16)` | `atol(text, 16)` |
| `rjust`, `zfill` | `ascii_rjust(width, "0")` |
| `partition`, `String.index`, `find` with an end | `find` on a `[byte=a:b]` view |
| `is_ascii_alpha`, `alnum`, `hexdigit` | `is_ascii_upper() or is_ascii_lower()`, plus `is_ascii_digit()` |
| `is_power_of_two` | `pop_count(n) == 1` |
| `Path.parent`, `Path.stem` | `dirname(p)`, `split_extension(basename(p))[0]` |
| `if var x := ...` | `var x: T` on an earlier line, then `if x := ...` |
| indexing a `comptime` list without a copy | `materialize[NAMES]()` once per call |
| a raising sort comparator | sort, then check pairs |
| `mojo test` | a test program (see Running code) |

## bitpattern's core

`host/vendor/bitpattern` holds bitpattern's `bigint.mojo` and `arena/`, copied
unchanged. Don't edit them. A missing operation goes in `host/numeric` and upstream.

- `BigUInt` is an unsigned integer of any size, for counts, members, magnitudes and
  exact arithmetic. `numeric.bigint.BigInt` is the signed form built on it.
  - literals convert, eg. `BigUInt(1)`, `x != 1`, `not x % five`
  - `BigUInt.mask(width)` is `2**width - 1`, eg. the largest `uN`
  - `bits()` is the bit length and `count_ones()` the popcount, so a power of two has
    `count_ones() == 1` and log2 `bits() - 1`
  - `bit(i)`, `set_bit(i, value)`, `low_bits(width)` and `limb(i)` read and write bits
  - `uint64_or_none()` and `uint128_or_none()` narrow it
  - `|`, `<<`, `>>`, `+`, `-`, `*`, `//`, `%`, `==`, `<` and `hash` work
- `BigUInt` lacks `&`, `^`, `~`, `divmod`, `pow` and a trailing-zero count. Those live
  in `host/numeric`. `BigUInt` isn't Writable, so tests compare with
  `assert_true(a == b)`. `BigUInt`, `BigInt` and `Real` copy only with `.copy()`.
- `Limbs` is the malloc'd `UInt64` array under a `BigUInt`, least significant first.
  `BigUInt(limbs=...)` takes one and drops high zero limbs, so packing bytes or hex
  digits into limbs builds a value in one pass:

  ```mojo
  var limbs = Limbs(length=(len(data) + 7) // 8, fill=0)
  for i, byte in enumerate(data):
      limbs.unsafe_get(i // 8) |= UInt64(byte) << UInt64(8 * (i % 8))
  return BigUInt(limbs=limbs^)
  ```
- `arena` holds sets of integers as hash-consed decision diagrams, so two sets are
  equal when their roots are. The host reaches it through `sets.SetContext` and
  `BitSet`, for sets up to 64 bits wide.
  - `apply`: `union`, `intersection`, `difference`, `symmetric_difference`, `complement`
  - `compare`: `subset` and `disjoint`, which build no nodes
  - `build`: `interval[narrow_bit]`, `exactly_these[narrow_bit]` over sorted distinct
    `UInt128`s, and `diagram(text)` for a bit pattern
  - `members`: `accepts`, `nth_narrow`, `rank_narrow`, and `bits_between(v, low=, high=)`
  - `walk`: `Walk[Narrow](root, width).next_run(arena)` gives the members in order, one
    run of `2**free` integers at a time
  - `Arena.count_narrow(root, width)` counts a set up to 64 bits wide in a `UInt128`
- The arena's operations raise `Interrupted`. A function parameter over them is `thin`:
  `op: def(mut Arena, Id, Id) thin raises Interrupted -> Id`.
- `arena.steps.take(x)` returns `x` and leaves `T()` in its place.
- `paths`, `export`, `reshape`, `rows` and `collect` are unused by the host.
- The vendored code is current Mojo written with care. Read it for style.

## Reference code

- bitpattern's CPython layer, for the extension module: `git -C ~/bitpattern show
  v0.3.0:src/python/capi.mojo` (and `lib.mojo`, `objects.mojo`, `errors.mojo`,
  `args.mojo` in the same directory), and `git -C ~/bitpattern show
  v0.3.0:hatch_build.py` for building and loading the shared library. It defines the
  module with the C API directly and avoids `PythonModuleBuilder`. The reasons are in
  `~/bitpattern/upstream/` (`bug-python-import-changes-process-environment.md`,
  `bug-python-errors-lose-exception-types.md` and others).
- `std.python._cpython` has the C-API constants and struct layouts (`Py_LT`,
  `PyMethodDef`, `PyModuleDef`, `Py_TPFLAGS_*`). The extension uses those and never
  `PythonObject`. One `PythonObject` in the extension rewrites `PYTHONPATH`, and child
  pythons then exit with 1.
- `~/bitpattern/upstream/*.md`: Mojo bugs met so far, with workarounds.
