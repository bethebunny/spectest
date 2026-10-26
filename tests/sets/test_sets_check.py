import math
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from spectest import ast
from spectest.sets import (
    Diagnostic,
    SetError,
    aggregate_set,
    check_partitions,
    compile_partition,
    domain,
    named_set,
    param_type,
    partition_sets,
    requires_set,
)
from spectest.types import FixedIntT, FloatT, scalar_type

from .floats import f16_values, fv
from .syntax import read_file, read_fns

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
F16, F64, I64 = FloatT("f16"), FloatT("f64"), FixedIntT(64, True)


def fn(source):
    return read_fns(source).decls[0]


def errors(diags):
    return [d for d in diags if d.severity == "error"]


def warnings(diags):
    return [d for d in diags if d.severity == "warning"]


def assert_disjoint_and_complete(classes, target):
    union = target.codec.none
    for i, (_, a) in enumerate(classes):
        for _, b in classes[:i]:
            assert (a & b).size == 0
        union = union | a
    assert union == target


# ---------------------------------------------------------------------------
# Acceptance: the example specs


def test_libm_partitions_are_disjoint_and_complete():
    spec = read_file(EXAMPLES / "libm" / "libm.spec")
    fns = {d.name: d for d in spec.decls}
    for name, elem in (("cos", F64), ("cos32", FloatT("f32")), ("sqrt", F64)):
        classes = partition_sets(fns[name], "x")
        assert len(classes) in (6, 7)
        assert all(s.size for _, s in classes)
        assert_disjoint_and_complete(classes, domain(elem))
    assert check_partitions(spec) == []


def test_libm_class_sizes():
    spec = read_file(EXAMPLES / "libm" / "libm.spec")
    sqrt = dict(partition_sets(spec.decls[3], "x"))
    assert sqrt["zero"].size == 2
    assert sqrt["inf"].size == 1
    assert list(sqrt["inf"]) == [fv("f64", float("inf"))]
    cos = dict(partition_sets(spec.decls[0], "x"))
    assert cos["zero"].size == 2 and cos["inf"].size == 2
    assert cos["small"].size == 2 * ((1022 - 26) << 52) + 1
    assert fv("f64", -(2.0**-26)) in cos["small"] and fv("f64", 2.0**-26) in cos["moderate"]


def test_binary_partitions():
    spec = read_file(EXAMPLES / "binary" / "binary.spec")
    pack = next(d for d in spec.decls if d.name == "pack_i32")
    classes = partition_sets(pack, "x")
    assert [name for name, _ in classes] == ["in_range", "too_small", "too_large"]
    assert_disjoint_and_complete(classes, domain(I64))
    assert dict(classes)["in_range"].size == 1 << 32
    unpack = next(d for d in spec.decls if d.name == "unpack_i32")
    assert partition_sets(unpack, "b") is None
    assert check_partitions(spec) == []


@pytest.mark.parametrize("path", sorted(EXAMPLES.glob("*/*.spec")), ids=lambda p: p.name)
def test_every_example_checks_clean(path):
    assert check_partitions(read_file(path)) == []


def test_checking_the_examples_is_fast():
    sources = [
        read_file(EXAMPLES / "libm" / "libm.spec"),
        read_file(EXAMPLES / "binary" / "binary.spec"),
    ]
    start = time.perf_counter()
    for spec in sources:
        assert check_partitions(spec) == []
    assert time.perf_counter() - start < 0.5


@pytest.mark.parametrize("path", sorted(EXAMPLES.glob("*/*.spec")), ids=lambda p: p.name)
def test_examples_through_the_real_parser(path):
    parser = pytest.importorskip("spectest.lang.parser")
    errors_ = pytest.importorskip("spectest.lang.errors")
    try:
        spec = parser.parse(path.read_text(), str(path))
    except errors_.SpecSyntaxError as err:
        pytest.skip(f"parser not ready: {err}")
    assert check_partitions(spec) == []
    mine = read_file(path)
    for decl in (d for d in spec.decls if isinstance(d, ast.FnDecl)):
        twin = next(d for d in mine.decls if d.name == decl.name)
        for part in decl.partitions:
            got = partition_sets(decl, part.param)
            want = partition_sets(twin, part.param)
            assert (got is None) == (want is None)
            if got is not None:
                assert got == want


def test_the_loader_reports_broken_partitions():
    loader = pytest.importorskip("spectest.lang.loader")
    errors_ = pytest.importorskip("spectest.lang.errors")
    source = """spec broken

fn sqrt(x: f64) -> f64
  partition x
    nan       = f64.nan
    negative  = f64.negative - f64.nan
    zero      = f64.zero
    rest      = f64.positive - f64.nan - f64.zero
"""
    with pytest.raises(errors_.SpecCheckError) as info:
        loader.load_source(source)
    text = str(info.value)
    assert "classes negative and zero overlap on 1 value" in text
    assert "x = -0.0 (0x8000000000000000)" in text


def test_aggregate_sets_compile_and_are_checked():
    lang = pytest.importorskip("spectest.lang")
    spec = lang.load_source(
        "spec t\nfn f(x: f16) -> f16\n"
        "  aggregate a: sum(v in f16.finite - f16.zero: qe(f(v), cr.cos(v))) == 0\n"
        "  aggregate b: max(n in range(0, 3): n) <= 3\n"
        "  aggregate c: all(v in f16.nan & f16.positive & f16.negative: is_nan(f(v)))\n"
    )
    a, b, c = spec.fns["f"].clauses
    s, elem = aggregate_set(a, spec.aliases)
    assert elem == F16 and s == named_set(F16, "finite") - named_set(F16, "zero")
    assert s.size == 2 * 0x7C00 - 2
    assert aggregate_set(b) is None
    empty, _ = aggregate_set(c)
    assert not empty
    diags = check_partitions(spec)
    assert [(d.severity, d.message) for d in diags] == [
        ("warning", "f: aggregate c: the set it ranges over is empty"),
    ]
    with pytest.raises(lang.SpecCheckError, match="f: aggregate a: f16.range bound 0.1"):
        lang.load_source(
            "spec t\nfn f(x: f16) -> f16\n"
            "  aggregate a: sum(v in f16.range(0, 0.1): qe(f(v), cr.cos(v))) == 0\n"
        )


# ---------------------------------------------------------------------------
# Broken partitions


COS = """\
fn cos(x: f64) -> f64
  partition x
    nan       = f64.nan
    inf       = f64.inf
{zero}
    subnormal = f64.subnormal
    small     = {small}
    moderate  = f64.range(-0x1p20, 0x1p20) & f64.normal - small
    huge      = f64.normal - small - moderate
"""


def cos(zero="    zero      = f64.zero", small="f64.range(-0x1p-26, 0x1p-26) & f64.normal"):
    return read_fns(COS.format(zero=zero, small=small))


def test_missing_class_is_reported_with_an_example():
    spec = cos(zero="")
    [diag] = check_partitions(spec)
    assert diag.severity == "error"
    assert diag.message == (
        "partition x of cos does not cover every f64: 2 values in no class, "
        "e.g. x = 0.0 (0x0000000000000000)"
    )
    assert diag.span == spec.decls[0].partitions[0].span


def test_overlaps_are_reported_pairwise():
    spec = cos(small="f64.range(-0x1p-26, 0x1p-26)")
    diags = check_partitions(spec)
    assert [d.message for d in diags] == [
        (
            "partition x of cos: classes zero and small overlap on 2 values, "
            "e.g. x = 0.0 (0x0000000000000000)"
        ),
        (
            "partition x of cos: classes subnormal and small overlap on about 2^53.0 values, "
            "e.g. x = 5e-324 (0x0000000000000001)"
        ),
    ]
    small = spec.decls[0].partitions[0].classes[4]
    assert all(d.span == small.span for d in diags)


def test_sqrt_forgetting_negative_zero():
    spec = read_fns(
        """\
fn sqrt(x: f64) -> f64
  partition x
    nan       = f64.nan
    negative  = f64.negative - f64.nan
    zero      = f64.zero
    subnormal = f64.subnormal & f64.positive
    normal    = f64.normal & f64.positive
    inf       = f64.inf & f64.positive
"""
    )
    [diag] = check_partitions(spec)
    assert diag.message == (
        "partition x of sqrt: classes negative and zero overlap on 1 value, "
        "e.g. x = -0.0 (0x8000000000000000)"
    )


def test_pack_i32_off_by_one():
    spec = read_fns(
        """\
fn pack_i32(x: i64) -> bytes
  partition x
    in_range  = i64.range(i32.min, i32.max)
    too_small = i64.range(none, i32.min)
    too_large = i64.range(i32.max + 1, none)
"""
    )
    [diag] = check_partitions(spec)
    assert diag.message == (
        "partition x of pack_i32 does not cover every i64: 1 value in no class, e.g. x = 2147483647"
    )


def test_type_mismatch_is_reported_once():
    spec = read_fns(
        """\
fn cos(x: f64) -> f64
  partition x
    nan   = f32.nan
    rest  = f64.all - nan
"""
    )
    [diag] = check_partitions(spec)
    assert diag.message == (
        "partition x of cos: class nan: f32.nan is a set of f32 values, "
        "but this partition is of f64"
    )
    cls = spec.decls[0].partitions[0].classes[0]
    assert diag.span == cls.expr.span


def test_bad_bound_points_at_the_bound():
    spec = read_fns(
        """\
fn f(x: f32) -> f32
  partition x
    low  = f32.range(none, 0.1)
    high = f32.range(0.1, none)
    nan  = f32.nan
"""
    )
    diags = check_partitions(spec)
    assert [d.message for d in diags] == [
        "partition x of f: class low: f32.range bound 0.1 is not exactly representable in f32",
        "partition x of f: class high: f32.range bound 0.1 is not exactly representable in f32",
    ]
    assert diags[0].span.line == 3 and diags[0].span.col == len("    low  = f32.range(none, ") + 1


def test_duplicate_and_empty_classes():
    spec = read_fns(
        """\
fn f(x: u8) -> u8
  partition x
    low  = u8.range(0, 128)
    low  = u8.range(128, none)
"""
    )
    [diag] = check_partitions(spec)
    assert diag.message == "partition x of f: class low is defined twice"
    spec = read_fns(
        """\
fn f(x: u8) -> u8
  partition x
    all   = u8.all
    none_ = u8.range(5, 5)
"""
    )
    [diag] = check_partitions(spec)
    assert diag.severity == "warning"
    assert diag.message == "partition x of f: class none_ is empty"


def test_predicate_class_on_a_fixed_width_parameter():
    spec = read_fns(
        """\
fn f(x: f64) -> f64
  partition x
    big   = x > 1
    other = x <= 1
"""
    )
    diags = check_partitions(spec)
    assert len(diags) == 2
    assert all("expected a set expression, got the operator" in d.message for d in diags)


def test_non_fixed_width_and_generic_partitions_are_skipped():
    spec = read_fns(
        """\
fn sort<T: Ord>(xs: list<T>) -> list<T>
  partition xs
    empty = len(xs) == 0
    other = len(xs) > 0

fn ident<T>(x: T) -> T
  partition x
    small = x < 3
"""
    )
    assert check_partitions(spec) == []
    assert param_type(spec.decls[1], "x", {"T"}) is None
    assert param_type(spec.decls[1], "x") is None


def test_diagnostic_str():
    d = Diagnostic(ast.Span(3, 5, 3, 9), "bad", "warning")
    assert str(d) == "3:5: warning: bad"


def test_compile_partition_raises_with_class_name():
    spec = cos(small="f64.range(0.1, 1)")
    with pytest.raises(SetError, match="class small: f64.range bound 0.1"):
        compile_partition(spec.decls[0].partitions[0], F64)


# ---------------------------------------------------------------------------
# requires narrows the target


def test_requires_not_nan_lets_the_partition_skip_nan():
    spec = read_fns(
        """\
fn fill(value: f64) -> f64
  requires not is_nan(value)
  partition value
    zero   = f64.zero
    finite = f64.finite - f64.zero
    inf    = f64.inf
"""
    )
    assert check_partitions(spec) == []


def test_requires_coverage_error_mentions_requires():
    spec = read_fns(
        """\
fn f(x: f64) -> f64
  requires x >= 0
  partition x
    pos = f64.positive - f64.zero - f64.nan
"""
    )
    [diag] = check_partitions(spec)
    assert diag.message == (
        "partition x of f does not cover the values requires admits: 2 values in no class, "
        "e.g. x = 0.0 (0x0000000000000000)"
    )


def test_class_outside_requires_is_a_warning():
    spec = read_fns(
        """\
fn f(x: f64) -> f64
  requires x >= 0
  partition x
    everything = f64.all
"""
    )
    [diag] = check_partitions(spec)
    assert diag.severity == "warning"
    assert diag.message.startswith("partition x of f: class everything has about 2^63.0 values")
    assert diag.message.endswith("that requires rejects, e.g. x = -1.0 (0xbff0000000000000)")


def test_requires_fits_on_ints():
    spec = read_fns(
        """\
fn g(n: i64) -> i32
  requires fits<i32>(n)
  partition n
    negative = i64.range(i32.min, 0)
    other    = i64.range(0, i32.max + 1)
"""
    )
    assert check_partitions(spec) == []


def test_requires_conjuncts_on_other_parameters_are_ignored():
    spec = read_fns(
        """\
fn h(x: u8, xs: list<u8>) -> u8
  requires x > 0 and len(xs) > 0
  requires len(xs) < 10
  partition x
    low  = u8.range(1, 128)
    high = u8.range(128, none)
"""
    )
    assert check_partitions(spec) == []


def test_requires_not_about_the_parameter_targets_the_whole_type():
    spec = read_fns(
        """\
fn h(x: u8, y: u8) -> u8
  requires x > 0 or y > 0
  partition x
    low  = u8.range(1, 128)
    high = u8.range(128, none)
"""
    )
    [diag] = check_partitions(spec)
    assert "does not cover every u8: 1 value in no class, e.g. x = 0" in diag.message


def requires_of(text, param, tname):
    decl = fn(f"fn f({param}: {tname}) -> {tname}\n  requires {text}\n")
    return requires_set(decl, param, scalar_type(tname))


F16_VALUES = f16_values()


def real(v):
    if math.isnan(v):
        raise ArithmeticError("NaN promoted to real")
    return v


def f16_set(pred):
    out = set()
    for bits, v in enumerate(F16_VALUES):
        try:
            if pred(v, math):
                out.add(bits)
        except ArithmeticError:
            pass
    return out


@pytest.mark.parametrize(
    ("text", "pred"),
    [
        ("x < 1", lambda v, m: real(v) < 1),
        ("not (x < 1)", lambda v, m: not (real(v) < 1)),
        ("x <= 0", lambda v, m: real(v) <= 0),
        ("x > 0", lambda v, m: real(v) > 0),
        ("0 < x", lambda v, m: 0 < real(v)),
        ("x >= -0.5", lambda v, m: real(v) >= -0.5),
        ("x < 0.1", lambda v, m: real(v) < 0.1),
        ("is_nan(x) or x > 0", lambda v, m: m.isnan(v) or real(v) > 0),
        ("x > 0 or is_nan(x)", lambda v, m: real(v) > 0 or m.isnan(v)),
        ("is_finite(x) implies x > 1", lambda v, m: not m.isfinite(v) or real(v) > 1),
        ("if is_nan(x) then true else x > 1", lambda v, m: True if m.isnan(v) else real(v) > 1),
        ("signbit(x) and not is_zero(x)", lambda v, m: m.copysign(1, v) < 0 and v != 0),
        ("is_inf(x) or is_subnormal(x)", lambda v, m: m.isinf(v) or (v != 0 and abs(v) < 2**-14)),
        ("real(x) <= 2", lambda v, m: real(v) <= 2),
        ("true", lambda v, m: True),
    ],
)
def test_requires_sets_follow_evaluation_on_every_f16(text, pred):
    s = requires_of(text, "x", "f16")
    assert set(s.storage) == f16_set(pred)


@pytest.mark.parametrize(
    ("text", "values"),
    [
        ("n != 0", set(range(-128, 128)) - {0}),
        ("n in [1, 2, 3]", {1, 2, 3}),
        ("fits<u8>(n)", set(range(128))),
        ("n >= 2.5", set(range(3, 128))),
        ("n < 2.5", set(range(-128, 3))),
        ("n == -128 or n == 127", {-128, 127}),
        ("n > i8.max - 3", {125, 126, 127}),
    ],
)
def test_requires_sets_on_ints(text, values):
    assert set(requires_of(text, "n", "i8")) == values


def test_requires_that_is_not_a_set():
    assert requires_of("is_prime(n)", "n", "i8") is None
    assert requires_of("len(xs) > 0", "n", "i8") is None
    assert requires_of("x == 1", "x", "f64") is None


def test_bool_parameter_partitions_and_requires():
    spec = read_fns(
        """\
fn b(flag: bool) -> bool
  requires flag
  partition flag
    yes = {true}
"""
    )
    assert check_partitions(spec) == []


# ---------------------------------------------------------------------------
# Spec objects from the checker


def test_spec_with_fns_and_interfaces():
    fns = read_fns(
        """\
fn cos(x: f64) -> f64
  partition x
    finite = f64.finite
"""
    )
    method = read_fns(
        """\
fn push(x: i32) -> unit
  partition x
    neg = i32.negative
    pos = i32.range(1, none)
"""
    ).decls[0]
    method_decl = ast.MethodDecl("push", method.params, None, method.partitions, method.clauses)
    iface = ast.InterfaceDecl("Queue", [], [], [], [method_decl], [])
    spec = SimpleNamespace(fns={"cos": fns.decls[0]}, interfaces={"Queue": iface}, aliases={})
    diags = check_partitions(spec)
    assert [d.message.split(":")[0] for d in diags] == [
        "partition x of cos does not cover every f64",
        "partition x of Queue.push does not cover every i32",
    ]
    assert check_partitions(SimpleNamespace()) == []


def test_spec_aliases():
    decl = fn(
        """\
fn f(x: Angle) -> Angle
  partition x
    nan  = Angle.nan
    rest = f64.all - nan
"""
    )
    spec = SimpleNamespace(fns={"f": decl}, interfaces={}, aliases={"Angle": F64})
    assert check_partitions(spec) == []
    specfile = ast.SpecFile("s", [ast.AliasDecl("Angle", ast.TypeExpr("f64")), decl])
    assert check_partitions(specfile) == []
