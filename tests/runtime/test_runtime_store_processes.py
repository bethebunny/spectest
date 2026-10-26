"""The counterexample store shared by processes: no save is lost, no reader sees half a file.

Threads stand in for processes: each save opens the lock file itself, and flock locks
belong to open files, so threads contend for the lock as processes do.
"""

from __future__ import annotations

import sys
import threading

import pytest

from spectest.runtime.store import CounterexampleStore

pytestmark = pytest.mark.skipif(sys.platform == "win32", reason="the store locks with fcntl")


def test_concurrent_saves_to_one_item_all_survive(tmp_path):
    def save_many(worker: int) -> None:
        store = CounterexampleStore(tmp_path, max_entries=1000)
        for i in range(15):
            store.save("hash", "item", {"x": worker * 1000 + i})

    workers = [threading.Thread(target=save_many, args=(w,)) for w in range(4)]
    for t in workers:
        t.start()
    for t in workers:
        t.join(30)
    entries = CounterexampleStore(tmp_path, max_entries=1000).load("hash", "item")
    assert sorted(e["x"] for e in entries) == sorted(
        w * 1000 + i for w in range(4) for i in range(15)
    )
    assert [p.name for p in tmp_path.rglob("*") if p.name.startswith(".tmp-")] == []
