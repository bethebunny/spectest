"""Runtime values of the spec language.

The evaluator, the prelude, generation and bindings all exchange these Python
representations. Static types decide how a value is read, so the same Python
type can carry several spec types (a ``tuple`` is a ``list<T>`` or a tuple).

| Spec type                         | Python value                               |
| --------------------------------- | ------------------------------------------ |
| bool                              | bool                                       |
| int, i8..i64, u8..u64             | int                                        |
| f16, bf16, f32, f64               | FloatValue (format + raw bits)             |
| real                              | fractions.Fraction, or POS_INF / NEG_INF   |
| string                            | str                                        |
| bytes                             | bytes                                      |
| list<T>, (A, B, ...)              | tuple                                      |
| map<K, V>                         | MapValue                                   |
| option<T>                         | None for none, Some(x) for some(x)         |
| "a" | "b", enum members           | str                                        |
| record R                          | RecordValue                                |
| model / interface handles         | Handle                                     |
| qerr                              | QError (steps + nans)                      |
| set<T> (partition classes)        | bitpattern BDDSet over raw bit patterns    |
| unit                              | None                                       |
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Any, ClassVar

from spectest.types import FLOAT_FORMATS


@dataclass(frozen=True)
class FloatValue:
    """An IEEE 754 value kept bit-exact: signed zeros and NaN payloads survive."""

    fmt: str  # a key of spectest.types.FLOAT_FORMATS
    bits: int

    def __post_init__(self) -> None:
        exp_bits, man_bits = FLOAT_FORMATS[self.fmt]
        width = 1 + exp_bits + man_bits
        if not 0 <= self.bits < (1 << width):
            raise ValueError(f"{self.bits:#x} is not a {self.fmt} bit pattern")

    @property
    def width(self) -> int:
        exp_bits, man_bits = FLOAT_FORMATS[self.fmt]
        return 1 + exp_bits + man_bits

    def __repr__(self) -> str:
        from spectest.prelude import floats  # deferred: prelude depends on values

        return f"{self.fmt}({floats.format_float(self)})"


class _Infinity:
    """+inf or -inf in the extended reals."""

    __slots__ = ("sign",)

    def __init__(self, sign: int) -> None:
        self.sign = sign

    def __repr__(self) -> str:
        return "+inf" if self.sign > 0 else "-inf"

    def __reduce__(self) -> tuple[Any, ...]:
        return (_infinity, (self.sign,))


def _infinity(sign: int) -> _Infinity:
    return POS_INF if sign > 0 else NEG_INF


POS_INF = _Infinity(1)
NEG_INF = _Infinity(-1)

Real = Fraction | _Infinity


def is_infinity(x: object) -> bool:
    return isinstance(x, _Infinity)


@dataclass(frozen=True)
class QError:
    """A quantized error ``steps + nans·nan``, the value of ``qe(x, y)``.

    ``steps`` counts the floats between two values and ``nans`` the NaN
    mismatches; both are whole numbers >= 0. Errors add componentwise and are
    ordered componentwise, which is a partial order.
    """

    steps: int
    nans: int
    ZERO: ClassVar[QError]

    def __post_init__(self) -> None:
        for name in ("steps", "nans"):
            v = getattr(self, name)
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                raise ValueError(f"QError {name} must be an int >= 0, got {v!r}")

    def __add__(self, other: object) -> QError:
        if not isinstance(other, QError):
            return NotImplemented
        return QError(self.steps + other.steps, self.nans + other.nans)

    def le(self, other: QError) -> bool:
        """Componentwise ``self <= other``."""
        return self.steps <= other.steps and self.nans <= other.nans

    def max(self, other: QError) -> QError:
        """The componentwise maximum."""
        return QError(max(self.steps, other.steps), max(self.nans, other.nans))

    def __str__(self) -> str:
        if not self.nans:
            return str(self.steps)
        if not self.steps:
            return f"{self.nans}nan"
        return f"{self.steps} + {self.nans}nan"

    __repr__ = __str__


QError.ZERO = QError(0, 0)


@dataclass(frozen=True)
class Some:
    """The present case of option<T>; none is Python's None."""

    value: Any

    def __repr__(self) -> str:
        return f"some({self.value!r})"


@dataclass(frozen=True)
class MapValue:
    """An immutable map; items are kept in insertion order."""

    items: tuple[tuple[Any, Any], ...]

    def get(self, key: Any) -> Any:
        for k, v in self.items:
            if k == key:
                return v
        raise KeyError(key)


@dataclass(frozen=True)
class RecordValue:
    name: str
    fields: tuple[tuple[str, Any], ...]

    def get(self, name: str) -> Any:
        for k, v in self.fields:
            if k == name:
                return v
        raise KeyError(name)


_handle_ids = itertools.count(1)


@dataclass(eq=False)
class Handle:
    """A reference to an object that lives in the implementation.

    Handles compare by identity. ``obj`` is the concrete object (in-process
    bindings hold it directly); ``model`` names the model or interface;
    ``created_by`` records which call produced it, for freshness checks;
    ``targs`` are the type arguments of a generic model (``MutableList<i64>``),
    which decide the types of its observers.
    """

    obj: Any
    model: str
    id: int = field(default_factory=lambda: next(_handle_ids))
    created_by: str | None = None
    targs: tuple[Any, ...] = ()

    def __repr__(self) -> str:
        return f"<{self.model} #{self.id}>"


class SpecError(Exception):
    """Base of errors that are the spec's or the harness's fault, never the implementation's."""


class EvalError(SpecError):
    """Evaluating a clause failed: out-of-range index, NaN promoted to real, ...

    Clause verdict: spec error.
    """


class BindingError(SpecError):
    """A binding failed: a concretizer or observer raised, or a conversion is missing.

    Clause verdict: spec error.
    """


class Unrepresentable(Exception):
    """A concretizer cannot build this model value; the example is skipped."""


class NotAValue(Exception):
    """A model binding refuses an object: it is not a value of the model.

    Observers (and a ModelBinding's ``accepts``) raise it, e.g. for a frame
    whose columns have the wrong dtype. On an object the implementation
    returned, ``<fn>#type`` fails; on any other object it is a binding failure.
    """


class SkipClause(Exception):
    """The clause does not apply to this example (e.g. a planned call failed requires or raised)."""
