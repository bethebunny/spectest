import math
from fractions import Fraction

import pytest
from bitpattern import IntSet
from budget import budget
from hypothesis import given, settings
from hypothesis import strategies as st

from spectest import ast
from spectest.sets import (
    LAYOUTS,
    SetError,
    codec_for,
    compile_set,
    domain,
    elem_type,
    float_range,
    named_set,
)
from spectest.types import BOOL, FixedIntT, FloatT
from spectest.values import FloatValue

from .floats import f16_values, fv, to_float
from .syntax import expr

F16, BF16, F32, F64 = FloatT("f16"), FloatT("bf16"), FloatT("f32"), FloatT("f64")
I8, I32, I64, U8, U32 = (
    FixedIntT(8, True),
    FixedIntT(32, True),
    FixedIntT(64, True),
    FixedIntT(8, False),
    FixedIntT(32, False),
)
NEG_ZERO = FloatValue("f64", 1 << 63)
POS_ZERO = FloatValue("f64", 0)


def compile_(text, elem, classes=None, **kwargs):
    return compile_set(expr(text), elem, classes, **kwargs)


def bits_of(s):
    return set(s.storage)


# ---------------------------------------------------------------------------
# Named sets


@pytest.mark.parametrize(
    ("fmt", "exp", "man"), [("f16", 5, 10), ("bf16", 8, 7), ("f32", 8, 23), ("f64", 11, 52)]
)
def test_float_named_set_sizes(fmt, exp, man):
    t = FloatT(fmt)
    payloads = (1 << man) - 1
    sizes = {
        name: compile_(f"{fmt}.{name}", t).size
        for name in ("nan", "inf", "zero", "subnormal", "normal")
    }
    assert sizes == {
        "nan": 2 * payloads,
        "inf": 2,
        "zero": 2,
        "subnormal": 2 * payloads,
        "normal": 2 * ((1 << exp) - 2) << man,
    }
    assert sum(sizes.values()) == 1 << (1 + exp + man)
    finite = compile_(f"{fmt}.finite", t)
    assert finite == compile_(f"{fmt}.zero | {fmt}.subnormal | {fmt}.normal", t)
    assert compile_(f"{fmt}.all", t).size == 1 << (1 + exp + man)


def test_positive_and_negative_are_by_sign_bit():
    positive, negative = compile_("f64.positive", F64), compile_("f64.negative", F64)
    assert positive.size == negative.size == 1 << 63
    assert POS_ZERO in positive and NEG_ZERO in negative
    assert fv("f64", math.nan) in positive
    assert fv("f64", -math.nan) in negative
    assert fv("f64", math.inf) in positive and fv("f64", -math.inf) in negative
    assert (positive & negative).size == 0
    assert positive | negative == domain(F64)


def test_named_sets_hold_the_right_values():
    assert NEG_ZERO in compile_("f64.zero", F64) and POS_ZERO in compile_("f64.zero", F64)
    assert fv("f64", 5e-324) in compile_("f64.subnormal", F64)
    assert fv("f64", 2.2250738585072014e-308) in compile_("f64.normal", F64)
    assert fv("f64", 2.2250738585072014e-308) not in compile_("f64.subnormal", F64)
    signaling = FloatValue("f64", 0x7FF0000000000001)
    assert signaling in compile_("f64.nan", F64)
    assert FloatValue("f64", 0x7FF0000000000000) not in compile_("f64.nan", F64)
    assert fv("f64", 1.0) not in compile_("f64.nan", F64)


def test_int_named_sets():
    assert compile_("i32.negative", I32).size == 1 << 31
    assert compile_("i32.positive", I32).size == 1 << 31
    assert 0 in compile_("i32.positive", I32) and -1 in compile_("i32.negative", I32)
    assert compile_("i8.zero", I8) == codec_for(I8).set([0])
    assert compile_("u32.negative", U32).size == 0
    assert compile_("u32.positive", U32) == domain(U32)
    assert compile_("i64.all", I64).size == 1 << 64


def test_bool_sets():
    assert list(compile_("{true}", BOOL)) == [True]
    assert compile_("bool.all", BOOL).size == 2
    assert compile_("bool.all - {false}", BOOL) == compile_("{true}", BOOL)


def test_elem_type_round_trips():
    for t in (F16, BF16, F32, F64, I8, I64, U8, BOOL):
        assert elem_type(domain(t)) == t


# ---------------------------------------------------------------------------
# Ranges


def test_range_around_zero_holds_both_zeros():
    s = compile_("f64.range(-1, 1)", F64)
    assert POS_ZERO in s and NEG_ZERO in s
    assert fv("f64", -1.0) in s and fv("f64", 1.0) not in s
    assert fv("f64", math.nan) not in s


def test_range_from_zero_holds_both_zeros():
    s = compile_("f64.range(0, 1)", F64)
    assert POS_ZERO in s and NEG_ZERO in s
    one = LAYOUTS["f64"].one
    assert s.size == one + 1
    assert fv("f64", -5e-324) not in s


def test_range_to_zero_holds_no_zero():
    s = compile_("f64.range(-1, 0)", F64)
    assert POS_ZERO not in s and NEG_ZERO not in s
    assert fv("f64", -1.0) in s and fv("f64", -5e-324) in s
    assert s.size == LAYOUTS["f64"].one


def test_ranges_never_hold_nan():
    nan = named_set(F64, "nan")
    for text in ("f64.range(none, none)", "f64.range(0, none)", "f64.range(none, 0)"):
        assert (compile_(text, F64) & nan).size == 0
    assert compile_("f64.range(none, none)", F64) == domain(F64) - nan


def test_open_ends_include_their_infinity():
    up, down = compile_("f64.range(0, none)", F64), compile_("f64.range(none, 0)", F64)
    assert fv("f64", math.inf) in up and fv("f64", -math.inf) not in up
    assert fv("f64", -math.inf) in down and fv("f64", math.inf) not in down
    assert fv("f64", math.inf) not in compile_("f64.range(0, f64.max)", F64)


def test_empty_and_inverted_ranges():
    assert compile_("f64.range(1, 1)", F64).size == 0
    assert compile_("f64.range(2, 1)", F64).size == 0
    assert compile_("i32.range(5, 5)", I32).size == 0
    assert compile_("i32.range(5, -5)", I32).size == 0


def test_range_with_type_bounds():
    s = compile_("f16.range(f16.min, f16.max)", F16)
    assert s.size == compile_("f16.finite", F16).size - 1
    assert fv("f16", -65504.0) in s and fv("f16", 65504.0) not in s


def test_range_of_subnormal_width():
    assert compile_("f64.range(0, 0x1p-1074)", F64) == named_set(F64, "zero")
    assert compile_("f64.range(-0x1p-1074, 0x1p-1074)", F64).size == 3


def test_libm_small_range():
    small = compile_("f64.range(-0x1p-26, 0x1p-26) & f64.normal", F64)
    assert fv("f64", 2**-26) not in small and fv("f64", -(2**-26)) in small
    assert fv("f64", 2**-27) in small and fv("f64", 2.2250738585072014e-308) in small
    assert POS_ZERO not in small and fv("f64", 5e-324) not in small


VALUES = f16_values()
F16_FINITE = sorted({v for v in VALUES if math.isfinite(v)})


@settings(max_examples=budget(60, 10), deadline=None)
@given(
    st.one_of(st.none(), st.sampled_from(F16_FINITE)),
    st.one_of(st.none(), st.sampled_from(F16_FINITE)),
)
def test_f16_range_matches_brute_force(lo, hi):
    s = float_range(F16, None if lo is None else Fraction(lo), None if hi is None else Fraction(hi))
    expected = [
        b
        for b, v in enumerate(VALUES)
        if not math.isnan(v) and (lo is None or lo <= v) and (hi is None or v < hi)
    ]
    assert s.storage == IntSet(expected, width=16)


def test_range_bounds_must_be_exact():
    for text, elem in (
        ("f64.range(0.1, 1)", F64),
        ("f16.range(0, 0x1p20)", F16),
        ("f32.range(0, 0x1p-150)", F32),
        ("f32.range(1/3, 1)", F32),
    ):
        with pytest.raises(SetError, match="not exactly representable"):
            compile_(text, elem)


def test_float_range_accepts_inexact_bounds_internally():
    s = float_range(F32, None, Fraction(1, 10))
    assert fv("f32", 0.1) not in s
    assert FloatValue("f32", fv("f32", 0.1).bits - 1) in s


def test_int_ranges():
    assert compile_("i8.range(-128, 128)", I8) == domain(I8)
    assert compile_("i8.range(none, 0)", I8) == named_set(I8, "negative")
    assert compile_("u8.range(0, 256)", U8) == domain(U8)
    assert compile_("i64.range(i32.min, i32.max + 1)", I64).size == 1 << 32
    assert compile_("i64.range(i32.max + 1, none)", I64).size == (1 << 63) - (1 << 31)
    with pytest.raises(SetError, match="outside i8"):
        compile_("i8.range(-129, 0)", I8)
    with pytest.raises(SetError, match="outside i8"):
        compile_("i8.range(0, 129)", I8)
    with pytest.raises(SetError, match="not an integer"):
        compile_("i32.range(0, 1.5)", I32)


@pytest.mark.parametrize("lo", [None, -128, -127, -1, 0, 1, 127, 128])
@pytest.mark.parametrize("hi", [None, -128, -1, 0, 1, 100, 128])
def test_i8_range_matches_brute_force(lo, hi):
    s = compile_set(
        ast.Call(
            ast.Attribute(ast.Name("i8"), "range"),
            [ast.NoneLit() if b is None else ast.Num(b, str(b)) for b in (lo, hi)],
        ),
        I8,
    )
    expected = {v for v in range(-128, 128) if (lo is None or lo <= v) and (hi is None or v < hi)}
    assert set(s) == expected


# ---------------------------------------------------------------------------
# Patterns, literals, constants


def test_patterns():
    assert compile_('f16.pattern("?111.11??.*.*")', F16) == compile_("f16.nan | f16.inf", F16)
    quiet = compile_('f64.pattern("?111.1111.1111.1*.*.*.*.*.*.*.*.*.*.*.*.*")', F64)
    assert quiet <= named_set(F64, "nan") and quiet.size == 1 << 52
    assert compile_('u8.pattern("1???.????")', U8).size == 128
    assert compile_('i8.pattern("1???.????")', I8) == named_set(I8, "negative")
    with pytest.raises(SetError, match="8 bits, not 64"):
        compile_('f64.pattern("0000.0000")', F64)
    with pytest.raises(SetError, match="pattern"):
        compile_('f64.pattern("xyz")', F64)


def test_set_literals():
    assert set(compile_("{1, 2, 3}", I32)) == {1, 2, 3}
    assert set(compile_("{i32.min, i32.max, -1}", I32)) == {-(2**31), 2**31 - 1, -1}
    s = compile_("{0.5, 1, -2, 0x1p-149}", F32)
    assert {to_float(v) for v in s} == {0.5, 1.0, -2.0, 2.0**-149}
    assert list(compile_("{0}", F64)) == [POS_ZERO]
    assert list(compile_("{f64.max}", F64)) == [FloatValue("f64", 0x7FEFFFFFFFFFFFFF)]
    assert list(compile_("{f64.min}", F64)) == [FloatValue("f64", 0xFFEFFFFFFFFFFFFF)]
    assert compile_("{}", I32).size == 0


def test_set_literal_errors():
    with pytest.raises(SetError, match="not exactly representable in f32"):
        compile_("{0.1}", F32)
    with pytest.raises(SetError, match="not a u8 value"):
        compile_("{300}", U8)
    with pytest.raises(SetError, match="not a i32 value"):
        compile_("{1.5}", I32)
    with pytest.raises(SetError, match="true and false"):
        compile_("{1}", BOOL)


def test_negative_zero_literal_is_rejected_with_a_hint():
    with pytest.raises(SetError, match=r"f64.zero & f64.negative"):
        compile_("{-0}", F64)
    with pytest.raises(SetError, match="-0"):
        compile_("{-0.0}", F64)


def test_constant_arithmetic():
    assert compile_("f64.range(-1/2, 2 * 0.25 + 0.5)", F64) == compile_("f64.range(-0.5, 1)", F64)
    assert compile_("i32.range(-(3 - 1), 2 * 3)", I32) == compile_("i32.range(-2, 6)", I32)
    assert compile_("i64.range(i32.min - 1, i32.min)", I64).size == 1
    with pytest.raises(SetError, match="division by zero"):
        compile_("f64.range(1/0, 2)", F64)


def test_set_algebra():
    a = compile_("f64.normal & f64.negative", F64)
    assert a.size == named_set(F64, "normal").size // 2
    b = compile_("f64.finite - f64.zero - f64.subnormal", F64)
    assert b == named_set(F64, "normal")
    assert compile_("f64.nan | f64.inf", F64).size == named_set(F64, "nan").size + 2


def test_precedence_of_minus_over_and_gives_the_same_set():
    small = compile_("f64.range(-0x1p-26, 0x1p-26) & f64.normal", F64)
    classes = {"small": small}
    parsed = compile_("f64.range(-0x1p20, 0x1p20) & f64.normal - small", F64, classes)
    explicit = compile_("(f64.range(-0x1p20, 0x1p20) & f64.normal) - small", F64, classes)
    assert parsed == explicit


# ---------------------------------------------------------------------------
# Names and errors


def test_earlier_classes_by_name():
    nan = compile_("f64.nan", F64)
    assert compile_("f64.all - nan", F64, {"nan": nan}) == domain(F64) - nan
    with pytest.raises(SetError, match="unknown class later"):
        compile_("f64.all - later", F64, {"nan": nan})


def test_type_mismatch():
    with pytest.raises(
        SetError, match="f64.nan is a set of f64 values, but this partition is of f32"
    ):
        compile_("f64.nan", F32)
    with pytest.raises(SetError, match="i32.range is a set of i32 values"):
        compile_("i32.range(0, 1)", I64)
    with pytest.raises(SetError, match="class small is a set of f32 values"):
        compile_("small", F64, {"small": named_set(F32, "nan")})


def test_unknown_and_misused_names():
    with pytest.raises(SetError, match="f64 has no set normals"):
        compile_("f64.normals", F64)
    with pytest.raises(SetError, match="i32 has no set nan"):
        compile_("i32.nan", I32)
    with pytest.raises(SetError, match=r"is a value, not a set; write \{f64.max\}"):
        compile_("f64.max", F64)
    with pytest.raises(SetError, match="f64 is a type; write f64.all"):
        compile_("f64", F64)
    with pytest.raises(SetError, match="not a partition set"):
        compile_("mp.cos", F64)


def test_predicates_are_not_sets():
    with pytest.raises(SetError, match="expected a set expression, got the operator =="):
        compile_("len(b) == 4", F64)
    with pytest.raises(SetError, match="got a call to is_nan"):
        compile_("is_nan(x)", F64)
    with pytest.raises(SetError, match="got the operator \\+"):
        compile_("f64.nan + f64.inf", F64)


def test_range_arity_and_constants():
    with pytest.raises(SetError, match="takes two bounds"):
        compile_("f64.range(0)", F64)
    with pytest.raises(SetError, match="expected a constant, got x"):
        compile_("f64.range(x, 1)", F64)
    with pytest.raises(SetError, match="takes one string"):
        compile_("f64.pattern(1)", F64)


def test_errors_carry_the_span_of_the_offending_node():
    e = expr("f64.nan | f64.range(0.1, 1)", line=7, col=11)
    with pytest.raises(SetError) as info:
        compile_set(e, F64)
    bound = e.right.args[0]
    assert info.value.span == bound.span
    assert info.value.span.line == 7 and info.value.span.col == 11 + len("f64.nan | f64.range(")


def test_aliases():
    aliases = {"Angle": F64}
    assert compile_("Angle.nan", F64, aliases=aliases) == named_set(F64, "nan")
    assert compile_("Angle.range(0, Angle.max)", F64, aliases=aliases).size > 0
    with pytest.raises(SetError):
        compile_("Angle.nan", F64)


def test_layout_rounding_matches_struct():
    import struct

    for fmt, flt, uint in (("f32", ">f", ">I"), ("f16", ">e", ">H")):
        layout = LAYOUTS[fmt]
        for x in (0.1, 1 / 3, 2.5e-8, 6e-8, 65519.0, 1e-45, 3.4e38, 1 + 2**-11, 1 + 3 * 2**-11):
            try:
                want = struct.unpack(uint, struct.pack(flt, x))[0]
            except OverflowError:
                continue
            assert layout.nearest(Fraction(x)) == want, (fmt, x)
            assert layout.nearest(Fraction(-x)) == want | layout.sign


def test_bool_has_no_range():
    with pytest.raises(SetError, match="bool has no range"):
        compile_("bool.range(0, 1)", BOOL)
