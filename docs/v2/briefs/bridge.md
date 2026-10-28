# Brief: bridge

The CPython extension module `spectest._host`, built from Mojo; conversion between
`Value` and wire objects; the client the host uses to call the driver; and the first
spike's measurements.

**Owns:** `spectest/_host/`, `scripts/build_host.py`, `tests/bridge/`, `docs/v2/spike.md`.
May add the built module's name to `.gitignore`.

**Read first:** `docs/v2/protocol.md`, `docs/v2/mojo.md`, `src/value/value.mojo`,
`src/value/bigint.mojo`, `src/value/float_formats.mojo`,
`spectest/driver/wire.py`. For the C API and the build, bitpattern's
`src/python/capi.mojo`, `src/lib.mojo` and `hatch_build.py` at v0.3.0 (see
`docs/v2/mojo.md`, Reference code).

## Deliver

1. **Build.** `scripts/build_host.py` compiles `spectest/_host/module.mojo` with
   `mojo build --emit shared-lib`, both include roots, to
   `spectest/_host/__init__.abi3.so`, set up to load the Mojo runtime libraries from the
   venv the way bitpattern's editable build does. It does nothing when no `.mojo`
   file under `src/` is newer than the module, and prints how long a build took.
   `tests/bridge/conftest.py` runs it once per session.
2. **The module**, defined with the C API as bitpattern's is (not with
   `PythonModuleBuilder`). Functions for Python:
   - `version() -> str`.
   - `echo(obj)`: wire object to `Value` and back. Raises `TypeError` for an object
     that isn't a wire object.
   - `call(driver, name, args)`: resolve `name` through the driver, convert `args` (a
     list of wire objects) to Values, call through the driver client, and return the
     result converted back. The whole path of a host call, for tests.
   - `bench(driver, name, args, n) -> float`: seconds per call, averaged over `n`
     calls through the driver client, conversions included.
3. **Mojo API** for later packages:
   - `to_python(value: Value) raises -> PyObjectPtr` (a new reference) and
     `from_python(obj: PyObjectPtr) raises -> Value`. From Python, the reading is
     untyped: `None` is an empty OPTION, and `Converted(cls, v)` is `v`'s Value (the
     class is dropped until the checker types converted parameters).
   - `struct DriverClient` wrapping the driver object: `resolve(name) raises -> Int`,
     `call(target, args: List[Value]) raises -> Value`, `get(target) raises -> Value`,
     `observe(obj: Value, name: String, args: Optional[List[Value]]) raises -> Value`,
     `release(ids: List[UInt64]) raises`. A wire `Error` comes back as an ERROR Value,
     not a Mojo error; `resolve` raises with the error's message. A Python exception
     escaping a driver method raises a Mojo error naming the exception's type and
     message.
   - Every reference taken is released; nothing leaks per call.
4. **Spike.** Measure on this machine and write `docs/v2/spike.md`: microseconds per
   call through `DriverClient` for (a) a Python function with no arguments returning
   `None`, (b) one taking two ints and returning their sum, (c) a method called on a
   handle, (d) `echo` of a list of 100 ints and of a nested record. Median of 5 runs.
   Compare with v1's ~7 ms per example and v2's target of 50 µs per example, and say
   what the floor means for that target. Use `tests/bridge/stub_driver.py`, a small
   driver written for the tests that implements the protocol's methods with
   `importlib` and `getattr`. Don't depend on `spectest.driver.Driver`, which is being
   built at the same time.

## Acceptance

- `uv run python scripts/build_host.py` builds from a clean workspace, and a second
  run does nothing.
- `uv run pytest tests/bridge` passes. `echo` round-trips every wire kind: ints 0, -1,
  2\*\*63, -(2\*\*200); `Float` of each format with -0.0, infinities and NaNs with
  payloads; empty and nested lists and tuples; a `Map` with list keys; `Record`;
  `Enum`, including type `""`; `Handle`; `Error`; `None`; `bytes` with zero bytes;
  strings outside the BMP. `Converted` reads as its inner value.
- `call` returns an `Error` object for an exception the called function raises, and
  `_host.call` raises (naming the original exception type) when the driver itself
  raises.
- No leaks: 100,000 `echo` calls of a nested value leave `sys.getrefcount` of a
  sentinel element unchanged and grow RSS by under 10 MB.
- `docs/v2/spike.md` has the numbers.

## Out of scope

Reading wire objects against spec types; the pytest plugin; the real driver.
