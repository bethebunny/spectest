"""What the collections.deque search of test_deque.py exercised.

Interface items record partition coverage, but deque.spec has no partitions,
and most of its edge cases depend on the state as well as on the arguments:
whether rotate ran with -len <= n < 0, or whether appendleft met a full
bounded(1) deque. This file repeats the collections.deque conformance over
ProbedDeque (collections.deque, counting the edge case each call meets) with
the plugin's seed, budget and item IDs, so the same step sequences run, and
checks every edge case in EDGE_CASES. Run it explicitly:

    uv run pytest examples/deque/explore_deque.py -s

It honours --spectest-seed and --spectest-max-examples like the conformances.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import test_deque as conformances
from deque_bindings import EDGE_CASES, probe_run


def test_search_reaches_the_edge_cases(request: pytest.FixtureRequest) -> None:
    name = "test_collections_deque"
    conf = getattr(conformances, name)
    conf.name = name
    file_nodeid = Path(conformances.__file__).resolve().relative_to(request.config.rootpath)
    runs = probe_run(
        conf,
        file_nodeid.as_posix(),
        request.config.getoption("spectest_seed"),
        request.config.getoption("spectest_max_examples"),
    )
    assert set(runs) == {"Deque[T=i64]", "Deque[T=string]"}
    for item, (seen, results) in runs.items():
        print(f"\n{name}::{item}")
        for case in sorted(seen):
            print(f"  {seen[case]:6d}  {case}")
        assert all(r.outcome == "passed" for r in results), item
        missing = [case for case in EDGE_CASES if seen[case] == 0]
        assert not missing, (item, missing)
