"""``_host.call`` and ``_host.bench`` through the stub driver."""

from __future__ import annotations

import gc
import sys

import pytest
from stub_driver import StubDriver

from spectest._host import bench, call
from spectest.driver.wire import Error, Float, Handle, Map, Record


@pytest.fixture
def driver() -> StubDriver:
    return StubDriver()


def test_no_arguments_returns_none(driver: StubDriver) -> None:
    assert call(driver, "stubmod.nothing", []) is None


def test_two_ints(driver: StubDriver) -> None:
    assert call(driver, "stubmod.add", [2, 3]) == 5
    assert call(driver, "stubmod.add", [2**70, 1]) == 2**70 + 1


def test_values_cross_both_ways(driver: StubDriver) -> None:
    value = [1, (b"x\x00", "\U0001f600"), None, Float("f64", 0x7FF8_0000_0000_0001)]
    assert call(driver, "stubmod.identity", [value]) == value


def test_the_name_resolves_once(driver: StubDriver) -> None:
    call(driver, "stubmod.add", [1, 1])
    call(driver, "stubmod.add", [1, 1])
    assert driver.ids == {"stubmod.add": 0}


def test_a_raised_exception_comes_back_as_error(driver: StubDriver) -> None:
    result = call(driver, "stubmod.boom", ["no"])
    assert result == Error("ValueError", ("Exception", "BaseException"), "no")


def test_unresolvable_name_raises(driver: StubDriver) -> None:
    with pytest.raises(RuntimeError, match="cannot resolve stubmod.missing"):
        call(driver, "stubmod.missing", [])


def test_handles_and_methods(driver: StubDriver) -> None:
    made = call(driver, "stubmod.make_counter", [10])
    assert made == Handle(1, "stubmod.Counter")
    assert call(driver, "stubmod.Counter.bump", [made, 5]) == 15
    assert call(driver, "stubmod.Counter.bump", [made]) == 16


def test_a_driver_that_raises_names_the_exception(driver: StubDriver) -> None:
    class Broken(StubDriver):
        def call(self, target, args, kwargs):
            raise KeyError("lost")

    with pytest.raises(RuntimeError, match=r"KeyError.*lost"):
        call(Broken(), "stubmod.add", [1, 2])


def test_a_driver_returning_garbage_raises_type_error(driver: StubDriver) -> None:
    class Garbage(StubDriver):
        def call(self, target, args, kwargs):
            return 1.5

    with pytest.raises(TypeError):
        call(Garbage(), "stubmod.add", [1, 2])


def test_bad_arguments(driver: StubDriver) -> None:
    with pytest.raises(TypeError):
        call(driver, "stubmod.add", (1, 2))
    with pytest.raises(TypeError):
        call(driver, "stubmod.add", [1.5])
    with pytest.raises(TypeError):
        call(driver, "stubmod.add")


def test_bench_reports_seconds_per_call(driver: StubDriver) -> None:
    per_call = bench(driver, "stubmod.add", [1, 2], 200)
    assert 0 < per_call < 0.01
    assert driver.calls == 200


def test_calls_do_not_leak_references(driver: StubDriver) -> None:
    sentinel = f"sentinel-{id(object())}"
    args = [[sentinel, Map(((sentinel, [1]),))]]
    for _ in range(100):
        call(driver, "stubmod.identity", args)
    before = (sys.getrefcount(sentinel), sys.getrefcount(driver))
    for _ in range(5_000):
        call(driver, "stubmod.identity", args)
    gc.collect()
    assert (sys.getrefcount(sentinel), sys.getrefcount(driver)) == before


def test_records_survive_a_call(driver: StubDriver) -> None:
    r = Record("pkg.P", (("a", [1, 2]), ("b", None)))
    assert call(driver, "stubmod.identity", [r]) == r
