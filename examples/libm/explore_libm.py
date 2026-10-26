"""Questions about numpy's cos in half and single precision, asked as aggregates.

Run it explicitly (it does not match test_*.py):
    uv run pytest examples/libm/explore_libm.py --spectest-report=examples/libm/EXPLORE.md
An aggregate that fails here is an answer, not a bug: the report gives the
measured value and the inputs with the largest errors.
"""

from __future__ import annotations

import numpy as np

import spectest

test_explore_numpy = spectest.conformance(
    "explore.spec",
    impls={"cos16": np.cos, "cos32": np.cos},
    scalars="numpy",
)
