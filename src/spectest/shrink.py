"""Deterministic shrinking after Hypothesis: shorter and simpler arguments that still fail.

Hypothesis shrinks the choices behind a failing example, and from some
examples no single change to those choices helps: when lengths 8, 12 and 16
fail, every single deletion from 16 bytes passes; bytes drawn as UTF-8 text
never become zero bytes; and a model whose rows are drawn to its column count
loses a column only when its name and one cell of every row go at once.
``minimize`` tries, argument by argument, the argument's default, shorter
prefixes and suffixes, single deletions and simpler elements, and keeps a
candidate only when ``fails`` holds for it.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Collection, Iterator, Mapping
from typing import Any

from spectest import generate, sets
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
    RecordT,
    StringT,
    TupleT,
    Type,
    substitute,
)
from spectest.values import FloatValue, MapValue, RecordValue, Some, SpecError

BUDGET = 1000
DEADLINE = 10.0

__all__ = ["BUDGET", "DEADLINE", "candidates", "minimize"]


def minimize(
    args: Mapping[str, Any],
    types: Mapping[str, Type],
    fails: Callable[[dict[str, Any]], bool],
    spec: Any,
    *,
    defaults: Collection[str] = (),
    budget: int = BUDGET,
    deadline: float = DEADLINE,
) -> dict[str, Any]:
    """The simplest arguments found from ``args`` for which ``fails`` holds.

    Each argument in turn is replaced by its first simpler candidate that still
    fails, until none does; passes repeat until a whole pass changes nothing,
    or ``budget`` calls of ``fails`` or ``deadline`` seconds are spent.
    ``defaults`` names the parameters that may be omitted (DEFAULT).
    """
    shrinker = _Shrinker(spec)
    current = dict(args)
    seen = {_key(current)}
    calls = 0
    stop = time.monotonic() + deadline

    def exhausted() -> bool:
        return calls >= budget or time.monotonic() > stop

    changed = True
    while changed and not exhausted():
        changed = False
        for name, t in types.items():
            if name not in current:
                continue
            improved = True
            while improved and not exhausted():
                improved = False
                options = shrinker.candidates(current[name], t)
                if name in defaults and current[name] is not generate.DEFAULT:
                    options = _chain([generate.DEFAULT], options)
                for candidate in options:
                    trial = {**current, name: candidate}
                    key = _key(trial)
                    if key in seen:
                        continue
                    seen.add(key)
                    calls += 1
                    if fails(trial):
                        current, improved, changed = trial, True, True
                        break
                    if exhausted():
                        break
    return current


def candidates(value: Any, t: Type, spec: Any = None) -> Iterator[Any]:
    """Values of type t simpler than ``value``, the simplest first."""
    return _Shrinker(spec).candidates(value, t)


def _chain(first: list[Any], rest: Iterator[Any]) -> Iterator[Any]:
    yield from first
    yield from rest


def _key(args: Mapping[str, Any]) -> str:
    return repr(sorted(args.items()))


_ZERO_CHAR = "0"


class _Shrinker:
    """Candidate generation for one spec: models need its declarations."""

    def __init__(self, spec: Any) -> None:
        self.spec = spec
        self.plans: dict[str, list[generate.FieldPlan]] = {}

    def candidates(self, v: Any, t: Type, fixed_inner: bool = False) -> Iterator[Any]:
        """Simpler values; ``fixed_inner``: elements of a list keep their lengths."""
        if v is generate.DEFAULT:
            return iter(())
        if isinstance(t, BoolT):
            return iter([False] if v is True else [])
        if isinstance(t, IntT | FixedIntT) and isinstance(v, int):
            return _ints(v, t)
        if isinstance(t, FloatT) and isinstance(v, FloatValue):
            return _floats(v, t)
        if isinstance(t, StringT) and isinstance(v, str):
            return self.sequence(v, _text_elems)
        if isinstance(t, BytesT) and isinstance(v, bytes):
            return self.sequence(v, _byte_elems)
        if isinstance(t, ListT) and isinstance(v, tuple):
            return self.sequence(v, self.elements(t.elem, fixed_inner))
        if isinstance(t, TupleT) and isinstance(v, tuple):
            return self.tuple_(v, t.elems)
        if isinstance(t, OptionT):
            return self.option(v, t)
        if isinstance(t, MapT) and isinstance(v, MapValue):
            return self.map_(v, t)
        if isinstance(t, RecordT) and isinstance(v, RecordValue):
            return self.record(v, t)
        if isinstance(t, LiteralT | EnumT):
            members = list(t.values if isinstance(t, LiteralT) else t.members)
            return iter(members[: members.index(v)] if v in members else [])
        if isinstance(t, ModelT) and isinstance(v, generate.GeneratedModel):
            return self.model(v)
        return iter(())

    # -- sequences ------------------------------------------------------------------

    def sequence(
        self, v: Any, elems: Callable[[Any, Any], Iterator[Any]] | None, keep_length: bool = False
    ) -> Iterator[Any]:
        """Shorter prefixes, shorter suffixes and single deletions (shortest first), then
        simpler elements; ``elems(v, i)`` yields the candidates of the whole sequence
        with element i simpler."""
        n = len(v)
        if not keep_length:
            for k in range(n):
                yield v[:k]
            for k in range(1, n):
                yield v[n - k :]
            for i in range(n):
                yield v[:i] + v[i + 1 :]
        if elems is not None:
            yield from elems(v, None)
            for i in range(n):
                yield from elems(v, i)

    def elements(
        self, elem: Type, fixed_inner: bool
    ) -> Callable[[tuple[Any, ...], int | None], Iterator[tuple[Any, ...]]]:
        def simpler(v: tuple[Any, ...], i: int | None) -> Iterator[tuple[Any, ...]]:
            if i is None:
                return
            if fixed_inner and isinstance(elem, ListT | StringT | BytesT):
                inner = self.fixed_length(v[i], elem)
            else:
                inner = self.candidates(v[i], elem)
            for c in inner:
                yield v[:i] + (c,) + v[i + 1 :]

        return simpler

    def fixed_length(self, v: Any, t: Type) -> Iterator[Any]:
        """Simpler values of the same length."""
        if isinstance(t, ListT):
            return self.sequence(v, self.elements(t.elem, False), keep_length=True)
        if isinstance(t, StringT):
            return self.sequence(v, _text_elems, keep_length=True)
        if isinstance(t, BytesT):
            return self.sequence(v, _byte_elems, keep_length=True)
        return iter(())

    # -- other compound values ------------------------------------------------------

    def tuple_(self, v: tuple[Any, ...], elems: tuple[Type, ...]) -> Iterator[tuple[Any, ...]]:
        for i, et in enumerate(elems):
            for c in self.candidates(v[i], et):
                yield v[:i] + (c,) + v[i + 1 :]

    def option(self, v: Any, t: OptionT) -> Iterator[Any]:
        if not isinstance(v, Some):
            return
        yield None
        for c in self.candidates(v.value, t.elem):
            yield Some(c)

    def map_(self, v: MapValue, t: MapT) -> Iterator[MapValue]:
        items = v.items
        for i in range(len(items)):
            yield MapValue(items[:i] + items[i + 1 :])
        for i, (k, x) in enumerate(items):
            for c in self.candidates(x, t.value):
                yield MapValue(items[:i] + ((k, c),) + items[i + 1 :])

    def record(self, v: RecordValue, t: RecordT) -> Iterator[RecordValue]:
        types = dict(t.fields)
        fields = v.fields
        for i, (name, x) in enumerate(fields):
            for c in self.candidates(x, types[name]):
                yield RecordValue(v.name, fields[:i] + ((name, c),) + fields[i + 1 :])

    # -- models -----------------------------------------------------------------------

    def field_plans(self, model: str) -> list[generate.FieldPlan]:
        if model not in self.plans:
            self.plans[model] = list(generate.field_plans(model, self.spec))
        return self.plans[model]

    def model(self, gm: generate.GeneratedModel) -> Iterator[generate.GeneratedModel]:
        """Fewer columns (a prefix, a suffix or all but one element of a field, with the
        matching elements of every element of the fields whose elements take its length),
        then each drawn field's own candidates; computed fields follow, and every
        invariant must hold."""
        if self.spec is None:
            return
        try:
            plans = self.field_plans(gm.model)
            types = _field_types(self.spec, gm)
        except (SpecError, KeyError):
            return
        sources = {fp.length_of for fp in plans if fp.length_of is not None}
        for g in sources:
            value = gm.fields.get(g)
            if not isinstance(value, tuple | str | bytes):
                continue
            dependents = [fp.name for fp in plans if fp.length_of == g]
            n = len(value)
            kept = [slice(0, k) for k in range(n)] + [slice(n - k, n) for k in range(1, n)]
            for keep in kept:
                fields = dict(gm.fields)
                fields[g] = value[keep]
                for f in dependents:
                    fields[f] = tuple(x[keep] for x in gm.fields[f])
                yield from self.valid(gm, fields)
            for j in range(n):
                fields = dict(gm.fields)
                fields[g] = value[:j] + value[j + 1 :]
                for f in dependents:
                    fields[f] = tuple(x[:j] + x[j + 1 :] for x in gm.fields[f])
                yield from self.valid(gm, fields)
        for fp in plans:
            if fp.compute is not None or fp.name not in gm.fields:
                continue
            t = types[fp.name]
            value = gm.fields[fp.name]
            if fp.name in sources:
                options = self.fixed_length(value, t)
            else:
                options = self.candidates(value, t, fixed_inner=fp.length_of is not None)
            for c in options:
                yield from self.valid(gm, {**gm.fields, fp.name: c})

    def valid(
        self, gm: generate.GeneratedModel, fields: dict[str, Any]
    ) -> Iterator[generate.GeneratedModel]:
        try:
            values = generate.computed_fields(self.field_plans(gm.model), fields)
        except (KeyError, TypeError):
            return
        candidate = generate.GeneratedModel(gm.model, gm.targs, values)
        if generate.invariants_hold(candidate, self.spec):
            yield candidate


def _field_types(spec: Any, gm: generate.GeneratedModel) -> dict[str, Type]:
    decl = spec.models[gm.model]
    tenv = dict(zip(spec.tparams.get(decl, {}), gm.targs))
    return {o.name: substitute(spec.signature[o].result, tenv) for o in spec.fields(gm.model)}


def _text_elems(v: str, i: int | None) -> Iterator[str]:
    if i is None:
        if v.strip(_ZERO_CHAR):
            yield _ZERO_CHAR * len(v)
        return
    if v[i] != _ZERO_CHAR:
        yield v[:i] + _ZERO_CHAR + v[i + 1 :]


def _byte_elems(v: bytes, i: int | None) -> Iterator[bytes]:
    if i is None:
        if any(v):
            yield bytes(len(v))
        return
    for b in (0, 1):
        if b < v[i]:
            yield v[:i] + bytes([b]) + v[i + 1 :]


def _int_key(v: int) -> tuple[int, bool]:
    return abs(v), v < 0


def _ints(v: int, t: Type) -> Iterator[int]:
    """0, 1, -1, half of v and the neighbour of v toward 0: those simpler than v."""
    lo, hi = (t.min, t.max) if isinstance(t, FixedIntT) else (None, None)
    half = v // 2 if v > 0 else -(-v // 2)
    toward_zero = v - 1 if v > 0 else v + 1
    out: list[int] = []
    for c in (0, 1, -1, half, toward_zero):
        if (lo is None or lo <= c <= hi) and _int_key(c) < _int_key(v) and c not in out:
            out.append(c)
    return iter(out)


def _floats(v: FloatValue, t: FloatT) -> Iterator[FloatValue]:
    """The simple members (0, -0, 1, -1, the quiet NaNs) that come before v."""
    domain = sets.domain(t)
    try:
        rank = sets.index_of(domain, v)
    except ValueError:
        return iter(())
    return iter(sets.member(domain, i) for i in range(min(rank, 6)))
