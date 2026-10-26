import math
from collections import Counter
from pathlib import Path

import pytest
from budget import budget
from hypothesis import HealthCheck, find, given, settings
from hypothesis import strategies as st
from hypothesis.errors import FailedHealthCheck, Unsatisfiable

from spectest import sets
from spectest.sets import (
    classify,
    compile_set,
    domain,
    domain_size,
    enumerate_domain,
    enumerate_set,
    format_value,
    index_of,
    index_strategy,
    member,
    named_set,
    partition_sets,
    partition_strategy,
    set_size,
    strategy_for_set,
    tagged_partition_strategy,
)
from spectest.types import BOOL, STRING, FixedIntT, FloatT, ListT
from spectest.values import FloatValue

from .floats import fv, to_float
from .syntax import expr, read_file

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
F16, BF16, F32, F64 = FloatT("f16"), FloatT("bf16"), FloatT("f32"), FloatT("f64")
I8, I32, I64, U8 = FixedIntT(8, True), FixedIntT(32, True), FixedIntT(64, True), FixedIntT(8, False)
FAST = settings(max_examples=300, deadline=None, database=None, derandomize=True)


def libm(name):
    spec = read_file(EXAMPLES / "libm" / "libm.spec")
    return partition_sets(next(d for d in spec.decls if d.name == name), "x")


def pack_i32():
    spec = read_file(EXAMPLES / "binary" / "binary.spec")
    return partition_sets(next(d for d in spec.decls if d.name == "pack_i32"), "x")


# ---------------------------------------------------------------------------
# member and index_of


def test_int_members_run_from_simple_to_extreme():
    s = domain(I8)
    values = [member(s, i) for i in range(256)]
    assert values[:6] == [0, 1, -1, 2, 3, 4]
    assert values[128:132] == [127, -2, -3, -4]
    assert values[-1] == -128
    assert sorted(values) == list(range(-128, 128))
    assert [index_of(s, v) for v in values] == list(range(256))


def test_float_members_start_simple():
    s = domain(F64)
    first = [member(s, i) for i in range(7)]
    assert [to_float(v) for v in first[:4]] == [0.0, -0.0, 1.0, -1.0]
    assert math.copysign(1, to_float(first[1])) == -1
    assert first[4] == FloatValue("f64", 0x7FF8000000000000)
    assert first[5] == FloatValue("f64", 0xFFF8000000000000)
    assert first[6] == FloatValue("f64", 1)
    assert member(named_set(F64, "nan"), 0) == FloatValue("f64", 0x7FF8000000000000)
    assert to_float(member(named_set(F64, "normal"), 0)) == 1.0


def test_members_of_a_class_without_specials_ascend_in_magnitude():
    huge = dict(libm("cos"))["huge"]
    assert to_float(member(huge, 0)) == 2.0**20
    assert to_float(member(huge, 1)) == math.nextafter(2.0**20, math.inf)
    positives = (huge & named_set(F64, "positive")).size
    assert positives == set_size(huge) // 2 + 1
    assert to_float(member(huge, positives - 1)) == 1.7976931348623157e308
    assert to_float(member(huge, positives)) == math.nextafter(-(2.0**20), -math.inf)
    assert to_float(member(huge, set_size(huge) - 1)) == -1.7976931348623157e308


def test_f16_members_are_a_bijection():
    s = domain(F16)
    seen = {member(s, i).bits for i in range(set_size(s))}
    assert len(seen) == 1 << 16
    for i in range(0, 1 << 16, 97):
        assert index_of(s, member(s, i)) == i


def test_index_of_rejects_non_members():
    zero = named_set(F64, "zero")
    with pytest.raises(ValueError, match="not in the set"):
        index_of(zero, fv("f64", 1.0))
    with pytest.raises(ValueError, match="not a member"):
        index_of(zero, 0)
    with pytest.raises(ValueError, match="not a member"):
        index_of(zero, fv("f32", 0.0))


def test_member_out_of_range():
    zero = named_set(F64, "zero")
    with pytest.raises(IndexError):
        member(zero, 2)
    with pytest.raises(IndexError):
        member(zero, -1)
    assert set_size(zero) == 2


# ---------------------------------------------------------------------------
# Strategies


@pytest.mark.parametrize(
    ("name", "elem", "text"),
    [
        ("zero", F64, "f64.zero"),
        ("one", F64, "f64.inf & f64.positive"),
        ("small", F64, "f64.range(-0x1p-26, 0x1p-26) & f64.normal"),
        ("nan32", F32, "f32.nan"),
        ("bf16", BF16, "bf16.subnormal | {1}"),
        ("ints", I64, "i64.range(i32.max + 1, none)"),
        ("bool", BOOL, "{false}"),
    ],
)
def test_strategy_draws_only_members(name, elem, text):
    s = compile_set(expr(text), elem)

    @settings(FAST, max_examples=budget(300, 30))
    @given(strategy_for_set(s, elem))
    def check(value):
        assert value in s

    check()


def test_empty_set_strategy_is_nothing():
    assert strategy_for_set(domain(U8) - domain(U8)).is_empty


def test_strategy_checks_the_element_type():
    with pytest.raises(TypeError, match="a set of f64 values, not f32"):
        strategy_for_set(domain(F64), F32)


@pytest.mark.slow
def test_draws_are_uniform_over_bit_patterns():
    normal = named_set(F64, "normal")
    drawn = []

    @settings(max_examples=1000, deadline=None, database=None, derandomize=True)
    @given(strategy_for_set(normal))
    def collect(value):
        drawn.append(to_float(value))

    collect()
    negative = sum(x < 0 for x in drawn) / len(drawn)
    huge = sum(abs(x) > 1e100 for x in drawn) / len(drawn)
    tiny = sum(abs(x) < 1e-100 for x in drawn) / len(drawn)
    assert 0.4 < negative < 0.6
    assert 0.25 < huge < 0.45
    assert 0.25 < tiny < 0.45


@pytest.mark.slow
def test_draws_cover_a_wide_int_range_uniformly():
    drawn = []

    @settings(max_examples=1000, deadline=None, database=None, derandomize=True)
    @given(strategy_for_set(domain(I32)))
    def collect(value):
        drawn.append(value)

    collect()
    assert 0.4 < sum(v < 0 for v in drawn) / len(drawn) < 0.6
    assert sum(abs(v) > 2**30 for v in drawn) / len(drawn) > 0.4


def test_shrinking_goes_toward_simple_members():
    normal = named_set(F64, "normal")
    assert to_float(find(strategy_for_set(normal), lambda v: True)) == 1.0
    assert to_float(find(strategy_for_set(normal), lambda v: to_float(v) < 0)) == -1.0
    big = to_float(find(strategy_for_set(normal), lambda v: to_float(v) > 1e10))
    assert big == math.nextafter(1e10, math.inf)
    assert find(strategy_for_set(domain(I32)), lambda v: v < -1000) == -1001
    assert find(strategy_for_set(domain(I32)), lambda v: v > 77) == 78
    assert find(strategy_for_set(domain(I64)), lambda v: v % 1000 == 999) == -1
    assert find(strategy_for_set(domain(I64)), lambda v: v > 10**6 and v % 2) == 10**6 + 1
    assert find(strategy_for_set(domain(I32)), lambda v: v < 0) == -1
    nan = named_set(F64, "nan")
    assert find(strategy_for_set(nan), lambda v: True) == FloatValue("f64", 0x7FF8000000000000)
    assert find(strategy_for_set(nan), lambda v: v.bits & 1) == FloatValue(
        "f64", 0x7FF0000000000001
    )


@pytest.mark.slow
def test_simple_members_are_drawn_a_little_more_often():
    drawn = []

    @settings(max_examples=1000, deadline=None, database=None, derandomize=True)
    @given(strategy_for_set(domain(F64)))
    def collect(value):
        drawn.append(value.bits)

    collect()
    simple = {0, 1 << 63, 0x3FF0000000000000, 0xBFF0000000000000}
    assert 0.01 < sum(b in simple for b in drawn) / len(drawn) < 0.15


def draw_indices(n, far):
    drawn = []

    @settings(max_examples=500, deadline=None, database=None, derandomize=True)
    @given(index_strategy(n, far=far))
    def collect(i):
        assert 0 <= i < n
        drawn.append(i)

    collect()
    return drawn


@pytest.mark.slow
@pytest.mark.parametrize("far", [True, False])
def test_index_strategies_are_uniform_and_in_range(far):
    n = 3 * 2**60 + 7
    drawn = draw_indices(n, far)
    assert 0.4 < sum(i < n // 2 for i in drawn) / len(drawn) < 0.6
    assert sum(i < n // 1000 for i in drawn) / len(drawn) < 0.05


def test_scaled_bytes_shrink_close_to_the_boundary():
    # Derandomized: how close a random run shrinks scaled bytes varies (to 2^32 from some
    # seeds), so a fresh Hypothesis database would make the first check flaky.
    once = settings(database=None, derandomize=True)
    index = find(index_strategy(2**40, far=False), lambda i: i > 10**9, settings=once)
    assert 10**9 < index < 1.01 * 10**9
    assert find(index_strategy(2**40, far=True), lambda i: i > 10**9, settings=once) == 10**9 + 1


def draw_many(count):
    lengths = []

    @settings(max_examples=10, deadline=None, database=None, derandomize=True)
    @given(st.lists(partition_strategy(libm("cos")), min_size=count, max_size=count))
    def check(xs):
        lengths.append(len(xs))

    check()
    return lengths


def test_index_choices_fit_hypothesis_test_case_budget():
    """At a 2^128 offset an index costs about 18 bytes of the 8 KiB a test case may use,
    so 200 partitioned draws fit in one test case; at 2^1100 they did not."""
    assert sets._FAR == 1 << 128
    lengths = draw_many(200)
    assert lengths and set(lengths) == {200}


def test_a_far_offset_overruns_the_budget(monkeypatch):
    monkeypatch.setattr(sets, "_FAR", 1 << 1100)
    with pytest.raises((FailedHealthCheck, Unsatisfiable)):
        draw_many(200)


def draw_classes(classes):
    sets_by_name = dict(classes)
    counts: Counter[str] = Counter()

    @FAST
    @given(tagged_partition_strategy(classes))
    def check(tagged):
        name, value = tagged
        assert value in sets_by_name[name]
        assert classify(value, classes) == name
        counts[name] += 1

    check()
    return counts


@pytest.mark.slow
@pytest.mark.parametrize("classes", [libm("cos"), libm("sqrt"), libm("cos32"), pack_i32()])
def test_partition_strategy_draws_every_class_and_only_members(classes):
    counts = draw_classes(classes)
    assert set(counts) == {name for name, _ in classes}
    for name, s in classes:
        assert counts[name] >= min(s.size, 300 // len(classes) // 3)


def test_partition_strategy_records_events(monkeypatch):
    events = []
    monkeypatch.setattr(sets.hypothesis, "event", events.append)
    classes = libm("sqrt")

    @settings(max_examples=50, deadline=None, database=None, derandomize=True)
    @given(partition_strategy(classes, F64, label="x"))
    def check(value):
        assert classify(value, classes) is not None

    check()
    assert {e.split(": ")[1] for e in events} == {name for name, _ in classes}
    assert all(e.startswith("x: ") for e in events)


def test_partition_strategy_outside_a_test_ignores_events():
    classes = [("zero", named_set(F64, "zero"))]
    value = find(partition_strategy(classes), lambda v: True)
    assert value == FloatValue("f64", 0)


def test_partition_strategy_skips_empty_classes():
    classes = {"none": domain(U8) - domain(U8), "low": compile_set(expr("{1, 2}"), U8)}

    @settings(
        max_examples=30, deadline=None, database=None, suppress_health_check=list(HealthCheck)
    )
    @given(tagged_partition_strategy(classes, U8))
    def check(tagged):
        assert tagged[0] == "low" and tagged[1] in (1, 2)

    check()
    assert tagged_partition_strategy({"none": domain(U8) - domain(U8)}).is_empty


def test_shrinking_a_partition_draw():
    classes = libm("cos")
    name, value = find(tagged_partition_strategy(classes), lambda t: to_float(t[1]) > 1e30)
    assert (name, value) == ("inf", fv("f64", math.inf))
    name, value = find(
        tagged_partition_strategy(classes),
        lambda t: math.isfinite(to_float(t[1])) and to_float(t[1]) > 1e30,
    )
    assert (name, to_float(value)) == ("huge", math.nextafter(1e30, math.inf))


# ---------------------------------------------------------------------------
# classify, domains, enumeration


def test_classify():
    classes = libm("sqrt")
    assert classify(fv("f64", -0.0), classes) == "zero"
    assert classify(fv("f64", 0.0), classes) == "zero"
    assert classify(fv("f64", -math.inf), classes) == "negative"
    assert classify(fv("f64", math.inf), classes) == "inf"
    assert classify(fv("f64", 5e-324), classes) == "subnormal"
    assert classify(FloatValue("f64", 0xFFF0000000000001), classes) == "nan"
    assert classify(fv("f32", 1.0), classes) is None
    assert classify("text", classes) is None
    assert classify(fv("f64", 1.0), dict(classes)) == "normal"
    assert classify(fv("f64", 1.0), [("zero", named_set(F64, "zero"))]) is None
    assert classify(2**31, pack_i32()) == "too_large"
    assert classify(-(2**31), pack_i32()) == "in_range"


def test_domain_size():
    assert domain_size([F16]) == 1 << 16
    assert domain_size([U8, BOOL]) == 512
    assert domain_size([F64, I64]) == 1 << 128
    assert domain_size([]) == 1
    assert domain_size([F64, ListT(F64)]) is None
    assert domain_size([STRING]) is None


def test_enumerate_f16():
    values = list(enumerate_domain([F16]))
    assert len(values) == 1 << 16
    assert all(len(t) == 1 and t[0].fmt == "f16" for t in values)
    assert len({t[0].bits for t in values}) == 1 << 16
    assert [t[0].bits for t in values[:3]] == [0, 1, 2]


def test_enumerate_products_in_bit_order():
    pairs = list(enumerate_domain([U8, I8]))
    assert len(pairs) == 1 << 16 and len(set(pairs)) == 1 << 16
    assert pairs[:2] == [(0, 0), (0, 1)]
    assert pairs[127:130] == [(0, 127), (0, -128), (0, -127)]
    assert pairs[256] == (1, 0)
    assert list(enumerate_domain([BOOL])) == [(False,), (True,)]
    assert list(enumerate_domain([])) == [()]
    with pytest.raises(TypeError):
        list(enumerate_domain([STRING]))


def test_enumerate_set():
    nans = list(enumerate_set(named_set(F16, "nan")))
    assert len(nans) == 2046 and len({v.bits for v in nans}) == 2046
    assert all(math.isnan(to_float(v)) for v in nans)
    assert list(enumerate_set(compile_set(expr("{3, -1, 0}"), I8))) == [0, 3, -1]


# ---------------------------------------------------------------------------
# Formatting


@pytest.mark.parametrize(
    ("value", "text"),
    [
        (FloatValue("f64", 0x8000000000000000), "-0.0 (0x8000000000000000)"),
        (FloatValue("f64", 0), "0.0 (0x0000000000000000)"),
        (FloatValue("f64", 0x7FF8000000000000), "nan (0x7ff8000000000000)"),
        (FloatValue("f64", 0xFFF0000000000001), "-nan (0xfff0000000000001)"),
        (FloatValue("f64", 0xFFF0000000000000), "-inf (0xfff0000000000000)"),
        (FloatValue("f64", 1), "5e-324 (0x0000000000000001)"),
        (FloatValue("f64", 0x3FF0000000000000), "1.0 (0x3ff0000000000000)"),
        (FloatValue("f32", 0x3DCCCCCD), "0.1 (0x3dcccccd)"),
        (FloatValue("f32", 1), "1e-45 (0x00000001)"),
        (FloatValue("f16", 0x7BFF), "65500.0 (0x7bff)"),
        (FloatValue("f16", 1), "6e-08 (0x0001)"),
        (FloatValue("f16", 0x3555), "0.3333 (0x3555)"),
        (FloatValue("bf16", 0x3F80), "1.0 (0x3f80)"),
        (FloatValue("bf16", 0x3DCD), "0.1 (0x3dcd)"),
        (True, "true"),
        (-5, "-5"),
    ],
)
def test_format_value(value, text):
    assert format_value(value) == text
