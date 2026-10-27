"""The existing example specs load into the host and list their items."""

from __future__ import annotations

from pathlib import Path

import pytest
from support import Loaded

ROOT = Path(__file__).resolve().parents[2]
SPECS = [
    "examples/binary/binary.spec",
    "examples/deque/deque.spec",
    "examples/frames/frames.spec",
    "examples/libm/explore.spec",
    "examples/libm/libm.spec",
    "examples/sorting/sorting.spec",
    "trials/bitpattern/bitpattern.spec",
]


@pytest.mark.parametrize("path", SPECS)
def test_an_existing_spec_loads_and_lists_items(path):
    loaded = Loaded(ROOT / path)
    try:
        items = loaded.items()
        # deque.spec declares only an interface, which a later package runs.
        assert items or path.endswith("deque.spec")
        for item in items:
            assert set(item) == {"decl", "clause_id", "kind", "text", "line", "file", "tparams"}
            assert item["kind"] not in ("requires", "unspecified", "impl_defined", "perf")
        ids = [i["clause_id"] for i in items]
        assert len(ids) == len(set(ids))
    finally:
        loaded.close()


def test_libm_items_match_the_spec():
    loaded = Loaded(ROOT / "examples/libm/libm.spec")
    try:
        ids = [i["clause_id"] for i in loaded.items() if i["decl"] == "cos"]
        assert ids == ["cos.accurate", "cos.bounded", "cos.even", "cos#type", "cos#raises"]
    finally:
        loaded.close()
