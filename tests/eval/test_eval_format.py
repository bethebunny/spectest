"""format_value and source_text."""

from __future__ import annotations

from fractions import Fraction

import pytest
from eval_support import example, f16, f32, f64, spec_of

from spectest import ast
from spectest.eval import format_value, source_text
from spectest.prelude import floats
from spectest.types import (
    BYTES,
    INT,
    REAL,
    STRING,
    UNIT,
    EnumT,
    FloatT,
    ListT,
    MapT,
    OptionT,
    RecordT,
    TupleT,
)
from spectest.values import NEG_INF, POS_INF, Handle, MapValue, RecordValue, Some


@pytest.mark.parametrize(
    ("value", "t", "expected"),
    [
        (True, None, "true"),
        (False, None, "false"),
        (0, INT, "0"),
        (-12345678901234567890, None, "-12345678901234567890"),
        (Fraction(3, 2), REAL, "1.5"),
        (Fraction(-1, 8), REAL, "-0.125"),
        (Fraction(4, 2), REAL, "2"),
        (Fraction(1, 3), REAL, "1/3 (~0.33333333333333333333)"),
        (Fraction(-2, 3), REAL, "-2/3 (~-0.66666666666666666667)"),
        (POS_INF, REAL, "+inf"),
        (NEG_INF, REAL, "-inf"),
        ("hi", STRING, '"hi"'),
        ('a"b\\c\n\t\x01', STRING, '"a\\"b\\\\c\\n\\t\\x01"'),
        ("é ü", STRING, '"é ü"'),
        ("\u200b", STRING, '"\\u{200b}"'),
        (b'ab\x00\xff"', BYTES, 'b"ab\\x00\\xff\\""'),
        (b"", BYTES, 'b""'),
        ((1, 2, 3), ListT(INT), "[1, 2, 3]"),
        ((), None, "[]"),
        ((1, "a"), TupleT((INT, STRING)), '(1, "a")'),
        ((Some(1), None), ListT(OptionT(INT)), "[some(1), none]"),
        (None, OptionT(INT), "none"),
        (None, UNIT, "unit"),
        (Some("x"), None, 'some("x")'),
        (MapValue((("a", 1), ("b", 2))), MapT(STRING, INT), '{"a": 1, "b": 2}'),
        (RecordValue("P", (("x", 1), ("y", "z"))), None, 'P { x: 1, y: "z" }'),
        ("Red", EnumT("Color", ("Red",)), "Red"),
    ],
)
def test_format_value(value: object, t: object, expected: str) -> None:
    assert format_value(value, t) == expected  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("text", "shown"),
    [
        ("\0", "\\x00"),
        ("\x01", "\\x01"),
        ("\x1f", "\\x1f"),
        ("\x7f", "\\x7f"),
        ("\n", "\\n"),
        ("\t", "\\t"),
        ("\r", "\\r"),
        ('"', '\\"'),
        ("\\", "\\\\"),
        ("0", "0"),
        (" ", " "),
    ],
)
def test_strings_and_bytes_escape_ascii_the_same_way(text: str, shown: str) -> None:
    assert format_value(text, STRING) == f'"{shown}"'
    assert format_value(text.encode(), BYTES) == f'b"{shown}"'


def test_strings_escape_the_replacement_character_and_other_non_printables() -> None:
    assert format_value("\ufffd", STRING) == '"\\u{fffd}"'
    assert format_value("0\0", STRING) == '"0\\x00"'
    assert format_value("\x80\xa0\u2028\U0001f600", STRING) == '"\\u{80}\\u{a0}\\u{2028}\U0001f600"'
    assert format_value(b"\xef\xbf\xbd\x80", BYTES) == 'b"\\xef\\xbf\\xbd\\x80"'


def test_format_floats() -> None:
    assert format_value(f64(1.5)) == "1.5 (0x3ff8000000000000)"
    assert format_value(f64(-0.0), FloatT("f64")) == "-0.0 (0x8000000000000000)"
    assert format_value(f32(0.1)) == "0.1 (0x3dcccccd)"
    assert format_value(f16(1.0)) == "1.0 (0x3c00)"
    assert format_value(floats.nan("f64")).startswith("nan (0x7ff8")
    assert format_value(floats.inf("f32", negative=True)) == "-inf (0xff800000)"
    assert format_value((f64(1.0), f64(-0.0)), ListT(FloatT("f64"))) == "[1.0, -0.0]"
    weird = floats.nan("f64", payload=1)
    assert format_value(Some(weird)) == "some(nan:0x7ff8000000000001)"


def test_format_long_reals_are_approximate() -> None:
    r = Fraction(1, 3**100)
    text = format_value(r, REAL)
    assert text.startswith("~") and "/" not in text
    dyadic = Fraction(0.1)
    assert format_value(dyadic) == "~0.10000000000000000555"


def test_format_handles() -> None:
    h = Handle(object(), "Deque", id=7)
    assert format_value(h) == "<Deque #7>"
    assert format_value((h,)) == "[<Deque #7>]"


def test_format_record_with_type() -> None:
    t = RecordT("P", (("x", FloatT("f32")),))
    assert format_value(RecordValue("P", (("x", f32(0.5)),)), t) == "P { x: 0.5 }"
    assert format_value(RecordValue("E", ())) == "E {}"


def test_format_unknown_values_fall_back_to_repr() -> None:
    assert format_value(object()).startswith("<object object")


def test_source_text_of_sub_expressions() -> None:
    spec = example("deque")
    c = spec.clause_ids["Deque.append.items"]
    assert isinstance(c.expr, ast.Let)
    assert source_text(c.expr.value, spec) == "old(self.items) + [x]"
    body = c.expr.body
    assert isinstance(body, ast.Binary)
    assert source_text(body.left, spec) == "self.items"
    assert source_text(body.right, spec) == (
        "if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen) "
        "then ys[len(ys) - unwrap(self.maxlen):len(ys)] else ys"
    )
    assert source_text(c.expr, spec) == c.text.split(": ", 1)[1]


def test_source_text_drops_comments_and_keeps_strings() -> None:
    spec = spec_of(
        """
        spec t
        fn f(s: string) -> bool
          ensures e: s == "a  # b" or   # first
            len(s) == 0     # second
        """
    )
    c = spec.clause_ids["f.e"]
    assert source_text(c.expr, spec) == 's == "a  # b" or len(s) == 0'


def test_source_text_of_nodes_without_spans() -> None:
    spec = spec_of("spec t\n")
    assert source_text(ast.Num(1, "1"), spec) == "<num>"


def test_source_text_of_used_files(tmp_path) -> None:
    (tmp_path / "base.spec").write_text(
        "spec base\nmodel Bag\n  observe items: list<i64>\n  invariant sized: len(items) >= 0\n"
    )
    (tmp_path / "main.spec").write_text(
        'spec main\nuse "base.spec"\n\n\nfn f(b: Bag) -> i64\n  ensures e: result >= 0\n'
    )
    from spectest.lang import load

    spec = load(tmp_path / "main.spec")
    inv = spec.clause_ids["Bag.sized"]
    assert source_text(inv.expr, spec) == "len(items) >= 0"
    assert source_text(spec.clause_ids["f.e"].expr, spec) == "result >= 0"
