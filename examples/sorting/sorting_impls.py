"""Implementations, adapters and seeded bugs for examples/sorting/sorting.spec.

The spec passes lists as Python lists (pairs as tuples) and reads results back
by their declared types: a numpy array reads as a list. ``MutableList`` is a
model, so each in-place sort comes with a binding that builds the object from
the generated ``items`` and observes ``items`` from it.
"""

from __future__ import annotations

import itertools
import operator
from collections.abc import Sequence
from typing import Any

import numpy as np

import spectest

first = operator.itemgetter(0)


# ---------------------------------------------------------------------------
# Python's built-ins


def sort_by_first(xs: Sequence[tuple[Any, Any]]) -> list[tuple[Any, Any]]:
    """sorted with key=itemgetter(0): Timsort is stable, so equal keys keep their order."""
    return sorted(xs, key=first)


python_list = spectest.ModelBinding(
    observers={"items": list},
    concretize=lambda fields: list(fields["items"]),
)


# ---------------------------------------------------------------------------
# numpy, for T = i64


def np_sort(xs: Sequence[int]) -> np.ndarray:
    """numpy.sort on an int64 array; the array reads back as list<i64>."""
    return np.sort(np.asarray(xs, dtype=np.int64))


def np_sort_by_first_stable(xs: Sequence[tuple[int, Any]]) -> list[tuple[int, Any]]:
    """The pairs in the order of a stable argsort of their keys."""
    keys = np.asarray([k for k, _ in xs], dtype=np.int64)
    return [xs[i] for i in np.argsort(keys, kind="stable")]


def np_sort_by_first_default(xs: Sequence[tuple[int, Any]]) -> list[tuple[int, Any]]:
    """The pairs in the order of argsort with numpy's default kind ("quicksort").

    numpy documents that kind as not stable. See FINDINGS.md for when that shows.
    """
    keys = np.asarray([k for k, _ in xs], dtype=np.int64)
    return [xs[i] for i in np.argsort(keys)]


int64_array = spectest.ModelBinding(
    observers={"items": lambda a: a},
    concretize=lambda fields: np.array(fields["items"], dtype=np.int64),
)


def default_argsort_is_stable_on(keys: Sequence[int]) -> bool:
    """Whether numpy's default argsort orders these keys as a stable sort does."""
    a = np.asarray(keys, dtype=np.int64)
    return bool(np.array_equal(np.argsort(a), np.argsort(a, kind="stable")))


def short_unstable_keys(max_len: int = 8) -> tuple[int, ...] | None:
    """The first keys in {0, 1, 2}^n, n <= max_len, that numpy's default argsort orders
    unstably, or None: whether short lists (most of spectest's have at most 8 elements)
    show it, which depends on the code path numpy dispatches to."""
    for n in range(2, max_len + 1):
        for keys in itertools.product(range(3), repeat=n):
            if not default_argsort_is_stable_on(keys):
                return keys
    return None


# ---------------------------------------------------------------------------
# Seeded bugs


def dedup_sort(xs: Sequence[Any]) -> list[Any]:
    """Sorts the distinct elements: duplicates are lost, so the result is no permutation."""
    return sorted(set(xs))


def reversed_ties_sort_by_first(xs: Sequence[tuple[Any, Any]]) -> list[tuple[Any, Any]]:
    """A stable descending sort, reversed: ordered by key, but equal keys come out reversed."""
    return sorted(xs, key=first, reverse=True)[::-1]


def sort_a_copy(xs: list[Any]) -> None:
    """Sorts a copy of the list and drops it: the list itself is left as it was."""
    copy = list(xs)
    copy.sort()
