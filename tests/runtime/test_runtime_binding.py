"""Bindings: conformance() validation, spec paths, value conversion, handles."""

from __future__ import annotations

import enum
import math
import runpy
import struct
from dataclasses import dataclass
from decimal import Decimal
from fractions import Fraction
from importlib import metadata
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
from hypothesis import given
from hypothesis import strategies as st

import spectest
from spectest.lang import load_source
from spectest.prelude import floats
from spectest.runtime import binding
from spectest.runtime.binding import (
    Conformance,
    ConformanceError,
    InterfaceBinding,
    ModelBinding,
    TypeMismatch,
    ValueRefused,
    call_arguments,
    concretize,
    concretize_value,
    conformance,
    digest,
    fields,
    from_python,
    map_exception,
    observe,
    reformat,
    shares_memory,
    to_python,
)
from spectest.types import (
    BOOL,
    BYTES,
    INT,
    REAL,
    STRING,
    UNIT,
    EnumT,
    FixedIntT,
    FloatT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    RecordT,
    TupleT,
    TypeVarT,
)
from spectest.values import (
    NEG_INF,
    POS_INF,
    BindingError,
    FloatValue,
    Handle,
    MapValue,
    NotAValue,
    RecordValue,
    Some,
    Unrepresentable,
)

try:
    from spectest.generate import DEFAULT, GeneratedModel
except ImportError:
    DEFAULT = None

    @dataclass(eq=False)
    class GeneratedModel:  # type: ignore[no-redef]
        model: str
        targs: tuple
        fields: dict


SOURCE = """\
spec conv

error Boom
error Oops

enum Color { Red, Green }
record Point { x: i32, y: f64 }

model Box
  observe items: list<i64>
  observe label: string
  observe weight: f64
  observe at(i: u64): option<i64>
  invariant nonneg: len(items) >= 0

model Bag<T>
  observe items: list<T>

interface Counter
  observe value: i64
  new zero() -> Counter
  method incr(self, by: u8)
    modifies self
    ensures grows: self.value == old(self.value) + by
  method get(self) -> i64

fn scalar(x: f64) -> f64
  ensures ok: is_finite(x) implies is_finite(result)
  impl_defined nan_payload

fn sort<T: Ord>(xs: list<T>) -> list<T>
  ensures ordered: is_sorted(result)

fn pair<K: Ord, V: Eq>(xs: list<(K, V)>) -> list<(K, V)>

fn boxed(b: Box) -> Box
  ensures same_items: result.items == b.items

fn bagged(b: Bag<i64>) -> i64

fn opt(x: i64, how: "any" | "all" = "any") -> i64
  requires x > 0
  may_raise Boom
"""

F16, BF16, F32, F64 = FloatT("f16"), FloatT("bf16"), FloatT("f32"), FloatT("f64")
I8, I32, I64, U8, U64 = (FixedIntT(8, True), FixedIntT(32, True), FixedIntT(64, True),
                         FixedIntT(8, False), FixedIntT(64, False))  # fmt: skip
WIDTH = {"f16": 16, "bf16": 16, "f32": 32, "f64": 64}
UINT = {"f16": np.uint16, "f32": np.uint32, "f64": np.uint64}


@pytest.fixture(scope="module")
def spec():
    return load_source(SOURCE, "conv.spec")


@pytest.fixture(scope="module")
def py(spec):
    return Conformance(spec=spec)


@pytest.fixture(scope="module")
def npc(spec):
    return Conformance(spec=spec, scalars="numpy")


def fv(fmt: str, bits: int) -> FloatValue:
    return FloatValue(fmt, bits)


def f64(x: float) -> FloatValue:
    return floats.from_python_float(x)


def bits_of(x: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def float_values(fmt: str):
    return st.integers(0, (1 << WIDTH[fmt]) - 1).map(lambda b: FloatValue(fmt, b))


# ---------------------------------------------------------------------------
# Floats


@pytest.mark.parametrize("fmt", ["f16", "bf16", "f32", "f64"])
@given(data=st.data())
def test_python_mode_round_trips_every_bit_pattern(fmt, data):
    v = data.draw(float_values(fmt))
    t = FloatT(fmt)
    x = to_python(v, t, None)
    assert type(x) is float
    back = from_python(x, t, None)
    assert back == v


@pytest.mark.parametrize("fmt", ["f16", "f32", "f64"])
@given(data=st.data())
def test_numpy_mode_round_trips_every_bit_pattern(npc, fmt, data):
    v = data.draw(float_values(fmt))
    t = FloatT(fmt)
    x = to_python(v, t, npc)
    assert x.dtype == np.dtype({"f16": np.float16, "f32": np.float32, "f64": np.float64}[fmt])
    assert int(np.asarray(x).view(UINT[fmt])) == v.bits
    assert from_python(x, t, npc) == v


@pytest.mark.parametrize(
    "v",
    [
        fv("f64", 0x8000000000000000),  # -0.0
        fv("f64", 0x7FF0000000000001),  # signaling NaN, payload 1
        fv("f64", 0xFFF8000000000123),  # negative quiet NaN with payload
        fv("f32", 0x80000000),
        fv("f32", 0x7F800001),
        fv("f32", 0xFFC00042),
        fv("f16", 0x8000),
        fv("f16", 0x7C01),
        fv("f16", 0xFE11),
    ],
)
@pytest.mark.parametrize("mode", ["python", "numpy"])
def test_signed_zeros_and_nan_payloads_survive(spec, v, mode):
    conf = Conformance(spec=spec, scalars=mode)
    t = FloatT(v.fmt)
    assert from_python(to_python(v, t, conf), t, conf) == v


def test_python_mode_f64_is_the_python_float_with_those_bits():
    x = to_python(fv("f64", 0x7FF0000000000001), F64)
    assert math.isnan(x) and bits_of(x) == 0x7FF0000000000001
    assert math.copysign(1.0, to_python(fv("f64", 0x8000000000000000), F64)) == -1.0
    assert to_python(f64(0.1), F64) == 0.1


def test_python_mode_narrow_formats_widen_exactly():
    assert to_python(fv("f32", 0x3DCCCCCD), F32) == float(np.float32(0.1))
    assert to_python(fv("f16", 0x3C00), F16) == 1.0
    assert to_python(fv("bf16", 0x3F80), BF16) == 1.0


def test_from_python_accepts_other_precisions_only_when_exact():
    assert from_python(np.float32(0.1), F64) == floats.from_numpy(np.float64(np.float32(0.1)))
    assert from_python(np.float64(0.5), F32) == fv("f32", 0x3F000000)
    assert from_python(0.5, F16) == fv("f16", 0x3800)
    assert from_python(float("-inf"), F16) == fv("f16", 0xFC00)
    assert from_python(-0.0, F32) == fv("f32", 0x80000000)
    assert from_python(np.float16(1.5), F32) == fv("f32", 0x3FC00000)
    with pytest.raises(
        TypeMismatch, match=r"expected f32, got float64 .*not exactly representable as f32"
    ):
        from_python(np.float64(0.1), F32)
    with pytest.raises(TypeMismatch, match="not exactly representable as f16"):
        from_python(1e300, F16)
    with pytest.raises(TypeMismatch, match="not exactly representable as f16"):
        from_python(np.float32(1e-30), F16)


def test_from_python_nan_of_another_precision():
    wide_from_f32 = struct.unpack("<d", struct.pack("<Q", 0x7FF0000020000000))[0]
    assert from_python(wide_from_f32, F32) == fv("f32", 0x7F800001)
    low_payload = struct.unpack("<d", struct.pack("<Q", 0x7FF8000000000001))[0]
    got = from_python(low_payload, F32)
    assert floats.is_nan(got) and got.fmt == "f32"
    assert from_python(np.float32("nan"), F64) == reformat(
        floats.from_numpy(np.float32("nan")), "f64"
    )


def test_reformat():
    assert reformat(fv("f32", 0x7F800001), "f64") == fv("f64", 0x7FF0000020000000)
    assert reformat(fv("f64", 0x7FF0000020000000), "f32") == fv("f32", 0x7F800001)
    assert reformat(fv("f64", 0x7FF0000000000001), "f32") is None
    assert reformat(f64(0.1), "f32") is None
    assert reformat(f64(-0.0), "f16") == fv("f16", 0x8000)
    assert reformat(fv("bf16", 0x7F7F), "f16") is None
    assert reformat(f64(1.0), "bf16") == fv("bf16", 0x3F80)


@pytest.mark.parametrize("obj", [1, True, "1.0", None, np.int32(1), Fraction(1, 2), [1.0]])
def test_floats_reject_non_floats(obj):
    with pytest.raises(TypeMismatch, match=r"^expected f64, got "):
        from_python(obj, F64)


def test_zero_dim_arrays_are_scalars():
    assert from_python(np.array(1.5), F64) == f64(1.5)
    assert from_python(np.array(7, dtype=np.int16), I32) == 7
    assert from_python(np.array(True), BOOL) is True


def test_to_python_checks_the_value():
    with pytest.raises(BindingError, match="cannot pass"):
        to_python(f64(1.0), F32)
    with pytest.raises(BindingError):
        to_python(1.0, F64)


def test_numpy_mode_bf16_without_ml_dtypes(spec):
    pytest.importorskip("numpy")
    try:
        import ml_dtypes  # noqa: F401
    except ImportError:
        with pytest.raises(BindingError, match="ml_dtypes"):
            to_python(fv("bf16", 0x3F80), BF16, Conformance(spec=spec, scalars="numpy"))


# ---------------------------------------------------------------------------
# Other types


def test_bools():
    assert from_python(True, BOOL) is True
    assert from_python(np.bool_(False), BOOL) is False
    assert to_python(True, BOOL) is True
    with pytest.raises(TypeMismatch, match="expected bool, got int 1"):
        from_python(1, BOOL)


class Small(enum.IntEnum):
    A = 3


def test_ints():
    assert from_python(5, I32) == 5
    assert from_python(np.int64(-5), I8) == -5
    assert type(from_python(np.uint64(2**64 - 1), U64)) is int
    assert from_python(Small.A, I64) == 3
    assert from_python(10**40, INT) == 10**40
    with pytest.raises(
        TypeMismatch, match=r"expected u8, got int 300 \(outside the u8 range 0\.\.255\)"
    ):
        from_python(300, U8)
    with pytest.raises(TypeMismatch, match="outside the i8 range -128..127"):
        from_python(np.int64(-129), I8)
    for bad in (True, 3.0, "3", np.float64(3), None, np.bool_(True)):
        with pytest.raises(TypeMismatch, match="^expected i64, got"):
            from_python(bad, I64)
    assert to_python(-128, I8) == -128
    with pytest.raises(BindingError, match="outside -128..127"):
        to_python(200, I8)
    with pytest.raises(BindingError):
        to_python(True, I64)


def test_reals():
    assert from_python(1.5, REAL) == Fraction(3, 2)
    assert type(from_python(-0.0, REAL)) is Fraction and from_python(-0.0, REAL) == 0
    assert from_python(3, REAL) == Fraction(3)
    assert from_python(Fraction(1, 3), REAL) == Fraction(1, 3)
    assert from_python(Decimal("0.1"), REAL) == Fraction(1, 10)
    assert from_python(float("inf"), REAL) is POS_INF
    assert from_python(Decimal("-Infinity"), REAL) is NEG_INF
    with pytest.raises(TypeMismatch, match="NaN is not a real number"):
        from_python(float("nan"), REAL)
    with pytest.raises(TypeMismatch):
        from_python(True, REAL)
    assert to_python(Fraction(1, 3), REAL) == Fraction(1, 3)
    assert to_python(NEG_INF, REAL) == float("-inf")


def test_strings_and_bytes():
    assert from_python("héllo", STRING) == "héllo"
    assert from_python(np.str_("x"), STRING) == "x"
    assert from_python(bytearray(b"ab"), BYTES) == b"ab"
    assert from_python(memoryview(b"cd"), BYTES) == b"cd"
    assert type(from_python(bytearray(b"ab"), BYTES)) is bytes
    with pytest.raises(TypeMismatch, match="expected bytes, got str 'ab'"):
        from_python("ab", BYTES)
    with pytest.raises(TypeMismatch, match="expected string, got bytes b'ab'"):
        from_python(b"ab", STRING)
    assert to_python(b"\x00\xff", BYTES) == b"\x00\xff"


def test_lists(npc):
    t = ListT(I32)
    assert from_python([1, 2], t) == (1, 2)
    assert from_python((1, 2), t) == (1, 2)
    assert from_python(np.array([1, 2], dtype=np.int32), t) == (1, 2)
    assert from_python(np.array([0.5, -0.0]), ListT(F64)) == (f64(0.5), f64(-0.0))
    grid = from_python(np.array([[1.0, 2.0], [3.0, 4.0]]), ListT(ListT(F64)))
    assert grid == ((f64(1.0), f64(2.0)), (f64(3.0), f64(4.0)))
    assert to_python((1, 2), t) == [1, 2]
    xs = to_python((fv("f32", 0x3F800000),), ListT(F32), npc)
    assert isinstance(xs, list) and xs[0].dtype == np.float32
    with pytest.raises(TypeMismatch, match="a list, tuple or numpy array is accepted"):
        from_python("ab", ListT(STRING))
    with pytest.raises(TypeMismatch) as e:
        from_python([1, 2, "a"], ListT(I64))
    assert str(e.value) == "at [2]: expected i64, got str 'a'"
    assert e.value.path == "[2]"
    with pytest.raises(TypeMismatch) as e:
        from_python([[1], [2, None]], ListT(ListT(I64)))
    assert str(e.value) == "at [1][1]: expected i64, got NoneType None"


def test_tuples():
    t = TupleT((I64, STRING))
    assert from_python((1, "a"), t) == (1, "a")
    assert from_python([1, "a"], t) == (1, "a")
    assert to_python((1, "a"), t) == (1, "a")
    with pytest.raises(TypeMismatch, match=r"3 elements instead of 2"):
        from_python((1, "a", 2), t)
    with pytest.raises(TypeMismatch) as e:
        from_python((1, 2), t)
    assert str(e.value) == "at .1: expected string, got int 2"


def test_options():
    t = OptionT(F64)
    assert from_python(None, t) is None
    assert from_python(1.5, t) == Some(f64(1.5))
    assert from_python([None, float("nan")], ListT(t))[1] == Some(f64(float("nan")))
    assert to_python(None, t) is None
    assert to_python(Some(f64(2.0)), t) == 2.0
    with pytest.raises(BindingError):
        to_python(f64(2.0), t)


def test_literals_and_enums():
    lit = LiteralT(("any", "all"))
    assert from_python("any", lit) == "any"
    with pytest.raises(TypeMismatch) as e:
        from_python("some", lit)
    assert str(e.value) == 'expected one of "any", "all", got str \'some\''
    color = EnumT("Color", ("Red", "Green"))

    class PyColor(enum.Enum):
        Red = 1

    class How(enum.Enum):
        ANY = "any"

    assert from_python("Green", color) == "Green"
    assert from_python(PyColor.Red, color) == "Red"
    assert from_python(How.ANY, lit) == "any"
    assert to_python("Red", color) == "Red"
    with pytest.raises(BindingError):
        to_python("Blue", color)


@dataclass
class PointObj:
    x: int
    y: float


def test_records():
    t = RecordT("Point", (("x", I32), ("y", F64)))
    expected = RecordValue("Point", (("x", 1), ("y", f64(2.0))))
    assert from_python({"x": 1, "y": 2.0}, t) == expected
    assert from_python(PointObj(1, 2.0), t) == expected
    assert from_python(SimpleNamespace(x=1, y=2.0), t) == expected
    assert to_python(expected, t) == {"x": 1, "y": 2.0}
    with pytest.raises(TypeMismatch, match="missing 'y'; unexpected 'z'"):
        from_python({"x": 1, "z": 2.0}, t)
    with pytest.raises(TypeMismatch, match="no attribute 'y'"):
        from_python(SimpleNamespace(x=1), t)
    with pytest.raises(TypeMismatch) as e:
        from_python({"x": 1, "y": "2"}, t)
    assert str(e.value) == "at .y: expected f64, got str '2'"


def test_maps():
    t = MapT(STRING, I64)
    m = from_python({"a": 1, "b": 2}, t)
    assert m == MapValue((("a", 1), ("b", 2)))
    assert to_python(m, t) == {"a": 1, "b": 2}
    keyed = MapT(ListT(I64), I64)
    assert to_python(MapValue((((1, 2), 3),)), keyed) == {(1, 2): 3}
    with pytest.raises(TypeMismatch) as e:
        from_python({"a": "x"}, t)
    assert str(e.value) == "at ['a']: expected i64, got str 'x'"
    with pytest.raises(TypeMismatch, match="expected map<string, i64>, got list"):
        from_python([("a", 1)], t)


def test_unit():
    assert from_python(None, UNIT) is None
    assert to_python(None, UNIT) is None
    with pytest.raises(TypeMismatch, match=r"expected no value \(None\), got int 3"):
        from_python(3, UNIT)


def test_models():
    t = ModelT("Bag", (I64,))
    obj = object()
    h = from_python(obj, t, created_by="bagged")
    assert isinstance(h, Handle) and h.obj is obj and h.model == "Bag"
    assert h.created_by == "bagged" and h.targs == (I64,)
    assert from_python(h, t) is h
    assert to_python(h, t) is obj
    with pytest.raises(TypeMismatch, match="expected a Bag<i64> object, got None"):
        from_python(None, t)
    with pytest.raises(BindingError, match="concretize"):
        to_python(GeneratedModel("Bag", (I64,), {"items": ()}), t)


def test_type_variables_are_binding_errors():
    with pytest.raises(BindingError, match="type parameter T is not instantiated"):
        from_python(1, TypeVarT("T"))
    with pytest.raises(BindingError):
        to_python(1, TypeVarT("T"))


def test_type_mismatch_messages_are_short():
    with pytest.raises(TypeMismatch) as e:
        from_python(list(range(1000)), STRING)
    assert len(str(e.value)) < 120


# ---------------------------------------------------------------------------
# conformance()


def problems(**kwargs) -> list[str]:
    with pytest.raises(ConformanceError) as e:
        conformance(kwargs.pop("spec"), **kwargs)
    return e.value.problems


def test_conformance_builds(spec):
    conf = conformance(
        spec,
        impls={"scalar": abs, "sort": sorted},
        errors={ValueError: "Boom", (KeyError, IndexError): "Oops"},
        instantiate={"T": "i64"},
        expect_fail={"scalar.ok"},
        max_examples=7,
    )
    assert isinstance(conf, Conformance) and conf.spec is spec
    assert conf.instantiate == [{"T": I64}]
    assert conf.expect_fail == frozenset({"scalar.ok"})
    assert conf.max_examples == 7 and conf.exhaustive_limit == 65536 and conf.scalars == "python"
    assert conf.name is None and conf.path == str(Path(__file__).resolve())
    assert "Conformance" in repr(conf) and len(repr(conf)) < 200


def test_unknown_impls(spec):
    (p,) = problems(spec=spec, impls={"scalr": abs})
    assert p.startswith("impls: 'scalr' is not a function of spec conv; did you mean 'scalar'?")
    (p,) = problems(spec=spec, impls={"scalar": 3})
    assert p == "impls['scalar'] is not callable: 3"


def test_unknown_models_and_interfaces(spec):
    (p,) = problems(spec=spec, models={"Bx": ModelBinding()})
    assert "'Bx' is not a model of spec conv; did you mean 'Box'?" in p
    (p,) = problems(spec=spec, models={"Counter": ModelBinding()})
    assert "it is an interface: bind it with interfaces=" in p
    (p,) = problems(spec=spec, interfaces={"Box": InterfaceBinding(constructors={})})
    assert "it is a model: bind it with models=" in p
    (p,) = problems(spec=spec, models={"Box": ModelBinding(observers={"itms": len})})
    assert p.startswith(
        "models['Box'].observers: 'itms' is not an observer of Box; did you mean 'items'?"
    )
    (p,) = problems(spec=spec, models={"Box": {"items": len}})
    assert "must be a ModelBinding" in p
    (p,) = problems(spec=spec, models={"Box": ModelBinding(concretize=5)})
    assert p == "models['Box'].concretize is not callable: 5"
    (p,) = problems(spec=spec, models={"Box": ModelBinding(accepts=True)})
    assert p == "models['Box'].accepts is not callable: True"
    (p,) = problems(spec=spec, models={"Box": ModelBinding(lossy="yes")})
    assert p == "models['Box'].lossy must be True or False, got 'yes'"


def test_interface_bindings(spec):
    ok = conformance(
        spec,
        interfaces={
            "Counter": InterfaceBinding(constructors={"zero": list}, methods={"incr": max})
        },
    )
    assert "Counter" in ok.interfaces
    ps = problems(
        spec=spec,
        interfaces={
            "Counter": InterfaceBinding(
                constructors={"one": list}, methods={"inc": max}, observers={"val": len}
            )
        },
    )
    assert any("constructors: 'one' is not a constructor of Counter" in p for p in ps)
    assert any("methods: 'inc' is not a method of Counter; did you mean 'incr'?" in p for p in ps)
    assert any("observers: 'val' is not an observer of Counter" in p for p in ps)
    (p,) = problems(spec=spec, interfaces={"Counter": InterfaceBinding(constructors={})})
    assert p == "interfaces['Counter'] needs at least one constructor"


def test_errors_mapping(spec):
    (p,) = problems(spec=spec, errors={ValueError: "Bom"})
    assert p.startswith("errors: ValueError maps to 'Bom', which spec conv does not declare")
    assert "did you mean 'Boom'?" in p
    (p,) = problems(spec=spec, errors={"ValueError": "Boom"})
    assert p == "errors: key 'ValueError' is not an exception class (or a tuple of them)"
    conformance(spec, errors={(ValueError, TypeError): "Boom"})


def test_instantiate_normalization(spec):
    conf = conformance(
        spec,
        impls={"sort": sorted, "pair": sorted},
        instantiate=[{"T": "i64"}, {"T": STRING}, {"K": "u8", "V": "(string, bool)"}],
    )
    assert conf.instantiate == [{"T": I64}, {"T": STRING}, {"K": U8, "V": TupleT((STRING, BOOL))}]
    assert conf.instantiations("sort") == [{"T": I64}, {"T": STRING}]
    assert conf.instantiations(spec.fns["pair"]) == [{"K": U8, "V": TupleT((STRING, BOOL))}]
    assert conf.instantiations("scalar") == [{}]
    assert conf.instantiations("Bag") == [{"T": I64}, {"T": STRING}]


def test_instantiate_errors(spec):
    (p,) = problems(spec=spec, instantiate={"X": "i64"})
    assert p.startswith("instantiate: 'X' is not a type parameter of any declaration")
    assert "(K, T, V)" in p
    (p,) = problems(spec=spec, instantiate={"T": "i46"})
    assert p.startswith("instantiate: T = 'i46': ") and "i46" in p
    (p,) = problems(spec=spec, instantiate={"T": 64})
    assert "neither a type name nor a Type" in p
    (p,) = problems(spec=spec, instantiate={"T": "real"})
    assert "cannot be a parameter type" in p
    (p,) = problems(spec=spec, instantiate="i64")
    assert p.startswith("instantiate must be a dict or a list of dicts")
    (p,) = problems(spec=spec, impls={"sort": sorted}, instantiate={"T": "f64"})
    assert p == "instantiate: T = f64 has no total order, as sort<T: Ord> needs"
    (p,) = problems(spec=spec, impls={"pair": sorted}, instantiate={"K": "i64", "V": "f32"})
    assert "V = f32 has no canonical equality, as pair<K: Ord, V: Eq> needs" in p
    (p,) = problems(spec=spec, impls={"sort": sorted})
    assert (
        p == "sort is generic <T: Ord> but no instantiation names T: pass instantiate={'T': 'i64'}"
    )
    conformance(spec, instantiate={"T": "f64"})


def test_models_used_as_arguments_need_concretize(spec):
    (p,) = problems(spec=spec, impls={"boxed": id})
    assert p == "boxed takes b: Box, so models['Box'] needs a ModelBinding with concretize="
    conformance(spec, impls={"boxed": id}, models={"Box": ModelBinding(concretize=dict)})


def test_expect_fail_ids(spec):
    conf = conformance(
        spec,
        impls={"scalar": abs, "opt": abs},
        interfaces={"Counter": InterfaceBinding(constructors={"zero": list})},
        expect_fail=["scalar.ok", "scalar#type", "scalar#raises", "Counter.incr.grows",
                     "Counter.get#type", "Box.nonneg"],
    )  # fmt: skip
    assert conf.is_expected_fail("scalar#type")
    (p,) = problems(spec=spec, impls={"scalar": abs}, expect_fail={"scalar.okk"})
    assert (
        p == "expect_fail: 'scalar.okk' is not a clause ID of spec conv; did you mean 'scalar.ok'?"
    )
    (p,) = problems(spec=spec, impls={"scalar": abs}, expect_fail={"scalar#typo"})
    assert p.startswith("expect_fail: 'scalar#typo' is not a clause ID")
    (p,) = problems(spec=spec, impls={"scalar": abs}, expect_fail={"nothing#type"})
    assert "is not a clause ID" in p
    (p,) = problems(spec=spec, expect_fail="scalar.ok")
    assert p == "expect_fail: scalar.ok belongs to scalar, which impls does not bind"
    (p,) = problems(spec=spec, expect_fail={"Counter.incr.grows"})
    assert p == "expect_fail: Counter.incr.grows belongs to Counter, which interfaces does not bind"
    (p,) = problems(spec=spec, expect_fail={"Counter.get#raises"})
    assert p == "expect_fail: Counter.get#raises belongs to Counter, which interfaces does not bind"
    (p,) = problems(spec=spec, impls={"scalar": abs}, expect_fail={"scalar#2"})
    assert p == "expect_fail: scalar#2 is a impl_defined clause, which never fails"
    (p,) = problems(spec=spec, impls={"opt": abs}, expect_fail={"opt#1"})
    assert "requires clause, which never fails" in p


def test_scalar_and_limit_options(spec):
    (p,) = problems(spec=spec, scalars="np")
    assert p == "scalars must be 'python' or 'numpy', got 'np'"
    assert conformance(spec, scalars="numpy").scalars == "numpy"
    (p,) = problems(spec=spec, max_examples=0)
    assert p == "max_examples must be a positive integer, got 0"
    (p,) = problems(spec=spec, exhaustive_limit=-1)
    assert "exhaustive_limit" in p
    assert conformance(spec, exhaustive_limit=0).exhaustive_limit == 0


def test_every_problem_is_reported_at_once(spec):
    with pytest.raises(ConformanceError) as e:
        conformance(
            spec,
            impls={"nope": abs},
            errors={ValueError: "Nope"},
            models={"Nope": ModelBinding()},
            expect_fail={"nope.x"},
            scalars="c",
        )
    assert len(e.value.problems) == 5
    text = str(e.value)
    assert text.startswith("conformance for spec conv: 5 problem(s)\n  - ")
    assert isinstance(e.value, ValueError)


# ---------------------------------------------------------------------------
# Spec paths


MINI = "spec mini\n\nfn f(x: i64) -> i64\n  ensures pos: result == x\n"


def test_relative_spec_path_resolves_against_the_calling_file(tmp_path, monkeypatch):
    pkg = tmp_path / "pkg"
    pkg.mkdir()
    (pkg / "mini.spec").write_text(MINI)
    (pkg / "test_mod.py").write_text(
        "import spectest\n"
        "spec = spectest.load('mini.spec')\n"
        "test_it = spectest.conformance('mini.spec', impls={'f': abs})\n"
    )
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)
    ns = runpy.run_path(str(pkg / "test_mod.py"))
    conf = ns["test_it"]
    assert conf.spec.name == "mini" and ns["spec"].name == "mini"
    assert Path(conf.spec.path) == (pkg / "mini.spec").resolve()
    assert conf.path == str((pkg / "test_mod.py").resolve())


def test_relative_spec_path_falls_back_to_the_working_directory(tmp_path, monkeypatch):
    (tmp_path / "cwd_only.spec").write_text(MINI)
    monkeypatch.chdir(tmp_path)
    assert conformance("cwd_only.spec").spec.name == "mini"
    assert spectest.load("cwd_only.spec").name == "mini"


def test_missing_spec_lists_where_it_looked(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    with pytest.raises(FileNotFoundError) as e:
        conformance("missing.spec")
    msg = str(e.value)
    assert "missing.spec" in msg and str(Path(__file__).parent) in msg and str(tmp_path) in msg


def test_absolute_spec_path(tmp_path):
    p = tmp_path / "abs.spec"
    p.write_text(MINI)
    assert conformance(str(p)).spec.name == "mini"
    assert conformance(p).spec.name == "mini"


def test_spec_errors_propagate(tmp_path):
    p = tmp_path / "bad.spec"
    p.write_text("spec bad\n\nfn f(x: i64) -> i64\n  ensures result == y\n")
    with pytest.raises(spectest.lang.SpecCheckError):
        conformance(str(p))


def test_example_specs_bind():
    root = Path(__file__).resolve().parents[2] / "examples"
    conf = conformance(
        root / "sorting" / "sorting.spec",
        impls={"sort": sorted, "sort_by_first": sorted, "sort_in_place": list.sort},
        models={
            "MutableList": ModelBinding(observers={"items": list}, concretize=lambda f: f["items"])
        },
        instantiate=[{"T": "i64"}, {"T": "string"}, {"K": "i64", "V": "string"}],
    )
    assert conf.instantiations("sort_in_place") == [{"T": I64}, {"T": STRING}]


# ---------------------------------------------------------------------------
# Handles


class BoxObj:
    def __init__(self, items, label="box", weight=1.0):
        self.items = list(items)
        self.label = label
        self._weight = weight

    def weight(self):
        return self._weight

    def at(self, i):
        return self.items[i] if i < len(self.items) else None


def box_binding(**overrides) -> ModelBinding:
    kwargs = {
        "observers": {"items": lambda b: b.items},
        "concretize": lambda f: BoxObj(f["items"], f["label"], f["weight"]),
    }
    kwargs.update(overrides)
    return ModelBinding(**kwargs)


def test_concretize_converts_fields_to_python(spec):
    seen = {}

    def build(f):
        seen.update(f)
        return BoxObj(f["items"], f["label"], f["weight"])

    conf = Conformance(spec=spec, models={"Box": ModelBinding(concretize=build)})
    gm = GeneratedModel("Box", (), {"items": (1, 2), "label": "a", "weight": f64(-0.0)})
    h = concretize(gm, conf, spec)
    assert isinstance(h, Handle) and h.model == "Box" and isinstance(h.obj, BoxObj)
    assert seen["items"] == [1, 2] and type(seen["weight"]) is float
    assert math.copysign(1, seen["weight"]) == -1
    nconf = Conformance(spec=spec, scalars="numpy", models={"Box": ModelBinding(concretize=build)})
    concretize(gm, nconf, spec)
    assert seen["weight"].dtype == np.float64


def test_concretize_failures(spec):
    gm = GeneratedModel("Box", (), {"items": (), "label": "", "weight": f64(1.0)})

    def unrepresentable(f):
        raise Unrepresentable("no empty boxes")

    conf = Conformance(spec=spec, models={"Box": ModelBinding(concretize=unrepresentable)})
    with pytest.raises(Unrepresentable):
        concretize(gm, conf, spec)
    conf = Conformance(spec=spec, models={"Box": ModelBinding(concretize=lambda f: 1 / 0)})
    with pytest.raises(BindingError, match="concretize for model Box raised ZeroDivisionError"):
        concretize(gm, conf, spec)
    conf = Conformance(spec=spec, models={"Box": ModelBinding(concretize=lambda f: None)})
    with pytest.raises(BindingError, match="returned None"):
        concretize(gm, conf, spec)
    with pytest.raises(BindingError, match="no concretize binding"):
        concretize(gm, Conformance(spec=spec), spec)
    conf = Conformance(spec=spec, models={"Box": box_binding()})
    with pytest.raises(BindingError, match="no field size"):
        concretize(GeneratedModel("Box", (), {"size": 1}), conf, spec)


def test_concretize_checks_that_the_object_observes_as_generated(spec):
    gm = GeneratedModel("Box", (), {"items": (1, 2), "label": "a", "weight": f64(-0.0)})
    conf = Conformance(spec=spec, models={"Box": box_binding()})
    assert concretize(gm, conf, spec).obj.items == [1, 2]
    positive = box_binding(concretize=lambda f: BoxObj(f["items"], f["label"], abs(f["weight"])))
    conf = Conformance(spec=spec, models={"Box": positive})
    with pytest.raises(BindingError) as e:
        concretize(gm, conf, spec)
    assert str(e.value) == (
        "concretize for model Box built an object that observes as "
        'Box { items: [1, 2], label: "a", weight: 0.0 (0x0000000000000000) }, not as the generated '
        'Box { items: [1, 2], label: "a", weight: -0.0 (0x8000000000000000) } (fields that '
        "differ: weight); a binding that cannot keep every field exactly declares "
        "ModelBinding(lossy=True)"
    )
    lossy = Conformance(spec=spec, models={"Box": box_binding(**{**vars(positive), "lossy": True})})
    assert floats.signbit(observe(concretize(gm, lossy, spec), "weight", (), lossy, spec)) is False
    refusing = Conformance(spec=spec, models={"Box": box_binding(accepts=lambda o: False)})
    with pytest.raises(BindingError, match="built an object it refuses"):
        concretize(gm, refusing, spec)


def test_concretize_compares_nested_models_by_their_fields(spec):
    source = SOURCE + "model Shelf\n  observe boxes: list<Bag<i64>>\n"
    nested_spec = load_source(source, "nested.spec")
    shelf = ModelBinding(observers={"boxes": lambda s: s}, concretize=lambda f: list(f["boxes"]))
    conf = Conformance(spec=nested_spec, models={"Bag": BAG, "Shelf": shelf})
    gm = GeneratedModel("Shelf", (), {"boxes": (GeneratedModel("Bag", (I64,), {"items": (1,)}),)})
    assert concretize(gm, conf, nested_spec).obj == [[1]]
    copies = ModelBinding(
        observers={"boxes": lambda s: [list(b) for b in s]}, concretize=lambda f: list(f["boxes"])
    )
    conf = Conformance(spec=nested_spec, models={"Bag": BAG, "Shelf": copies})
    assert concretize(gm, conf, nested_spec).obj == [[1]]
    dropped = ModelBinding(observers={"boxes": lambda s: [[]]}, concretize=lambda f: [])
    conf = Conformance(spec=nested_spec, models={"Bag": BAG, "Shelf": dropped})
    with pytest.raises(BindingError, match="fields that differ: boxes"):
        concretize(gm, conf, nested_spec)


def test_a_polars_frame_built_from_a_list_of_series_is_caught():
    # examples/frames: pl.DataFrame([pl.Series("", ...)]) names the column "column_0", so
    # the frame is not the generated input. The round trip reports it as a binding error.
    pl = pytest.importorskip("polars")
    frames = load_source(
        "spec frames\nmodel Frame\n  observe columns: list<string>\n"
        "  observe rows: list<list<option<f64>>>\n  observe nrows: u64\n",
        "frames.spec",
    )

    def from_series(fields):
        rows = fields["rows"]
        columns = [
            pl.Series(n, [r[j] for r in rows], dtype=pl.Float64)
            for j, n in enumerate(fields["columns"])
        ]
        return pl.DataFrame(columns)

    observers = {
        "columns": lambda df: df.columns,
        "rows": lambda df: [list(r) for r in df.rows()],
        "nrows": lambda df: df.height,
    }
    binding = ModelBinding(observers=observers, concretize=from_series)
    conf = Conformance(spec=frames, models={"Frame": binding})
    row = (None, Some(f64(1.0)))
    gm = GeneratedModel("Frame", (), {"columns": ("", "a"), "rows": (row,), "nrows": 1})
    with pytest.raises(BindingError) as e:
        concretize(gm, conf, frames)
    assert 'observes as Frame { columns: ["column_0", "a"]' in str(e.value)
    assert 'not as the generated Frame { columns: ["", "a"]' in str(e.value)
    assert "(fields that differ: columns)" in str(e.value)
    named = GeneratedModel("Frame", (), {"columns": ("b", "a"), "rows": (row,), "nrows": 1})
    assert concretize(named, conf, frames).obj.columns == ["b", "a"]


BAG = ModelBinding(observers={"items": list}, concretize=lambda f: list(f["items"]))


def test_concretize_generic_model_records_type_arguments(spec):
    conf = Conformance(spec=spec, models={"Bag": BAG})
    h = concretize(GeneratedModel("Bag", (F64,), {"items": (f64(0.5),)}), conf, spec)
    assert h.obj == [0.5] and h.targs == (F64,)
    assert observe(h, "items", (), conf, spec) == (f64(0.5),)


def test_concretize_value_replaces_nested_models(spec):
    conf = Conformance(spec=spec, models={"Bag": BAG})
    gm = GeneratedModel("Bag", (I64,), {"items": (1,)})
    out = concretize_value((gm, gm), ListT(ModelT("Bag", (I64,))), conf, spec)
    assert all(isinstance(h, Handle) for h in out) and out[0] is not out[1]
    assert concretize_value(Some(gm), OptionT(ModelT("Bag", (I64,))), conf).value.obj == [1]
    assert concretize_value((1, 2), ListT(I64), conf) == (1, 2)


def test_observe_through_bindings_and_fallbacks(spec):
    conf = Conformance(spec=spec, models={"Box": box_binding()})
    h = Handle(BoxObj([3, 4], "lbl", 2.5), "Box")
    assert observe(h, "items", (), conf, spec) == (3, 4)
    assert observe(h, "label", (), conf, spec) == "lbl"
    assert observe(h, "weight", (), conf, spec) == f64(2.5)
    assert observe(h, "at", (1,), conf, spec) == Some(4)
    assert observe(h, "at", (5,), conf, spec) is None
    assert fields(h, conf, spec) == {"items": (3, 4), "label": "lbl", "weight": f64(2.5)}
    plain = Conformance(spec=spec)
    assert observe(h, "items", (), plain) == (3, 4)


def test_observe_failures_are_binding_errors(spec):
    conf = Conformance(
        spec=spec, models={"Box": box_binding(observers={"items": lambda b: b.nope})}
    )
    h = Handle(BoxObj([1]), "Box")
    with pytest.raises(BindingError, match="observer Box.items raised AttributeError"):
        observe(h, "items", (), conf, spec)
    conf = Conformance(spec=spec, models={"Box": box_binding(observers={"items": lambda b: ["x"]})})
    with pytest.raises(BindingError) as e:
        observe(h, "items", (), conf, spec)
    assert "observer Box.items returned a value that is not list<i64>" in str(e.value)
    assert "at [0]: expected i64, got str 'x'" in str(e.value)
    assert isinstance(e.value.__cause__, TypeMismatch)
    with pytest.raises(BindingError, match="has no attribute 'label'"):
        observe(Handle(object(), "Box"), "label", (), Conformance(spec=spec), spec)
    with pytest.raises(BindingError, match="is not an observer"):
        observe(h, "size", (), conf, spec)
    with pytest.raises(BindingError, match="takes 1 argument"):
        observe(h, "at", (), conf, spec)


def test_an_observer_refusing_the_object_raises_value_refused(spec):
    def items(b):
        if not isinstance(b, BoxObj):
            raise NotAValue(f"a {type(b).__name__} is not a box")
        return b.items

    conf = Conformance(spec=spec, models={"Box": box_binding(observers={"items": items})})
    h = Handle(["x"], "Box")
    with pytest.raises(ValueRefused) as e:
        observe(h, "items", (), conf, spec)
    assert str(e.value) == "observer Box.items says the object is not a Box: a list is not a box"
    assert e.value.handle is h and isinstance(e.value, BindingError)
    assert observe(Handle(BoxObj([1]), "Box"), "items", (), conf, spec) == (1,)


def test_accepts_decides_what_reads_as_a_model(spec):
    def accepts(obj):
        if isinstance(obj, list):
            raise NotAValue("a list is not a box")
        return isinstance(obj, BoxObj)

    conf = Conformance(spec=spec, models={"Box": box_binding(accepts=accepts)})
    t = ModelT("Box")
    assert from_python(BoxObj([1]), t, conf).obj.items == [1]
    with pytest.raises(TypeMismatch, match="refuses this dict as a Box: models\\['Box'\\].accepts"):
        from_python({}, t, conf)
    with pytest.raises(TypeMismatch, match="refuses this list as a Box: a list is not a box"):
        from_python([], t, conf)
    with pytest.raises(TypeMismatch, match=r"at \[1\]: the binding refuses this int"):
        from_python([BoxObj([]), 5], ListT(t), conf)
    assert from_python({}, t, Conformance(spec=spec)).obj == {}
    broken = Conformance(spec=spec, models={"Box": box_binding(accepts=lambda o: 1 / 0)})
    with pytest.raises(BindingError, match="accepts for model Box raised ZeroDivisionError"):
        from_python(BoxObj([]), t, broken)


def test_observe_generic_model_without_type_arguments(spec):
    conf = Conformance(spec=spec, models={"Bag": BAG})
    with pytest.raises(BindingError, match="not instantiated"):
        observe(Handle([1], "Bag"), "items", (), conf, spec)
    assert observe(Handle([1], "Bag", targs=(I64,)), "items", (), conf) == (1,)


def test_interface_observers(spec):
    class Ctr:
        def __init__(self):
            self.n = 0

        def value(self):
            return self.n

    conf = Conformance(
        spec=spec,
        interfaces={
            "Counter": InterfaceBinding(
                constructors={"zero": Ctr}, observers={"value": lambda c: c.n * 2}
            )
        },
    )
    c = Ctr()
    c.n = 2
    assert observe(Handle(c, "Counter"), "value", (), conf, spec) == 4
    assert observe(Handle(c, "Counter"), "value", (), Conformance(spec=spec), spec) == 2
    assert binding.constructor(conf, "Counter", "zero") is Ctr
    assert binding.constructor(conf, "Counter", "one") is None
    incr = binding.method(conf, "Counter", "incr")
    with pytest.raises(BindingError, match="method Counter.incr has no binding"):
        incr(c, 1)


def test_digest_default_is_exact(spec):
    conf = Conformance(spec=spec, models={"Box": box_binding()})
    a = Handle(BoxObj([1], "x", 0.0), "Box")
    b = Handle(BoxObj([1], "x", 0.0), "Box")
    c = Handle(BoxObj([1], "x", -0.0), "Box")
    d1 = digest(a, conf, spec)
    hash(d1)
    assert d1 == digest(b, conf, spec)
    assert d1 != digest(c, conf, spec)
    a.obj.items.append(2)
    assert digest(a, conf, spec) != d1
    nan = struct.unpack("<d", struct.pack("<Q", 0x7FF8000000000001))[0]
    n1, n2 = Handle(BoxObj([], "", nan), "Box"), Handle(BoxObj([], "", nan), "Box")
    assert digest(n1, conf, spec) == digest(n2, conf, spec)


def test_digest_from_binding(spec):
    conf = Conformance(spec=spec, models={"Box": box_binding(digest=lambda b: tuple(b.items))})
    assert digest(Handle(BoxObj([1, 2]), "Box"), conf, spec) == (1, 2)
    conf = Conformance(spec=spec, models={"Box": box_binding(digest=lambda b: b.items)})
    with pytest.raises(BindingError, match="digest for Box failed: TypeError"):
        digest(Handle(BoxObj([1, 2]), "Box"), conf, spec)


def test_map_exception_first_match_in_order(spec):
    conf = Conformance(
        spec=spec, errors={KeyError: "Oops", LookupError: "Boom", (ValueError, TypeError): "Boom"}
    )
    assert map_exception(KeyError("k"), conf) == "Oops"
    assert map_exception(IndexError(1), conf) == "Boom"
    assert map_exception(TypeError(), conf) == "Boom"
    assert map_exception(ZeroDivisionError(), conf) is None
    conf2 = Conformance(spec=spec, errors={LookupError: "Boom", KeyError: "Oops"})
    assert map_exception(KeyError("k"), conf2) == "Boom"


def test_shares_memory(spec):
    conf = Conformance(
        spec=spec, models={"Box": box_binding(shares_memory=lambda a, b: a.items is b.items)}
    )
    x = BoxObj([1])
    y = BoxObj([])
    y.items = x.items
    assert shares_memory(Handle(x, "Box"), Handle(y, "Box"), conf) is True
    arr = np.arange(4)
    plain = Conformance(spec=spec)
    assert shares_memory(Handle(arr, "Bag"), Handle(arr[1:], "Bag"), plain) is True
    assert shares_memory(Handle(arr, "Bag"), Handle(arr.copy(), "Bag"), plain) is False
    with pytest.raises(BindingError, match="no shares_memory binding"):
        shares_memory(Handle(x, "Box"), Handle(y, "Box"), plain)


def test_call_arguments(spec):
    conf = Conformance(spec=spec)
    args, kwargs = call_arguments(["x", "how"], [I64, LiteralT(("any", "all"))], [3, "all"], conf)
    assert args == [3, "all"] and kwargs == {}
    if DEFAULT is None:
        pytest.skip("spectest.generate is not available")
    args, kwargs = call_arguments(["x", "how"], [I64, LiteralT(("any", "all"))], [3, DEFAULT], conf)
    assert args == [3] and kwargs == {}
    args, kwargs = call_arguments(["a", "b", "c"], [I64, I64, I64], [1, DEFAULT, 3], conf)
    assert args == [1] and kwargs == {"c": 3}


def test_impl_lookup(spec):
    conf = conformance(spec, impls={"scalar": abs})
    assert binding.impl(conf, "scalar") is abs
    assert binding.impl(conf, "sort") is None


def test_public_package_exports():
    assert spectest.__version__ == metadata.version("spectest")
    assert spectest.conformance is conformance
    assert spectest.ModelBinding is ModelBinding and spectest.InterfaceBinding is InterfaceBinding
    assert spectest.Conformance is Conformance and spectest.Unrepresentable is Unrepresentable
    assert spectest.NotAValue is NotAValue
    assert callable(spectest.load)
    with pytest.raises(AttributeError):
        spectest.nope  # noqa: B018
    assert {"load", "conformance"} <= set(dir(spectest))


def test_importing_spectest_stays_light():
    import subprocess
    import sys

    code = (
        "import sys, spectest\n"
        "heavy = [m for m in ('numpy', 'pandas', 'hypothesis', 'spectest.lang') if m in sys.modules]\n"
        "print(','.join(heavy))\n"
    )
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
    assert out.stdout.strip() == ""


def test_qerr_conversions():
    from spectest import types as spec_types
    from spectest import values as spec_values

    if not hasattr(spec_values, "QError") or not hasattr(spec_types, "QErrT"):
        pytest.skip("the contract does not define qerr yet")
    t = spec_types.QErrT()
    q = spec_values.QError(2, 1)
    assert from_python(q, t) is q and to_python(q, t) is q
    assert from_python(4, t) == spec_values.QError(4, 0)
    with pytest.raises(TypeMismatch):
        from_python(-1, t)
    with pytest.raises(TypeMismatch):
        from_python(1.5, t)
