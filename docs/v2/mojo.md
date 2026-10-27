# Mojo 1.2 notes

The host builds with the venv's `mojo` (mojo-compiler 1.2.0, `.venv/bin/mojo`). Mojo
changes fast and much older material describes a different language, so these notes
record what compiles here. When in doubt, compile a five-line file: a cached rerun
takes about a second.

## Running code

- There is no `mojo test`. A test file is a program:

  ```mojo
  from std.testing import assert_equal, assert_true, assert_raises, TestSuite

  def test_something() raises:
      assert_equal(1 + 1, 2)

  def main() raises:
      TestSuite.discover_tests[__functions_in_module()]().run()
  ```

  A failing test makes `mojo run` exit with 1. `tests/host/conftest.py` runs each
  `tests/host/**/test_*.mojo` this way as one pytest item.
- Include roots: `-I host -I host/vendor/bitpattern`. Packages under `host/` need an
  `__init__.mojo`. Import by module path: `from wire.value import Value`,
  `from arena import Arena`, `from bigint import BigUInt`.
- A cold compile of a small test takes 4 to 10 s, and `mojo run` spends 1 to 3 s even
  when its cache is warm. `tests/host/conftest.py` therefore builds each test file
  once per state of `host/` and keeps the binary in `.mojo-tests/`, so an unchanged
  test reruns at once. `-O0` is not faster.
- A Mojo test can scale its sample counts with `getenv("SPECTEST_STRENGTH")`: `dev`
  in the dev loop, `full` under `--ci`.

## Idioms that compile in 1.2

Prefer these Python-like forms. Each was compiled on 1.2:

- List comprehensions: `[x * 2 for x in xs if x > 1]`.
- `in` on lists, strings, dicts and sets: `name in names`, `"." in s`.
- `any` and `all`: `any([p(x) for x in xs])`.
- `match`, on ints and strings, with `case _:`.
- Template strings for messages: `t"{name} takes {n} arguments"`, also inside
  `Error(...)`. There are no f-strings. `String(a, b, c)` also joins several values.
- Dict and set literals: `{"a": 1}`, `{1, 2}`. `xs.index(x)` raises when `x` is
  missing. `", ".join(parts)` and `sort(xs)` (from `std.builtin.sort`) work.
- `@fieldwise_init` writes the constructor, and takes keywords: `P(a=1, b="x")`.
  Struct fields can't have default values.

- Functions are `def` with typed arguments; `fn` is gone. Constants and aliases are
  `comptime NAME = ...`. The standard library is imported from `std`:
  `std.testing`, `std.memory` (`ArcPointer`, `bitcast`), `std.hash` (`Hasher`,
  `hash`), `std.collections`, `std.utils` (`Variant`), `std.bit`, `std.ffi`.
- Constructors are `def __init__(out self, ...)`. `@fieldwise_init` writes the obvious
  one. A `var` argument takes ownership; pass with `^` to move. Non-trivial values copy
  only explicitly, with `.copy()`.
- Traits used here: `Copyable`, `Movable`, `Equatable` (`__eq__`), `Hashable`,
  `Comparable` (`__lt__`), `Writable`, `Defaultable`, `Sized`, `Boolable`, and
  `TrivialRegisterPassable` for small plain structs, which then copy implicitly.
- `def write_to(self, mut writer: Some[Writer])` makes a type printable and gives it
  `String(x)`. `writer.write(a, b, c)` takes several values.
- `def __hash__(self, mut hasher: Some[Hasher])` hashes by calling each field's
  `__hash__(hasher)`. `hasher.update` takes bytes only.
- A method returning a reference into a list names the element's origin:
  `def node(self, i: Int) -> ref [self.nodes[0]] Node: return self.nodes[i]`.
  `ref [self.nodes]` is rejected for an element.
- Bytes of a string: `s.as_bytes()[i]` is a `UInt8`; compare it as `Int(b) == ord("x")`.
  `s.byte_length()`, `s.codepoints()`, `s[byte=a:b]`.
- Floats: `Float16`, `BFloat16`, `Float32`, `Float64`;
  `bitcast[DType.uint64](x)` (from `std.memory`) gives the bits, and back.
- `Dict[K, V]` needs `K: Hashable & Equatable & Copyable`. `Optional[T]`: test with
  `if x:`, read with `x.value()`.
- Errors: `raise Error("message")` in a `def ... raises`. Typed raises
  (`raises Interrupted`) exist; bitpattern's arena uses them.
- `InlineArray` is not in scope by default; prefer a `List` or a function.
- Imports that aren't where older Mojo had them: `from std.builtin.sort import sort`,
  `from std.os import abort, getenv`, `from std.bit import count_trailing_zeros`,
  `from std.hash import default_hasher` (`var h = default_hasher()`, then
  `h^.finish()`). `std.time.perf_counter_ns`, `std.os.makedirs`, `std.pathlib.Path`
  and `std.tempfile.mkdtemp` work.
- `Pointer[T, MutUntrackedOrigin](unsafe_from_address=a)`, indexed with
  `p[unsafe_offset=i]`, replaces the deprecated `UnsafePointer`. A destructor is
  `def __deinit__(deinit self)`.
- `Comparable` needs only `__eq__` and `__lt__`. `abs(x)` needs the `Absable` trait;
  `BigInt` lacks it, so call `x.__abs__()`. `BigUInt` isn't `Writable`, so
  `assert_equal` rejects it; compare with `assert_true(a == b)`.
- `BigInt`, `BigUInt` and `Real` are `Copyable` but not `ImplicitlyCopyable`: pass them
  with `.copy()` or `^`, also inside call arguments and when returning a local (`r^`).
  `BigUInt(x)` takes a `UInt64`, `UInt128` or literal, not a runtime `Int`.
- A list literal of one element type can infer a fixed-size array: write
  `var xs: List[T] = [a, b]` where a `List` is expected. `for x in xs` needs a
  copyable element type; use `for i in range(len(xs))` otherwise. A module-level
  `comptime` list needs `materialize[NAMES]()` to be iterated at run time.
- `len(s)` on a `String` is an error: use `s.byte_length()`. `String.split` returns
  `StringSlice`s; wrap one in `String(...)` to own it. `String(unsafe_from_utf8=Span(bytes))`
  builds a String from a `List[UInt8]`, NULs included. `chr(code)` encodes a code
  point. A `\u` escape in a literal takes exactly four hex digits.
- Moves out of the middle of a value fail ("destroyed out of the middle of a value"):
  `return holder.field^` from a local, or `tok.text^` with `tok` used later. Copy
  instead, or consume the holder: `def into_ast(deinit self) -> Ast: return self.ast^`.
- A `Span` or pointer into a `String` field of `self` is invalidated by any later
  `mut self` call. Pass such bytes down as an argument from a string that isn't a
  field of the struct being changed.
- `syntax.ast.Span` hides std's `Span` when imported; alias one of them.
- `comptime` constants typed `UInt8` don't convert to `Int` in a `List[Int]` literal.
- Integer arithmetic on `Int` and `UInt64` wraps without trapping; `Int //` floors,
  as Python's does.
- A file given to `mojo build` as the top-level module can't use relative imports;
  use package paths there.

## Limits found so far

- Recursive types. A struct cannot hold `List[Self]`. Worse, a struct `A` holding
  `List[B]`, where `B` holds `ArcPointer[A]`, compiles in its own file but fails with
  "non-'Deinitable' type" once another module imports it. What works across modules:
  `ArcPointer[Self]` and `List[ArcPointer[Self]]` fields, and flat tables indexed by
  integers (`syntax/ast.mojo`). `wire/value.mojo` keeps each child of a compound
  value behind its own `ArcPointer[Value]`.
- A defaulted argument of a recursive type (`var items: List[Value] = ...`) in a
  helper struct's constructor triggers the same error; build such values inside the
  recursive type's own constructor.
- Temporaries die early. A local that owns a Python reference is destroyed right
  after its last use, so passing `owner.ptr` to a call can free the object before the
  call runs. Pass the owning struct itself as a borrowed argument, or keep the owner
  alive past the call (`_ = len(buf)` after a call that reads `buf` through a raw
  pointer). `host/bridge` shows both.
- Module-level state in a shared library: `std.ffi._Global[name, init_fn]`, whose
  `init_fn` is a non-raising `def() -> T`; `get_or_create_ptr()` raises and returns a
  `MutUntrackedOrigin` pointer.

## Reference code

- `host/vendor/bitpattern`: bitpattern's arena (decision diagrams) and `BigUInt`,
  current Mojo written with care. Read it for style and idioms.
- bitpattern's CPython layer, for the extension module: `git -C ~/bitpattern show
  v0.3.0:src/python/capi.mojo` (and `lib.mojo`, `objects.mojo`, `errors.mojo`,
  `args.mojo` in the same directory), and `git -C ~/bitpattern show
  v0.3.0:hatch_build.py` for building and loading the shared library. It defines the
  module with the C API directly rather than with `PythonModuleBuilder`; the reasons
  are in `~/bitpattern/upstream/` (`bug-python-import-changes-process-environment.md`,
  `bug-python-errors-lose-exception-types.md` and others).
- `~/bitpattern/upstream/*.md`: Mojo bugs met so far, with workarounds.
