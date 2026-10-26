"""spectest.shrink: the deterministic pass after Hypothesis's shrinking."""

from pathlib import Path

from spectest import shrink
from spectest.generate import DEFAULT, GeneratedModel
from spectest.lang import load
from spectest.types import (
    BYTES,
    STRING,
    FixedIntT,
    FloatT,
    ListT,
    ModelT,
    OptionT,
    TupleT,
)
from spectest.values import FloatValue, Some

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
FRAMES = load(EXAMPLES / "frames" / "frames.spec")
FRAME = ModelT("Frame")
I32, I64, U8 = FixedIntT(32, True), FixedIntT(64, True), FixedIntT(8, False)
F64 = FloatT("f64")


def minimal(value, t, fails, spec=None, **kw):
    calls = []

    def counted(args):
        calls.append(args)
        return fails(args["v"])

    out = shrink.minimize({"v": value}, {"v": t}, counted, spec, **kw)["v"]
    return out, len(calls)


def test_bytes_reach_the_shortest_failing_prefix_and_zero_bytes():
    def fails(b):
        return len(b) > 4 and len(b) % 4 == 0

    for start in (b"\x80" + b"0" * 15, b"\xc2\x80\xc2\x80\xf0\x90\x80\x80", bytes(16)):
        assert minimal(start, BYTES, fails)[0] == bytes(8)


def test_bytes_keep_what_the_failure_needs():
    def fails(b):
        return len(b) == 8 and any(b[4:])

    out, _ = minimal(b"\xf0\x90\x80\x80\xf0\x90\x80\x80", BYTES, fails)
    assert out == bytes(7) + b"\x01"


def test_strings_and_lists_shrink_to_simple_elements():
    assert minimal("éx\U0001f600yz", STRING, lambda s: len(s) >= 3)[0] == "000"
    out, _ = minimal((5, -7, 1000, 3), ListT(I64), lambda xs: len(xs) >= 2 and xs[-1] < 0)
    assert out == (0, -1)
    pairs = ((3, "ab"), (3, "c"), (1, ""))
    out, _ = minimal(
        pairs, ListT(TupleT((I64, STRING))), lambda ps: len(ps) > 1 and ps[0][1] != ps[-1][1]
    )
    assert out == ((0, ""), (0, "0"))


def test_ints_and_floats():
    assert minimal(-2, I64, lambda v: v < 0)[0] == -1
    assert minimal(2**31, I64, lambda v: v > 2**31 - 1)[0] == 2**31
    assert minimal(-(2**31) - 1, I64, lambda v: v < -(2**31))[0] == -(2**31) - 1
    nan = FloatValue("f64", 0x7FF0000000000001)
    out, _ = minimal(nan, F64, lambda v: v.bits & 0x7FF0000000000000 == 0x7FF0000000000000)
    assert out == FloatValue("f64", 0x7FF8000000000000)
    assert minimal(Some(7), OptionT(U8), lambda o: True)[0] is None


def test_a_default_is_tried_first():
    out = shrink.minimize(
        {"how": "all"}, {"how": STRING}, lambda a: True, None, defaults={"how"}
    )
    assert out == {"how": DEFAULT}


def test_the_budget_bounds_the_calls():
    out, calls = minimal(tuple(range(1, 60)), ListT(I64), lambda xs: len(xs) > 40, budget=10)
    assert calls == 10 and len(out) > 40


def frame(columns, rows):
    return GeneratedModel(
        "Frame", (), {"columns": tuple(columns), "rows": tuple(map(tuple, rows)), "nrows": len(rows)}
    )


NAN, ZERO = Some(FloatValue("f64", 0x7FF8000000000000)), Some(FloatValue("f64", 0))


def test_a_model_column_goes_with_its_cells():
    start = frame(["", "0", "1", "00"], [[None, None, ZERO, NAN]])

    def fails(gm):
        return any(c == NAN for r in gm.fields["rows"] for c in r)

    out, _ = minimal(start, FRAME, fails, FRAMES)
    assert out.fields == {"columns": ("",), "rows": ((NAN,),), "nrows": 1}


def test_a_model_keeps_its_invariants():
    start = frame(["a", "b"], [[None, ZERO], [ZERO, None], [None, None]])

    def fails(gm):
        rows = gm.fields["rows"]
        assert len(set(gm.fields["columns"])) == len(gm.fields["columns"])
        assert all(len(r) == len(gm.fields["columns"]) for r in rows)
        assert gm.fields["nrows"] == len(rows)
        return len(gm.fields["columns"]) == 2

    out, _ = minimal(start, FRAME, fails, FRAMES)
    assert out.fields == {"columns": ("", "0"), "rows": (), "nrows": 0}


def test_model_columns_go_all_at_once_when_one_at_a_time_passes():
    start = frame(["", "0"], [[None, ZERO]])

    def fails(gm):
        # dropna ignoring how="all": a row with a value but a null is dropped, and a row
        # without cells is kept; one column alone passes either way.
        rows = gm.fields["rows"]
        return any(None in r and any(c is not None for c in r) or not r for r in rows)

    out, _ = minimal(start, FRAME, fails, FRAMES)
    assert out.fields == {"columns": (), "rows": ((),), "nrows": 1}
