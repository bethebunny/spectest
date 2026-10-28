# ruff: noqa: BLE001
"""Converters between classes of the code under test and wire values.

``spectest.marshal(cls)`` registers a function that turns an object of ``cls`` into a
wire value; its ``.inverse`` decorator registers the function that turns the wire
value back. The registry is global: the driver reads it on every conversion.
"""

from __future__ import annotations

import typing
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

_KINDS = {
    int: "int",
    bool: "bool",
    str: "string",
    bytes: "bytes",
    float: "float",
    list: "list",
    tuple: "tuple",
    dict: "map",
    type(None): "none",
}


@dataclass(slots=True)
class Registration:
    cls: type
    name: str  # the qualified name of cls
    to_wire: Callable[[Any], Any]
    kind: str
    from_wire: Callable[[Any], Any] | None = None


_by_class: dict[type, Registration] = {}
_by_name: dict[str, Registration] = {}
_lookup_cache: dict[type, Registration | None] = {}


def qualified_name(cls: type) -> str:
    return f"{cls.__module__}.{cls.__qualname__}"


def _kind_of(fn: Callable[..., Any]) -> str:
    try:
        hints = typing.get_type_hints(fn)
    except Exception:
        hints = getattr(fn, "__annotations__", {})
    if (ret := hints.get("return")) is None:
        return "any"
    if type(ret) is str:
        name = ret.split("[", 1)[0].strip()
        return {"str": "string", "dict": "map"}.get(name, name)
    origin = typing.get_origin(ret) or ret
    return _KINDS.get(origin) or getattr(origin, "__name__", str(origin))


def marshal(cls: type) -> Callable[[Callable[[Any], Any]], Callable[[Any], Any]]:
    """Register the decorated function as the converter of ``cls`` to a wire value."""

    def register(fn: Callable[[Any], Any]) -> Callable[[Any], Any]:
        reg = Registration(cls, qualified_name(cls), fn, _kind_of(fn))
        _by_class[cls] = reg
        _by_name[reg.name] = reg
        _lookup_cache.clear()

        def inverse(inv: Callable[[Any], Any]) -> Callable[[Any], Any]:
            reg.from_wire = inv
            return inv

        fn.inverse = inverse  # type: ignore[attr-defined]
        return fn

    return register


def find(cls: type) -> Registration | None:
    """The registration for ``cls`` or its nearest registered base."""
    if cls not in _lookup_cache:
        _lookup_cache[cls] = next(
            (r for base in cls.__mro__ if (r := _by_class.get(base))), None
        )
    return _lookup_cache[cls]


def by_name(name: str) -> Registration | None:
    return _by_name.get(name)


def registered() -> dict[str, str]:
    return {r.name: r.kind for r in _by_class.values()}
