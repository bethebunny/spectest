from itertools import islice
from pathlib import Path

import pytest

from spectest.generate import GenerateError, admitted_set, exhaustive_inputs
from spectest.lang import load, load_source
from spectest.prelude import floats
from spectest.types import FloatT
from spectest.values import FloatValue

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
LIBM = load(EXAMPLES / "libm" / "libm.spec")
EXPLORE = load(EXAMPLES / "libm" / "explore.spec")
DEQUE = load(EXAMPLES / "deque" / "deque.spec")
BINARY = load(EXAMPLES / "binary" / "binary.spec")
SORTING = load(EXAMPLES / "sorting" / "sorting.spec")
FRAMES = load(EXAMPLES / "frames" / "frames.spec")


@pytest.mark.parametrize("spec", [LIBM, EXPLORE], ids=["libm", "explore"])
def test_cos16_runs_on_every_bit_pattern(spec):
    count, inputs = exhaustive_inputs(spec.fns["cos16"], spec)
    assert count == 65536
    values = [args["x"] for args in inputs]
    assert len(values) == 65536
    assert all(isinstance(v, FloatValue) and v.fmt == "f16" for v in values)
    assert len({v.bits for v in values}) == 65536


def test_exhaustive_order_is_deterministic():
    first = [a["x"].bits for a in islice(exhaustive_inputs("cos16", LIBM)[1], 100)]
    again = [a["x"].bits for a in islice(exhaustive_inputs("cos16", LIBM)[1], 100)]
    assert first == again == list(range(100))


def test_large_domains_are_not_exhaustive():
    assert exhaustive_inputs("cos", LIBM) is None
    assert exhaustive_inputs("cos32", LIBM) is None
    assert exhaustive_inputs("sqrt", LIBM) is None
    assert exhaustive_inputs("pack_i32", BINARY) is None
    assert exhaustive_inputs("cos16", LIBM, limit=65535) is None
    assert exhaustive_inputs("cos16", LIBM, limit=65536)[0] == 65536


def test_non_fixed_width_parameters_are_not_exhaustive():
    assert exhaustive_inputs("unpack_i32", BINARY) is None
    assert exhaustive_inputs("utf8_encode", BINARY) is None
    assert exhaustive_inputs("dropna", FRAMES) is None
    assert exhaustive_inputs("sort", SORTING, {"T": "u8"}) is None


def test_deque_constructors_and_methods():
    count, inputs = exhaustive_inputs("Deque.bounded", DEQUE)
    assert count == 256 and [a["n"] for a in inputs] == list(range(256))
    count, inputs = exhaustive_inputs("Deque.rotate", DEQUE)
    assert count == 256
    assert sorted(a["n"] for a in inputs) == list(range(-128, 128))
    count, inputs = exhaustive_inputs("Deque.empty", DEQUE)
    assert count == 1 and list(inputs) == [{}]
    assert exhaustive_inputs("Deque.pop", DEQUE, {"T": "i64"})[0] == 1


def test_type_variables_instantiate_before_counting():
    assert exhaustive_inputs("Deque.append", DEQUE, {"T": "i8"})[0] == 256
    assert exhaustive_inputs("Deque.append", DEQUE, {"T": "bool"})[0] == 2
    assert exhaustive_inputs("Deque.append", DEQUE, {"T": "string"}) is None
    assert exhaustive_inputs("Deque.append", DEQUE, {"T": "i64"}) is None
    with pytest.raises(GenerateError, match="type variable T"):
        exhaustive_inputs("Deque.append", DEQUE)


SPEC = load_source(
    """spec local

fn not_nan(x: f16) -> f16
  requires not is_nan(x)

fn split(x: u8) -> u8
  requires x < 10
  partition x
    low  = u8.range(0, 5)
    high = u8.range(5, 256)

fn pair(a: bool, b: u8) -> u8

fn flagged(a: bool, b: u8) -> u8
  requires a

fn wide(x: i16, y: bool) -> bool

fn halves(x: i16) -> bool
  partition x
    neg = i16.range(none, 0)
    pos = i16.range(0, none)

fn positive16(x: f16) -> f16
  requires x > 0
  partition x
    sub = f16.subnormal & f16.positive
    rest = f16.positive - f16.subnormal

fn generic<T>(x: T, y: u8) -> T

fn nothing(x: u8, y: i16) -> bool
  requires x < 0
"""
)


def test_requires_narrows_the_domain():
    count, inputs = exhaustive_inputs("not_nan", SPEC)
    assert count == 65536 - 2046
    assert not any(floats.is_nan(a["x"]) for a in inputs)
    count, inputs = exhaustive_inputs("split", SPEC)
    assert count == 10 and [a["x"] for a in inputs] == list(range(10))
    count, inputs = exhaustive_inputs("flagged", SPEC)
    assert count == 256 and all(a["a"] is True for a in inputs)


def test_partition_union_and_requires_intersect():
    count, inputs = exhaustive_inputs("positive16", SPEC)
    xs = [a["x"] for a in inputs]
    assert count == len(xs) == 0x7C00
    assert all(floats.to_python_float(x) > 0 for x in xs)
    assert admitted_set("positive16", "x", SPEC).size == 0x7C00


def test_products_of_parameters():
    count, inputs = exhaustive_inputs("pair", SPEC)
    rows = [(a["a"], a["b"]) for a in inputs]
    assert count == len(rows) == 512
    assert rows[:3] == [(False, 0), (False, 1), (False, 2)]
    assert rows[256] == (True, 0)
    assert len(set(rows)) == 512
    assert exhaustive_inputs("wide", SPEC) is None
    assert exhaustive_inputs("wide", SPEC, limit=131072)[0] == 131072
    assert exhaustive_inputs("halves", SPEC)[0] == 65536


def test_generic_function_domains():
    assert exhaustive_inputs("generic", SPEC, {"T": "bool"})[0] == 512
    assert exhaustive_inputs("generic", SPEC, {"T": FloatT("f16")}, limit=1 << 24)[0] == 1 << 24
    assert exhaustive_inputs("generic", SPEC, {"T": "list<bool>"}) is None


def test_admitted_set():
    assert admitted_set("split", "x", SPEC).size == 10
    assert admitted_set("cos16", "x", LIBM).size == 65536
    assert admitted_set("sqrt", "x", LIBM).size == 1 << 64
    assert admitted_set("unpack_i32", "b", BINARY) is None
    with pytest.raises(GenerateError, match="no parameter"):
        admitted_set("split", "y", SPEC)


def test_an_empty_admitted_domain_has_no_inputs():
    count, inputs = exhaustive_inputs("nothing", SPEC)
    assert count == 0 and list(inputs) == []
