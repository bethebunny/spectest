"""Module mapping in the driver: names under a mapped prefix resolve under its replacement."""

from __future__ import annotations

import math
import os.path
import struct

from spectest.driver import Driver
from spectest.driver.wire import Error, Float


def test_a_mapped_module_replaces_the_prefix() -> None:
    d = Driver(module_map={"lib": "math"})
    tid = d.resolve("lib.sqrt")
    assert isinstance(tid, int)
    assert d.call(tid, [Float("f64", struct.unpack("<Q", struct.pack("<d", 16.0))[0])]) == Float(
        "f64", struct.unpack("<Q", struct.pack("<d", 4.0))[0]
    )


def test_the_longest_mapped_prefix_wins() -> None:
    d = Driver(module_map={"lib": "math", "lib.paths": "os.path"})
    assert d._lookup("lib.paths.join") is os.path.join
    assert d._lookup("lib.fabs") is math.fabs


def test_only_whole_name_parts_match() -> None:
    d = Driver(module_map={"lib": "math"})
    assert isinstance(d.resolve("libs.sqrt"), Error)
    assert d._mapped("lib") == "math"
    assert d._mapped("libx.y") == "libx.y"


def test_an_unmapped_driver_resolves_as_before() -> None:
    d = Driver()
    assert d._lookup("math.sqrt") is math.sqrt


def test_a_mapped_name_that_is_missing_is_a_resolve_error() -> None:
    d = Driver(module_map={"lib": "math"})
    err = d.resolve("lib.nothing")
    assert isinstance(err, Error)
    assert err.cls == "spectest.ResolveError"
