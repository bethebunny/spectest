# Host and driver protocol

The host and the Python driver run in one process. The host calls the driver's
methods through the CPython C API, passing and receiving wire objects: the Python form
of wire values, defined in `src/spectest/driver/wire.py`. The protocol is defined
apart from this transport, so a transport across processes could carry the same
messages later.

## Wire objects

| Wire kind | Python form |
| --- | --- |
| bool | `bool` |
| int | `int`, any size |
| float | `Float(fmt, bits)`: `fmt` is `"f16"`, `"bf16"`, `"f32"` or `"f64"` |
| string | `str` |
| bytes | `bytes` |
| list | `list` |
| tuple | `tuple` |
| map | `Map(pairs)`: key-value pairs in order |
| option | `None` for none; a present option is its value, unwrapped |
| record | `Record(type, fields)`: qualified class name, `(name, value)` pairs |
| enum | `Enum(type, member)`: qualified enum class, member name; `type` is `""` for a string-literal union |
| handle | `Handle(id, cls)`: the driver's id for an object it keeps, and its class's qualified name |
| error | `Error(cls, bases, message)`: qualified class, qualified bases nearest first without `object`, `str(exc)` |
| converted | `Converted(cls, value)`: an object of a class with a registered converter, as the converter's wire value |

Wire objects are untyped. The host reads each one against the type the spec declares:
`None` where it expects `option<T>` is none, and anything else there is `some` of it.

## The driver's methods

The host holds one `spectest.driver.Driver` and calls these methods. None of them
raises for a failure of the code under test or a bad name: those come back as `Error`
objects. An exception escaping a method is a bug in the driver or the host.

| Method | Returns | Does |
| --- | --- | --- |
| `resolve(name)` | `int` or `Error` | Resolves a qualified name (`bitpattern.IntSet.range`) to a target id: import the longest module prefix, then read attributes. The same name gives the same id. A name that doesn't resolve is `Error("spectest.ResolveError", ...)`. |
| `call(target, args, kwargs)` | wire object | Calls the target with the arguments converted to Python, and converts the result back. A method target takes its receiver first. A property target reads the property of `args[0]`. An exception the call raises is returned as `Error`. |
| `get(target)` | wire object | The target's value, converted: a constant such as `bitpattern.codecs.int8`, usually a `Handle`. |
| `observe(obj, name, args)` | wire object | Reads attribute `name` of `obj` (a `Handle` or a wire object), then calls it with `args` when `args` is a list. `args` is `None` for a plain attribute or property. |
| `release(ids)` | `None` | Forgets the handles with these ids. |
| `converters()` | `dict[str, str]` | Each class with a registered converter, by qualified name, and the wire kind of its converted form (`"int"`, `"string"`, ...). |

## Conversions in the driver

Python to wire, for results and observations, in this order:

1. `None`, `bool`, `int`, `str`: themselves. (`bool` before `int`, since it subclasses
   `int`.)
2. `float`: `Float("f64", bits)`. numpy floating scalars: `Float` of the matching
   format (`float16` is `f16`, `float32` is `f32`, `float64` is `f64`). numpy integers:
   `int`. numpy `bool_`: `bool`.
3. `bytes`, `bytearray`, `memoryview`: `bytes`.
4. An object whose class (or a base class) has a registered converter:
   `Converted(cls, converter(obj))`, where `cls` names the registered class.
5. `enum.Enum` members: `Enum(qualified class, member name)`.
6. Named tuples and dataclass instances: `Record(qualified class, fields)`.
7. `tuple`: `tuple`. `list`: `list`. `dict`: `Map`. Elements are converted in turn.
8. A raised exception: `Error`.
9. Anything else: a new `Handle` for the object.

Converting one result visits at most `max_elements` values in all (2\*\*17 by
default); a larger result is `Error("spectest.TooLarge", ...)`, never a truncated
value.

Wire to Python, for arguments:

- `None`, `bool`, `int`, `str`, `bytes`: themselves. `Float`: a Python `float` with
  the same value (every format's values are exact in f64; a NaN keeps its payload where
  f64 can hold it).
- `list`, `tuple`: the same, with elements converted. `Map`: a `dict`.
- `Record(type, fields)`: the class `type` names, called with the fields as keyword
  arguments.
- `Enum(type, member)`: `getattr(cls, member)` for the class `type` names; a plain
  `str` when `type` is `""`.
- `Handle(id, cls)`: the object with that id.
- `Converted(cls, value)`: the registered inverse converter for `cls` applied to the
  converted `value`.

## Registering a converter

In `conftest.py` (or any module imported before the run):

```python
import datetime
import spectest

@spectest.marshal(datetime.date)
def date_to_wire(d: datetime.date) -> int:
    return d.toordinal()

@date_to_wire.inverse
def date_from_wire(n: int) -> datetime.date:
    return datetime.date.fromordinal(n)
```

The return annotation of the converter names its wire kind (`int`, `str`, `bytes`,
`float`, `bool`, `list`, `tuple`, `dict`); `converters()` reports it.

## In the host

`host/bridge` converts between `Value` and wire objects. Untyped, a wire object
becomes the Value of its own kind (`None` becomes an empty OPTION); typed reading
against a declared type comes with the checker. Every target id and handle id is a
plain integer on the Mojo side.
