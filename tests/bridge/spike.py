"""Measures the host's call path: microseconds per call through ``DriverClient``,
median of 5 runs of ``_host.bench``.

Run: ``uv run python tests/bridge/spike.py``. The stub driver does its own work in
Python, so each case is also timed with a driver that returns its argument untouched
(``bare``), which isolates the host's conversions and call overhead.
"""

from __future__ import annotations

import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import build_host

build_host.build()

from stub_driver import StubDriver

from spectest import _host
from spectest.driver.wire import Enum, Map, Record

CALLS = 20_000
RUNS = 5


class Bare:
    """The cheapest possible driver: every call returns its first argument."""

    def resolve(self, name: str) -> int:
        return 0

    def call(self, target: int, args: list, kwargs: dict) -> object:
        return args[0] if args else None


def median_us(driver: object, name: str, args: list) -> float:
    runs = [_host.bench(driver, name, args, CALLS) for _ in range(RUNS)]
    return statistics.median(runs) * 1e6


def main() -> None:
    stub = StubDriver()
    handle = _host.call(stub, "stubmod.make_counter", [0])
    record = Record(
        "pkg.R",
        (
            ("a", [1, 2, (3, "x")]),
            ("b", Map((("k", [None, True]),))),
            ("c", Enum("pkg.E", "m")),
        ),
    )
    ints = list(range(100))
    cases = [
        ("function, no arguments, returns None", "stubmod.nothing", []),
        ("function, two ints, returns the sum", "stubmod.add", [2, 3]),
        ("method on a handle", "stubmod.Counter.bump", [handle]),
        ("identity of a list of 100 ints", "stubmod.identity", [ints]),
        ("identity of a nested record", "stubmod.identity", [record]),
    ]
    print(f"{'case':42} {'stub':>9} {'bare':>9}   (us per call)")
    bare = Bare()
    for label, name, args in cases:
        print(
            f"{label:42} {median_us(stub, name, args):9.2f}"
            f" {median_us(bare, name, args):9.2f}"
        )
    echo = [
        ("echo, list of 100 ints", ints),
        ("echo, nested record", record),
    ]
    import timeit

    for label, value in echo:
        runs = timeit.repeat(lambda v=value: _host.echo(v), number=CALLS, repeat=RUNS)
        print(f"{label:42} {statistics.median(runs) / CALLS * 1e6:9.2f}")


if __name__ == "__main__":
    main()
