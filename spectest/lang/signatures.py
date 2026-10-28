"""Static signatures of the prelude, type constants and set constructors.

This table is the contract between the checker and the prelude
(spectest.prelude): every name here has an implementation there with the
same arity and keyword arguments. ``T`` is a float format (f16, bf16, f32,
f64); "real" accepts int, fixed-width ints, floats (promoted) and real.
``qe`` takes an optional type argument (``qe<T>(a, b)``); the other generic
functions require theirs.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from spectest import ast
from spectest.types import (
    BOOL,
    INT,
    QERR,
    REAL,
    STRING,
    AnyT,
    BoolT,
    BytesT,
    FixedIntT,
    FloatT,
    FnT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    QErrT,
    RealT,
    RecordT,
    SetT,
    StringT,
    TupleT,
    Type,
    TypeVarT,
    has_total_order,
    is_integer,
    is_numeric,
)

FLOAT_SETS = (
    "nan", "inf", "zero", "subnormal", "normal", "finite", "positive", "negative", "all",
)  # fmt: skip
SET_CONSTRUCTORS = ("range", "pattern")
GENERIC_PRELUDE = ("wrap", "fits", "round", "ulp", "qe")
OPTIONAL_TYPE_ARGS = ("qe",)
CR_FUNCTIONS = ("sqrt", "exp", "log", "sin", "cos", "tan", "atan")
CLASSIFIER_HINTS = {
    "nan": "is_nan(x)",
    "inf": "is_inf(x)",
    "zero": "is_zero(x)",
    "subnormal": "is_subnormal(x)",
    "finite": "is_finite(x)",
    "negative": "signbit(x)",
    "positive": "not signbit(x)",
}
EQ_FLOAT_MODES = ("bits", "ieee", "nan_any")
EQ_ORDER_MODES = ("exact", "ignore")


class SigError(Exception):
    """A prelude call is ill-typed; ``where`` is an argument index or keyword name."""

    def __init__(self, message: str, where: int | str | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.where = where


@dataclass
class CallInfo:
    """What a typing function sees of one call."""

    name: str
    args: list[Type]
    nodes: list[ast.Expr] = field(default_factory=list)
    kwargs: dict[str, tuple[Type, ast.Expr]] = field(default_factory=dict)
    type_args: list[Type] = field(default_factory=list)
    contains_float: Callable[[Type], bool] | None = None

    def floats_in(self, t: Type) -> bool:
        return (self.contains_float or contains_float)(t)


@dataclass(frozen=True)
class PreludeSig:
    name: str
    shape: str  # human-readable signature, used in messages
    arity: tuple[int, int]  # (min, max) positional arguments
    typer: Callable[[CallInfo], Type]
    type_args: int = 0
    kwargs: tuple[str, ...] = ()
    needs_ctx: bool = False
    optional_type_args: bool = False  # the type arguments may be left out


# ---------------------------------------------------------------------------
# Type utilities shared with the checker


def is_any(t: Type) -> bool:
    return isinstance(t, AnyT)


def contains_any(t: Type) -> bool:
    if isinstance(t, AnyT):
        return True
    return any(contains_any(c) for c in components(t))


def components(t: Type) -> tuple[Type, ...]:
    if isinstance(t, (ListT, OptionT, SetT)):
        return (t.elem,)
    if isinstance(t, MapT):
        return (t.key, t.value)
    if isinstance(t, TupleT):
        return t.elems
    if isinstance(t, RecordT):
        return tuple(ft for _, ft in t.fields)
    if isinstance(t, ModelT):
        return t.args
    return ()


def contains_float(t: Type) -> bool:
    """Whether a value of type t can hold a float (model handles are not expanded)."""
    if isinstance(t, FloatT):
        return True
    if isinstance(t, ModelT):
        return False
    return any(contains_float(c) for c in components(t))


def is_stringish(t: Type) -> bool:
    return isinstance(t, (StringT, LiteralT))


def join(a: Type, b: Type) -> Type | None:
    """The common type of two values (if-branches, list elements, operands of == and same).

    Integers of any width join to int, integers and reals to real; a float
    joins only with the same float format. None when there is no common type.
    """
    if isinstance(a, AnyT):
        return b
    if isinstance(b, AnyT):
        return a
    if a == b:
        return a
    if isinstance(a, FloatT) or isinstance(b, FloatT):
        return None
    if is_integer(a) and is_integer(b):
        return INT
    if is_numeric(a) and is_numeric(b):
        return REAL
    if is_stringish(a) and is_stringish(b):
        return STRING
    if isinstance(a, ListT) and isinstance(b, ListT):
        e = join(a.elem, b.elem)
        return None if e is None else ListT(e)
    if isinstance(a, OptionT) and isinstance(b, OptionT):
        e = join(a.elem, b.elem)
        return None if e is None else OptionT(e)
    if isinstance(a, MapT) and isinstance(b, MapT):
        k, v = join(a.key, b.key), join(a.value, b.value)
        return None if k is None or v is None else MapT(k, v)
    if isinstance(a, TupleT) and isinstance(b, TupleT) and len(a.elems) == len(b.elems):
        elems = [join(x, y) for x, y in zip(a.elems, b.elems, strict=True)]
        if any(e is None for e in elems):
            return None
        return TupleT(tuple(e for e in elems if e is not None))
    return None


def non_eq_part(t: Type) -> Type | None:
    """The component of t that lacks canonical equality, or None (unknown parts pass)."""
    if isinstance(t, AnyT):
        return None
    if isinstance(t, (FloatT, ModelT, SetT, FnT)):
        return t
    if isinstance(t, TypeVarT):
        return None if t.bound in ("Eq", "Ord") else t
    if isinstance(t, (ListT, OptionT, MapT, TupleT, RecordT)):
        for c in components(t):
            bad = non_eq_part(c)
            if bad is not None:
                return bad
    return None


def ordered(t: Type) -> bool:
    """has_total_order, letting unknown parts (an empty list literal) pass."""
    if isinstance(t, AnyT):
        return True
    if isinstance(t, ListT):
        return ordered(t.elem)
    if isinstance(t, TupleT):
        return all(ordered(e) for e in t.elems)
    return has_total_order(t)


def satisfies(t: Type, bound: str | None) -> bool:
    """Does type t meet a type-parameter bound (None, "Eq" or "Ord")?"""
    if bound is None or isinstance(t, AnyT):
        return True
    if bound == "Eq":
        return non_eq_part(t) is None
    return non_eq_part(t) is None and ordered(t)


def type_constant(scalar: Type, attr: str) -> Type | None:
    """Type of ``T.attr`` for a scalar type name, or None if T has no such constant."""
    if isinstance(scalar, FloatT):
        if attr in ("min", "max"):
            return scalar
        if attr in FLOAT_SETS:
            return SetT(scalar)
    elif isinstance(scalar, FixedIntT):
        if attr in ("min", "max"):
            return INT
        if attr == "all":
            return SetT(scalar)
    elif isinstance(scalar, BoolT) and attr == "all":
        return SetT(scalar)
    return None


def constants_of(scalar: Type) -> list[str]:
    """Names usable after ``T.`` for a scalar type (for messages)."""
    if isinstance(scalar, FloatT):
        return ["min", "max", *FLOAT_SETS, "range(a, b)", 'pattern("...")']
    if isinstance(scalar, FixedIntT):
        return ["min", "max", "all", "range(a, b)", 'pattern("...")']
    if isinstance(scalar, BoolT):
        return ["all"]
    return []


def has_set_constructor(scalar: Type, attr: str) -> bool:
    return attr in SET_CONSTRUCTORS and isinstance(scalar, (FloatT, FixedIntT))


# ---------------------------------------------------------------------------
# Argument checks


def _ord(i: int) -> str:
    return f"argument {i + 1}"


def _float(c: CallInfo, i: int) -> Type:
    t = c.args[i]
    if isinstance(t, (FloatT, AnyT)):
        return t
    hint = ""
    if is_numeric(t):
        hint = f" ({t} is not a float type; floats are f16, bf16, f32, f64)"
    raise SigError(f"{c.name} takes a float, but {_ord(i)} is {t}{hint}", i)


def _real_like(c: CallInfo, i: int) -> Type:
    t = c.args[i]
    if is_numeric(t) or isinstance(t, AnyT):
        return t
    raise SigError(
        f"{c.name} takes a number (int, fixed-width int, float or real), but {_ord(i)} is {t}", i
    )


def _integer(c: CallInfo, i: int) -> Type:
    t = c.args[i]
    if is_integer(t) or isinstance(t, AnyT):
        return t
    hint = " (use // for integer division)" if isinstance(t, RealT) else ""
    raise SigError(f"{c.name} takes an integer, but {_ord(i)} is {t}{hint}", i)


def _list(c: CallInfo, i: int) -> Type:
    t = c.args[i]
    if isinstance(t, ListT):
        return t.elem
    if isinstance(t, AnyT):
        return t
    raise SigError(f"{c.name} takes a list, but {_ord(i)} is {t}", i)


def _option(c: CallInfo, i: int) -> Type:
    t = c.args[i]
    if isinstance(t, OptionT):
        return t.elem
    if isinstance(t, AnyT):
        return t
    raise SigError(f"{c.name} takes an option, but {_ord(i)} is {t}", i)


def _map(c: CallInfo, i: int) -> MapT | AnyT:
    t = c.args[i]
    if isinstance(t, (MapT, AnyT)):
        return t
    raise SigError(f"{c.name} takes a map, but {_ord(i)} is {t}", i)


def _bytes(c: CallInfo, i: int) -> None:
    t = c.args[i]
    if not isinstance(t, (BytesT, AnyT)):
        raise SigError(f"{c.name} takes bytes, but {_ord(i)} is {t}", i)


def _model(c: CallInfo, i: int) -> None:
    t = c.args[i]
    if not isinstance(t, (ModelT, AnyT)):
        raise SigError(f"{c.name} takes a model or interface handle, but {_ord(i)} is {t}", i)


def _eq_elems(c: CallInfo, elem: Type, what: str) -> None:
    bad = non_eq_part(elem)
    if bad is None:
        return
    if isinstance(bad, FloatT):
        hint = (
            "floats have no canonical equality; map them to bits(x) or real(x) first, "
            "or compare whole values with eq(a, b, float=...)"
        )
    elif isinstance(bad, ModelT):
        hint = f"model {bad.name} handles have no canonical equality"
    elif isinstance(bad, TypeVarT):
        hint = f"declare the type parameter as {bad.name}: Eq"
    else:
        hint = f"{bad} has no canonical equality"
    raise SigError(
        f"{c.name} compares {what} with ==, but {elem} has no canonical equality: {hint}"
    )


def _ordered_elems(c: CallInfo, elem: Type) -> None:
    if ordered(elem):
        return
    if isinstance(elem, FloatT):
        hint = "floats have no total order (NaN); map them to real(x) first"
    elif isinstance(elem, TypeVarT):
        hint = f"declare the type parameter as {elem.name}: Ord"
    else:
        hint = f"{elem} has no total order"
    raise SigError(f"{c.name} needs ordered elements, but the elements are {elem}: {hint}", 0)


def _same_type(c: CallInfo, i: int, j: int) -> Type:
    t = join(c.args[i], c.args[j])
    if t is None:
        raise SigError(
            f"{c.name} compares two values of one type, but got {c.args[i]} and {c.args[j]}", j
        )
    return t


def _type_arg(c: CallInfo, kinds: tuple[type, ...], what: str) -> Type:
    t = c.type_args[0]
    if isinstance(t, (*kinds, AnyT)):
        return t
    raise SigError(f"{c.name}<{t}>: the type argument must be {what}")


# ---------------------------------------------------------------------------
# Typing functions


def _float_pred(c: CallInfo) -> Type:
    _float(c, 0)
    return BOOL


def _bits(c: CallInfo) -> Type:
    _float(c, 0)
    return INT


def _same_float(c: CallInfo) -> Type:
    return _float(c, 0)


def _ulp(c: CallInfo) -> Type:
    _type_arg(c, (FloatT,), "a float type (f16, bf16, f32, f64)")
    _real_like(c, 0)
    return REAL


def _qe_untyped(c: CallInfo, i: int) -> Type:
    t = c.args[i]
    if isinstance(t, (FloatT, AnyT)):
        return t
    hint = ""
    if is_numeric(t):
        hint = (
            f" ({t} is not a float: round a real first, qe(result, round<f64>(r)), "
            "or name the format, qe<f64>(result, r))"
        )
    raise SigError(f"qe compares two floats of one format, but {_ord(i)} is {t}{hint}", i)


def _qe(c: CallInfo) -> Type:
    if c.type_args:
        t = _type_arg(c, (FloatT,), "a float type (f16, bf16, f32, f64)")
        for i in (0, 1):
            a = c.args[i]
            if isinstance(a, AnyT) or isinstance(t, AnyT):
                continue
            if isinstance(a, FloatT) and a != t:
                raise SigError(f"qe<{t}> compares {t} values, but {_ord(i)} is {a}", i)
            if not is_numeric(a):
                raise SigError(f"qe<{t}> takes {t} values or numbers, but {_ord(i)} is {a}", i)
        return QERR
    a, b = _qe_untyped(c, 0), _qe_untyped(c, 1)
    if isinstance(a, FloatT) and isinstance(b, FloatT) and a != b:
        raise SigError(
            f"qe compares two floats of one format, but got {a} and {b}: convert one first", 1
        )
    return QERR


def _qerr_part(c: CallInfo) -> Type:
    t = c.args[0]
    if not isinstance(t, (QErrT, AnyT)):
        raise SigError(f"{c.name} takes a qerr (the value of qe(a, b)), but argument 1 is {t}", 0)
    return INT


def _cr(c: CallInfo) -> Type:
    t = c.args[0]
    if isinstance(t, (FloatT, AnyT)):
        return t
    hint = f"; for a real use mp.{c.name[3:]}" if is_numeric(t) else ""
    raise SigError(
        f"{c.name} rounds in the format of its argument, so it takes a float, "
        f"but argument 1 is {t}{hint}",
        0,
    )


def _same(c: CallInfo) -> Type:
    _same_type(c, 0, 1)
    return BOOL


def _ieee_eq(c: CallInfo) -> Type:
    _float(c, 0)
    _float(c, 1)
    return BOOL


def _real(c: CallInfo) -> Type:
    _real_like(c, 0)
    return REAL


def _round(c: CallInfo) -> Type:
    t = _type_arg(c, (FloatT,), "a float type (f16, bf16, f32, f64)")
    _real_like(c, 0)
    return t


def _wrap(c: CallInfo) -> Type:
    t = _type_arg(c, (FixedIntT,), "a fixed-width integer type (i8 ... u64)")
    _integer(c, 0)
    return t


def _fits(c: CallInfo) -> Type:
    _type_arg(c, (FixedIntT, FloatT), "a fixed-width integer or float type")
    _real_like(c, 0)
    return BOOL


def _mp(c: CallInfo) -> Type:
    _real_like(c, 0)
    return REAL


def _le_uint(c: CallInfo) -> Type:
    _bytes(c, 0)
    return INT


def _len(c: CallInfo) -> Type:
    t = c.args[0]
    if isinstance(t, (ListT, StringT, LiteralT, BytesT, MapT, AnyT)):
        return INT
    raise SigError(f"len takes a list, string, bytes or map, but argument 1 is {t}", 0)


def _sorted(c: CallInfo) -> Type:
    elem = _list(c, 0)
    _ordered_elems(c, elem)
    return c.args[0] if isinstance(c.args[0], ListT) else ListT(elem)


def _is_sorted(c: CallInfo) -> Type:
    _ordered_elems(c, _list(c, 0))
    return BOOL


def _two_lists(c: CallInfo) -> Type:
    a, b = _list(c, 0), _list(c, 1)
    elem = join(a, b)
    if elem is None:
        raise SigError(
            f"{c.name} takes two lists of one element type, but got {c.args[0]} and {c.args[1]}", 1
        )
    _eq_elems(c, elem, "elements")
    return BOOL


def _distinct(c: CallInfo) -> Type:
    _eq_elems(c, _list(c, 0), "elements")
    return BOOL


def _index_of(c: CallInfo) -> Type:
    elem = _list(c, 0)
    t = join(elem, c.args[1])
    if t is None:
        raise SigError(
            f"index_of looks for a {elem} in {c.args[0]}, but argument 2 is {c.args[1]}", 1
        )
    _eq_elems(c, t, "elements")
    return INT


def _keys(c: CallInfo) -> Type:
    m = _map(c, 0)
    return ListT(m.key) if isinstance(m, MapT) else ListT(m)


def _values(c: CallInfo) -> Type:
    m = _map(c, 0)
    return ListT(m.value) if isinstance(m, MapT) else ListT(m)


def _range(c: CallInfo) -> Type:
    _integer(c, 0)
    _integer(c, 1)
    return ListT(INT)


def _some(c: CallInfo) -> Type:
    return OptionT(c.args[0])


def _opt_pred(c: CallInfo) -> Type:
    _option(c, 0)
    return BOOL


def _unwrap(c: CallInfo) -> Type:
    return _option(c, 0)


def _valid_utf8(c: CallInfo) -> Type:
    _bytes(c, 0)
    return BOOL


def _codepoints(c: CallInfo) -> Type:
    t = c.args[0]
    if not (is_stringish(t) or isinstance(t, AnyT)):
        raise SigError(f"codepoints takes a string, but {_ord(0)} is {t}", 0)
    return ListT(INT)


def _fresh(c: CallInfo) -> Type:
    _model(c, 0)
    return BOOL


def _two_models(c: CallInfo) -> Type:
    _model(c, 0)
    _model(c, 1)
    return BOOL


def _eq(c: CallInfo) -> Type:
    t = _same_type(c, 0, 1)
    for key, allowed in (("float", EQ_FLOAT_MODES), ("order", EQ_ORDER_MODES)):
        if key not in c.kwargs:
            continue
        node = c.kwargs[key][1]
        choices = " | ".join(f'"{v}"' for v in allowed)
        if not isinstance(node, ast.Str) or node.value not in allowed:
            raise SigError(f"eq: {key}= must be one of {choices}", key)
    if "float" not in c.kwargs and c.floats_in(t):
        raise SigError(
            f"eq compares values of type {t}, which contain floats: say how to compare them "
            f'with float="bits" (bit-identical), float="ieee" or float="nan_any"'
        )
    return BOOL


def _sig(
    name: str,
    shape: str,
    arity: int | tuple[int, int],
    typer: Callable[[CallInfo], Type],
    **kw: object,
) -> PreludeSig:
    if isinstance(arity, int):
        arity = (arity, arity)
    return PreludeSig(name, shape, arity, typer, **kw)  # type: ignore[arg-type]


_TABLE = [
    *(_sig(n, f"{n}(x: T) -> bool", 1, _float_pred)
      for n in ("is_nan", "is_inf", "is_finite", "is_zero", "is_subnormal", "signbit")),
    _sig("bits", "bits(x: T) -> int", 1, _bits),
    _sig("next_up", "next_up(x: T) -> T", 1, _same_float),
    _sig("next_down", "next_down(x: T) -> T", 1, _same_float),
    _sig("ulp", "ulp<T>(r: real) -> real", 1, _ulp, type_args=1),
    _sig("qe", "qe(a: T, b: T) -> qerr (or qe<T>(a, b))", 2, _qe, type_args=1,
         optional_type_args=True),
    _sig("steps", "steps(e: qerr) -> int", 1, _qerr_part),
    _sig("nans", "nans(e: qerr) -> int", 1, _qerr_part),
    _sig("same", "same(a: A, b: A) -> bool", 2, _same),
    _sig("ieee_eq", "ieee_eq(a: T, b: T) -> bool", 2, _ieee_eq),
    _sig("real", "real(x: real) -> real", 1, _real),
    _sig("round", "round<T>(r: real) -> T", 1, _round, type_args=1),
    _sig("wrap", "wrap<I>(n: int) -> I", 1, _wrap, type_args=1),
    _sig("fits", "fits<I>(n: real) -> bool", 1, _fits, type_args=1),
    *(_sig(f"mp.{n}", f"mp.{n}(x: real) -> real", 1, _mp)
      for n in ("sqrt", "exp", "log", "sin", "cos", "tan", "atan")),
    *(_sig(f"cr.{n}", f"cr.{n}(x: T) -> T", 1, _cr) for n in CR_FUNCTIONS),
    _sig("le_uint", "le_uint(b: bytes) -> int", 1, _le_uint),
    _sig("len", "len(x: list<A> | string | bytes | map<K, V>) -> int", 1, _len),
    _sig("sorted", "sorted(xs: list<A>) -> list<A>", 1, _sorted),
    _sig("is_sorted", "is_sorted(xs: list<A>) -> bool", 1, _is_sorted),
    _sig("is_permutation", "is_permutation(a: list<A>, b: list<A>) -> bool", 2, _two_lists),
    _sig("is_subsequence", "is_subsequence(a: list<A>, b: list<A>) -> bool", 2, _two_lists),
    _sig("distinct", "distinct(xs: list<A>) -> bool", 1, _distinct),
    _sig("index_of", "index_of(xs: list<A>, x: A) -> int", 2, _index_of),
    _sig("keys", "keys(m: map<K, V>) -> list<K>", 1, _keys),
    _sig("values", "values(m: map<K, V>) -> list<V>", 1, _values),
    _sig("range", "range(a: int, b: int) -> list<int>", 2, _range),
    _sig("some", "some(x: A) -> option<A>", 1, _some),
    _sig("is_some", "is_some(o: option<A>) -> bool", 1, _opt_pred),
    _sig("is_none", "is_none(o: option<A>) -> bool", 1, _opt_pred),
    _sig("unwrap", "unwrap(o: option<A>) -> A", 1, _unwrap),
    _sig("valid_utf8", "valid_utf8(b: bytes) -> bool", 1, _valid_utf8),
    _sig("codepoints", "codepoints(s: string) -> list<int>", 1, _codepoints),
    _sig("fresh", "fresh(h: model) -> bool", 1, _fresh, needs_ctx=True),
    _sig("same_object", "same_object(a: model, b: model) -> bool", 2, _two_models,
         needs_ctx=True),
    _sig("shares_memory", "shares_memory(a: model, b: model) -> bool", 2, _two_models,
         needs_ctx=True),
    _sig("eq", 'eq(a: A, b: A, float="bits"|"ieee"|"nan_any", order="exact"|"ignore") -> bool',
         2, _eq, kwargs=("float", "order"), needs_ctx=True),
]  # fmt: skip

PRELUDE_SIGNATURES: dict[str, PreludeSig] = {s.name: s for s in _TABLE}
MP_FUNCTIONS = tuple(n[3:] for n in PRELUDE_SIGNATURES if n.startswith("mp."))


def type_prelude_call(info: CallInfo) -> Type:
    """Result type of a prelude call; raises SigError when ill-typed."""
    return PRELUDE_SIGNATURES[info.name].typer(info)


__all__ = [
    "CLASSIFIER_HINTS", "CR_FUNCTIONS", "EQ_FLOAT_MODES", "EQ_ORDER_MODES", "FLOAT_SETS", "GENERIC_PRELUDE",
    "MP_FUNCTIONS", "OPTIONAL_TYPE_ARGS", "PRELUDE_SIGNATURES", "SET_CONSTRUCTORS", "CallInfo", "PreludeSig",
    "SigError", "components", "constants_of", "contains_any", "contains_float",
    "has_set_constructor", "is_any", "is_stringish", "join", "non_eq_part", "ordered",
    "satisfies", "type_constant", "type_prelude_call",
]  # fmt: skip
