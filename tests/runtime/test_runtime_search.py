"""The search: sizes, explicit examples, minimal counterexamples, shrunk spec errors and
the verdicts of clauses on an input where a raise was due."""

from __future__ import annotations

import math
import textwrap

import pytest

from spectest.generate import Sizes
from spectest.lang import load_source
from spectest.runtime.binding import (
    ConformanceError,
    InterfaceBinding,
    ModelBinding,
    conformance,
)
from spectest.runtime.plans import FunctionPlan
from spectest.runtime.runner import Runner, RunOptions, collect_items


def spec_of(source: str):
    return load_source(textwrap.dedent(source).lstrip("\n"), "t.spec")


def run_one(conf, name: str, runner: Runner | None = None):
    item = {it.name: it for it in collect_items(conf)}[name]
    (result,) = (runner or Runner()).run(item, f"t.py::conf::{name}", f"repro {name}")
    return result


# ---------------------------------------------------------------------------
# Sizes


LENGTH = """
spec t
fn count(xs: list<i64>) -> u64
  ensures short: result <= 16
"""


def test_default_lists_are_sometimes_long():
    conf = conformance(spec_of(LENGTH), impls={"count": len}, max_examples=300)
    result = run_one(conf, "count.short")
    assert result.outcome == "failed"
    assert result.counterexample.inputs == {"xs": "[" + ", ".join(["0"] * 17) + "]"}


@pytest.mark.slow
def test_sizes_option_bounds_the_lists():
    sizes = Sizes(max_list=16, long_share=0)
    conf = conformance(spec_of(LENGTH), impls={"count": len}, sizes=sizes, max_examples=300)
    assert conf.sizes == sizes
    assert run_one(conf, "count.short").outcome == "passed"
    small = conformance(spec_of(LENGTH), impls={"count": len}, sizes=Sizes(max_list=40))
    assert run_one(small, "count.short").outcome == "failed"


def test_sizes_must_be_sizes():
    with pytest.raises(ConformanceError, match="sizes must be a spectest.generate.Sizes"):
        conformance(spec_of(LENGTH), impls={"count": len}, sizes={"max_list": 3})


# ---------------------------------------------------------------------------
# Minimal counterexamples


UNPACK = """
spec t
fn unpack(b: bytes) -> bool
  ensures ok: result
"""


@pytest.mark.parametrize("seed", [0, 1, 2])
def test_bytes_counterexamples_are_minimal(seed):
    # False exactly at lengths 8, 12 and 16, like numpy.frombuffer(b, "<i4")[0].
    conf = conformance(
        spec_of(UNPACK),
        impls={"unpack": lambda b: not (len(b) > 4 and len(b) % 4 == 0)},
        max_examples=300,
    )
    result = run_one(conf, "unpack.ok", Runner(RunOptions(seed=seed)))
    assert result.counterexample.inputs == {"b": 'b"' + "\\x00" * 8 + '"'}


WRAP = """
spec t
model Box
  observe v: i64
  invariant nonnegative: v >= 0
fn wrap(n: i64) -> Box
"""


def test_negative_ints_shrink_to_minus_one():
    box = ModelBinding(observers={"v": lambda b: b["v"]})
    conf = conformance(spec_of(WRAP), impls={"wrap": lambda n: {"v": n}}, models={"Box": box})
    result = run_one(conf, "wrap:Box.nonnegative")
    assert result.counterexample.inputs == {"n": "-1"}


FRAMES = """
spec t
model Frame
  observe columns: list<string>
  observe rows: list<list<option<f64>>>
  observe nrows: u64
  invariant unique_columns: distinct(columns)
  invariant rectangular: all(r in rows: len(r) == len(columns))
  invariant row_count: nrows == len(rows)

fn dropna(df: Frame, how: "any" | "all" = "any") -> Frame
  ensures rows: eq(result.rows,
                   filter(r in df.rows: if how == "any" then all(c in r: is_some(c))
                                        else exists(c in r: is_some(c))),
                   float="bits")

fn fillna(df: Frame, value: f64) -> Frame
  requires not is_nan(value)
  ensures rows: eq(result.rows,
                   map(r in df.rows: map(c in r: if is_none(c) then some(value) else c)),
                   float="bits")
"""


def frame(fields):
    return {"columns": list(fields["columns"]), "rows": [list(r) for r in fields["rows"]]}


FRAME = ModelBinding(
    observers={
        "columns": lambda f: f["columns"],
        "rows": lambda f: f["rows"],
        "nrows": lambda f: len(f["rows"]),
    },
    concretize=frame,
)


def dropna_ignores_how(df, how="any"):
    return {"columns": df["columns"], "rows": [r for r in df["rows"] if None not in r]}


def fillna_fills_nan(df, value):
    rows = [[value if c is None or math.isnan(c) else c for c in r] for r in df["rows"]]
    return {"columns": df["columns"], "rows": rows}


@pytest.mark.slow
@pytest.mark.parametrize("seed", [0, 1])
def test_model_columns_shrink_with_their_cells(seed):
    conf = conformance(
        spec_of(FRAMES),
        impls={"dropna": dropna_ignores_how, "fillna": fillna_fills_nan},
        models={"Frame": FRAME},
    )
    runner = Runner(RunOptions(seed=seed))
    fillna = run_one(conf, "fillna.rows", runner).counterexample
    assert fillna.inputs == {
        "df": 'Frame { columns: [""], rows: [[some(nan)]], nrows: 1 }',
        "value": "0.0 (0x0000000000000000)",
    }
    dropna = run_one(conf, "dropna.rows", runner).counterexample
    assert dropna.inputs == {"df": "Frame { columns: [], rows: [[]], nrows: 1 }", "how": '"all"'}


# ---------------------------------------------------------------------------
# Spec errors are shrunk


INDEX = """
spec t
fn total(xs: list<i64>) -> i64
  ensures past_the_end: len(xs) < 3 or xs[len(xs)] == result
"""


def test_spec_errors_are_reported_on_a_shrunk_input():
    conf = conformance(spec_of(INDEX), impls={"total": sum})
    result = run_one(conf, "total.past_the_end")
    assert result.outcome == "error"
    assert result.counts["spec_error"] > 0
    # One kind of error, reported once, on the smallest input that raises it.
    [error] = result.spec_errors
    assert error.startswith("index 3 is out of range for a list of length 3")
    assert error.endswith("example: xs = [0, 0, 0]")


# ---------------------------------------------------------------------------
# Clauses on an input where a raise was due


RAISE_DUE = """
spec t
error StructError
fn unpack(b: bytes) -> i32
  raises StructError when len(b) != 4
  ensures value: wrap<u32>(result) == le_uint(b)
  ensures sign: (result < 0) == (b[3] >= 128)
"""


def from_bytes(b: bytes) -> int:
    return int.from_bytes(b, "little", signed=True)


def test_a_clause_that_errors_where_a_raise_was_due_skips():
    conf = conformance(spec_of(RAISE_DUE), impls={"unpack": from_bytes})
    plan = FunctionPlan(conf, conf.spec.fns["unpack"])
    ex = plan.run({"b": b"\x80"})
    assert ex.verdicts["unpack#1"] == "fail"
    assert ex.verdicts["unpack.sign"] == "skip"
    assert ex.notes["unpack.sign"] == "raise due (unpack#1)"
    assert ex.verdicts["unpack.value"] == "fail"
    assert "note: unpack#1 required StructError on this input" in ex.notes["unpack.value"]
    four = plan.run({"b": b"\x00\x00\x00\x80"})
    assert four.verdicts["unpack.sign"] == "pass"
    assert four.verdicts["unpack.value"] == "pass"


def test_without_a_due_raise_an_evaluation_error_is_a_spec_error():
    source = RAISE_DUE.replace("raises StructError when len(b) != 4", "may_raise StructError")
    conf = conformance(spec_of(source), impls={"unpack": from_bytes})
    plan = FunctionPlan(conf, conf.spec.fns["unpack"])
    ex = plan.run({"b": b"\x80"})
    assert ex.verdicts["unpack.sign"] == "spec_error"
    assert "note:" not in ex.notes.get("unpack.value", "")


def test_the_raise_due_note_is_in_the_counterexample():
    conf = conformance(spec_of(RAISE_DUE), impls={"unpack": from_bytes})
    result = run_one(conf, "unpack.value")
    assert result.outcome == "failed"
    assert "note: unpack#1 required StructError on this input" in (
        result.counterexample.observation
    )
    sign = run_one(conf, "unpack.sign")
    assert sign.counts["spec_error"] == 0


# ---------------------------------------------------------------------------
# Explicit examples


MAGIC = """
spec t
fn echo(s: string) -> string
  ensures same: result == s
"""


def magic_echo(s: str) -> str:
    return "" if s == "*magic*" else s


def test_explicit_examples_run_before_the_search():
    conf = conformance(
        spec_of(MAGIC), impls={"echo": magic_echo}, examples={"echo": [{"s": "*magic*"}]}
    )
    result = run_one(conf, "echo.same")
    assert result.outcome == "failed"
    assert result.counterexample.inputs == {"s": '"*magic*"'}
    assert "explicit example" in result.counterexample.observation
    assert run_one(conf, "echo#type").outcome == "passed"
    plain = conformance(spec_of(MAGIC), impls={"echo": magic_echo})
    assert run_one(plain, "echo.same").outcome == "passed"


def test_explicit_model_examples_go_through_the_concretizer():
    built = []

    def concretize(fields):
        built.append(fields)
        return frame(fields)

    binding = ModelBinding(observers=FRAME.observers, concretize=concretize)
    conf = conformance(
        spec_of(FRAMES),
        impls={"fillna": fillna_fills_nan},
        models={"Frame": binding},
        examples={"fillna": [{"df": {"columns": ["a"], "rows": [[float("nan")]]}, "value": 1.0}]},
        max_examples=1,
    )
    result = run_one(conf, "fillna.rows")
    assert result.outcome == "failed"
    assert built[0] == {"columns": ["a"], "rows": [[built[0]["rows"][0][0]]], "nrows": 1}
    assert result.counterexample.inputs["df"].startswith('Frame { columns: ["a"]')


def test_explicit_examples_are_validated():
    with pytest.raises(ConformanceError) as info:
        conformance(
            spec_of(MAGIC),
            impls={"echo": magic_echo},
            examples={
                "echo": [{"s": 3}, {"t": "x"}, {}],
                "nope": [{"s": ""}],
            },
        )
    problems = "\n".join(info.value.problems)
    assert "examples['echo'][0]: s = 3" in problems
    assert "examples['echo'][1]: echo has no parameter t" in problems
    assert "examples['echo'][2]: s is missing" in problems
    assert "examples: 'nope' is not a bound function" in problems


BOX = """
spec t
interface Box
  observe value: string
  new make() -> Box
  method put(self, s: string)
    modifies self
    ensures stored: self.value == s
"""


class MagicBox:
    def __init__(self):
        self.value = ""

    def put(self, s):
        if s != "*magic*":
            self.value = s


@pytest.mark.slow
def test_explicit_examples_of_an_interface_member_are_drawn_by_its_steps():
    def results(**options):
        box = InterfaceBinding(constructors={"make": MagicBox})
        conf = conformance(spec_of(BOX), interfaces={"Box": box}, **options)
        (item,) = collect_items(conf)
        return {r.clause_id: r for r in Runner().run(item, "t.py::conf::Box", "repro")}

    assert results()["Box.put.stored"].outcome == "passed"
    found = results(examples={"Box.put": [{"s": "*magic*"}]})["Box.put.stored"]
    assert found.outcome == "failed"
    assert '"*magic*"' in "\n".join(found.counterexample.inputs.values())


def test_a_replayed_counterexample_is_minimized_and_stored_again(tmp_path):
    from spectest.runtime.store import CounterexampleStore

    conf = conformance(
        spec_of(UNPACK), impls={"unpack": lambda b: not (len(b) > 4 and len(b) % 4 == 0)}
    )
    store = CounterexampleStore(tmp_path)
    item_id = "t.py::conf::unpack.ok"
    store.save(conf.spec.hash, item_id, {"b": b"\xf0\x90\x80\x80" * 4})
    item = {it.name: it for it in collect_items(conf)}["unpack.ok"]
    (result,) = Runner(RunOptions(store=tmp_path)).run(item, item_id, "repro")
    assert result.replayed
    assert result.counterexample.inputs == {"b": 'b"' + "\\x00" * 8 + '"'}
    assert store.load(conf.spec.hash, item_id)[0] == {"b": bytes(8)}


SMALL = """
spec t
fn h(x: u8) -> u8
  ensures same: result == x
"""


def test_explicit_examples_join_the_exhaustive_pass():
    conf = conformance(
        spec_of(SMALL), impls={"h": lambda x: x if x != 7 else 8}, examples={"h": [{"x": 7}]}
    )
    result = run_one(conf, "h.same")
    assert result.mode == "exhaustive"
    assert result.counts["fail"] == 2 and result.counts["pass"] == 255
    assert result.counterexample.inputs == {"x": "7"}


BOXED = """
spec t
error Empty
model Box
  observe items: list<i64>
  invariant first_is_small: items[0] < 100
fn box(xs: list<i64>) -> Box
  raises Empty when len(xs) == 0
"""


def test_an_invariant_that_errors_where_a_raise_was_due_skips():
    binding = ModelBinding(observers={"items": lambda b: b})
    conf = conformance(spec_of(BOXED), impls={"box": list}, models={"Box": binding})
    plan = FunctionPlan(conf, conf.spec.fns["box"])
    ex = plan.run({"xs": ()})
    assert ex.verdicts["box#1"] == "fail"
    assert ex.verdicts["box:Box.first_is_small"] == "skip"
    assert ex.notes["box:Box.first_is_small"] == "raise due (box#1)"
    big = plan.run({"xs": (500,)})
    assert big.verdicts["box:Box.first_is_small"] == "fail"
    assert "note:" not in big.notes["box:Box.first_is_small"]
