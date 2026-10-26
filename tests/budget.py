"""Budgets that differ between the dev loop and the full-strength run.

The root conftest.py loads the "dev" Hypothesis profile for ``uv run pytest`` and the
"ci" profile for ``uv run pytest --ci``. Hypothesis tests take their budget from the
profile. Tests whose cost is some other count (an exhaustive loop, a sample size, a
spectest search budget) choose it here: the full count under any profile but "dev",
a smaller one in the dev loop. Assertions never depend on the profile.
"""

from __future__ import annotations

from hypothesis import settings


def full() -> bool:
    """Whether checks run at full strength: under every Hypothesis profile but "dev"."""
    return settings.get_current_profile_name() != "dev"


def budget(full_count: int, dev_count: int) -> int:
    """``full_count`` at full strength, ``dev_count`` in the dev loop."""
    return full_count if full() else min(dev_count, full_count)
