"""Exact JSON encoding of spec values and the counterexample store."""

from __future__ import annotations

import json
import sys
import types
from dataclasses import dataclass
from fractions import Fraction

import pytest
from hypothesis import given
from hypothesis import strategies as st

from spectest.lang import load_source
from spectest.runtime import store
from spectest.runtime.store import (
    CounterexampleStore,
    DecodeError,
    canonical_json,
    decode_value,
    encode_value,
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
)
from spectest.values import (
    NEG_INF,
    POS_INF,
    FloatValue,
    Handle,
    MapValue,
    RecordValue,
    Some,
)

I32, I64, U8 = FixedIntT(32, True), FixedIntT(64, True), FixedIntT(8, False)
F16, F32, F64 = FloatT("f16"), FloatT("f32"), FloatT("f64")
POINT = RecordT("Point", (("x", I32), ("y", F64)))


def generate_or_fake():
    """spectest.generate's DEFAULT and GeneratedModel, or stand-ins while it is missing."""
    real = store.generate_module()
    if real is not None and hasattr(real, "GeneratedModel") and hasattr(real, "DEFAULT"):
        return real
    return None


@pytest.fixture
def gen(monkeypatch):
    real = generate_or_fake()
    if real is not None:
        yield real
        return
    fake = types.ModuleType("spectest.generate")

    @dataclass(eq=False)
    class GeneratedModel:
        model: str
        targs: tuple
        fields: dict

    fake.GeneratedModel = GeneratedModel
    fake.DEFAULT = object()
    monkeypatch.setitem(sys.modules, "spectest.generate", fake)
    store.generate_module.cache_clear()
    yield fake
    store.generate_module.cache_clear()


def rt(v, t=None):
    """Encode, go through JSON text, decode."""
    text = json.dumps(encode_value(v, t))
    return decode_value(json.loads(text), t)


CASES = [
    (True, BOOL),
    (False, BOOL),
    (0, INT),
    (-(10**40), INT),
    (2**63 - 1, I64),
    (255, U8),
    (FloatValue("f64", 0x8000000000000000), F64),
    (FloatValue("f64", 0x7FF0000000000001), F64),
    (FloatValue("f64", 0xFFF8000000000123), F64),
    (FloatValue("f32", 0x7F800001), F32),
    (FloatValue("f16", 0x7E01), F16),
    (FloatValue("bf16", 0xFF81), FloatT("bf16")),
    (Fraction(1, 3), REAL),
    (Fraction(-7), REAL),
    (POS_INF, REAL),
    (NEG_INF, REAL),
    ('héllo "wörld"\n\x00', STRING),
    (b"\x00\xff\x10", BYTES),
    (b"", BYTES),
    ((1, 2, 3), ListT(I64)),
    ((), ListT(STRING)),
    ((1, "a"), TupleT((I64, STRING))),
    (None, OptionT(I64)),
    (Some(5), OptionT(I64)),
    (Some(None), OptionT(OptionT(I64))),
    (Some(Some(1)), OptionT(OptionT(I64))),
    ((None, Some(FloatValue("f64", 0x7FF8000000000000))), ListT(OptionT(F64))),
    ("all", LiteralT(("any", "all"))),
    ("Red", EnumT("Color", ("Red", "Green"))),
    (RecordValue("Point", (("x", 1), ("y", FloatValue("f64", 0)))), POINT),
    (MapValue((("b", 2), ("a", 1))), MapT(STRING, I64)),
    (MapValue((((1, 2), Some(b"x")),)), MapT(ListT(I64), OptionT(BYTES))),
    (None, UNIT),
]


@pytest.mark.parametrize(("v", "t"), CASES, ids=[str(t) for _, t in CASES])
def test_round_trip_every_value_kind(v, t):
    assert rt(v, t) == v
    assert rt(v) == v
    back = rt(v, t)
    assert type(back) is type(v)


def test_round_trip_keeps_types_apart():
    assert rt(1) == 1 and type(rt(1)) is int
    assert rt(True) is True
    assert rt(Fraction(1)) == Fraction(1) and type(rt(Fraction(1))) is Fraction
    assert rt(None) is None and rt(Some(None)) == Some(None)
    assert rt("ab") == "ab" and rt(b"ab") == b"ab"
    assert rt([1, 2]) == (1, 2)


def test_encoding_shape():
    assert encode_value(FloatValue("f64", 0x8000000000000000)) == {
        "$float": "f64:0x8000000000000000"
    }
    assert encode_value(FloatValue("f16", 1)) == {"$float": "f16:0x0001"}
    assert encode_value(Fraction(-1, 3)) == {"$real": "-1/3"}
    assert encode_value(POS_INF) == {"$real": "inf"}
    assert encode_value(b"\x01") == {"$bytes": "01"}
    assert encode_value(Some(None)) == {"$some": None}
    assert encode_value((1, (2,))) == [1, [2]]
    assert encode_value(MapValue((("a", 1),))) == {"$map": [["a", 1]]}
    rec = encode_value(RecordValue("P", (("x", 1),)))
    assert rec == {"$record": "P", "fields": [["x", 1]]}
    assert encode_value({"steps": (1,)}) == {"$dict": [["steps", [1]]]}
    assert decode_value({"$dict": [["steps", [1]]]}) == {"steps": (1,)}


@given(st.integers(0, 2**64 - 1))
def test_every_f64_bit_pattern_round_trips(bits):
    v = FloatValue("f64", bits)
    assert rt(v, F64) == v


def test_canonical_maps_ignore_order():
    a = MapValue((("a", 1), ("b", 2)))
    b = MapValue((("b", 2), ("a", 1)))
    assert canonical_json(encode_value(a, canonical=True)) == canonical_json(
        encode_value(b, canonical=True)
    )
    assert encode_value(a) != encode_value(b)


def test_handles_need_an_encoder():
    h = Handle(object(), "Frame")
    with pytest.raises(ValueError, match="handles live in the implementation"):
        encode_value(h)
    assert encode_value((h,), handle=lambda x: {"$handle": x.model}) == [{"$handle": "Frame"}]


def test_unencodable_values():
    for bad in (1.5, object(), {1, 2}):
        with pytest.raises(ValueError, match="cannot encode"):
            encode_value(bad)


def test_type_mismatches_are_rejected():
    with pytest.raises(ValueError, match="is not a value of type f32"):
        encode_value(FloatValue("f64", 0), F32)
    with pytest.raises(ValueError, match="is not a value of type u8"):
        decode_value(300, U8)
    with pytest.raises(ValueError, match=r"at \[1\]"):
        decode_value([1, "x"], ListT(I64))
    with pytest.raises(ValueError):
        decode_value(1, BOOL)
    with pytest.raises(ValueError):
        decode_value({"$record": "Q", "fields": []}, POINT)


@pytest.mark.parametrize(
    "bad",
    [
        {},
        {"$nope": 1},
        {"$float": "f65:0x0"},
        {"$float": 3},
        {"$real": "x"},
        {"$bytes": "zz"},
        {"$map": [[1]]},
        1.5,
    ],
)
def test_malformed_encodings(bad):
    with pytest.raises(ValueError):
        decode_value(bad)


def test_decode_error_is_a_value_error():
    with pytest.raises(DecodeError):
        decode_value({"$float": 3})


def test_generated_models_and_default(gen):
    t = ModelT("Bag", (I64,))
    gm = gen.GeneratedModel("Bag", (I64,), {"items": (1, 2), "w": FloatValue("f32", 0x80000000)})
    enc = encode_value(gm, t)
    assert enc == {
        "$model": "Bag",
        "targs": ["i64"],
        "fields": {"items": [1, 2], "w": {"$float": "f32:0x80000000"}},
    }
    back = decode_value(json.loads(json.dumps(enc)), t)
    assert isinstance(back, gen.GeneratedModel)
    assert back.model == "Bag" and back.targs == (I64,) and back.fields == gm.fields
    untyped = decode_value(enc)
    assert untyped.targs == (I64,)
    assert encode_value(gen.DEFAULT) == {"$default": True}
    assert decode_value({"$default": True}) is gen.DEFAULT
    assert rt((gen.DEFAULT, 1)) == (gen.DEFAULT, 1)
    with pytest.raises(ValueError, match="type argument i64 is not string"):
        decode_value(enc, ModelT("Bag", (STRING,)))


def test_generated_model_targs_resolve_through_the_spec(gen):
    spec = load_source("spec s\nrecord P { x: i64 }\nmodel Bag<T>\n  observe items: list<T>\n")
    gm = gen.GeneratedModel("Bag", (spec.records["P"],), {"items": ()})
    enc = encode_value(gm)
    assert enc["targs"] == ["P"]
    with pytest.raises(ValueError, match="without a spec"):
        decode_value(enc)
    assert decode_value(enc, spec=spec).targs == (spec.records["P"],)


# ---------------------------------------------------------------------------
# CounterexampleStore


HASH = "ab" * 32


def test_store_round_trip(tmp_path):
    s = CounterexampleStore(tmp_path / ".spectest")
    assert s.load(HASH, "test_x.py::test_m::cos.accurate") == []
    inputs = {"x": FloatValue("f64", 0x8000000000000000), "how": "any"}
    assert s.save(HASH, "test_x.py::test_m::cos.accurate", inputs) is True
    assert s.load(HASH, "test_x.py::test_m::cos.accurate") == [inputs]
    path = s.path(HASH, "test_x.py::test_m::cos.accurate")
    assert path.is_file() and path.parent.name == HASH[:16]
    data = json.loads(path.read_text())
    assert data["spec_hash"] == HASH and data["item_id"] == "test_x.py::test_m::cos.accurate"
    assert data["examples"] == [
        {"inputs": {"x": {"$float": "f64:0x8000000000000000"}, "how": "any"}}
    ]


def test_store_newest_first_and_deduplicated(tmp_path):
    s = CounterexampleStore(tmp_path)
    for i in range(3):
        s.save(HASH, "item", {"x": i})
    assert [e["x"] for e in s.load(HASH, "item")] == [2, 1, 0]
    assert s.save(HASH, "item", {"x": 2}) is False
    assert s.save(HASH, "item", {"x": 0}) is False
    assert [e["x"] for e in s.load(HASH, "item")] == [0, 2, 1]


def test_store_keeps_at_most_50(tmp_path):
    s = CounterexampleStore(tmp_path)
    for i in range(60):
        s.save(HASH, "item", {"x": i})
    got = s.load(HASH, "item")
    assert len(got) == 50 and got[0] == {"x": 59} and got[-1] == {"x": 10}
    small = CounterexampleStore(tmp_path / "small", max_entries=2)
    for i in range(5):
        small.save(HASH, "item", {"x": i})
    assert small.load(HASH, "item") == [{"x": 4}, {"x": 3}]


def test_store_keys_by_spec_hash_and_item(tmp_path):
    s = CounterexampleStore(tmp_path)
    s.save(HASH, "a", {"x": 1})
    s.save(HASH, "b", {"x": 2})
    s.save("cd" * 32, "a", {"x": 3})
    assert s.load(HASH, "a") == [{"x": 1}]
    assert s.load(HASH, "b") == [{"x": 2}]
    assert s.load("cd" * 32, "a") == [{"x": 3}]
    assert s.path(HASH, "a/b::c[T=i64]").name.startswith("a_b_c_T_i64-")
    assert s.path(HASH, "a/b") != s.path(HASH, "a_b")


def test_store_ignores_corrupt_and_foreign_files(tmp_path):
    s = CounterexampleStore(tmp_path)
    p = s.path(HASH, "item")
    p.parent.mkdir(parents=True)
    p.write_text("{not json")
    assert s.load(HASH, "item") == []
    p.write_text(
        json.dumps({"spec_hash": "other", "item_id": "item", "examples": [{"inputs": {}}]})
    )
    assert s.load(HASH, "item") == []
    s.save(HASH, "item", {"x": 1})
    assert s.load(HASH, "item") == [{"x": 1}]


def test_store_drops_entries_that_no_longer_decode(tmp_path):
    s = CounterexampleStore(tmp_path)
    s.save(HASH, "item", {"x": 1})
    s.save(HASH, "item", {"x": "s"})
    data = json.loads(s.path(HASH, "item").read_text())
    data["examples"].append({"inputs": {"x": {"$float": "nope"}}})
    s.path(HASH, "item").write_text(json.dumps(data))
    assert s.load(HASH, "item") == [{"x": "s"}, {"x": 1}]
    assert s.load(HASH, "item", {"x": I64}) == [{"x": 1}]


def test_store_typed_save_checks_values(tmp_path):
    s = CounterexampleStore(tmp_path)
    with pytest.raises(ValueError):
        s.save(HASH, "item", {"x": "s"}, {"x": I64})
    assert s.save(HASH, "item", {"x": 3}, {"x": I64})


def test_store_clear(tmp_path):
    s = CounterexampleStore(tmp_path)
    s.save(HASH, "a", {"x": 1})
    s.save(HASH, "b", {"x": 1})
    s.save("cd" * 32, "a", {"x": 1})
    s.clear(HASH, "a")
    assert s.load(HASH, "a") == [] and s.load(HASH, "b") != []
    s.clear(HASH)
    assert s.load(HASH, "b") == [] and s.load("cd" * 32, "a") != []
    s.clear()
    assert s.load("cd" * 32, "a") == []
    assert "CounterexampleStore" in repr(s)


def test_store_default_root_is_relative(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    s = CounterexampleStore()
    s.save(HASH, "item", {"x": 1})
    assert (tmp_path / ".spectest" / "counterexamples").is_dir()


def test_qerr_values_round_trip():
    from spectest import types as spec_types
    from spectest import values as spec_values

    if not hasattr(spec_values, "QError") or not hasattr(spec_types, "QErrT"):
        pytest.skip("the contract does not define qerr yet")
    q = spec_values.QError(3, 1)
    t = spec_types.QErrT()
    assert encode_value(q, t) == {"$qerr": [3, 1]}
    assert rt(q, t) == q and rt((q,)) == (q,)
    with pytest.raises(ValueError):
        decode_value(3, t)
