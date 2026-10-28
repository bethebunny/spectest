"""Static types of the spec language.

Types are immutable and hashable. The checker attaches one to every expression
node (``Expr.ty``) and to every declaration it resolves.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# Float formats: name -> (exponent bits, explicit mantissa bits).
FLOAT_FORMATS: dict[str, tuple[int, int]] = {
    "f16": (5, 10),
    "bf16": (8, 7),
    "f32": (8, 23),
    "f64": (11, 52),
}

# Fixed-width integer names -> (bits, signed).
INT_FORMATS: dict[str, tuple[int, bool]] = {
    f"{prefix}{bits}": (bits, prefix == "i")
    for prefix in ("i", "u")
    for bits in (8, 16, 32, 64)
}


class Type:
    """Base class of every static type."""

    def __str__(self) -> str:  # pragma: no cover - overridden
        return type(self).__name__


@dataclass(frozen=True)
class BoolT(Type):
    def __str__(self) -> str:
        return "bool"


@dataclass(frozen=True)
class IntT(Type):
    """Unbounded mathematical integers."""

    def __str__(self) -> str:
        return "int"


@dataclass(frozen=True)
class FixedIntT(Type):
    bits: int
    signed: bool

    @property
    def name(self) -> str:
        return f"{'i' if self.signed else 'u'}{self.bits}"

    @property
    def min(self) -> int:
        return -(1 << (self.bits - 1)) if self.signed else 0

    @property
    def max(self) -> int:
        return (1 << (self.bits - 1)) - 1 if self.signed else (1 << self.bits) - 1

    def __str__(self) -> str:
        return self.name


@dataclass(frozen=True)
class FloatT(Type):
    fmt: str  # a key of FLOAT_FORMATS

    @property
    def exp_bits(self) -> int:
        return FLOAT_FORMATS[self.fmt][0]

    @property
    def man_bits(self) -> int:
        return FLOAT_FORMATS[self.fmt][1]

    @property
    def width(self) -> int:
        return 1 + self.exp_bits + self.man_bits

    def __str__(self) -> str:
        return self.fmt


@dataclass(frozen=True)
class RealT(Type):
    """Extended reals: exact rationals plus +-infinity. Clause-only."""

    def __str__(self) -> str:
        return "real"


@dataclass(frozen=True)
class StringT(Type):
    def __str__(self) -> str:
        return "string"


@dataclass(frozen=True)
class BytesT(Type):
    def __str__(self) -> str:
        return "bytes"


@dataclass(frozen=True)
class UnitT(Type):
    """The result type of a function or method that returns nothing."""

    def __str__(self) -> str:
        return "unit"


@dataclass(frozen=True)
class QErrT(Type):
    """Quantized errors k + m·nan from ``qe``: canonical equality, componentwise order."""

    def __str__(self) -> str:
        return "qerr"


@dataclass(frozen=True)
class ListT(Type):
    elem: Type

    def __str__(self) -> str:
        return f"list<{self.elem}>"


@dataclass(frozen=True)
class MapT(Type):
    key: Type
    value: Type

    def __str__(self) -> str:
        return f"map<{self.key}, {self.value}>"


@dataclass(frozen=True)
class TupleT(Type):
    elems: tuple[Type, ...]

    def __str__(self) -> str:
        return "(" + ", ".join(map(str, self.elems)) + ")"


@dataclass(frozen=True)
class OptionT(Type):
    elem: Type

    def __str__(self) -> str:
        return f"option<{self.elem}>"


@dataclass(frozen=True)
class LiteralT(Type):
    """A union of string literals, e.g. "any" | "all"."""

    values: tuple[str, ...]

    def __str__(self) -> str:
        return " | ".join(f'"{v}"' for v in self.values)


@dataclass(frozen=True)
class EnumT(Type):
    name: str
    members: tuple[str, ...]

    def __str__(self) -> str:
        return self.name


@dataclass(frozen=True)
class RecordT(Type):
    name: str
    fields: tuple[tuple[str, Type], ...]

    def __str__(self) -> str:
        return self.name


@dataclass(frozen=True)
class ModelT(Type):
    """A handle to an object of a declared model, or of an interface."""

    name: str
    args: tuple[Type, ...] = ()
    is_interface: bool = False

    def __str__(self) -> str:
        if not self.args:
            return self.name
        return f"{self.name}<{', '.join(map(str, self.args))}>"


@dataclass(frozen=True)
class TypeVarT(Type):
    """A type parameter; bound is None, "Eq" or "Ord"."""

    name: str
    bound: str | None = None

    def __str__(self) -> str:
        return self.name


@dataclass(frozen=True)
class SetT(Type):
    """A set of values of a fixed-width scalar type (partition classes)."""

    elem: Type

    def __str__(self) -> str:
        return f"set<{self.elem}>"


@dataclass(frozen=True)
class ErrorT(Type):
    """An error variant declared with `error Name`."""

    name: str

    def __str__(self) -> str:
        return self.name


@dataclass(frozen=True)
class AnyT(Type):
    """Placeholder the checker uses when a type cannot be inferred.

    The checker reports an error whenever AnyT would decide the equality rule.
    """

    def __str__(self) -> str:
        return "?"


@dataclass(frozen=True)
class FnT(Type):
    """Signature of a spec function, method, constructor or observer."""

    params: tuple[Type, ...]
    result: Type
    param_names: tuple[str, ...] = field(default=())

    def __str__(self) -> str:
        return f"({', '.join(map(str, self.params))}) -> {self.result}"


BOOL = BoolT()
INT = IntT()
REAL = RealT()
STRING = StringT()
BYTES = BytesT()
UNIT = UnitT()
QERR = QErrT()
ANY = AnyT()


def scalar_type(name: str) -> Type | None:
    """Return the built-in scalar type for a name, or None."""
    if name in FLOAT_FORMATS:
        return FloatT(name)
    if name in INT_FORMATS:
        bits, signed = INT_FORMATS[name]
        return FixedIntT(bits, signed)
    return {
        "bool": BOOL,
        "int": INT,
        "real": REAL,
        "string": STRING,
        "bytes": BYTES,
    }.get(name)


def is_integer(t: Type) -> bool:
    return isinstance(t, (IntT, FixedIntT))


def is_numeric(t: Type) -> bool:
    return isinstance(t, (IntT, FixedIntT, FloatT, RealT))


def is_fixed_width(t: Type) -> bool:
    """Types whose values are finite sets of bit patterns (partition sets apply)."""
    return isinstance(t, (FixedIntT, FloatT, BoolT))


def has_canonical_eq(t: Type) -> bool:
    """The equality rule: may `==`, `!=` and `in` be used on values of type t?"""
    if isinstance(
        t, (BoolT, IntT, FixedIntT, RealT, StringT, BytesT, LiteralT, EnumT, UnitT, QErrT)
    ):
        return True
    if isinstance(t, (FloatT, ModelT, SetT, FnT, AnyT, ErrorT)):
        return False
    if isinstance(t, (ListT, OptionT)):
        return has_canonical_eq(t.elem)
    if isinstance(t, MapT):
        return has_canonical_eq(t.key) and has_canonical_eq(t.value)
    if isinstance(t, TupleT):
        return all(has_canonical_eq(e) for e in t.elems)
    if isinstance(t, RecordT):
        return all(has_canonical_eq(ft) for _, ft in t.fields)
    if isinstance(t, TypeVarT):
        return t.bound in ("Eq", "Ord")
    return False


def has_total_order(t: Type) -> bool:
    """May `<`, `sorted`, `is_sorted` be used on values of type t?

    Floats are ordered only after promotion to real (NaN is an evaluation error).
    qerr is not: its componentwise order is partial.
    """
    if isinstance(t, (IntT, FixedIntT, RealT, StringT, BytesT, BoolT)):
        return True
    if isinstance(t, TypeVarT):
        return t.bound == "Ord"
    if isinstance(t, TupleT):
        return all(has_total_order(e) for e in t.elems)
    if isinstance(t, ListT):
        return has_total_order(t.elem)
    return False


def substitute(t: Type, env: dict[str, Type]) -> Type:
    """Replace type variables by name."""
    if isinstance(t, TypeVarT):
        return env.get(t.name, t)
    if isinstance(t, ListT):
        return ListT(substitute(t.elem, env))
    if isinstance(t, OptionT):
        return OptionT(substitute(t.elem, env))
    if isinstance(t, SetT):
        return SetT(substitute(t.elem, env))
    if isinstance(t, MapT):
        return MapT(substitute(t.key, env), substitute(t.value, env))
    if isinstance(t, TupleT):
        return TupleT(tuple(substitute(e, env) for e in t.elems))
    if isinstance(t, ModelT):
        return ModelT(t.name, tuple(substitute(a, env) for a in t.args), t.is_interface)
    if isinstance(t, FnT):
        return FnT(
            tuple(substitute(p, env) for p in t.params),
            substitute(t.result, env),
            t.param_names,
        )
    return t
