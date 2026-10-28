"""The evaluation context the runtime gives the evaluator: observation through the bindings.

``RuntimeContext`` implements ``spectest.eval.EvalContext`` over a Conformance:
observers go through ``binding.observe`` with a per-state cache, identity
questions compare implementation objects, planned calls (``relates`` and
``aggregate``) go to a ``planner`` and the members of an aggregate's set to a
``members`` policy.
"""

from __future__ import annotations

import random
from collections.abc import Callable, Iterable, Iterator
from typing import Any

from bitpattern import BDDSet

from spectest import sets
from spectest.lang.spec import Spec
from spectest.runtime import binding
from spectest.runtime.binding import Conformance
from spectest.types import Type
from spectest.values import BindingError, EvalError, Handle

Planner = Callable[[str, tuple], Any]
Members = Callable[[BDDSet, Type], tuple[Iterable[Any], bool]]


class RuntimeContext:
    """Observers, identity and planned calls for one state of one example.

    ``known`` holds the implementation objects that existed before the call
    (inputs and live handles): a handle is fresh when its object is none of
    them. Call ``reset`` when the state changes (after the call) so cached
    observations are not reused.
    """

    def __init__(
        self,
        conf: Conformance,
        spec: Spec | None = None,
        *,
        known: Iterable[Any] = (),
        planner: Planner | None = None,
        members: Members | None = None,
    ) -> None:
        self.conf = conf
        self.spec = spec or conf.spec
        self.known = list(known)
        self.planner = planner
        self.members_policy = members
        self.cache: dict[Any, Any] = {}

    def reset(self) -> None:
        self.cache.clear()

    def observe(self, handle: Handle, observer: str, args: tuple) -> Any:
        key: Any = (handle.id, observer, tuple(args))
        try:
            hash(key)
        except TypeError:
            key = None
        if key is not None and key in self.cache:
            return self.cache[key]
        value = binding.observe(handle, observer, tuple(args), self.conf, self.spec)
        if key is not None:
            self.cache[key] = value
        return value

    def fields(self, handle: Handle) -> dict[str, Any]:
        try:
            names = [o.name for o in self.spec.fields(handle.model)]
        except KeyError:
            raise BindingError(f"{handle.model} is not a model of spec {self.spec.name}") from None
        return {n: self.observe(handle, n, ()) for n in names}

    def call_spec_fn(self, name: str, args: tuple) -> Any:
        if self.planner is None:
            raise EvalError(f"calling {name} needs a planned implementation call, not allowed here")
        return self.planner(name, tuple(args))

    def is_fresh(self, handle: Handle) -> bool:
        return not any(handle.obj is o for o in self.known)

    def same_object(self, a: Handle, b: Handle) -> bool:
        return a.obj is b.obj

    def shares_memory(self, a: Handle, b: Handle) -> bool:
        return binding.shares_memory(a, b, self.conf)

    def members(self, s: BDDSet, elem: Type) -> tuple[Iterable[Any], bool]:
        if self.members_policy is None:
            return all_members(s), False
        return self.members_policy(s, elem)


def all_members(s: BDDSet) -> Iterator[Any]:
    """Every member of a set, in bit-pattern order."""
    return sets.enumerate_set(s)


def sampled_members(s: BDDSet, k: int, seed: int) -> list[Any]:
    """k distinct members of a set drawn uniformly with a seeded generator (all when k >= size)."""
    n = sets.set_size(s)
    if k >= n:
        return list(all_members(s))
    rng = random.Random(seed)
    chosen: dict[int, None] = {}
    while len(chosen) < k:
        chosen.setdefault(rng.randrange(n))
    return [sets.member(s, i) for i in chosen]


def member_policy(limit: int, samples: int, seed: int) -> Members:
    """Every member of sets of at most ``limit`` values, else a seeded sample of ``samples``."""

    def members(s: BDDSet, elem: Type) -> tuple[Iterable[Any], bool]:
        if sets.set_size(s) <= limit:
            return all_members(s), False
        return sampled_members(s, samples, seed), True

    return members


class FieldsContext:
    """A context over generated model values (``Handle(GeneratedModel, model)``), for residual
    invariants checked before the concretizer runs: fields are the drawn values."""

    def __init__(self, spec: Spec) -> None:
        self.spec = spec

    def observe(self, handle: Handle, observer: str, args: tuple) -> Any:
        gm = handle.obj
        if args or observer not in getattr(gm, "fields", {}):
            raise EvalError(
                f"{handle.model}.{observer} cannot be observed before the object is built"
            )
        return gm.fields[observer]

    def fields(self, handle: Handle) -> dict[str, Any]:
        return dict(handle.obj.fields)

    def call_spec_fn(self, name: str, args: tuple) -> Any:
        raise EvalError(f"calling {name} is not allowed in a model invariant")

    def is_fresh(self, handle: Handle) -> bool:
        raise EvalError("fresh is not available in a model invariant")

    def same_object(self, a: Handle, b: Handle) -> bool:
        return a.obj is b.obj

    def shares_memory(self, a: Handle, b: Handle) -> bool:
        raise EvalError("shares_memory is not available before the object is built")

    def members(self, s: BDDSet, elem: Type) -> tuple[Iterable[Any], bool]:
        return all_members(s), False


__all__ = [
    "FieldsContext",
    "Members",
    "Planner",
    "RuntimeContext",
    "all_members",
    "member_policy",
    "sampled_members",
]
