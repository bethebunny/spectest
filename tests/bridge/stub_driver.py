"""A small driver for the bridge tests: the protocol's methods (docs/v2/protocol.md)
with ``importlib`` and ``getattr``, converting only what the tests send."""

from __future__ import annotations

import importlib
import struct
from typing import Any

from spectest.driver.wire import Error, Float, Handle, Map, Record


class StubDriver:
    def __init__(self) -> None:
        self.targets: list[Any] = []
        self.ids: dict[str, int] = {}
        self.objects: dict[int, Any] = {}
        self.next_handle = 1
        self.released: list[int] = []
        self.calls = 0

    def resolve(self, name: str) -> int | Error:
        if name in self.ids:
            return self.ids[name]
        parts = name.split(".")
        obj: Any = None
        for cut in range(len(parts), 0, -1):
            try:
                obj = importlib.import_module(".".join(parts[:cut]))
            except ImportError:
                continue
            try:
                for attribute in parts[cut:]:
                    obj = getattr(obj, attribute)
            except AttributeError:
                break
            self.targets.append(obj)
            self.ids[name] = len(self.targets) - 1
            return self.ids[name]
        return Error("spectest.ResolveError", (), f"cannot resolve {name}")

    def call(self, target: int, args: list, kwargs: dict) -> Any:
        self.calls += 1
        try:
            result = self.targets[target](*[self.to_python(a) for a in args], **kwargs)
        except Exception as exc:  # noqa: BLE001
            return self.error(exc)
        return self.to_wire(result)

    def get(self, target: int) -> Any:
        return self.to_wire(self.targets[target])

    def observe(self, obj: Any, name: str, args: list | None) -> Any:
        try:
            value = getattr(self.to_python(obj), name)
            if args is not None:
                value = value(*[self.to_python(a) for a in args])
        except Exception as exc:  # noqa: BLE001
            return self.error(exc)
        return self.to_wire(value)

    def release(self, ids: list[int]) -> None:
        for i in ids:
            self.objects.pop(i, None)
            self.released.append(i)

    def converters(self) -> dict[str, str]:
        return {}

    def error(self, exc: Exception) -> Error:
        bases = tuple(c.__qualname__ for c in type(exc).__mro__[1:] if c is not object)
        return Error(type(exc).__qualname__, bases, str(exc))

    def to_python(self, w: Any) -> Any:
        if isinstance(w, Handle):
            return self.objects[w.id]
        if isinstance(w, Float):
            if w.fmt == "f64":
                return struct.unpack("<d", w.bits.to_bytes(8, "little"))[0]
            raise ValueError("stub: only f64")
        if isinstance(w, list):
            return [self.to_python(x) for x in w]
        if isinstance(w, tuple):
            return tuple(self.to_python(x) for x in w)
        return w

    def to_wire(self, v: Any) -> Any:
        if v is None or isinstance(v, bool | int | str | bytes):
            return v
        if isinstance(v, float):
            return Float("f64", struct.unpack("<Q", struct.pack("<d", v))[0])
        if isinstance(v, Float | Map | Record | Handle | Error):
            return v
        if isinstance(v, list):
            return [self.to_wire(x) for x in v]
        if isinstance(v, tuple):
            return tuple(self.to_wire(x) for x in v)
        handle = Handle(
            self.next_handle, f"{type(v).__module__}.{type(v).__qualname__}"
        )
        self.objects[self.next_handle] = v
        self.next_handle += 1
        return handle
