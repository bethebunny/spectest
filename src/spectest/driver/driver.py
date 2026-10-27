# ruff: noqa: BLE001
"""The driver: name resolution, calls, and conversion (docs/v2/protocol.md)."""

from __future__ import annotations

import dataclasses
import enum
import importlib
import struct
import sys
from collections.abc import Callable
from functools import cache
from typing import Any

from spectest.driver import convert
from spectest.driver.wire import (
    FLOAT_FORMATS,
    Converted,
    Enum,
    Error,
    Float,
    Handle,
    Map,
    Record,
)

_SIMPLE = frozenset({type(None), bool, int, str})
_BYTES_LIKE = (bytes, bytearray, memoryview)

_NUMPY_FLOAT_FORMATS = {"float16": "f16", "float32": "f32", "float64": "f64"}
_PACK = {"f16": "<e", "f32": "<f", "f64": "<d"}
_UINT = {"f16": "<H", "f32": "<I", "f64": "<Q"}
_WIDTH = {"f16": 16, "bf16": 16, "f32": 32, "f64": 64}
# (exponent bits, mantissa bits) of each format
_LAYOUT = {"f16": (5, 10), "bf16": (8, 7), "f32": (8, 23), "f64": (11, 52)}

_MISSING = object()


class _Failure(Exception):
    """A failure of the driver itself, reported as an Error under ``spectest.``."""

    def __init__(self, cls: str, message: str):
        super().__init__(message)
        self.cls = cls
        self.message = message

    def error(self) -> Error:
        return Error(self.cls, (), self.message)


class _TooLarge(Exception):
    pass


def _convert_failure(message: str) -> _Failure:
    return _Failure("spectest.ConvertError", message)


def _resolve_failure(message: str) -> _Failure:
    return _Failure("spectest.ResolveError", message)


def _error(exc: BaseException) -> Error:
    t = type(exc)
    bases = tuple(convert.qualified_name(b) for b in t.__mro__[1:] if b is not object)
    return Error(convert.qualified_name(t), bases, str(exc))


def _reinterpret(value: int, *, as_fmt: str, from_fmt: str) -> float:
    return struct.unpack(as_fmt, struct.pack(from_fmt, value))[0]


def float_to_python(f: Float) -> float:
    """The f64 value of a wire float; a NaN keeps its payload (and sign) as far as f64
    can hold it."""
    fmt, bits = f.fmt, f.bits
    if fmt not in FLOAT_FORMATS:
        raise _convert_failure(f"unknown float format {fmt!r}")
    width = _WIDTH[fmt]
    if not 0 <= bits < (1 << width):
        raise _convert_failure(f"{bits} does not fit {fmt}")
    if fmt == "f64":
        return _reinterpret(bits, as_fmt="<d", from_fmt="<Q")
    ebits, mbits = _LAYOUT[fmt]
    exp = (bits >> mbits) & ((1 << ebits) - 1)
    mant = bits & ((1 << mbits) - 1)
    if exp == (1 << ebits) - 1 and mant:
        sign = bits >> (width - 1)
        wide = (sign << 63) | (0x7FF << 52) | (mant << (52 - mbits))
        return _reinterpret(wide, as_fmt="<d", from_fmt="<Q")
    if fmt == "bf16":
        return _reinterpret(bits << 16, as_fmt="<f", from_fmt="<I")
    return _reinterpret(bits, as_fmt=_PACK[fmt], from_fmt=_UINT[fmt])


def float_from_python(x: float) -> Float:
    return Float("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


class Driver:
    def __init__(
        self, max_elements: int = 2**17, module_map: dict[str, str] | None = None
    ):
        self.max_elements = max_elements
        # qualified-name prefix -> replacement, eg. {"math": "examples.libm.buggy"}
        self.module_map = dict(module_map or {})
        self._targets: dict[int, Any] = {}  # target id -> the resolved object
        self._fns: dict[int, Any] = {}  # target id -> what `call` invokes
        self._by_name: dict[str, int] = {}
        self._objects: dict[int, Any] = {}  # handle id -> object
        # id(object) -> handle id. Python has no identity map for arbitrary objects. Each
        # object stays in _objects while its id is here, so the id can't be reused.
        self._ids: dict[int, int] = {}
        self._next_target = 1
        self._next_handle = 1

    # -- protocol methods ---------------------------------------------------

    def resolve(self, name: str) -> int | Error:
        if (tid := self._by_name.get(name)) is not None:
            return tid
        try:
            obj = self._lookup(name)
        except _Failure as f:
            return f.error()
        fn = obj
        match obj:
            case property(fget=None):
                return Error(
                    "spectest.ResolveError", (), f"property {name} has no getter"
                )
            case property(fget=getter):
                fn = getter
            case _ if type(obj).__name__ in ("member_descriptor", "getset_descriptor"):
                fn = obj.__get__
        tid = self._next_target
        self._next_target += 1
        self._targets[tid] = obj
        self._fns[tid] = fn
        self._by_name[name] = tid
        return tid

    def call(self, target: int, args: Any, kwargs: Any = None) -> Any:
        if (fn := self._fns.get(target)) is None:
            return Error("spectest.ResolveError", (), f"unknown target {target}")
        try:
            pargs = [a if type(a) in _SIMPLE else self._to_python(a) for a in args]
            pkwargs = self._kwargs_to_python(kwargs) if kwargs else None
        except _Failure as f:
            return f.error()
        except Exception as exc:
            return Error("spectest.ConvertError", (), f"{type(exc).__name__}: {exc}")
        try:
            result = fn(*pargs, **pkwargs) if pkwargs else fn(*pargs)
        except Exception as exc:
            return _error(exc)
        return result if type(result) in _SIMPLE else self._result(result)

    def _kwargs_to_python(self, kwargs: Any) -> dict[str, Any]:
        if type(kwargs) is Map:
            return self._to_python(kwargs)
        return {k: self._to_python(v) for k, v in dict(kwargs).items()}

    def get(self, target: int) -> Any:
        if (obj := self._targets.get(target, _MISSING)) is _MISSING:
            return Error("spectest.ResolveError", (), f"unknown target {target}")
        return self._result(obj)

    def observe(self, obj: Any, name: str, args: Any = None) -> Any:
        try:
            attr = getattr(self._to_python(obj), name)
            if args is not None:
                attr = attr(*[self._to_python(a) for a in args])
        except _Failure as f:
            return f.error()
        except Exception as exc:
            return _error(exc)
        return self._result(attr)

    def release(self, ids: Any) -> None:
        for i in ids:
            if (obj := self._objects.pop(i, _MISSING)) is not _MISSING:
                self._ids.pop(id(obj), None)

    def converters(self) -> dict[str, str]:
        return convert.registered()

    # -- name resolution ----------------------------------------------------

    def _mapped(self, name: str) -> str:
        """The name with its longest mapped prefix (whole dotted parts) replaced."""
        parts = name.split(".")
        for n in range(len(parts), 0, -1):
            if (replacement := self.module_map.get(".".join(parts[:n]))) is not None:
                return ".".join([replacement, *parts[n:]])
        return name

    def _lookup(self, name: str) -> Any:
        if self.module_map:
            name = self._mapped(name)
        parts = name.split(".")
        if not name or "" in parts:
            raise _resolve_failure(f"bad name {name!r}")
        for used in range(len(parts), 0, -1):
            prefix = ".".join(parts[:used])
            try:
                obj = importlib.import_module(prefix)
            except ModuleNotFoundError as exc:
                if exc.name and (
                    prefix == exc.name or prefix.startswith(f"{exc.name}.")
                ):
                    continue
                raise _resolve_failure(f"importing {prefix} failed: {exc}") from None
            except ImportError as exc:
                raise _resolve_failure(f"importing {prefix} failed: {exc}") from None
            except Exception as exc:
                raise _resolve_failure(f"importing {prefix} failed: {exc!r}") from None
            break
        else:
            raise _resolve_failure(f"no module for {name}")
        for i, part in enumerate(parts[used:], used):
            try:
                obj = getattr(obj, part)
            except AttributeError:
                raise _resolve_failure(
                    f"{'.'.join(parts[:i])} has no attribute {part}"
                ) from None
        return obj

    def _class_named(self, name: str) -> Any:
        tid = self.resolve(name)
        if type(tid) is Error:
            raise _convert_failure(f"unknown class {name}: {tid.message}")
        return self._targets[tid]

    # -- python to wire -----------------------------------------------------

    def _result(self, obj: Any) -> Any:
        try:
            return self._to_wire(obj, [self.max_elements])
        except _TooLarge:
            return Error(
                "spectest.TooLarge",
                (),
                f"result has more than {self.max_elements} values",
            )
        except _Failure as f:
            return f.error()
        except Exception as exc:
            return _error(exc)

    def _to_wire(self, o: Any, budget: list[int]) -> Any:
        budget[0] -= 1
        if budget[0] < 0:
            raise _TooLarge
        t = type(o)
        if t in _SIMPLE:
            return o
        if t is float:
            return float_from_python(o)
        if t.__module__ == "numpy" and (wire := self._numpy(o, t)) is not _MISSING:
            return wire
        converter = _wire_converter(t)
        # bytes-like values are never converted by a registration
        if converter is not Driver._bytes and (reg := convert.find(t)) is not None:
            return Converted(reg.name, self._to_wire(reg.to_wire(o), budget))
        return converter(self, o, budget)

    def _bytes(self, o: Any, budget: list[int]) -> bytes:
        return bytes(o)

    def _enum(self, o: Any, budget: list[int]) -> Enum:
        return Enum(convert.qualified_name(type(o)), o.name)

    def _named_tuple(self, o: Any, budget: list[int]) -> Record:
        t = type(o)
        fields = tuple((f, self._to_wire(v, budget)) for f, v in zip(t._fields, o))
        return Record(convert.qualified_name(t), fields)

    def _dataclass(self, o: Any, budget: list[int]) -> Record:
        fields = tuple(
            (f.name, self._to_wire(getattr(o, f.name), budget))
            for f in dataclasses.fields(o)
        )
        return Record(convert.qualified_name(type(o)), fields)

    def _bool(self, o: Any, budget: list[int]) -> bool:
        return bool(o)

    def _int(self, o: Any, budget: list[int]) -> int:
        return int(o)

    def _str(self, o: Any, budget: list[int]) -> str:
        return str(o)

    def _float(self, o: Any, budget: list[int]) -> Float:
        return float_from_python(float(o))

    def _tuple(self, o: Any, budget: list[int]) -> tuple:
        return tuple([self._to_wire(v, budget) for v in o])

    def _list(self, o: Any, budget: list[int]) -> list:
        return [self._to_wire(v, budget) for v in o]

    def _dict(self, o: Any, budget: list[int]) -> Map:
        return Map(
            tuple(
                (self._to_wire(k, budget), self._to_wire(v, budget))
                for k, v in o.items()
            )
        )

    def _handle(self, o: Any, budget: list[int]) -> Handle:
        if (hid := self._ids.get(id(o))) is None:
            hid = self._next_handle
            self._next_handle += 1
            self._ids[id(o)] = hid
            self._objects[hid] = o
        return Handle(hid, convert.qualified_name(type(o)))

    def _numpy(self, o: Any, t: type) -> Any:
        if (np := sys.modules.get("numpy")) is None:
            return _MISSING
        if isinstance(o, np.floating):
            if (fmt := _NUMPY_FLOAT_FORMATS.get(t.__name__)) is None:
                return _MISSING
            uint = {"f16": np.uint16, "f32": np.uint32, "f64": np.uint64}[fmt]
            return Float(fmt, int(o.view(uint)))
        if isinstance(o, np.bool_):
            return bool(o)
        if isinstance(o, np.integer):
            return int(o)
        return _MISSING

    # -- wire to python -----------------------------------------------------

    def _to_python(self, w: Any) -> Any:
        t = type(w)
        if t in _SIMPLE:
            return w
        if (converter := _PYTHON_CONVERTERS.get(t)) is None:
            raise _convert_failure(f"{t.__name__} is not a wire object")
        return converter(self, w)

    def _from_list(self, w: list) -> list:
        return [a if type(a) in _SIMPLE else self._to_python(a) for a in w]

    def _from_tuple(self, w: tuple) -> tuple:
        return tuple([self._to_python(a) for a in w])

    def _from_handle(self, w: Handle) -> Any:
        try:
            return self._objects[w.id]
        except (KeyError, TypeError):
            raise _convert_failure(f"unknown handle {w.id}") from None

    def _from_map(self, w: Map) -> dict:
        try:
            return {self._to_python(k): self._to_python(v) for k, v in w.pairs}
        except TypeError as exc:
            raise _convert_failure(f"unhashable map key: {exc}") from None

    def _from_record(self, w: Record) -> Any:
        cls = self._class_named(w.type)
        fields = {k: self._to_python(v) for k, v in w.fields}
        try:
            return cls(**fields)
        except Exception as exc:
            raise _convert_failure(
                f"cannot build {w.type} from its fields: {exc}"
            ) from None

    def _from_enum(self, w: Enum) -> Any:
        if w.type == "":
            return w.member
        try:
            return getattr(self._class_named(w.type), w.member)
        except AttributeError:
            raise _convert_failure(f"{w.type} has no member {w.member}") from None

    def _from_converted(self, w: Converted) -> Any:
        reg = convert.by_name(w.cls)
        if reg is None or reg.from_wire is None:
            raise _convert_failure(f"no inverse converter registered for {w.cls}")
        return reg.from_wire(self._to_python(w.value))


_Converter = Callable[[Driver, Any, list[int]], Any]

# In priority order: a type uses the first entry whose base is among its bases.
_PLAIN_CONVERTERS: tuple[tuple[type, _Converter], ...] = (
    (bool, Driver._bool),
    (int, Driver._int),
    (str, Driver._str),
    (float, Driver._float),
    (tuple, Driver._tuple),
    (list, Driver._list),
    (dict, Driver._dict),
)

_PYTHON_CONVERTERS: dict[type, Callable[[Driver, Any], Any]] = {
    bytes: lambda driver, w: w,
    bytearray: lambda driver, w: bytes(w),
    memoryview: lambda driver, w: bytes(w),
    Float: lambda driver, w: float_to_python(w),
    list: Driver._from_list,
    tuple: Driver._from_tuple,
    Handle: Driver._from_handle,
    Map: Driver._from_map,
    Record: Driver._from_record,
    Enum: Driver._from_enum,
    Converted: Driver._from_converted,
}


@cache
def _wire_converter(t: type) -> _Converter:
    if issubclass(t, _BYTES_LIKE):
        return Driver._bytes
    if issubclass(t, enum.Enum):
        return Driver._enum
    if issubclass(t, tuple) and hasattr(t, "_fields"):
        return Driver._named_tuple
    if dataclasses.is_dataclass(t):
        return Driver._dataclass
    return next(
        (c for base, c in _PLAIN_CONVERTERS if base in t.__mro__), Driver._handle
    )
