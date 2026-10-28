"""Wire values as Python objects: what the host and the Python driver pass each other.

Plain Python types carry the simple kinds: ``None`` (an empty option, or no result),
``bool``, ``int`` (any size), ``str``, ``bytes``, ``list`` and ``tuple``. A present
option is its value, unwrapped; the host knows from the spec's types where an option
is expected. The classes below carry the rest.

These objects are untyped. The host reads them against the declared type: a ``None``
where ``option<T>`` is expected is ``none``, and a ``Map`` where a record is expected
must have exactly the record's fields.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

FLOAT_FORMATS = ("f16", "bf16", "f32", "f64")


@dataclass(frozen=True, slots=True)
class Float:
    """A float of one format, as its bit pattern (so -0.0 and NaN payloads survive)."""

    fmt: str  # one of FLOAT_FORMATS
    bits: int  # the pattern, zero-extended


@dataclass(frozen=True, slots=True)
class Map:
    """Key-value pairs in order. Keys may be any wire value, hashable or not."""

    pairs: tuple[tuple[Any, Any], ...]


@dataclass(frozen=True, slots=True)
class Record:
    """A dataclass or named tuple: ``type`` is its class's qualified name."""

    type: str
    fields: tuple[tuple[str, Any], ...]


@dataclass(frozen=True, slots=True)
class Enum:
    """An enum member: ``type`` is the class's qualified name (``""`` for a member of a
    string-literal union, which crosses to Python as the plain string)."""

    type: str
    member: str


@dataclass(frozen=True, slots=True)
class Handle:
    """An object that stays in the driver: its id in the driver's table and its class."""

    id: int
    cls: str


@dataclass(frozen=True, slots=True)
class Error:
    """A raised exception: qualified names of its class and bases (nearest first, without
    ``object``), and ``str(exc)``. The driver's own failures use classes under ``spectest.``."""

    cls: str
    bases: tuple[str, ...]
    message: str


@dataclass(frozen=True, slots=True)
class Converted:
    """A value of a class with a registered converter, and the wire value it converts to."""

    cls: str
    value: Any
