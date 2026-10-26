"""Bindings of deque.spec's Deque interface, and a probe that measures what a run exercised.

Interface items record partition coverage, but deque.spec has no partitions and
most of its edge cases depend on the deque's state, so the report cannot show
which of them ran. ``ProbedDeque`` is collections.deque with every method
counting the edge case it meets; ``probe_run`` repeats a conformance's search
over it with the plugin's seed, options and item IDs, so the counts describe
the step sequences the conformance ran.
"""

from __future__ import annotations

import collections
from collections import Counter
from collections.abc import Callable
from typing import Any, ClassVar

from spectest import InterfaceBinding
from spectest.runtime.binding import Conformance

ERRORS: dict[type[BaseException], str] = {IndexError: "IndexError"}
INSTANTIATE = [{"T": "i64"}, {"T": "string"}]


def deque_binding(
    make: Callable[..., Any], constructors: tuple[str, ...] = ("empty", "bounded")
) -> InterfaceBinding:
    """Deque over a class built like collections.deque: ``make()`` for ``empty`` and
    ``make(maxlen=n)`` for ``bounded(n)``; the methods are the object's own.

    ``constructors`` names the constructors to bind; the search uses only those.
    """
    ctors = {"empty": lambda: make(), "bounded": lambda n: make(maxlen=n)}
    return InterfaceBinding(
        constructors={name: ctors[name] for name in constructors},
        observers={"items": list, "maxlen": lambda d: d.maxlen},
    )


COLLECTIONS_DEQUE = deque_binding(collections.deque)


def _bound(maxlen: int | None) -> str:
    if maxlen is None:
        return "unbounded"
    return f"bounded({maxlen})" if maxlen <= 1 else "bounded(n >= 2)"


class ProbedDeque(collections.deque):  # type: ignore[type-arg]
    """collections.deque, counting in ``seen`` the edge case each call meets."""

    seen: ClassVar[Counter[str]] = Counter()

    def __init__(self, maxlen: int | None = None) -> None:
        super().__init__((), maxlen)
        self.seen["new " + ("empty()" if maxlen is None else _bound(maxlen))] += 1

    def _adding(self, name: str) -> None:
        if self.maxlen is not None and len(self) == self.maxlen:
            self.seen[f"{name} on a full {_bound(self.maxlen)}"] += 1

    def _taking(self, name: str) -> None:
        self.seen[f"{name} on {'a non-empty' if self else 'an empty'} deque"] += 1

    def append(self, x: Any) -> None:
        self._adding("append")
        super().append(x)

    def appendleft(self, x: Any) -> None:
        self._adding("appendleft")
        super().appendleft(x)

    def pop(self) -> Any:
        self._taking("pop")
        return super().pop()

    def popleft(self) -> Any:
        self._taking("popleft")
        return super().popleft()

    def rotate(self, n: int = 1) -> None:
        size = len(self)
        if size == 0:
            self.seen["rotate on an empty deque"] += 1
        else:
            if n < 0:
                self.seen["rotate with n < 0"] += 1
            if n > size:
                self.seen["rotate with n > len"] += 1
            if n < -size:
                self.seen["rotate with n < -len"] += 1
            if -size <= n < 0:
                self.seen["rotate with -len <= n < 0"] += 1
            if n != 0 and n % size == 0:
                self.seen["rotate by a nonzero multiple of len"] += 1
            if self.maxlen is not None and size == self.maxlen:
                self.seen["rotate on a full bounded deque"] += 1
        super().rotate(n)


EDGE_CASES = [
    "new bounded(0)",
    "new bounded(1)",
    "append on a full bounded(0)",
    "append on a full bounded(1)",
    "append on a full bounded(n >= 2)",
    "appendleft on a full bounded(0)",
    "appendleft on a full bounded(1)",
    "appendleft on a full bounded(n >= 2)",
    "pop on an empty deque",
    "popleft on an empty deque",
    "rotate on an empty deque",
    "rotate with n < 0",
    "rotate with n > len",
    "rotate with n < -len",
    "rotate with -len <= n < 0",
    "rotate by a nonzero multiple of len",
    "rotate on a full bounded deque",
]


def probe_run(
    conf: Conformance, file_nodeid: str, seed: int = 0, max_examples: int | None = None
) -> dict[str, tuple[Counter[str], list[Any]]]:
    """Run ``conf``'s Deque items again over ProbedDeque, as the plugin runs them.

    ``conf.name`` and ``file_nodeid`` ("examples/deque/test_deque.py") rebuild
    the plugin's item IDs, which seed each search. Returns, per item name, the
    edge-case counts and the ClauseResults.
    """
    from spectest import conformance
    from spectest.runtime.runner import Runner, RunOptions, collect_items

    bound = tuple(conf.interfaces["Deque"].constructors)
    probed = conformance(
        conf.spec,
        interfaces={"Deque": deque_binding(ProbedDeque, bound)},
        errors=conf.errors,
        instantiate=[{k: str(t) for k, t in inst.items()} for inst in conf.instantiate],
        expect_fail=conf.expect_fail,
        max_examples=conf.max_examples,
        steps=conf.steps,
        max_handles=conf.max_handles,
    )
    runner = Runner(RunOptions(seed=seed, max_examples=max_examples))
    out: dict[str, tuple[Counter[str], list[Any]]] = {}
    for item in collect_items(probed):
        ProbedDeque.seen = Counter()
        results = runner.run(item, f"{file_nodeid}::{conf.name}::{item.name}", "")
        out[item.name] = (ProbedDeque.seen, results)
    return out
