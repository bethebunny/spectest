# Brief: driver

The Python driver, `spectest.driver`: the only part of v2 that touches the objects of
the code under test.

**Owns:** `spectest/driver/` (`wire.py` is a contract: add to it only),
`tests/driver/`, and the `marshal` entry of `_EXPORTS` in `spectest/__init__.py`.

**Read first:** `docs/v2/protocol.md` (the spec for this package),
`spectest/driver/wire.py`, and v1's `spectest/runtime/binding.py` for how v1
called Python code.

## Deliver

1. `class Driver` with the protocol's methods: `resolve`, `call`, `get`, `observe`,
   `release`, `converters`. `Driver(max_elements=2**17)`.
2. **Name resolution:** the longest importable module prefix, then attributes. Class
   attributes resolve without binding: `bitpattern.IntSet.__or__` is the function
   that takes the receiver first, and a property resolves to the property, which
   `call` applies to `args[0]`. Builtins resolve under `builtins` (`builtins.len`,
   `builtins.list.__len__`). `resolve` caches by name and returns the same id for the
   same name.
3. **Conversions** both ways, exactly as the protocol lists them, including the
   `max_elements` cap.
4. **Handles:** ids start at 1. An object already in the table gets its existing id,
   so the host can test identity by id. `release` drops entries.
5. **Errors:** an exception raised by the called code becomes `Error` with the
   qualified class (`module.QualName`), its bases nearest first without `object`, and
   `str(exc)`. `KeyboardInterrupt` and `SystemExit` propagate. The driver's own
   failures are `Error`s with classes under `spectest.`: `spectest.ResolveError`,
   `spectest.ConvertError` (an argument that can't be converted, such as an unknown
   handle id or a record class that doesn't take those fields) and
   `spectest.TooLarge`.
6. **Converters:** `spectest.marshal(cls)` registers a converter and returns it with
   an `.inverse` decorator, as in the protocol. A subclass of a registered class
   converts with the nearest registered base. `converters()` reports each registered
   class and its wire kind, read from the converter's return annotation.
7. **Speed:** the call path does no introspection that could be cached. Add a test
   that measures `call` of a two-int function (resolved once) and prints
   microseconds per call; aim for under 5 µs on this machine.

## Acceptance

`uv run pytest tests/driver` passes, covering:

- resolution of a module function, a class, a constructor call, a method with the
  receiver first, a property, a staticmethod, a classmethod, a module constant, a
  nested class, a builtin, and names that don't resolve;
- every row of both conversion tables, including bool before int, numpy scalars,
  `-0.0` and NaN payloads kept through `Float`, named tuples and dataclasses as
  records, enum members, and handles for anything else;
- identity: returning the same object twice gives the same handle id;
- errors from the called code, with qualified classes and bases (use `ipaddress`'s
  `AddressValueError` as one case);
- converters both ways, including a subclass, and `converters()`;
- the `max_elements` cap on a large result;
- driving bitpattern (installed in the venv): resolve `bitpattern.IntSet.range`, call
  it, call `bitpattern.IntSet.__contains__` and `__or__` on the handles, and observe
  `width` and `size`.

## Out of scope

The extension module and anything in Mojo; typed reading of results (the host's job).
