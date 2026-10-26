# ruff: noqa: BLE001
"""The driver: name resolution, calls, and conversion (docs/v2/protocol.md)."""

from __future__ import annotations

import dataclasses
import enum
import importlib
import struct
import sys
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


class _Failure(Exception):
    """A failure of the driver itself, reported as an Error under ``spectest.``."""

    def __init__(self, cls: str, message: str):
        super().__init__(message)
        self.cls = cls
        self.message = message


def _error(exc: BaseException) -> Error:
    t = type(exc)
    bases = tuple(convert.qualified_name(b) for b in t.__mro__[1:] if b is not object)
    return Error(convert.qualified_name(t), bases, str(exc))


def _failure_error(f: _Failure) -> Error:
    return Error(f.cls, (), f.message)


def float_to_python(f: Float) -> float:
    """The f64 value of a wire float; a NaN keeps its payload (and sign) as far as f64
    can hold it."""
    fmt, bits = f.fmt, f.bits
    if fmt not in FLOAT_FORMATS:
        raise _Failure("spectest.ConvertError", f"unknown float format {fmt!r}")
    width = _WIDTH[fmt]
    if not 0 <= bits < (1 << width):
        raise _Failure("spectest.ConvertError", f"{bits} does not fit {fmt}")
    if fmt == "f64":
        return struct.unpack("<d", struct.pack("<Q", bits))[0]
    ebits, mbits = _LAYOUT[fmt]
    exp = (bits >> mbits) & ((1 << ebits) - 1)
    mant = bits & ((1 << mbits) - 1)
    if exp == (1 << ebits) - 1 and mant:
        sign = bits >> (width - 1)
        wide = (sign << 63) | (0x7FF << 52) | (mant << (52 - mbits))
        return struct.unpack("<d", struct.pack("<Q", wide))[0]
    if fmt == "bf16":
        return struct.unpack("<f", struct.pack("<I", bits << 16))[0]
    return struct.unpack(_PACK[fmt], struct.pack(_UINT[fmt], bits))[0]


def float_from_python(x: float) -> Float:
    return Float("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


class Driver:
    def __init__(self, max_elements: int = 2**17):
        self.max_elements = max_elements
        self._targets: dict[int, Any] = {}  # id -> the resolved object
        self._fns: dict[int, Any] = {}  # id -> what `call` invokes
        self._by_name: dict[str, int] = {}
        self._next_target = 1
        self._objects: dict[int, Any] = {}  # handle id -> object
        self._ids: dict[int, int] = {}  # id(object) -> handle id
        self._next_handle = 1

    # -- protocol methods ---------------------------------------------------

    def resolve(self, name: str) -> int | Error:
        tid = self._by_name.get(name)
        if tid is not None:
            return tid
        try:
            obj = self._lookup(name)
        except _Failure as f:
            return _failure_error(f)
        fn = obj
        if isinstance(obj, property):
            fn = obj.fget
            if fn is None:
                return Error(
                    "spectest.ResolveError", (), f"property {name} has no getter"
                )
        elif type(obj).__name__ in ("member_descriptor", "getset_descriptor"):
            fn = obj.__get__
        tid = self._next_target
        self._next_target += 1
        self._targets[tid] = obj
        self._fns[tid] = fn
        self._by_name[name] = tid
        return tid

    def call(self, target: int, args: Any, kwargs: Any = None) -> Any:
        fn = self._fns.get(target)
        if fn is None:
            return Error("spectest.ResolveError", (), f"unknown target {target}")
        try:
            pargs = [a if type(a) in _SIMPLE else self._to_python(a) for a in args]
            if kwargs:
                pkw = (
                    self._to_python(kwargs)
                    if isinstance(kwargs, Map)
                    else {k: self._to_python(v) for k, v in dict(kwargs).items()}
                )
            else:
                pkw = None
        except _Failure as f:
            return _failure_error(f)
        except Exception as exc:
            return Error("spectest.ConvertError", (), f"{type(exc).__name__}: {exc}")
        try:
            result = fn(*pargs, **pkw) if pkw else fn(*pargs)
        except Exception as exc:
            return _error(exc)
        if type(result) in _SIMPLE:
            return result
        return self._result(result)

    def get(self, target: int) -> Any:
        obj = self._targets.get(target, _MISSING)
        if obj is _MISSING:
            return Error("spectest.ResolveError", (), f"unknown target {target}")
        return self._result(obj)

    def observe(self, obj: Any, name: str, args: Any = None) -> Any:
        try:
            subject = self._to_python(obj)
            attr = getattr(subject, name)
            if args is not None:
                pargs = [self._to_python(a) for a in args]
                attr = attr(*pargs)
        except _Failure as f:
            return _failure_error(f)
        except Exception as exc:
            return _error(exc)
        return self._result(attr)

    def release(self, ids: Any) -> None:
        for i in ids:
            obj = self._objects.pop(i, _MISSING)
            if obj is not _MISSING:
                self._ids.pop(id(obj), None)

    def converters(self) -> dict[str, str]:
        return convert.registered()

    # -- name resolution ----------------------------------------------------

    def _lookup(self, name: str) -> Any:
        parts = name.split(".")
        if not name or "" in parts:
            raise _Failure("spectest.ResolveError", f"bad name {name!r}")
        module = None
        used = 0
        for n in range(len(parts), 0, -1):
            prefix = ".".join(parts[:n])
            try:
                module = importlib.import_module(prefix)
            except ImportError as exc:
                missing = getattr(exc, "name", None)
                if (
                    isinstance(exc, ModuleNotFoundError)
                    and missing
                    and (prefix == missing or prefix.startswith(missing + "."))
                ):
                    continue
                raise _Failure(
                    "spectest.ResolveError", f"importing {prefix} failed: {exc}"
                ) from None
            except Exception as exc:
                raise _Failure(
                    "spectest.ResolveError", f"importing {prefix} failed: {exc!r}"
                ) from None
            used = n
            break
        if module is None:
            raise _Failure("spectest.ResolveError", f"no module for {name}")
        obj: Any = module
        for i in range(used, len(parts)):
            try:
                obj = getattr(obj, parts[i])
            except AttributeError:
                raise _Failure(
                    "spectest.ResolveError",
                    f"{'.'.join(parts[:i])} has no attribute {parts[i]}",
                ) from None
        return obj

    def _class_named(self, name: str) -> Any:
        tid = self.resolve(name)
        if isinstance(tid, Error):
            raise _Failure(
                "spectest.ConvertError", f"unknown class {name}: {tid.message}"
            )
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
            return _failure_error(f)
        except Exception as exc:
            return _error(exc)

    def _handle(self, obj: Any) -> Handle:
        hid = self._ids.get(id(obj))
        if hid is None:
            hid = self._next_handle
            self._next_handle += 1
            self._ids[id(obj)] = hid
            self._objects[hid] = obj
        return Handle(hid, convert.qualified_name(type(obj)))

    def _to_wire(self, o: Any, budget: list[int]) -> Any:
        budget[0] -= 1
        if budget[0] < 0:
            raise _TooLarge
        t = type(o)
        if t in _SIMPLE:
            return o
        if t is float:
            return Float("f64", struct.unpack("<Q", struct.pack("<d", o))[0])
        if t.__module__ == "numpy":
            r = self._numpy(o, t)
            if r is not _MISSING:
                return r
        if isinstance(o, _BYTES_LIKE):
            return bytes(o)
        reg = convert.find(t)
        if reg is not None:
            return Converted(reg.name, self._to_wire(reg.to_wire(o), budget))
        if isinstance(o, enum.Enum):
            return Enum(convert.qualified_name(t), o.name)
        if isinstance(o, tuple) and hasattr(t, "_fields"):
            return Record(
                convert.qualified_name(t),
                tuple((f, self._to_wire(v, budget)) for f, v in zip(t._fields, o)),
            )
        if dataclasses.is_dataclass(o) and not isinstance(o, type):
            return Record(
                convert.qualified_name(t),
                tuple(
                    (f.name, self._to_wire(getattr(o, f.name), budget))
                    for f in dataclasses.fields(o)
                ),
            )
        if isinstance(o, tuple):
            if t is tuple:
                return tuple([self._to_wire(v, budget) for v in o])
        elif t is list:
            return [self._to_wire(v, budget) for v in o]
        elif t is dict:
            return Map(
                tuple(
                    (self._to_wire(k, budget), self._to_wire(v, budget))
                    for k, v in o.items()
                )
            )
        # subclasses of the plain kinds
        if isinstance(o, bool):
            return bool(o)
        if isinstance(o, int):
            return int(o)
        if isinstance(o, str):
            return str(o)
        if isinstance(o, float):
            return float_from_python(float(o))
        if isinstance(o, tuple):
            return tuple([self._to_wire(v, budget) for v in o])
        if isinstance(o, list):
            return [self._to_wire(v, budget) for v in o]
        if isinstance(o, dict):
            return Map(
                tuple(
                    (self._to_wire(k, budget), self._to_wire(v, budget))
                    for k, v in o.items()
                )
            )
        return self._handle(o)

    def _numpy(self, o: Any, t: type) -> Any:
        np = sys.modules.get("numpy")
        if np is None:
            return _MISSING
        if isinstance(o, np.floating):
            fmt = _NUMPY_FLOAT_FORMATS.get(t.__name__)
            if fmt is None:
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
        if t in _SIMPLE or t is bytes:
            return w
        if t is Float:
            return float_to_python(w)
        if t is list:
            return [a if type(a) in _SIMPLE else self._to_python(a) for a in w]
        if t is tuple:
            return tuple([self._to_python(a) for a in w])
        if t is Handle:
            try:
                return self._objects[w.id]
            except (KeyError, TypeError):
                raise _Failure(
                    "spectest.ConvertError", f"unknown handle {w.id}"
                ) from None
        if t is Map:
            try:
                return {self._to_python(k): self._to_python(v) for k, v in w.pairs}
            except TypeError as exc:
                raise _Failure(
                    "spectest.ConvertError", f"unhashable map key: {exc}"
                ) from None
        if t is Record:
            cls = self._class_named(w.type)
            kwargs = {k: self._to_python(v) for k, v in w.fields}
            try:
                return cls(**kwargs)
            except Exception as exc:
                raise _Failure(
                    "spectest.ConvertError",
                    f"cannot build {w.type} from its fields: {exc}",
                ) from None
        if t is Enum:
            if w.type == "":
                return w.member
            cls = self._class_named(w.type)
            try:
                return getattr(cls, w.member)
            except AttributeError:
                raise _Failure(
                    "spectest.ConvertError", f"{w.type} has no member {w.member}"
                ) from None
        if t is Converted:
            reg = convert.by_name(w.cls)
            if reg is None or reg.from_wire is None:
                raise _Failure(
                    "spectest.ConvertError",
                    f"no inverse converter registered for {w.cls}",
                )
            return reg.from_wire(self._to_python(w.value))
        if isinstance(w, bytearray | memoryview):
            return bytes(w)
        raise _Failure("spectest.ConvertError", f"{t.__name__} is not a wire object")


class _TooLarge(Exception):
    pass


_MISSING = object()
