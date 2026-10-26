"""Collecting draws from strategies, with and without Hypothesis's engine."""

from __future__ import annotations

import random
from typing import Any

from budget import budget
from hypothesis import HealthCheck, Phase, given, settings
from hypothesis import strategies as st
from hypothesis.control import BuildContext
from hypothesis.internal.conjecture.data import ConjectureData

FAST = settings(
    max_examples=budget(200, 25),
    deadline=None,
    database=None,
    derandomize=True,
    suppress_health_check=[HealthCheck.too_slow],
)


def draws(s: st.SearchStrategy[Any], n: int = 200) -> list[Any]:
    """Values the engine generates for a test of ``n`` examples (no shrinking).

    The engine deduplicates inputs and zero-extends early examples, so this
    shows what a test sees, not the strategy's own distribution (see ``sample``).
    """
    out: list[Any] = []

    @settings(FAST, max_examples=n, phases=["generate"])
    @given(s)
    def collect(v: Any) -> None:
        out.append(v)

    collect()
    return out


def sample(s: st.SearchStrategy[Any], n: int = 500, seed: int = 0) -> list[Any]:
    """``n`` independent draws from the strategy's own distribution, outside the engine."""
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        data = ConjectureData(random=rnd)
        with BuildContext(data, wrapped_test=sample):
            out.append(data.draw(s))
    return out


QUIET = settings(
    database=None,
    max_examples=2000,
    deadline=None,
    derandomize=True,
    phases=[Phase.generate, Phase.shrink],
    suppress_health_check=[HealthCheck.too_slow],
)
"""Settings for ``hypothesis.find``: no explain phase, whose variations would replace
the shrunk example that ``find`` returns."""


def choice_bytes(s: st.SearchStrategy[Any], n: int = 200, seed: int = 0) -> int:
    """The largest share of Hypothesis's per-test-case budget (8 KiB) one draw used."""
    rnd = random.Random(seed)
    most = 0
    for _ in range(n):
        data = ConjectureData(random=rnd)
        with BuildContext(data, wrapped_test=choice_bytes):
            data.draw(s)
        most = max(most, data.length)
    return most
