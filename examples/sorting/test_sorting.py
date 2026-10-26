"""sorting conformance: Python's built-ins, numpy, and three seeded bugs.

The conformances run as pytest items, one per clause and instantiation. The
plain test functions at the end check the findings of
examples/sorting/FINDINGS.md without spectest.
"""

from __future__ import annotations

import json
import operator
import os
import platform
import subprocess
import sys
import textwrap
from collections import Counter
from functools import partial

import numpy as np
import pytest
import sorting_impls as impls

import spectest
from spectest.lang import SpecCheckError, load_source

spec = spectest.load("sorting.spec")

test_builtin = spectest.conformance(
    spec,
    impls={
        "sort": sorted,
        "sort_by_first": partial(sorted, key=operator.itemgetter(0)),
        "sort_in_place": list.sort,
    },
    models={"MutableList": impls.python_list},
    instantiate=[
        {"T": "i64", "K": "i64", "V": "string"},
        {"T": "string", "K": "string", "V": "i64"},
    ],
    max_examples=500,
)

test_numpy = spectest.conformance(
    spec,
    impls={
        "sort": impls.np_sort,
        "sort_by_first": impls.np_sort_by_first_stable,
        "sort_in_place": np.ndarray.sort,
    },
    models={"MutableList": impls.int64_array},
    instantiate={"T": "i64", "K": "i64", "V": "string"},
    max_examples=500,
)

# numpy documents its default argsort kind as not stable. On x86-64 with AVX2 its SIMD sort
# reorders equal keys from 4 elements on; its portable sort is stable up to 16 elements, and
# spectest's long lists (17 to 100 elements, a sixteenth of the lists) reach past that. So
# the clause fails on both code paths; FINDINGS.md, "numpy's default argsort". The probe
# says which path this machine takes, for the plain tests below.
SHORT_UNSTABLE_KEYS = impls.short_unstable_keys()

test_numpy_default_kind = spectest.conformance(
    spec,
    impls={"sort_by_first": impls.np_sort_by_first_default},
    instantiate={"K": "i64", "V": "string"},
    expect_fail={"sort_by_first.stable"},
    max_examples=500,
)

test_seeded_bugs = spectest.conformance(
    spec,
    impls={
        "sort": impls.dedup_sort,
        "sort_by_first": impls.reversed_ties_sort_by_first,
        "sort_in_place": impls.sort_a_copy,
    },
    models={"MutableList": impls.python_list},
    instantiate={"T": "i64", "K": "i64", "V": "string"},
    expect_fail={
        # sorted(set(xs)) drops duplicates.
        "sort.permutation",
        # A reversed descending sort: ordered, but equal keys come out reversed.
        "sort_by_first.stable",
        # Sorts a copy: the list is unchanged, which is a permutation of itself, so only
        # ordered can see it.
        "sort_in_place.ordered",
    },
)


# ---------------------------------------------------------------------------
# The findings, checked without spectest


def stable_order(xs: list[tuple[object, object]]) -> list[tuple[object, object]]:
    """Pairs by key, equal keys in input order: the definition, without sorting the pairs."""
    keys = sorted({k for k, _ in xs})
    return [p for k in keys for p in xs if p[0] == k]


def test_dedup_sort_drops_duplicates() -> None:
    assert impls.dedup_sort([0, 0]) == [0]
    assert Counter(impls.dedup_sort([0, 0])) != Counter([0, 0])


def test_reversed_ties_sort_reverses_equal_keys() -> None:
    xs = [(0, "0"), (0, "")]
    out = impls.reversed_ties_sort_by_first(xs)
    assert out == [(0, ""), (0, "0")]
    assert Counter(out) == Counter(xs)
    assert stable_order(xs) == xs != out


def test_sort_a_copy_leaves_the_list_unchanged() -> None:
    xs = [0, -1]
    assert impls.sort_a_copy(xs) is None
    assert xs == [0, -1]
    assert Counter(xs) == Counter([0, -1])
    assert xs != sorted(xs)


def test_builtin_sorts_agree_with_the_definitions() -> None:
    xs = [(1, "b"), (0, "x"), (1, "a"), (0, "y")]
    assert sorted(xs, key=operator.itemgetter(0)) == stable_order(xs)
    ys = [3, 1, 2, 1]
    list.sort(ys)
    assert ys == [1, 1, 2, 3]
    arr = np.array([3, 1, 2, 1], dtype=np.int64)
    np.ndarray.sort(arr)
    assert arr.tolist() == [1, 1, 2, 3]


SIMD = pytest.mark.skipif(
    SHORT_UNSTABLE_KEYS is None,
    reason="numpy's default argsort is stable on short arrays on this machine",
)


@SIMD
def test_numpy_default_argsort_is_unstable_on_short_arrays() -> None:
    xs = [(1, ""), (1, ""), (0, ""), (0, "0")]
    keys = np.array([1, 1, 0, 0], dtype=np.int64)
    assert np.argsort(keys).tolist() == [3, 2, 1, 0]
    assert np.argsort(keys, kind="stable").tolist() == [2, 3, 0, 1]
    assert impls.np_sort_by_first_default(xs) == [(0, "0"), (0, ""), (1, ""), (1, "")]
    stable = [(0, ""), (0, "0"), (1, ""), (1, "")]
    assert impls.np_sort_by_first_stable(xs) == stable_order(xs) == stable
    assert len(SHORT_UNSTABLE_KEYS) == 4


PORTABLE_CHECK = textwrap.dedent(
    """
    import itertools, json
    import numpy as np
    from numpy._core._multiarray_umath import __cpu_features__ as features

    def stable(keys):
        a = np.asarray(keys, dtype=np.int64)
        return bool(np.array_equal(np.argsort(a), np.argsort(a, kind="stable")))

    # Every weak order of up to 6 keys, and keys from {0, 1, 2} up to 8.
    short = [k for n in range(1, 7) for k in itertools.product(range(n), repeat=n)]
    short += [k for n in (7, 8) for k in itertools.product(range(3), repeat=n)]
    print(json.dumps({
        "x86_v3": features.get("X86_V3"),
        "short_unstable": [k for k in short if not stable(k)][:3],
        "equal_keys_stable": {n: stable([0] * n) for n in (8, 16, 17, 40)},
    }))
    """
)


@pytest.mark.skipif(
    platform.machine().lower() not in ("x86_64", "amd64"), reason="about numpy's x86-64 dispatch"
)
def test_numpy_portable_argsort_is_stable_on_short_arrays() -> None:
    """Without the AVX2 (x86-64-v3) dispatch, short arrays sort stably but 17 do not."""
    env = {**os.environ, "NPY_DISABLE_CPU_FEATURES": "X86_V3"}
    if not np._core._multiarray_umath.__cpu_features__.get("X86_V3"):
        env.pop("NPY_DISABLE_CPU_FEATURES")
    out = subprocess.run(
        [sys.executable, "-c", PORTABLE_CHECK], env=env, capture_output=True, text=True, check=True
    )
    found = json.loads(out.stdout)
    assert found == {
        "x86_v3": False,
        "short_unstable": [],
        "equal_keys_stable": {"8": True, "16": True, "17": False, "40": False},
    }


def test_conformance_rejects_f64_for_an_ord_parameter() -> None:
    with pytest.raises(spectest.ConformanceError) as info:
        spectest.conformance(spec, impls={"sort": sorted}, instantiate={"T": "f64"})
    assert info.value.problems == ["instantiate: T = f64 has no total order, as sort<T: Ord> needs"]


def test_checker_rejects_equality_on_lists_of_floats() -> None:
    source = textwrap.dedent(
        """
        spec float_sort
        fn sort_floats(xs: list<f64>) -> list<f64>
          ensures same_list: result == xs
        """
    )
    with pytest.raises(SpecCheckError) as info:
        load_source(source, "float_sort.spec")
    [message] = info.value.messages
    assert message.startswith("== is not defined on f64 (inside list<f64>)")
    assert "same(a, b)" in message and "eq(a, b, float=...)" in message
    assert "float_sort.spec:4:22" in str(info.value)
