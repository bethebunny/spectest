from collections import Counter
from pathlib import Path
from typing import Any

import pytest
from budget import budget
from hypothesis import find, given

from spectest.generate import (
    GeneratedModel,
    GenerateError,
    Sizes,
    model_strategy,
    residual_invariants,
    strategy,
)
from spectest.lang import load, load_source
from spectest.prelude import floats
from spectest.types import STRING, FixedIntT, ListT, ModelT, OptionT, TupleT
from spectest.values import Handle, Some

from .sampling import FAST, QUIET, draws, sample
from .validate import problems

try:
    from spectest import eval as spec_eval
except ImportError:  # pragma: no cover - eval is built in parallel
    spec_eval = None

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
FRAMES = load(EXAMPLES / "frames" / "frames.spec")
SORTING = load(EXAMPLES / "sorting" / "sorting.spec")
I8, I64, U8 = FixedIntT(8, True), FixedIntT(64, True), FixedIntT(8, False)


class FieldsContext:
    """Serves a GeneratedModel's field values to the evaluator, as a binding would."""

    def observe(self, handle: Handle, observer: str, args: tuple) -> Any:
        assert not args
        return handle.obj.fields[observer]

    def fields(self, handle: Handle) -> dict[str, Any]:
        return dict(handle.obj.fields)

    def call_spec_fn(self, name: str, args: tuple) -> Any:
        raise AssertionError("no spec functions in invariants")

    def is_fresh(self, handle: Handle) -> bool:
        return True

    def same_object(self, a: Handle, b: Handle) -> bool:
        return a is b

    def shares_memory(self, a: Handle, b: Handle) -> bool:
        return False


def invariants_hold(gm: GeneratedModel, spec) -> dict[str, bool]:
    """Each invariant's verdict on a generated model, through spectest.eval."""
    decl = spec.models[gm.model]
    handle = Handle(gm, gm.model)
    tenv = dict(zip(spec.tparams.get(decl, {}), gm.targs, strict=True))
    env = spec_eval.Env(values={"self": handle}, fields=handle, tenv=tenv)
    return {
        c.id: spec_eval.holds(c, env, spec, FieldsContext())
        for c in decl.clauses
        if c.kind == "invariant"
    }


def frame_ok(gm: GeneratedModel) -> bool:
    """Frame's invariants checked directly, without the evaluator."""
    cols, rows, nrows = gm.fields["columns"], gm.fields["rows"], gm.fields["nrows"]
    return (
        len(set(cols)) == len(cols)
        and all(len(r) == len(cols) for r in rows)
        and nrows == len(rows)
    )


FRAME = ModelT("Frame")


# -- frames --------------------------------------------------------------------------


def test_frame_is_fully_constructive():
    assert residual_invariants("Frame", FRAMES) == []


@pytest.mark.skipif(spec_eval is None, reason="spectest.eval is not available")
def test_frame_invariants_hold_on_every_draw():
    @FAST
    @given(model_strategy("Frame", (), FRAMES))
    def check(gm):
        assert frame_ok(gm)
        verdicts = invariants_hold(gm, FRAMES)
        assert verdicts == {
            "Frame.unique_columns": True,
            "Frame.rectangular": True,
            "Frame.row_count": True,
        }

    check()


def test_frame_draws_have_the_field_types():
    for gm in draws(model_strategy("Frame", (), FRAMES), budget(200, 25)):
        assert frame_ok(gm)
        assert not problems(gm, FRAME, FRAMES)
        assert list(gm.fields) == ["columns", "rows", "nrows"]
        assert gm.model == "Frame" and gm.targs == ()


def test_frames_are_small():
    sizes = Sizes(max_list=5, max_inner=3)
    out = sample(model_strategy("Frame", (), FRAMES, sizes), budget(400, 50))
    assert all(len(gm.fields["columns"]) <= 3 for gm in out)
    assert all(gm.fields["nrows"] <= 5 for gm in out)
    assert max(len(gm.fields["columns"]) for gm in out) == 3
    assert max(gm.fields["nrows"] for gm in out) == 5
    assert any(gm.fields["nrows"] == 0 for gm in out)
    assert any(gm.fields["nrows"] > 0 and not gm.fields["columns"] for gm in out)


def test_frame_cells_are_interesting():
    cells = [
        c
        for gm in sample(model_strategy("Frame", (), FRAMES), budget(400, 50))
        for r in gm.fields["rows"]
        for c in r
    ]
    kinds = Counter()
    for c in cells:
        if c is None:
            kinds["none"] += 1
            continue
        assert isinstance(c, Some)
        v = c.value
        if floats.is_nan(v):
            kinds["nan"] += 1
            assert v.bits & ~(1 << 63) == 0x7FF8000000000000, "cells hold quiet NaNs"
        elif floats.is_inf(v):
            kinds["inf"] += 1
        elif floats.is_zero(v):
            kinds["-0.0" if floats.signbit(v) else "0.0"] += 1
        elif 1e-6 < abs(floats.to_python_float(v)) < 1e6:
            kinds["ordinary"] += 1
        else:
            kinds["extreme"] += 1
    for kind in ("none", "nan", "inf", "-0.0", "0.0", "ordinary", "extreme"):
        assert kinds[kind] > len(cells) / 50, kinds
    assert 0.1 < kinds["none"] / len(cells) < 0.35


def test_frame_columns_are_distinct_strings():
    out = sample(model_strategy("Frame", (), FRAMES), budget(400, 50))
    assert any(len(gm.fields["columns"]) >= 3 for gm in out)
    for gm in out:
        cols = gm.fields["columns"]
        assert all(isinstance(c, str) for c in cols)
        assert len(set(cols)) == len(cols)


def test_frame_shrinks_to_simple_frames():
    two_rows = find(
        model_strategy("Frame", (), FRAMES), lambda gm: gm.fields["nrows"] >= 2, settings=QUIET
    )
    assert two_rows.fields == {"columns": (), "rows": ((), ()), "nrows": 2}
    two_cols = find(
        model_strategy("Frame", (), FRAMES),
        lambda gm: len(gm.fields["columns"]) >= 2 and gm.fields["nrows"] >= 1,
        settings=QUIET,
    )
    assert two_cols.fields["columns"] == ("", "0")
    assert two_cols.fields["rows"] == ((None, None),)
    nan_cell = find(
        model_strategy("Frame", (), FRAMES),
        lambda gm: any(
            isinstance(c, Some) and floats.is_nan(c.value) for r in gm.fields["rows"] for c in r
        ),
        settings=QUIET,
    )
    assert nan_cell.fields["columns"] == ("",)
    assert nan_cell.fields["rows"] == ((Some(floats.nan("f64")),),)


def test_frame_is_reachable_through_strategy():
    for gm in draws(strategy(FRAME, FRAMES), budget(50, 10)):
        assert isinstance(gm, GeneratedModel) and frame_ok(gm)
    for frames in draws(strategy(ListT(FRAME), FRAMES), budget(30, 5)):
        assert all(frame_ok(gm) for gm in frames)


def test_generated_model_repr():
    gm = GeneratedModel("Frame", (), {"columns": ("a",), "rows": (), "nrows": 0})
    assert repr(gm) == "Frame(columns=('a',), rows=(), nrows=0)"
    assert (
        repr(GeneratedModel("MutableList", (I64,), {"items": ()})) == "MutableList<i64>(items=())"
    )


# -- generic models ------------------------------------------------------------------


@pytest.mark.parametrize("targ", [I64, STRING, TupleT((U8, OptionT(STRING)))], ids=str)
def test_mutable_list_with_type_arguments(targ):
    t = ModelT("MutableList", (targ,))
    for gm in draws(model_strategy("MutableList", (targ,), SORTING), budget(100, 20)):
        assert gm.targs == (targ,)
        assert not problems(gm, t, SORTING)
    assert residual_invariants("MutableList", SORTING) == []


def test_type_arguments_by_name_or_text():
    gm = draws(model_strategy("MutableList", {"T": I64}, SORTING), 5)[-1]
    assert gm.targs == (I64,)
    gm = draws(model_strategy("MutableList", ["list<u8>"], SORTING), 5)[-1]
    assert gm.targs == (ListT(U8),)


def test_model_errors():
    with pytest.raises(GenerateError, match="takes 1 type argument"):
        model_strategy("MutableList", (), SORTING)
    with pytest.raises(GenerateError, match="type variable T"):
        model_strategy("MutableList", {}, SORTING)
    with pytest.raises(GenerateError, match="unknown model"):
        model_strategy("Nope", (), SORTING)
    deque = load(EXAMPLES / "deque" / "deque.spec")
    with pytest.raises(GenerateError, match="interface"):
        model_strategy("Deque", (I64,), deque)
    with pytest.raises(GenerateError, match="interface"):
        residual_invariants("Deque", deque)


# -- invariants as constraints -------------------------------------------------------


SPEC = load_source(
    """spec shapes

model Table
  observe ids: list<i64>
  observe names: list<string>
  observe tags: list<string>
  observe count: u32
  observe copy: list<i64>
  observe flag: bool
  observe label: string
  observe level: i8
  invariant ids_unique: distinct(ids)
  invariant tag_lengths: all(t in tags: len(t) == len(ids))
  invariant counted: len(self.ids) == count
  invariant copied: copy == ids
  invariant flagged: flag == true and "x" == label
  invariant level_fixed: level == -3

model Loose
  observe xs: list<u8>
  observe n: u8
  observe m: int
  observe later: list<u8>
  invariant nonempty: len(xs) > 0
  invariant both: distinct(xs) and n < 200
  invariant forward: m == len(later)
  invariant first_wins: n == len(xs)
  invariant second: n == 3

model Grid
  observe width: list<bool>
  observe cells: list<list<option<i8>>>
  observe more: list<list<option<i8>>>
  invariant w: all(r in cells: len(r) == len(width))
  invariant w2: all(r in more: len(width) == len(r))
  invariant unique_rows: distinct(cells)

model Computed
  observe width: list<bool>
  observe base: list<list<u8>>
  observe twin: list<list<u8>>
  observe size: u8
  invariant twin_is_base: twin == base
  invariant twin_distinct: distinct(twin)
  invariant sized: size == len(base)
  invariant twin_len: all(x in twin: len(x) == len(width))

model Node
  observe value: i64
  observe next: option<Node>
"""
)


def holds_all(gm, spec, skip=()):
    verdicts = invariants_hold(gm, spec)
    return all(v for k, v in verdicts.items() if k not in skip), verdicts


@pytest.mark.skipif(spec_eval is None, reason="spectest.eval is not available")
def test_table_invariants_are_all_constructive():
    assert residual_invariants("Table", SPEC) == []
    for gm in draws(model_strategy("Table", (), SPEC), budget(150, 20)):
        ok, verdicts = holds_all(gm, SPEC)
        assert ok, verdicts
        assert gm.fields["count"] == len(gm.fields["ids"])
        assert gm.fields["copy"] == gm.fields["ids"]
        assert gm.fields["flag"] is True and gm.fields["label"] == "x"
        assert gm.fields["level"] == -3


def test_table_tags_have_the_length_of_ids_and_ids_are_inner():
    out = sample(model_strategy("Table", (), SPEC), budget(300, 38))
    assert all(len(gm.fields["ids"]) <= Sizes().max_inner for gm in out)
    assert any(len(gm.fields["ids"]) == Sizes().max_inner for gm in out)
    assert any(len(gm.fields["tags"]) > 2 for gm in out)
    assert all(len(t) == len(gm.fields["ids"]) for gm in out for t in gm.fields["tags"])


def test_residual_invariants_are_the_ones_not_constructed():
    residual = [c.id for c in residual_invariants("Loose", SPEC)]
    assert residual == ["Loose.nonempty", "Loose.both", "Loose.forward", "Loose.second"]


@pytest.mark.skipif(spec_eval is None, reason="spectest.eval is not available")
def test_enforced_parts_of_loose_hold():
    for gm in draws(model_strategy("Loose", (), SPEC), budget(100, 20)):
        xs = gm.fields["xs"]
        assert len(set(xs)) == len(xs), "distinct(xs) is enforced even inside a residual clause"
        assert gm.fields["n"] == len(xs)
        verdicts = invariants_hold(gm, SPEC)
        assert verdicts["Loose.first_wins"]


@pytest.mark.skipif(spec_eval is None, reason="spectest.eval is not available")
def test_grid_lengths_and_unique_rows():
    assert residual_invariants("Grid", SPEC) == []
    out = sample(model_strategy("Grid", (), SPEC), budget(300, 38))
    for gm in out:
        ok, verdicts = holds_all(gm, SPEC)
        assert ok, verdicts
    assert any(len(gm.fields["cells"]) >= 3 and len(gm.fields["width"]) >= 2 for gm in out)


@pytest.mark.skipif(spec_eval is None, reason="spectest.eval is not available")
def test_computed_fields_take_priority_over_other_constraints():
    residual = [c.id for c in residual_invariants("Computed", SPEC)]
    assert residual == ["Computed.twin_distinct", "Computed.twin_len"]
    for gm in draws(model_strategy("Computed", (), SPEC), budget(80, 20)):
        assert gm.fields["twin"] == gm.fields["base"]
        assert gm.fields["size"] == len(gm.fields["base"])


def test_recursive_models_terminate():
    out = sample(model_strategy("Node", (), SPEC), budget(200, 25))
    depths = []
    for gm in out:
        depth = 0
        while gm.fields["next"] is not None:
            gm = gm.fields["next"].value
            depth += 1
        depths.append(depth)
    assert max(depths) >= 2 and 0 in depths


def test_sizes_bound_computed_lengths():
    small = load_source(
        """spec small

model M
  observe xs: list<u8>
  observe n: i8
  invariant n_is_len: n == len(xs)
"""
    )
    assert residual_invariants("M", small) == []
    assert [c.id for c in residual_invariants("M", small, Sizes(max_list=200))] == ["M.n_is_len"]


def test_length_constraints_need_an_earlier_field():
    spec = load_source(
        """spec order

model Late
  observe rows: list<list<u8>>
  observe width: list<bool>
  invariant w: all(r in rows: len(r) == len(width))
"""
    )
    assert [c.id for c in residual_invariants("Late", spec)] == ["Late.w"]
    out = draws(model_strategy("Late", (), spec), budget(50, 20))
    assert all(set(gm.fields) == {"rows", "width"} for gm in out)


def test_large_frames_fit_the_choice_budget():
    from .sampling import choice_bytes

    big = Sizes(max_list=16, max_inner=8)
    assert choice_bytes(model_strategy("Frame", (), FRAMES, big), budget(100, 20)) < 8192 // 2
