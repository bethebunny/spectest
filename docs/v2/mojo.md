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
- A cold compile of a small test takes 4 to 10 s; unchanged code reruns from the cache
  in about 1 s. `-O0` is not faster.

## Idioms that compile in 1.2

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
