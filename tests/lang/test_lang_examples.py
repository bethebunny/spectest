"""The example specs are the acceptance corpus of the front end."""

import functools
import re
from pathlib import Path

import pytest

from spectest import ast
from spectest.lang import Resolution, Spec, load
from spectest.lang.checker import POISON
from spectest.types import (
    BOOL,
    QERR,
    AnyT,
    FloatT,
    ListT,
    ModelT,
    OptionT,
    SetT,
    TypeVarT,
)

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = sorted((ROOT / "examples").glob("*/*.spec"))
F64 = FloatT("f64")

CLAUSE_LINE = re.compile(
    r"(requires|ensures|relates|invariant|aggregate|raises|may_raise|modifies"
    r"|unspecified|impl_defined|perf)\b\s*(?:(\w+)\s*:)?"
)
DECL_LINE = re.compile(r"(fn|model|interface|new|method)\s+(\w+)")


def ids_from_text(path: Path) -> list[str]:
    """Clause IDs read off a spec's lines, by the rule of docs/language.md: a clause
    is ``<decl>.<label>``, or ``<decl>#<n>`` for the n-th clause of its declaration."""
    out: list[str] = []
    owner, member, count = "", "", 0
    for line in path.read_text().splitlines():
        text = line.split("#", 1)[0].strip()
        if decl := DECL_LINE.match(text):
            kind, name = decl.groups()
            if kind in ("new", "method"):
                member = f"{owner}.{name}"
            else:
                owner = member = name
            count = 0
        elif clause := CLAUSE_LINE.match(text):
            count += 1
            label = clause.group(2)
            out.append(f"{member}.{label}" if label else f"{member}#{count}")
    return out


@functools.cache
def loaded(path: Path) -> Spec:
    """The checked spec of an example file, loaded once for the tests that only read it."""
    return load(path)


@pytest.fixture(scope="module")
def specs() -> dict[str, Spec]:
    return {p.stem: loaded(p) for p in EXAMPLES}


def test_corpus_is_present():
    assert {p.stem for p in EXAMPLES} >= {"binary", "deque", "frames", "libm", "explore", "sorting"}


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda p: p.name)
def test_example_loads(path: Path):
    spec = load(path)
    assert spec.clause_ids
    assert not [w for w in spec.warnings if w.severity == "error"]


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda p: p.name)
def test_every_expression_is_typed(path: Path):
    spec = loaded(path)
    for node in ast.walk(spec.file):
        if isinstance(node, ast.Expr):
            assert node.ty is not None and node.ty != POISON, (node, node.span)
            namespace = isinstance(node, ast.Name) and node.id in ("mp", "cr")
            assert namespace or not isinstance(node.ty, AnyT), (node, node.span)


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda p: p.name)
def test_every_name_call_and_attribute_is_resolved(path: Path):
    spec = loaded(path)
    bases = {
        id(n.value)
        for n in ast.walk(spec.file)
        if isinstance(n, ast.Attribute)
        and spec.resolution.get(n, Resolution("", "")).kind in ("type_const", "set_ctor", "prelude")
    }
    for node in ast.walk(spec.file):
        if isinstance(node, (ast.Name, ast.Call, ast.Attribute)):
            assert node in spec.resolution or id(node) in bases, (node, node.span)


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda p: p.name)
def test_every_callable_has_a_signature_and_owner(path: Path):
    spec = loaded(path)
    for node in ast.walk(spec.file):
        if isinstance(node, (ast.FnDecl, ast.CtorDecl, ast.MethodDecl, ast.Observe)):
            assert node in spec.signature
        if isinstance(node, ast.Clause):
            assert node.id and spec.clause_ids[node.id] is node
            assert spec.owner[node] is not None


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda p: p.name)
def test_clause_ids_follow_the_text(path: Path):
    spec = loaded(path)
    assert list(spec.clause_ids) == ids_from_text(path)
    assert not set(spec.clause_ids) & set(spec.decl_ids.values())


def test_clause_ids(specs: dict[str, Spec]):
    assert list(specs["libm"].clause_ids) == [
        "cos.accurate", "cos.bounded", "cos.even", "cos#4",
        "cos32.accurate", "cos32.even", "cos32#3",
        "cos16.accurate", "cos16#2",
        "sqrt#1", "sqrt.correctly_rounded", "sqrt.signed_zero", "sqrt.monotone", "sqrt#5",
    ]  # fmt: skip
    deque = list(specs["deque"].clause_ids)
    assert deque == ids_from_text(ROOT / "examples" / "deque" / "deque.spec")
    assert deque[:5] == [
        "Deque.within_bound",
        "Deque.empty.items", "Deque.empty.unbounded",
        "Deque.bounded.items", "Deque.bounded.maxlen",
    ]  # fmt: skip
    for method in ("append", "appendleft", "pop", "popleft", "rotate"):
        assert f"Deque.{method}.maxlen" in deque
    assert not set(deque) & set(specs["deque"].decl_ids.values())
    assert list(specs["frames"].clause_ids) == [
        "Frame.unique_columns", "Frame.rectangular", "Frame.row_count",
        "dropna.columns", "dropna.rows", "dropna.fresh", "dropna#4",
        "fillna#1", "fillna.columns", "fillna.rows", "fillna.fresh", "fillna#5",
        "select#1", "select#2", "select.columns", "select.rows", "select#5",
    ]  # fmt: skip
    assert list(specs["binary"].clause_ids) == [
        "pack_i32#1", "pack_i32.length", "pack_i32.little_endian", "pack_i32.roundtrip",
        "unpack_i32#1", "unpack_i32.value",
        "utf8_encode.valid", "utf8_encode.length", "utf8_encode.roundtrip",
        "utf8_decode#1", "utf8_decode.roundtrip",
    ]  # fmt: skip
    assert list(specs["sorting"].clause_ids) == [
        "sort.permutation", "sort.ordered",
        "sort_by_first.permutation", "sort_by_first.ordered", "sort_by_first.stable",
        "sort_in_place#1", "sort_in_place.permutation", "sort_in_place.ordered",
    ]  # fmt: skip
    assert list(specs["explore"].clause_ids) == ["cos16.correctly_rounded", "cos32.worst_small"]


def test_libm(specs: dict[str, Spec]):
    spec = specs["libm"]
    cos = spec.fns["cos"]
    (part,) = cos.partitions
    assert [c.name for c in part.classes] == [
        "nan", "inf", "zero", "subnormal", "small", "moderate", "huge",
    ]  # fmt: skip
    assert all(c.expr.ty == SetT(F64) for c in part.classes)
    assert spec.errors == {"DomainError"}
    even = spec.clause_ids["cos.even"]
    calls = [n for n in ast.walk(even.expr) if isinstance(n, ast.Call)]
    assert Resolution("spec_fn", "cos", cos) in [spec.resolution[c] for c in calls]
    (planned,) = [c for c in calls if spec.resolution[c].kind == "spec_fn"]
    assert planned.args[0].ty == F64
    monotone = spec.clause_ids["sqrt.monotone"]
    assert monotone.text == (
        "relates monotone: is_finite(x) and x > 0 and is_finite(next_up(x)) implies "
        "let y = sqrt(next_up(x)) in is_finite(result) and is_finite(y) and "
        "real(result) <= real(y)"
    )
    assert isinstance(monotone.expr, ast.Binary) and monotone.expr.op == "implies"
    assert isinstance(monotone.expr.right, ast.Let)
    accurate = spec.clause_ids["cos.accurate"].expr
    assert isinstance(accurate, ast.Binary) and accurate.left.ty == QERR
    assert accurate.left.args[1].ty == F64
    assert spec.resolution[accurate.left.args[1]] == Resolution("prelude", "cr.cos")
    rounded = spec.clause_ids["sqrt.correctly_rounded"]
    assert rounded.text == "ensures correctly_rounded: qe(result, cr.sqrt(x)) == 0"
    assert spec.resolution[spec.clause_ids["sqrt#1"]] == Resolution("error", "DomainError")


def test_explore(specs: dict[str, Spec]):
    spec = specs["explore"]
    cr = spec.clause_ids["cos16.correctly_rounded"]
    assert cr.kind == "aggregate"
    assert isinstance(cr.expr, ast.Binary) and cr.expr.op == "=="
    top = cr.expr.left
    assert isinstance(top, ast.Comprehension) and top.kind == "sum"
    assert top.iterable.ty == SetT(FloatT("f16")) and top.ty == QERR
    worst = spec.clause_ids["cos32.worst_small"].expr
    assert isinstance(worst, ast.Binary) and worst.op == "<="
    assert worst.left.kind == "max" and worst.left.iterable.ty == SetT(FloatT("f32"))


def test_binary(specs: dict[str, Spec]):
    spec = specs["binary"]
    pack = spec.fns["pack_i32"]
    assert [c.expr.ty for c in pack.partitions[0].classes] == [
        SetT(spec.signature[pack].params[0])
    ] * 3
    unpack = spec.fns["unpack_i32"]
    assert [c.expr.ty for c in unpack.partitions[0].classes] == [BOOL, BOOL]


def test_deque(specs: dict[str, Spec]):
    spec = specs["deque"]
    deque = spec.interfaces["Deque"]
    t = TypeVarT("T", "Eq")
    assert spec.tparams[deque] == {"T": t}
    pop = deque.methods[2]
    assert pop.name == "pop"
    assert spec.signature[pop].result == t
    items = spec.clause_ids["Deque.append.items"]
    assert "\n" not in items.text and "  " not in items.text
    assert spec.signature[deque.ctors[0]].result == ModelT("Deque", (t,), True)


def test_frames(specs: dict[str, Spec]):
    spec = specs["frames"]
    rows = spec.clause_ids["dropna.rows"].expr
    assert isinstance(rows, ast.Call)
    assert spec.resolution[rows] == Resolution("prelude", "eq")
    assert rows.args[1].ty == ListT(ListT(OptionT(F64)))
    assert [k for k, _ in rows.kwargs] == ["float"]


def test_sorting(specs: dict[str, Spec]):
    spec = specs["sorting"]
    sip = spec.fns["sort_in_place"]
    perm = spec.clause_ids["sort_in_place.permutation"].expr
    assert isinstance(perm, ast.Call)
    assert perm.args[0].ty == ListT(TypeVarT("T", "Ord"))
    assert spec.signature[sip].params == (ModelT("MutableList", (TypeVarT("T", "Ord"),)),)
