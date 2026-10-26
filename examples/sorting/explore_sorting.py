"""Questions about sorting.spec that the default run does not ask.

Run it explicitly (it does not match test_*.py). On x86-64 with AVX2, numpy
dispatches argsort to a SIMD sort; NPY_DISABLE_CPU_FEATURES selects the
portable code path instead:
    uv run pytest examples/sorting/explore_sorting.py
    NPY_DISABLE_CPU_FEATURES=X86_V3 uv run pytest examples/sorting/explore_sorting.py
A conformance item that fails here is an answer, not a bug.
"""

from __future__ import annotations

import sorting_impls as impls

import spectest
from spectest import generate
from spectest.runtime.runner import Runner, collect_items

spec = spectest.load("sorting.spec")
PAIRS = {"K": "i64", "V": "string"}
SHORT_ONLY = generate.Sizes(long_share=0)


def utf16_sort(xs: list[str]) -> list[str]:
    """Strings in UTF-16 code-unit order, as Java's and JavaScript's string comparison has it."""
    return sorted(xs, key=lambda s: s.encode("utf-16-be"))


# Can lists of at most 8 elements show that numpy's default argsort is unstable? Long lists
# are turned off here (test_sorting.py's test_numpy_default_kind has them). On the SIMD
# path, yes (4 elements suffice); on the portable path, no: it is stable up to 16.
test_explore_default_kind = spectest.conformance(
    spec,
    impls={"sort_by_first": impls.np_sort_by_first_default},
    instantiate=PAIRS,
    sizes=SHORT_ONLY,
    max_examples=2000,
)

# Which order on strings does Ord mean? The prelude compares code points; an
# implementation that compares UTF-16 code units differs above U+FFFF. Two strings must
# differ first at a character in U+E000..U+FFFF against one above U+FFFF, which takes a
# few thousand examples (3,166 at seed 0; 368 to 1,990 at seeds 1 to 5).
test_explore_utf16_order = spectest.conformance(
    spec,
    impls={"sort": utf16_sort},
    instantiate={"T": "string"},
    max_examples=4000,
)


def test_longer_lists_expose_the_default_kind() -> None:
    """The runner with lists of up to 40 elements (sizes=, no long ones): the minimized
    counterexample is a shortest failing list, 17 pairs on the portable path."""
    conf = spectest.conformance(
        spec,
        impls={"sort_by_first": impls.np_sort_by_first_default},
        instantiate=PAIRS,
        sizes=generate.Sizes(max_list=40, long_share=0),
        max_examples=500,
    )
    item = next(it for it in collect_items(conf) if it.key == "sort_by_first.stable")
    (result,) = Runner().run(item, "explore_sorting.py::longer_lists")
    assert result.counterexample is not None
    xs = result.counterexample.inputs["xs"]
    n = xs.count("(")
    print(f"\nshortest failing list found: {n} elements: {xs}")
    if impls.short_unstable_keys() is None:
        assert n == 17
