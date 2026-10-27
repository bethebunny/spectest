"""``spectest.check``: a v2 spec for the pytest plugin to collect.

A module-level ``test*`` name bound to a ``check(...)`` object becomes a collector
with one item per clause the host reports (and per instantiation of a generic
declaration). The object only records the options; ``spectest.pytest_plugin`` loads the
spec and runs it through ``spectest._host``.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from typing import Any


@dataclass
class SpecCheck:
    """A spec and the options of its run.

    ``path`` is relative to the test module that binds the object. ``max_examples`` and
    ``seed`` override the session's options when set.

    Fields:
      - modules: qualified-name prefix of the spec to another module (see ``Driver``)
      - expect_fail: clauses that must fail, by clause id or printed name
      - instantiations: type arguments of each generic declaration
      - examples: explicit inputs per declaration
    """

    path: str
    modules: dict[str, str] = field(default_factory=dict)
    expect_fail: frozenset[str] = frozenset()
    instantiations: dict[str, list[dict[str, str]]] = field(default_factory=dict)
    examples: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    max_examples: int | None = None
    seed: int | None = None
    name: str = ""


def check(
    path: str,
    *,
    modules: Mapping[str, str] | None = None,
    expect_fail: Iterable[str] = (),
    instantiations: Mapping[str, Iterable[Mapping[str, str]]] | None = None,
    examples: Mapping[str, Iterable[Mapping[str, Any]]] | None = None,
    max_examples: int | None = None,
    seed: int | None = None,
) -> SpecCheck:
    """A spec for the pytest plugin to collect from the test module that binds it."""
    return SpecCheck(
        path=str(path),
        modules=dict(modules or {}),
        expect_fail=frozenset(expect_fail),
        instantiations={
            d: [{str(k): str(v) for k, v in inst.items()} for inst in insts]
            for d, insts in (instantiations or {}).items()
        },
        examples={d: [dict(e) for e in exs] for d, exs in (examples or {}).items()},
        max_examples=max_examples,
        seed=seed,
    )


__all__ = ["SpecCheck", "check"]
