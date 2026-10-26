# Spike: the cost of a host-to-driver call

What one call from the Mojo host to the Python driver costs, measured through
`DriverClient` (`host/bridge/client.mojo`) and the conversions in
`host/bridge/convert.mojo`. Reproduce with `uv run python tests/bridge/spike.py`.

Machine: 12th Gen Intel Core i7-1255U, CPython 3.13.9, Mojo 1.2.0. Each figure is the
median of 5 runs of `_host.bench`, 20,000 calls per run, in microseconds per call. A
call is: build the Python argument list from `Value`s, call `driver.call(target, args,
{})`, convert the reply back to a `Value`.

## Numbers

| Case | Stub driver | Bare driver |
| --- | --- | --- |
| (a) function, no arguments, returns `None` | 0.43 | 0.25 |
| (b) function, two ints, returns the sum | 1.02 | 0.28 |
| (c) method on a handle | 1.23 | 0.76 |
| (d) identity of a list of 100 ints | 56 | 9.6 |
| (d) identity of a nested record | 6.7 | 5.9 |
| `echo` (Python to `Value` and back), list of 100 ints | 7.1 | |
| `echo`, nested record | 4.6 | |

- The stub driver is `tests/bridge/stub_driver.py`, written in Python with `importlib`
  and `getattr`; it converts its arguments and results itself, which is most of its
  time. The bare driver returns its first argument untouched, so its column is the
  host's own cost: argument conversion, the call into Python, and result conversion.
- The nested record is `Record` with a list, a tuple, a `Map` and an `Enum` inside, 14
  wire objects in all. Its cost is dominated by building the wire classes
  (`Record`, `Map`, `Enum` are frozen dataclasses, so each construction runs a Python
  `__init__`), about 0.3 to 0.4 us each.
- The 100-int list through the stub is 56 us because the stub copies it twice in
  Python (its own conversions), with the cycle collector running as the copies are
  allocated. The host's share is the bare column, 9.6 us, or 7.1 us for `echo`. Ints
  cost about 35 ns each each way.

## Against the targets

v1 spends about 7 ms per example; v2 aims at 50 us per example. The host's floor is
about 0.25 us for a call with trivial arguments, and in the low single digits of
microseconds for realistic arguments. That is about four orders of magnitude under v1
and 1 to 10 percent of the v2 budget.

So the bridge does not threaten the 50 us target on its own. What the floor says:

- An example with a handful of scalar arguments costs about 1 us in the bridge, plus
  whatever the driver and the code under test spend. The driver's marshalling (its
  `to_python` and `to_wire` in Python) is the larger share, as the stub column shows:
  Python-side conversion of a 100-element list costs several times what the host spends
  converting it.
- Large arguments are the risk, not call counts: about 0.07 us per list element
  round-tripped. A 1,000-element argument spends about 70 us in the bridge, past the
  whole per-example budget. Generators that routinely produce arguments of that size
  need the driver and host to avoid converting them (by handle) or the target to be
  per-element.
- Wire classes are the expensive objects (0.3 to 0.4 us each to construct). Records
  and enums in hot paths cost more than ints, lists and strings.
- Timings of the `Bare` driver show the call itself (vectorcall into a Python method,
  an empty `kwargs` dict built per call, `PyLong` and list construction) is a fraction
  of a microsecond. Caching the empty `kwargs` dict, or calling a driver method with
  fewer arguments, would save little.
