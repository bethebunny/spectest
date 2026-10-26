"""A checker for runtime value representations (spectest.values) of static types."""

from __future__ import annotations

from fractions import Fraction
from typing import Any

from spectest.generate import GeneratedModel
from spectest.prelude.floats import same
from spectest.types import (
    BoolT,
    BytesT,
    EnumT,
    FixedIntT,
    FloatT,
    IntT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    RealT,
    RecordT,
    StringT,
    TupleT,
    Type,
    UnitT,
    substitute,
)
from spectest.values import FloatValue, MapValue, RecordValue, Some, is_infinity


def problems(value: Any, t: Type, spec: Any = None, where: str = "value") -> list[str]:
    """Every way ``value`` fails to be a runtime value of ``t``; empty when it conforms."""
    out: list[str] = []

    def bad(message: str) -> list[str]:
        out.append(f"{where}: {message} (got {value!r} for {t})")
        return out

    if isinstance(t, BoolT):
        return out if type(value) is bool else bad("not a bool")
    if isinstance(t, IntT):
        return out if type(value) is int else bad("not an int")
    if isinstance(t, FixedIntT):
        if type(value) is not int:
            return bad("not an int")
        return out if t.min <= value <= t.max else bad("out of range")
    if isinstance(t, FloatT):
        if not isinstance(value, FloatValue):
            return bad("not a FloatValue")
        return out if value.fmt == t.fmt else bad("wrong format")
    if isinstance(t, RealT):
        return out if isinstance(value, Fraction) or is_infinity(value) else bad("not a real")
    if isinstance(t, StringT):
        if type(value) is not str:
            return bad("not a str")
        if any(0xD800 <= ord(c) <= 0xDFFF for c in value):
            return bad("contains a surrogate")
        return out
    if isinstance(t, BytesT):
        return out if type(value) is bytes else bad("not bytes")
    if isinstance(t, UnitT):
        return out if value is None else bad("not None")
    if isinstance(t, ListT):
        if type(value) is not tuple:
            return bad("a list is not a tuple")
        for i, v in enumerate(value):
            out.extend(problems(v, t.elem, spec, f"{where}[{i}]"))
        return out
    if isinstance(t, TupleT):
        if type(value) is not tuple or len(value) != len(t.elems):
            return bad("not a tuple of the right arity")
        for i, (v, et) in enumerate(zip(value, t.elems, strict=True)):
            out.extend(problems(v, et, spec, f"{where}.{i}"))
        return out
    if isinstance(t, OptionT):
        if value is None:
            return out
        if not isinstance(value, Some):
            return bad("not None or Some")
        return problems(value.value, t.elem, spec, f"unwrap({where})")
    if isinstance(t, MapT):
        if not isinstance(value, MapValue) or type(value.items) is not tuple:
            return bad("not a MapValue")
        keys: list[Any] = []
        for k, v in value.items:
            if any(same(k, seen) for seen in keys):
                bad(f"duplicate key {k!r}")
            keys.append(k)
            out.extend(problems(k, t.key, spec, f"{where} key"))
            out.extend(problems(v, t.value, spec, f"{where}[{k!r}]"))
        return out
    if isinstance(t, LiteralT):
        return out if value in t.values else bad("not one of the literals")
    if isinstance(t, EnumT):
        return out if value in t.members else bad("not an enum member")
    if isinstance(t, RecordT):
        if not isinstance(value, RecordValue) or value.name != t.name:
            return bad("not a RecordValue of this record")
        if [n for n, _ in value.fields] != [n for n, _ in t.fields]:
            return bad("wrong field names")
        for (n, v), (_, ft) in zip(value.fields, t.fields, strict=True):
            out.extend(problems(v, ft, spec, f"{where}.{n}"))
        return out
    if isinstance(t, ModelT):
        if not isinstance(value, GeneratedModel) or value.model != t.name:
            return bad("not a GeneratedModel of this model")
        if value.targs != t.args:
            return bad("wrong type arguments")
        decl = spec.models[t.name]
        env = dict(zip(spec.tparams.get(decl, {}), t.args, strict=True))
        names = [o.name for o in spec.fields(t.name)]
        if list(value.fields) != names:
            return bad(f"fields {list(value.fields)} instead of {names}")
        for o in spec.fields(t.name):
            ft = substitute(spec.signature[o].result, env)
            out.extend(problems(value.fields[o.name], ft, spec, f"{where}.{o.name}"))
        return out
    return bad("unsupported type")


def conforms(value: Any, t: Type, spec: Any = None) -> bool:
    return not problems(value, t, spec)
