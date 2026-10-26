from collections import Counter
from pathlib import Path

import hypothesis
import pytest
from budget import budget
from hypothesis import find, given, settings

from spectest import sets
from spectest.generate import (
    DEFAULT,
    GeneratedModel,
    GenerateError,
    PartitionInfo,
    Sizes,
    args_strategy,
    partitions,
)
from spectest.lang import load, load_source
from spectest.prelude import floats
from spectest.types import (
    BYTES,
    STRING,
    FixedIntT,
    FloatT,
    ListT,
    ModelT,
    TupleT,
)

from .sampling import FAST, QUIET, draws, sample
from .validate import problems

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
LIBM = load(EXAMPLES / "libm" / "libm.spec")
SORTING = load(EXAMPLES / "sorting" / "sorting.spec")
DEQUE = load(EXAMPLES / "deque" / "deque.spec")
BINARY = load(EXAMPLES / "binary" / "binary.spec")
FRAMES = load(EXAMPLES / "frames" / "frames.spec")
F64, F32 = FloatT("f64"), FloatT("f32")
I8, I64, U8 = FixedIntT(8, True), FixedIntT(64, True), FixedIntT(8, False)


def check_args(decl, spec, tenv=None, n=150, **kw):
    """Draw argument dicts (fewer in the dev loop) and check every value against its
    instantiated type."""
    sig = spec.signature[decl]
    from spectest.types import substitute

    env = {k: spec.resolve_type(v) if isinstance(v, str) else v for k, v in (tenv or {}).items()}
    types = [substitute(t, env) for t in sig.params]
    out = draws(args_strategy(decl, spec, tenv, **kw), budget(n, max(n // 10, 5)))
    for args in out:
        assert list(args) == [p.name for p in decl.params]
        for p, t in zip(decl.params, types, strict=True):
            if args[p.name] is DEFAULT:
                assert p.default is not None
                continue
            assert not problems(args[p.name], t, spec, p.name)
    return out


def classes_reached(decl, spec, param, n=800):
    info = next(i for i in partitions(decl, spec) if i.param == param)
    values = [args[param] for args in sample(args_strategy(decl, spec), n)]
    return Counter(info.classify(v) for v in values), info


# -- libm: partition-uniform draws ---------------------------------------------------


@pytest.mark.parametrize("name", ["cos", "cos32", "sqrt"])
def test_partition_draws_reach_every_class_about_uniformly(name):
    decl = LIBM.fns[name]
    counts, info = classes_reached(decl, LIBM, "x")
    assert set(counts) == set(info.names), counts
    assert None not in counts
    expected = 800 / len(info.names)
    for cls in info.names:
        assert counts[cls] > expected / 2, (cls, counts)


def test_libm_draws_have_the_parameter_type():
    for name, t in (("cos", F64), ("cos32", F32), ("cos16", FloatT("f16")), ("sqrt", F64)):
        for args in check_args(LIBM.fns[name], LIBM, n=60):
            assert args["x"].fmt == t.fmt


def test_partition_draws_record_events(monkeypatch):
    events = []
    monkeypatch.setattr(hypothesis, "event", lambda value, payload="": events.append(value))
    sample(args_strategy(LIBM.fns["sqrt"], LIBM), budget(300, 38))
    names = {e for e in events if e.startswith("x: ")}
    assert names == {f"x: {c}" for c in ("nan", "negative", "zero", "subnormal", "normal", "inf")}


def test_events_inside_a_hypothesis_test():
    seen = set()

    @FAST
    @given(args_strategy(LIBM.fns["cos"], LIBM))
    def run(args):
        seen.add(partitions(LIBM.fns["cos"], LIBM)[0].classify(args["x"]))

    run()
    assert seen == {"nan", "inf", "zero", "subnormal", "small", "moderate", "huge"}


def test_partition_draws_shrink_to_simple_members():
    sqrt = args_strategy(LIBM.fns["sqrt"], LIBM)
    neg = find(sqrt, lambda a: floats.signbit(a["x"]) and not floats.is_nan(a["x"]), settings=QUIET)
    assert floats.is_zero(neg["x"]) or floats.to_python_float(neg["x"]) == -1.0
    big = find(
        args_strategy(LIBM.fns["cos"], LIBM),
        lambda a: floats.is_finite(a["x"]) and abs(floats.to_python_float(a["x"])) >= 2**20,
        settings=QUIET,
    )
    assert floats.to_python_float(big["x"]) == 2.0**20


# -- partitions ----------------------------------------------------------------------


def test_partitions_of_libm_are_sets():
    (info,) = partitions(LIBM.fns["cos"], LIBM)
    assert isinstance(info, PartitionInfo)
    assert info.param == "x" and info.kind == "set" and info.elem == F64
    assert info.names == ["nan", "inf", "zero", "subnormal", "small", "moderate", "huge"]
    assert all(isinstance(s, sets.BDDSet) for _, s in info.classes)
    assert info.classify(floats.from_python_float(-0.0)) == "zero"
    assert info.classify(floats.from_python_float(3.0)) == "moderate"
    assert partitions(LIBM.fns["cos16"], LIBM) == []


def test_predicate_partitions_keep_their_expressions():
    (info,) = partitions(BINARY.fns["unpack_i32"], BINARY)
    assert info.kind == "predicate" and info.elem == BYTES
    assert info.names == ["four", "other"]
    assert all(e is c.expr for (_, e), c in zip(info.classes, info.partition.classes, strict=True))
    with pytest.raises(GenerateError, match="predicate"):
        info.classify(b"1234")
    (sort,) = partitions(SORTING.fns["sort"], SORTING, {"T": I64})
    assert sort.kind == "predicate" and sort.elem == ListT(I64)
    assert sort.names == ["empty", "single", "unique", "duplicates"]


def share(values, test):
    return sum(1 for v in values if test(v)) / len(values)


@pytest.mark.slow
def test_predicate_classes_steer_generation():
    bs = [a["b"] for a in sample(args_strategy(BINARY.fns["unpack_i32"], BINARY), 2000)]
    # Two classes and one unsteered option: four gets a third, plus what the rest draws.
    assert 0.3 < share(bs, lambda b: len(b) == 4) < 0.45
    utf8 = [a["b"] for a in sample(args_strategy(BINARY.fns["utf8_decode"], BINARY), 2000)]
    valid = share(utf8, lambda b: b.decode("utf-8", "ignore").encode() == b)
    assert 0.4 < valid < 0.6
    xs = [a["xs"] for a in sample(args_strategy(SORTING.fns["sort"], SORTING, {"T": I64}), 2000)]
    for test in (
        lambda v: len(v) == 0,
        lambda v: len(v) == 1,
        lambda v: len(v) > 1 and len(set(v)) == len(v),
        lambda v: len(v) > 1 and len(set(v)) < len(v),
    ):
        assert 0.18 < share(xs, test) < 0.4


@pytest.mark.slow
def test_length_classes_are_drawn_to_their_lengths():
    spec = load_source(
        """spec lengths
fn f(b: bytes, s: string, xs: list<i64>) -> bool
  partition b
    short = len(b) < 3
    mid = len(b) >= 3 and len(b) <= 5
    exact = 7 == len(b)
  partition s
    long = len(s) > 20
    rest = len(s) <= 20
  partition xs
    pair = len(xs) == 2 and xs[0] != xs[1]
    other = len(xs) != 2
"""
    )
    out = sample(args_strategy(spec.fns["f"], spec), 1200)
    lengths = Counter(len(a["b"]) for a in out)
    assert lengths[7] > 250 and sum(lengths[n] for n in (3, 4, 5)) > 250
    assert sum(lengths[n] for n in range(3)) > 250
    assert share([a["s"] for a in out], lambda s: len(s) > 20) > 0.3
    pairs = [a["xs"] for a in out if len(a["xs"]) == 2]
    assert len(pairs) > 300 and share(pairs, lambda v: v[0] != v[1]) > 0.9


def test_steered_draws_shrink_to_the_first_class():
    found = find(
        args_strategy(BINARY.fns["unpack_i32"], BINARY), lambda a: True, settings=QUIET
    )
    assert found == {"b": bytes(4)}


def test_partitions_of_an_int_parameter():
    (info,) = partitions(BINARY.fns["pack_i32"], BINARY)
    assert info.kind == "set" and info.elem == I64
    assert info.classify(2**31) == "too_large"
    assert info.classify(-(2**31)) == "in_range"
    assert info.classify(-(2**31) - 1) == "too_small"


def test_partitions_by_name():
    assert partitions("cos", LIBM)[0].names[0] == "nan"
    assert partitions("Deque.rotate", DEQUE) == []
    with pytest.raises(GenerateError, match="unknown"):
        partitions("nope", LIBM)


# -- sorting, deque, binary: instantiations ------------------------------------------


@pytest.mark.parametrize("tenv", [{"T": I64}, {"T": STRING}, {"T": "u8"}, {"T": "(i32, string)"}])
def test_sort_arguments_for_instantiations(tenv):
    check_args(SORTING.fns["sort"], SORTING, tenv)


@pytest.mark.slow
def test_sort_reaches_every_predicate_class():
    seen = Counter()
    for tenv in ({"T": I64}, {"T": STRING}):
        for args in sample(args_strategy(SORTING.fns["sort"], SORTING, tenv), 600):
            xs = args["xs"]
            if len(xs) == 0:
                seen["empty"] += 1
            elif len(xs) == 1:
                seen["single"] += 1
            elif len(set(xs)) == len(xs):
                seen["unique"] += 1
            else:
                seen["duplicates"] += 1
        assert min(seen.values()) > 30, (tenv, seen)


def test_sort_by_first_with_two_type_parameters():
    out = check_args(SORTING.fns["sort_by_first"], SORTING, {"K": I64, "V": STRING})
    pairs = [p for args in out for p in args["xs"]]
    assert all(isinstance(k, int) and isinstance(v, str) for k, v in pairs)
    keys = Counter(
        k
        for args in sample(
            args_strategy(SORTING.fns["sort_by_first"], SORTING, {"K": I64, "V": STRING}), 300
        )
        for k, _ in args["xs"]
    )
    assert keys.most_common(1)[0][1] > 5, "equal keys are common, so stability is exercised"


def test_sort_in_place_draws_a_generic_model():
    out = check_args(SORTING.fns["sort_in_place"], SORTING, {"T": I64})
    for args in out:
        gm = args["xs"]
        assert isinstance(gm, GeneratedModel)
        assert gm.model == "MutableList" and gm.targs == (I64,)
        assert list(gm.fields) == ["items"]


def test_sort_type_parameter_bounds_are_checked():
    with pytest.raises(GenerateError, match="Ord"):
        args_strategy(SORTING.fns["sort"], SORTING, {"T": F64})
    with pytest.raises(GenerateError, match="Eq"):
        args_strategy(SORTING.fns["sort_by_first"], SORTING, {"K": I64, "V": F64})


def test_unbound_type_variables_are_errors():
    with pytest.raises(GenerateError, match="type variable T"):
        args_strategy(SORTING.fns["sort"], SORTING)
    with pytest.raises(GenerateError, match="type variable V"):
        args_strategy(SORTING.fns["sort_by_first"], SORTING, {"K": I64})


def deque_member(name):
    iface = DEQUE.interfaces["Deque"]
    return next(d for d in [*iface.ctors, *iface.methods] if d.name == name)


@pytest.mark.parametrize("tenv", [{"T": I64}, {"T": STRING}, {"T": "option<i8>"}])
def test_deque_method_arguments(tenv):
    for name in ("empty", "bounded", "append", "appendleft", "pop", "popleft", "rotate"):
        decl = deque_member(name)
        out = check_args(decl, DEQUE, tenv, n=40)
        assert all("self" not in args for args in out)
    n = budget(400, 150)
    rotate = [a["n"] for a in sample(args_strategy(deque_member("rotate"), DEQUE, tenv), n)]
    assert {-128, 127, 0, 1, -1} <= set(rotate)
    bounded = [a["n"] for a in sample(args_strategy("Deque.bounded", DEQUE, tenv), n)]
    assert {0, 1, 255} <= set(bounded)


def test_deque_pop_takes_no_arguments():
    assert draws(args_strategy("Deque.pop", DEQUE, {"T": I64}), 5) == [{}]


def test_binary_arguments():
    for name in ("pack_i32", "unpack_i32", "utf8_encode", "utf8_decode"):
        check_args(BINARY.fns[name], BINARY)
    counts, _ = classes_reached(BINARY.fns["pack_i32"], BINARY, "x", 600)
    assert set(counts) == {"in_range", "too_small", "too_large"}
    assert min(counts.values()) > 120
    values = {a["x"] for a in sample(args_strategy("pack_i32", BINARY), budget(600, 75))}
    assert {2**31 - 1, -(2**31), 2**31, -(2**31) - 1} & values


def test_binary_unpack_draws_four_byte_strings_sometimes():
    lengths = Counter(len(a["b"]) for a in sample(args_strategy("unpack_i32", BINARY), 600))
    assert lengths[4] > 15


def test_partition_draws_shrink_to_class_boundaries():
    big = find(args_strategy("pack_i32", BINARY), lambda a: a["x"] > 2**31, settings=QUIET)
    assert big == {"x": 2**31 + 1}
    small = find(args_strategy("pack_i32", BINARY), lambda a: a["x"] < -(2**31), settings=QUIET)
    assert small == {"x": -(2**31) - 1}


# -- frames: models and defaults ------------------------------------------------------


@pytest.mark.slow
def test_dropna_how_is_sometimes_default():
    out = sample(args_strategy(FRAMES.fns["dropna"], FRAMES), 800)
    hows = Counter(a["how"] if a["how"] is DEFAULT else repr(a["how"]) for a in out)
    assert 0.15 < hows[DEFAULT] / len(out) < 0.35, hows
    assert hows["'any'"] > 100 and hows["'all'"] > 100
    assert all(isinstance(a["df"], GeneratedModel) for a in out)


def test_defaults_can_be_turned_off():
    out = sample(args_strategy(FRAMES.fns["dropna"], FRAMES, defaults=False), budget(300, 50))
    assert all(a["how"] in ("any", "all") for a in out)


def test_default_shrinks_to_omitted():
    found = find(args_strategy("dropna", FRAMES), lambda a: True, settings=QUIET)
    assert found["how"] is DEFAULT


def test_frames_arguments_have_the_right_types():
    for name in ("dropna", "fillna", "select"):
        check_args(FRAMES.fns[name], FRAMES, n=80)


def test_fillna_value_stays_inside_requires():
    values = [a["value"] for a in sample(args_strategy("fillna", FRAMES), budget(600, 100))]
    assert not any(floats.is_nan(v) for v in values)
    assert any(floats.is_inf(v) for v in values)
    assert any(floats.is_zero(v) and floats.signbit(v) for v in values)


def test_select_names_are_distinct_by_construction():
    out = sample(args_strategy("select", FRAMES), budget(400, 60))
    assert all(len(set(a["names"])) == len(a["names"]) for a in out)
    assert max(len(a["names"]) for a in out) >= 3


@pytest.mark.slow
def test_select_names_often_come_from_the_frame():
    out = sample(args_strategy("select", FRAMES), 600)
    hits = [a for a in out if a["names"] and set(a["names"]) <= set(a["df"].fields["columns"])]
    assert len(hits) > 60


# -- requires narrowing and local specs ----------------------------------------------


SPEC = load_source(
    """spec local

fn positive(x: i32, y: f64 = 1.5) -> i32
  requires x >= 5 and x < 100
  requires y > 0

fn flags(a: bool, b: u8) -> u8
  requires a

fn split(x: u8) -> u8
  requires x < 10
  partition x
    low  = u8.range(0, 5)
    high = u8.range(5, 256)

fn mixed(xs: list<i64>, m: map<string, (bool, option<f32>)>) -> bool
"""
)


def test_requires_narrows_fixed_width_draws():
    out = sample(args_strategy("positive", SPEC), 600)
    xs = [a["x"] for a in out]
    assert all(5 <= x < 100 for x in xs)
    assert {5, 6, 98, 99} <= set(xs)
    ys = [a["y"] for a in out if a["y"] is not DEFAULT]
    assert all(floats.to_python_float(y) > 0 for y in ys)
    assert any(floats.is_inf(y) for y in ys) and any(floats.is_subnormal(y) for y in ys)
    assert sum(a["y"] is DEFAULT for a in out) > 80


def test_requires_narrows_bools_and_partition_classes():
    assert {a["a"] for a in sample(args_strategy("flags", SPEC), budget(100, 20))} == {True}
    split = [a["x"] for a in sample(args_strategy("split", SPEC), budget(300, 38))]
    assert set(split) == set(range(10))


def test_mixed_collections():
    t_xs = ListT(I64)
    mixed = args_strategy("mixed", SPEC, sizes=Sizes(max_list=3, long_share=0))
    for args in draws(mixed, budget(100, 20)):
        assert not problems(args["xs"], t_xs)
        assert len(args["xs"]) <= 3 and len(args["m"].items) <= 3
        for k, (flag, opt) in args["m"].items:
            assert isinstance(k, str) and isinstance(flag, bool)


def test_tuple_and_model_types_resolve_in_args():
    sig = SORTING.signature[SORTING.fns["sort_by_first"]]
    assert sig.params[0].elem == TupleT((sig.params[0].elem.elems[0], sig.params[0].elem.elems[1]))
    assert isinstance(SORTING.signature[SORTING.fns["sort_in_place"]].params[0], ModelT)


def test_argument_strategies_work_as_stateful_rules():
    from hypothesis.stateful import (
        RuleBasedStateMachine,
        initialize,
        rule,
        run_state_machine_as_test,
    )

    seen = []

    class Machine(RuleBasedStateMachine):
        @initialize(args=args_strategy("Deque.bounded", DEQUE, {"T": I64}))
        def make(self, args):
            self.items = []
            assert 0 <= args["n"] <= 255

        @rule(args=args_strategy("Deque.append", DEQUE, {"T": I64}))
        def append(self, args):
            self.items.append(args["x"])
            seen.append(tuple(self.items))

        @rule(args=args_strategy("Deque.rotate", DEQUE, {"T": I64}))
        def rotate(self, args):
            assert -128 <= args["n"] <= 127

    run_state_machine_as_test(Machine, settings=settings(FAST, max_examples=budget(50, 5)))
    assert any(len(set(items)) < len(items) for items in seen), "values repeat across steps"
