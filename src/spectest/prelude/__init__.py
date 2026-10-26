"""The prelude: runtime implementations of the spec language's built-in functions.

``PRELUDE`` maps each prelude name (as written in specs: "len", "mp.cos",
"qe", ...) to a PreludeFn. ``call`` applies one to runtime values (see
spectest.values). Every function is total over well-typed inputs or raises
EvalError naming the function and the offending value.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from fractions import Fraction
from typing import Any

from spectest.prelude import collections, cr, floats, ints, mp, reals
from spectest.types import FixedIntT, FloatT, Type, scalar_type
from spectest.values import EvalError, FloatValue, QError, SpecError, is_infinity


@dataclass(frozen=True)
class PreludeFn:
    name: str  # "len", "mp.cos", "qe", "wrap", ...
    impl: Callable[..., Any]  # impl(*args, **kwargs) on runtime values
    needs_ctx: bool = False  # receives ctx=...
    needs_types: bool = False  # receives type_args=..., arg_types=...


def _type_arg(fn: str, type_args: tuple[Any, ...]) -> Type:
    if len(type_args) != 1:
        raise EvalError(f"{fn} takes exactly one type argument, got {len(type_args)}")
    t = type_args[0]
    resolved = scalar_type(t) if isinstance(t, str) else t
    if resolved is None:
        raise EvalError(f"{fn}: unknown type {t!r}")
    return resolved


def _float_arg(fn: str, type_args: tuple[Any, ...]) -> FloatT:
    t = _type_arg(fn, type_args)
    if not isinstance(t, FloatT):
        raise EvalError(f"{fn}<{t}>: {t} is not a float format")
    return t


def _wrap(n: Any, *, type_args: tuple[Any, ...] = (), arg_types: tuple[Any, ...] = ()) -> int:
    return ints.wrap(n, _type_arg("wrap", type_args))


def _fits(x: Any, *, type_args: tuple[Any, ...] = (), arg_types: tuple[Any, ...] = ()) -> bool:
    t = _type_arg("fits", type_args)
    if not isinstance(t, (FixedIntT, FloatT)):
        raise EvalError(f"fits<{t}>: {t} is not a fixed-width scalar type")
    return ints.fits(x, t)


def _round(
    r: Any, *, type_args: tuple[Any, ...] = (), arg_types: tuple[Any, ...] = ()
) -> FloatValue:
    t = _float_arg("round", type_args)
    return floats.round_to(floats.as_real(r, f"round<{t}>"), t)


def _ulp(r: Any, *, type_args: tuple[Any, ...] = (), arg_types: tuple[Any, ...] = ()) -> Any:
    t = _float_arg("ulp", type_args)
    return floats.ulp(floats.as_real(r, f"ulp<{t}>"), t)


def _in_format(v: Any, t: FloatT) -> FloatValue:
    fn = f"qe<{t}>"
    if isinstance(v, FloatValue):
        if v.fmt != t.fmt:
            raise EvalError(f"{fn}: compares {t} values, got a {v.fmt}")
        return v
    if isinstance(v, bool) or not (isinstance(v, (int, Fraction)) or is_infinity(v)):
        raise EvalError(f"{fn}: expected a number or a {t}, got {v!r}")
    if not floats.fits(v, t):
        raise EvalError(f"{fn}: {reals.format_real(v)} is not exactly representable as {t}")
    return floats.round_to(v, t)


def _qe(
    x: Any, y: Any, *, type_args: tuple[Any, ...] = (), arg_types: tuple[Any, ...] = ()
) -> QError:
    if not type_args:
        return floats.qe(x, y)
    t = _float_arg("qe", type_args)
    return floats.qe(_in_format(x, t), _in_format(y, t))


def type_const(t: Type | str, attr: str) -> Any:
    """``I.min`` / ``I.max`` (ints) and ``F.min`` / ``F.max`` (finite extremes, as F values)."""
    resolved = scalar_type(t) if isinstance(t, str) else t
    if isinstance(resolved, FixedIntT) and attr in ("min", "max"):
        return resolved.min if attr == "min" else resolved.max
    if isinstance(resolved, FloatT) and attr in ("min", "max"):
        return floats.min_finite(resolved) if attr == "min" else floats.max_finite(resolved)
    raise EvalError(f"{t}.{attr} is not a constant")


_FNS: list[PreludeFn] = [
    PreludeFn("is_nan", floats.is_nan),
    PreludeFn("is_inf", floats.is_inf),
    PreludeFn("is_finite", floats.is_finite),
    PreludeFn("is_zero", floats.is_zero),
    PreludeFn("is_subnormal", floats.is_subnormal),
    PreludeFn("signbit", floats.signbit),
    PreludeFn("bits", floats.bits),
    PreludeFn("next_up", floats.next_up),
    PreludeFn("next_down", floats.next_down),
    PreludeFn("ulp", _ulp, needs_types=True),
    PreludeFn("qe", _qe, needs_types=True),
    PreludeFn("steps", floats.steps),
    PreludeFn("nans", floats.nans),
    PreludeFn("same", floats.same),
    PreludeFn("ieee_eq", floats.ieee_eq),
    PreludeFn("real", reals.promote),
    PreludeFn("round", _round, needs_types=True),
    PreludeFn("wrap", _wrap, needs_types=True),
    PreludeFn("fits", _fits, needs_types=True),
    PreludeFn("mp.sqrt", mp.sqrt),
    PreludeFn("mp.exp", mp.exp),
    PreludeFn("mp.log", mp.log),
    PreludeFn("mp.sin", mp.sin),
    PreludeFn("mp.cos", mp.cos),
    PreludeFn("mp.tan", mp.tan),
    PreludeFn("mp.atan", mp.atan),
    *(PreludeFn(f"cr.{n}", getattr(cr, n)) for n in cr.FUNCTIONS),
    PreludeFn("le_uint", ints.le_uint),
    PreludeFn("len", collections.len),
    PreludeFn("sorted", collections.sorted),
    PreludeFn("is_sorted", collections.is_sorted),
    PreludeFn("is_permutation", collections.is_permutation),
    PreludeFn("is_subsequence", collections.is_subsequence),
    PreludeFn("distinct", collections.distinct),
    PreludeFn("index_of", collections.index_of),
    PreludeFn("keys", collections.keys),
    PreludeFn("values", collections.values),
    PreludeFn("range", collections.range),
    PreludeFn("some", collections.some),
    PreludeFn("is_some", collections.is_some),
    PreludeFn("is_none", collections.is_none),
    PreludeFn("unwrap", collections.unwrap),
    PreludeFn("valid_utf8", collections.valid_utf8),
    PreludeFn("codepoints", collections.codepoints),
    PreludeFn("fresh", collections.fresh, needs_ctx=True),
    PreludeFn("same_object", collections.same_object, needs_ctx=True),
    PreludeFn("shares_memory", collections.shares_memory, needs_ctx=True),
    PreludeFn("eq", collections.eq, needs_ctx=True),
]

PRELUDE: dict[str, PreludeFn] = {fn.name: fn for fn in _FNS}


def call(
    name: str,
    args: tuple[Any, ...] | list[Any],
    *,
    kwargs: dict[str, Any] | None = None,
    type_args: tuple[Any, ...] | list[Any] = (),
    arg_types: tuple[Any, ...] | list[Any] = (),
    ctx: Any = None,
) -> Any:
    """Apply a prelude function to runtime values.

    Only SpecError subclasses (EvalError above all) escape; a Python error
    from a malformed call is reported as an EvalError naming the function.
    """
    fn = PRELUDE.get(name)
    if fn is None:
        raise EvalError(f"unknown prelude function {name!r}")
    kw = dict(kwargs or {})
    if fn.needs_types:
        kw["type_args"] = tuple(type_args)
        kw["arg_types"] = tuple(arg_types)
    if fn.needs_ctx:
        kw["ctx"] = ctx
    try:
        return fn.impl(*args, **kw)
    except SpecError:
        raise
    except (TypeError, ValueError, ArithmeticError, LookupError, RecursionError) as exc:
        raise EvalError(f"{name}: {exc}") from exc


__all__ = [
    "PRELUDE",
    "PreludeFn",
    "call",
    "collections",
    "cr",
    "floats",
    "ints",
    "mp",
    "reals",
    "type_const",
]
