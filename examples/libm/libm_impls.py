"""Seeded bugs for the libm spec: plausible formulas that are not accurate enough.

Each is algebraically right and numerically wrong, so a clause that bounds the
error against the correctly rounded result must catch it.
"""

from __future__ import annotations

import math


def cos(x: float) -> float:
    """cos(x) = sin(x + pi/2): the shifted argument is rounded, so the result drifts."""
    return math.sin(x + math.pi / 2)


def sqrt(x: float) -> float:
    """sqrt(x) = exp(log(x) / 2): two roundings, so the result is often an ulp off."""
    return math.exp(math.log(x) / 2)
