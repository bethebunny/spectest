from collections import Counter
from fractions import Fraction

import pytest
from budget import budget
from hypothesis import find, given
from hypothesis import strategies as st

from spectest import sets
from spectest.generate import (
    DEFAULT,
    GenerateError,
    Sizes,
    fixed_strategy,
    strategy,
)
from spectest.lang import load_source
from spectest.prelude import floats
from spectest.prelude.collections import valid_utf8
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
from spectest.values import FloatValue, MapValue, RecordValue, Some

from .sampling import FAST, QUIET, draws, sample
from .validate import conforms, problems

F16, BF16, F32, F64 = FloatT("f16"), FloatT("bf16"), FloatT("f32"), FloatT("f64")
I8, I32, I64 = FixedIntT(8, True), FixedIntT(32, True), FixedIntT(64, True)
U8, U16, U64 = FixedIntT(8, False), FixedIntT(16, False), FixedIntT(64, False)

SPEC = load_source(
    """spec shapes

enum Color { Red, Green, Blue }
record Point { x: i32, y: f64, tag: option<string> }
type Grid = list<list<u8>>
"""
)
COLOR, POINT = SPEC.enums["Color"], SPEC.records["Point"]

TYPES = [
    BOOL,
    INT,
    REAL,
    STRING,
    BYTES,
    UNIT,
    I8,
    I32,
    I64,
    U8,
    U16,
    U64,
    F16,
    BF16,
    F32,
    F64,
    ListT(I64),
    ListT(ListT(STRING)),
    ListT(OptionT(F64)),
    TupleT((I32, STRING, BOOL)),
    TupleT((ListT(F32), OptionT(BYTES))),
    OptionT(I64),
    OptionT(OptionT(BOOL)),
    MapT(STRING, I64),
    MapT(I8, ListT(F16)),
    MapT(TupleT((I64, STRING)), BOOL),
    LiteralT(("any", "all")),
    COLOR,
    POINT,
    ListT(POINT),
    SPEC.aliases["Grid"],
]


def is_special(v: FloatValue) -> bool:
    return floats.is_nan(v) or floats.is_inf(v) or floats.is_zero(v) or floats.is_subnormal(v)


@pytest.mark.slow
@pytest.mark.parametrize("t", TYPES, ids=str)
def test_values_have_the_runtime_representation_of_their_type(t):
    @FAST
    @given(strategy(t, SPEC))
    def check(v):
        assert not problems(v, t, SPEC)

    check()


def test_the_validator_rejects_wrong_representations():
    assert not conforms([1, 2], ListT(I64))
    assert not conforms((1, 300), ListT(U8))
    assert not conforms(1.5, F64)
    assert not conforms(FloatValue("f32", 0), F64)
    assert not conforms(True, I64)
    assert not conforms(1, BOOL)
    assert not conforms("\ud800", STRING)
    assert not conforms(Some(1), OptionT(STRING))
    assert not conforms(MapValue(((1, True), (1, False))), MapT(I64, BOOL))
    assert not conforms("Purple", COLOR)
    assert not conforms(RecordValue("Point", (("x", 1),)), POINT)
    assert conforms(MapValue(((1, True), (2, False))), MapT(I64, BOOL))
    assert conforms(None, OptionT(STRING))


# -- integers ------------------------------------------------------------------------


def test_unbounded_ints_are_mostly_small_and_sometimes_huge():
    values = sample(strategy(INT), 800)
    assert sum(abs(v) < 1 << 16 for v in values) > len(values) / 2
    assert any(abs(v) >= 1 << 64 for v in values)
    assert any(abs(v) >= 1 << 100 for v in values)
    assert any(v < 0 for v in values) and any(v > 0 for v in values)


def test_ints_include_values_near_big_powers_of_two():
    values = set(sample(strategy(INT), budget(1200, 150)))
    near = {s * ((1 << k) + d) for k in (63, 64, 100) for d in (-1, 0, 1) for s in (1, -1)}
    assert values & near


@pytest.mark.parametrize("t", [I8, I32, I64, U8, U64], ids=str)
def test_fixed_ints_emphasize_boundaries(t):
    values = sample(strategy(t), budget(640, 200))
    assert all(t.min <= v <= t.max for v in values)
    assert t.min in values and t.max in values and 0 in values
    assert {1, t.max - 1} & set(values)
    powers = {1 << k for k in range(2, t.bits - 1)}
    assert set(values) & powers
    middle = [v for v in values if 1 << 20 < abs(v) < t.max >> 2] if t.bits >= 32 else values
    assert middle, "uniform draws reach the middle of the range"


def test_fixed_int_uniform_draws_cover_the_byte_range():
    values = sample(strategy(U8), 1600)
    assert len(set(values)) > 150


# -- floats --------------------------------------------------------------------------


@pytest.mark.parametrize("t", [F16, BF16, F32, F64], ids=str)
def test_floats_draw_specials_often(t):
    values = sample(strategy(t), budget(800, 300))
    kinds = Counter(
        "nan"
        if floats.is_nan(v)
        else "inf"
        if floats.is_inf(v)
        else "zero"
        if floats.is_zero(v)
        else "subnormal"
        if floats.is_subnormal(v)
        else "normal"
        for v in values
    )
    for kind in ("nan", "inf", "zero", "subnormal", "normal"):
        assert kinds[kind] >= len(values) / 20, kinds
    assert any(floats.is_zero(v) and floats.signbit(v) for v in values), "-0.0 appears"
    assert any(floats.is_inf(v) and floats.signbit(v) for v in values), "-inf appears"
    simple = {floats.to_python_float(v) for v in values if floats.is_finite(v)}
    assert {1.0, -1.0, 0.5, 2.0} & simple
    assert sum(is_special(v) for v in values) > len(values) / 3


def test_f64_draws_ordinary_magnitudes():
    values = sample(strategy(F64), budget(800, 100))
    moderate = [
        v for v in values if floats.is_finite(v) and 1e-6 < abs(floats.to_python_float(v)) < 1e6
    ]
    assert len(moderate) > len(values) / 5


def test_float_nans_include_payloads():
    nans = {v.bits for v in sample(strategy(F64), 800) if floats.is_nan(v)}
    assert len(nans) > 3


def test_fixed_strategy_stays_inside_a_set():
    within = sets.float_range(F64, 0, 1)
    values = sample(fixed_strategy(F64, within), budget(400, 50))
    assert all(v in within for v in values)
    assert any(floats.is_zero(v) for v in values)
    assert any(floats.is_subnormal(v) for v in values)


def test_fixed_strategy_inside_an_int_set():
    within = sets.int_range(I64, -5, 1000)
    values = sample(fixed_strategy(I64, within), 400)
    assert all(-5 <= v < 1000 for v in values)
    assert {-5, -4, 998, 999, -1, 0, 1} <= set(values)
    assert {255, 256, 257, 511, 512, 513} & set(values)
    assert any(v > 100 and v not in (127, 128, 129, 255, 256, 257, 511, 512, 513) for v in values)


def test_fixed_strategy_ignores_an_empty_set():
    values = draws(fixed_strategy(U8, sets.codec_for(U8).none), budget(50, 20))
    assert all(0 <= v <= 255 for v in values)


def test_bool_strategy_inside_a_set():
    values = draws(fixed_strategy(BOOL, sets.codec_for(BOOL).set([True])), 30)
    assert set(values) == {True}


# -- text and bytes ------------------------------------------------------------------


def test_strings_respect_max_text_and_vary_in_category():
    values = draws(strategy(STRING, sizes=Sizes(max_text=5, long_share=0)), budget(600, 80))
    assert all(len(s) <= 5 for s in values)
    chars = {c for s in values for c in s}
    assert any(c.isascii() for c in chars)
    assert any(ord(c) > 0xFFFF for c in chars), "astral characters appear"
    assert any(0x80 <= ord(c) <= 0x7FF for c in chars)
    assert "" in values


def test_bytes_mix_valid_utf8_and_arbitrary():
    values = draws(strategy(BYTES, sizes=Sizes(max_bytes=10, long_share=0)), budget(600, 60))
    assert all(len(b) <= 10 for b in values)
    valid = [b for b in values if valid_utf8(b)]
    invalid = [b for b in values if not valid_utf8(b)]
    assert len(valid) > len(values) / 5 and len(invalid) > len(values) / 5
    assert any(any(x >= 0x80 for x in b) for b in valid), "multi-byte valid UTF-8 appears"


# -- collections ---------------------------------------------------------------------


def test_list_sizes_top_level_and_nested():
    sizes = Sizes(max_list=6, max_inner=2, long_share=0)
    values = draws(strategy(ListT(ListT(I64)), sizes=sizes), budget(300, 40))
    assert all(len(xs) <= 6 for xs in values)
    assert all(len(inner) <= 2 for xs in values for inner in xs)
    assert max(len(xs) for xs in values) == 6
    assert max(len(inner) for xs in values for inner in xs) == 2


@pytest.mark.slow
def test_top_level_lists_strings_and_bytes_are_sometimes_long():
    lists = sample(strategy(ListT(I64)), 3000)
    long = [xs for xs in lists if len(xs) > 8]
    assert 0.03 < len(long) / len(lists) < 0.1
    assert all(17 <= len(xs) <= 100 for xs in long)
    assert sum(len(xs) >= 64 for xs in long) > len(long) / 3
    texts = [s for s in sample(strategy(STRING), 2000) if len(s) > 12]
    assert texts and all(25 <= len(s) <= 100 for s in texts)
    blobs = [b for b in sample(strategy(BYTES), 2000) if len(b) > 16]
    assert blobs and all(33 <= len(b) <= 100 for b in blobs)


def test_nested_collections_are_never_long():
    for xs in sample(strategy(ListT(ListT(I64))), budget(1000, 20)):
        assert len(xs) <= 8 and all(len(inner) <= 4 for inner in xs)
    for pairs in sample(strategy(ListT(TupleT((STRING, BYTES)))), budget(1000, 20)):
        assert all(len(a) <= 12 and len(b) <= 16 for a, b in pairs)


def test_long_values_follow_sizes():
    sizes = Sizes(max_list=4, long_list=30, long_share=0.5)
    lengths = [len(xs) for xs in sample(strategy(ListT(I64), sizes=sizes), 400)]
    assert 0.35 < sum(n > 4 for n in lengths) / len(lengths) < 0.65
    assert all(n <= 4 or 9 <= n <= 30 for n in lengths)
    assert max(lengths) == 30
    assert Sizes(long_share=0).long_bounds("list") is None
    assert Sizes(max_list=60).long_bounds("list") is None
    assert Sizes().long_bounds("text") == (25, 100)
    assert Sizes(long_list=-1, long_share=2).problems() == [
        "long_list must be a non-negative integer, got -1",
        "long_share must be a number in [0, 1), got 2",
    ]


def test_long_values_shrink_to_the_shortest_failing_length():
    assert find(strategy(ListT(I64)), lambda xs: len(xs) > 16, settings=QUIET) == (0,) * 17
    assert find(strategy(ListT(I64)), lambda xs: len(xs) > 70, settings=QUIET) == (0,) * 71
    assert find(strategy(BYTES), lambda b: len(b) > 40, settings=QUIET) == bytes(41)
    assert find(strategy(STRING), lambda s: len(s) > 30, settings=QUIET) == "0" * 31


def test_option_is_none_about_a_fifth_of_the_time():
    values = sample(strategy(OptionT(I64)), budget(1200, 300))
    nones = sum(v is None for v in values)
    assert 0.1 < nones / len(values) < 0.35


def test_map_keys_are_distinct_even_when_floats_or_nested():
    t = MapT(F64, I8)
    for m in draws(strategy(t), budget(300, 10)):
        bits = [k.bits for k, _ in m.items]
        assert len(bits) == len(set(bits))
    t2 = MapT(MapT(I8, BOOL), I8)
    for m in draws(strategy(t2), budget(200, 10)):
        assert conforms(m, t2)


def test_maps_sometimes_have_several_entries():
    values = draws(strategy(MapT(STRING, I64)), budget(300, 30))
    assert max(len(m.items) for m in values) >= 3


def test_records_enums_and_literals():
    points = draws(strategy(POINT, SPEC), budget(200, 25))
    assert all(isinstance(p, RecordValue) and p.name == "Point" for p in points)
    colors = set(draws(strategy(COLOR, SPEC), budget(100, 20)))
    assert colors == {"Red", "Green", "Blue"}
    assert set(draws(strategy(LiteralT(("any", "all"))), budget(100, 20))) == {"any", "all"}


@pytest.mark.slow
def test_equal_values_are_common_across_one_example():
    @st.composite
    def pairs(draw):
        return draw(strategy(STRING)), draw(strategy(STRING))

    values = draws(pairs(), 400)
    assert sum(a == b and a != "" for a, b in values) > 10


def test_reals_are_fractions_or_infinities():
    for v in draws(strategy(REAL), budget(100, 20)):
        assert conforms(v, REAL)
    reals = draws(strategy(REAL), budget(200, 25))
    assert any(isinstance(v, Fraction) and v.denominator > 1 for v in reals)


# -- type variables and errors -------------------------------------------------------


def test_type_variables_come_from_tenv():
    t = ListT(TupleT((TypeVarT("K", "Ord"), TypeVarT("V", "Eq"))))
    values = draws(strategy(t, SPEC, {"K": I64, "V": STRING}), budget(100, 20))
    assert all(conforms(v, ListT(TupleT((I64, STRING)))) for v in values)


def test_tenv_accepts_type_text():
    values = draws(strategy(ListT(TypeVarT("T")), SPEC, {"T": "option<u8>"}), budget(50, 10))
    assert all(conforms(v, ListT(OptionT(U8))) for v in values)


def test_an_unbound_type_variable_is_an_error():
    with pytest.raises(GenerateError, match="type variable T is not instantiated"):
        strategy(ListT(TypeVarT("T")), SPEC)


def test_interfaces_and_unknown_models_are_errors():
    with pytest.raises(GenerateError, match="interface"):
        strategy(ModelT("Deque", (I64,), is_interface=True), SPEC)
    with pytest.raises(GenerateError, match="unknown model"):
        strategy(ModelT("Nope"), SPEC)


def test_default_sentinel():
    assert repr(DEFAULT) == "DEFAULT"
    import pickle

    assert pickle.loads(pickle.dumps(DEFAULT)) is DEFAULT


def test_enum_type_from_scratch():
    t = EnumT("E", ("A", "B"))
    assert set(draws(strategy(t), budget(50, 20))) == {"A", "B"}


def test_record_from_scratch():
    t = RecordT("R", (("a", I8), ("b", ListT(BOOL))))
    for v in draws(strategy(t), budget(50, 20)):
        assert conforms(v, t)


# -- shrinking -----------------------------------------------------------------------


@pytest.mark.slow
def test_ints_shrink_to_the_boundary():
    assert find(strategy(I64), lambda v: v < 0, settings=QUIET) == -1
    assert find(strategy(I8), lambda v: v < 0, settings=QUIET) == -1
    assert find(fixed_strategy(I32, sets.int_range(I32, -50, 50)), lambda v: v < 0, settings=QUIET) == -1
    assert find(strategy(INT), lambda v: v > 1000, settings=QUIET) == 1001
    assert find(strategy(INT), lambda v: v < -(1 << 70), settings=QUIET) == -(1 << 70) - 1
    assert find(strategy(I64), lambda v: v > 1000, settings=QUIET) == 1001
    assert find(strategy(I64), lambda v: v < -1000, settings=QUIET) == -1001
    assert find(strategy(I64), lambda v: v > I64.max - 10, settings=QUIET) == I64.max - 9
    assert find(strategy(U64), lambda v: v > 1 << 40, settings=QUIET) == (1 << 40) + 1
    assert find(strategy(I8), lambda v: v != 0, settings=QUIET) == 1
    assert find(strategy(U8), lambda v: True, settings=QUIET) == 0


def test_floats_shrink_to_simple_values():
    assert find(strategy(F64), lambda v: True, settings=QUIET) == FloatValue("f64", 0)
    nan = find(strategy(F64), floats.is_nan, settings=QUIET)
    assert nan.bits == 0x7FF8000000000000
    big = find(
        strategy(F64),
        lambda v: floats.is_finite(v) and abs(floats.to_python_float(v)) > 1,
        settings=QUIET,
    )
    assert floats.to_python_float(big) in (1.5, 2.0, -1.5, -2.0)
    huge = find(
        strategy(F64),
        lambda v: floats.is_finite(v) and floats.to_python_float(v) > 1e10,
        settings=QUIET,
    )
    assert floats.to_python_float(huge) < 1.0000001e10


def test_collections_shrink_to_small_values():
    short = Sizes(long_share=0)
    xs = find(strategy(ListT(I64), sizes=short), lambda xs: len(xs) >= 3, settings=QUIET)
    assert xs == (0, 0, 0)
    # A long list Hypothesis finds first keeps the shortest long length when its palette
    # shrinks first; spectest.shrink's pass shortens it (tests/generate/test_generate_shrink.py).
    xs = find(strategy(ListT(I64)), lambda xs: len(xs) >= 3, settings=QUIET)
    assert xs in ((0,) * 3, (0,) * 17)
    s = find(strategy(STRING), lambda s: len(s) >= 2, settings=QUIET)
    assert s == "00"
    b = find(strategy(BYTES), lambda b: len(b) >= 2, settings=QUIET)
    assert b == b"\x00\x00"
    o = find(strategy(OptionT(I64)), lambda o: True, settings=QUIET)
    assert o is None
    m = find(strategy(MapT(STRING, I64)), lambda m: len(m.items) >= 2, settings=QUIET)
    assert sorted(m.items) == [("", 0), ("0", 0)]
    p = find(strategy(POINT, SPEC), lambda p: True, settings=QUIET)
    assert p == RecordValue("Point", (("x", 0), ("y", FloatValue("f64", 0)), ("tag", None)))


def test_qerr_values_when_the_type_exists():
    from spectest import types, values

    if not hasattr(types, "QErrT") or not hasattr(values, "QError"):
        pytest.skip("qerr is not in the contract modules yet")
    for v in sample(strategy(types.QERR), budget(100, 20)):
        assert isinstance(v, values.QError) and v.steps >= 0 and v.nans >= 0


def test_uniform_draws_spread_over_bit_patterns():
    values = sample(strategy(U64), budget(2000, 200))
    top = sum(v >= 1 << 63 for v in values) / len(values)
    assert 0.15 < top < 0.45, top
    mid = sum(1 << 40 <= v < 1 << 62 for v in values) / len(values)
    assert mid > 0.05, mid
    normals = [
        floats.to_python_float(v)
        for v in sample(strategy(F64), budget(3000, 300))
        if floats.is_finite(v) and not floats.is_zero(v)
    ]
    assert sum(abs(x) > 1e100 for x in normals) / len(normals) > 0.04
    assert sum(abs(x) < 1e-100 for x in normals) / len(normals) > 0.1


def test_draws_stay_small_in_the_choice_budget():
    from .sampling import choice_bytes

    assert choice_bytes(strategy(I64), budget(300, 20)) < 64
    assert choice_bytes(strategy(F64), budget(300, 20)) < 64
    assert choice_bytes(strategy(ListT(ListT(F64))), budget(200, 20)) < 2500
    # Long lists, strings and bytes (Sizes.long_share) stay well inside the 8 KiB too.
    n = budget(1000, 20)
    assert choice_bytes(strategy(ListT(TupleT((I64, STRING)))), n) < 6000
    assert choice_bytes(strategy(ListT(STRING)), n) < 6000
    assert choice_bytes(strategy(ListT(F64)), n) < 4000
    assert choice_bytes(strategy(STRING), n) < 2000
    assert choice_bytes(strategy(BYTES), n) < 2000
