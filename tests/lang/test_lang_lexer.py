from fractions import Fraction

import pytest

from spectest.lang.errors import SpecSyntaxError
from spectest.lang.lexer import (
    DEDENT,
    EOF,
    INDENT,
    NEWLINE,
    PERF,
    parse_number,
    tokenize,
)


def kinds(source: str) -> list[str]:
    out = []
    for t in tokenize(source):
        out.append(t.kind if t.kind in (NEWLINE, INDENT, DEDENT, EOF, PERF) else t.text)
    return out


def syntax_error(source: str) -> SpecSyntaxError:
    with pytest.raises(SpecSyntaxError) as info:
        tokenize(source, "t.spec")
    return info.value


class TestLayout:
    def test_flat_lines(self):
        assert kinds("spec a\nerror E\n") == [
            "spec", "a", NEWLINE, "error", "E", NEWLINE, EOF,
        ]  # fmt: skip

    def test_block_after_opener(self):
        src = "spec a\nfn f(x: int)\n  requires x > 0\n  ensures true\nerror E\n"
        assert kinds(src) == [
            "spec", "a", NEWLINE,
            "fn", "f", "(", "x", ":", "int", ")", NEWLINE,
            INDENT, "requires", "x", ">", "0", NEWLINE,
            "ensures", "true", NEWLINE,
            DEDENT, "error", "E", NEWLINE, EOF,
        ]  # fmt: skip

    def test_continuation_lines_join_the_clause(self):
        src = "fn f()\n  ensures a and\n    b and\n      c\n  ensures d\n"
        assert kinds(src) == [
            "fn", "f", "(", ")", NEWLINE,
            INDENT, "ensures", "a", "and", "b", "and", "c", NEWLINE,
            "ensures", "d", NEWLINE, DEDENT, EOF,
        ]  # fmt: skip

    def test_continuation_of_a_top_level_statement(self):
        src = "type Row =\n  list<f64>\nerror E\n"
        assert kinds(src) == [
            "type", "Row", "=", "list", "<", "f64", ">", NEWLINE,
            "error", "E", NEWLINE, EOF,
        ]  # fmt: skip

    def test_nested_blocks_close_together(self):
        src = (
            "interface Q\n"
            "  method m(self, x: f64)\n"
            "    partition x\n"
            "      nan = f64.nan\n"
            "      rest = f64.all - nan\n"
            "fn g()\n"
        )
        toks = kinds(src)
        i = toks.index("rest")
        assert toks[i:] == [
            "rest", "=", "f64", ".", "all", "-", "nan", NEWLINE,
            DEDENT, DEDENT, DEDENT, "fn", "g", "(", ")", NEWLINE, EOF,
        ]  # fmt: skip
        assert toks.count(INDENT) == 3

    def test_partition_then_clause_dedents_once(self):
        src = "fn f(x: f64)\n  partition x\n    a = f64.all\n  ensures true\n"
        toks = kinds(src)
        assert toks[toks.index("all") + 1 :] == [
            NEWLINE, DEDENT, "ensures", "true", NEWLINE, DEDENT, EOF,
        ]  # fmt: skip

    def test_blank_and_comment_lines_are_ignored(self):
        src = (
            "# header comment\n"
            "spec a   # trailing\n"
            "\n"
            "fn f()\n"
            "\n"
            "      # a comment indented anywhere\n"
            "  ensures a and\n"
            "\n"
            "# a comment at column 1 inside a continuation\n"
            "    b\n"
            "   \n"
            "  ensures c\n"
        )
        assert kinds(src) == [
            "spec", "a", NEWLINE, "fn", "f", "(", ")", NEWLINE,
            INDENT, "ensures", "a", "and", "b", NEWLINE,
            "ensures", "c", NEWLINE, DEDENT, EOF,
        ]  # fmt: skip

    def test_newlines_inside_brackets_are_ignored(self):
        src = "fn f()\n  ensures g(a,\nb,\n          c) == [1,\n 2]\n  ensures d\n"
        assert kinds(src) == [
            "fn", "f", "(", ")", NEWLINE,
            INDENT, "ensures", "g", "(", "a", ",", "b", ",", "c", ")", "==",
            "[", "1", ",", "2", "]", NEWLINE,
            "ensures", "d", NEWLINE, DEDENT, EOF,
        ]  # fmt: skip

    def test_multiline_parameters_then_block(self):
        src = "fn f(a: int,\n     b: int) -> int\n  ensures true\n"
        toks = kinds(src)
        assert toks[toks.index("->") :] == [
            "->", "int", NEWLINE, INDENT, "ensures", "true", NEWLINE, DEDENT, EOF,
        ]  # fmt: skip

    def test_opener_without_block(self):
        assert kinds("fn f()\nfn g()\n") == [
            "fn", "f", "(", ")", NEWLINE, "fn", "g", "(", ")", NEWLINE, EOF,
        ]  # fmt: skip

    def test_opener_keyword_used_as_a_class_name_is_not_an_opener(self):
        src = "fn f(xs: list<int>)\n  partition xs\n    new = len(xs) == 0\n      or false\n"
        toks = kinds(src)
        assert toks.count(INDENT) == 2
        assert toks[toks.index("new") :] == [
            "new", "=", "len", "(", "xs", ")", "==", "0", "or", "false", NEWLINE,
            DEDENT, DEDENT, EOF,
        ]  # fmt: skip

    def test_crlf_line_endings(self):
        assert kinds("spec a\r\nfn f()\r\n  ensures b\r\n") == [
            "spec", "a", NEWLINE, "fn", "f", "(", ")", NEWLINE,
            INDENT, "ensures", "b", NEWLINE, DEDENT, EOF,
        ]  # fmt: skip

    def test_tab_in_indentation_is_an_error(self):
        err = syntax_error("fn f()\n\tensures true\n")
        assert "tab in indentation" in str(err)
        assert err.diagnostics[0].span.line == 2

    def test_tab_inside_a_line_is_whitespace(self):
        assert kinds("spec\ta\n") == ["spec", "a", NEWLINE, EOF]

    def test_unexpected_indentation_on_the_first_line(self):
        assert "unexpected indentation" in str(syntax_error("  spec a\n"))

    def test_dedent_to_an_unknown_level(self):
        err = syntax_error("fn f()\n    ensures a\n  ensures b\n")
        assert "does not match any enclosing block" in str(err)
        assert err.diagnostics[0].span.line == 3

    def test_unclosed_bracket(self):
        err = syntax_error("fn f()\n  ensures g(a,\n")
        assert "'(' is never closed" in str(err)
        assert (err.diagnostics[0].span.line, err.diagnostics[0].span.col) == (2, 12)

    def test_mismatched_brackets(self):
        assert "')' does not match '['" in str(syntax_error("spec a\nfn f()\n  ensures [a)\n"))
        assert "unmatched ')'" in str(syntax_error("spec a)\n"))

    def test_perf_takes_the_rest_of_the_line_raw(self):
        toks = tokenize("fn f()\n  perf p99 < 20µs @ n=1e6 # not a comment\n  ensures b\n")
        perf = [t for t in toks if t.kind == PERF]
        assert [t.value for t in perf] == ["p99 < 20µs @ n=1e6 # not a comment"]
        assert perf[0].span.col == 8

    def test_perf_continuation_lines_are_raw_too(self):
        toks = tokenize("fn f()\n  perf a $\n    b ~\n  ensures c\n")
        assert [t.value for t in toks if t.kind == PERF] == ["a $", "b ~"]

    def test_perf_as_a_prefix_of_a_name_is_not_perf(self):
        assert "perfect" in kinds("spec perfect\n")


class TestTokens:
    def test_operators_longest_match(self):
        assert kinds("a->b==c!=d<=e>=f//g<h>i=j\n")[:-2] == [
            "a", "->", "b", "==", "c", "!=", "d", "<=", "e", ">=", "f", "//", "g",
            "<", "h", ">", "i", "=", "j",
        ]  # fmt: skip

    def test_spans_are_one_based_with_exclusive_end(self):
        toks = tokenize("spec abc\n  # c\nfn f()\n")
        name = toks[1]
        assert (name.span.line, name.span.col, name.span.end_line, name.span.end_col) == (
            1, 6, 1, 9,
        )  # fmt: skip
        fn = toks[3]
        assert (fn.span.line, fn.span.col) == (3, 1)

    def test_strings_and_escapes(self):
        toks = tokenize(r'"a\"b\\c\n\t\x41\u00e9\u{1F600}"' + "\n")
        assert toks[0].value == 'a"b\\c\n\tAé\U0001f600'
        assert toks[0].text.startswith('"a\\"')

    def test_hash_inside_a_string_is_not_a_comment(self):
        toks = tokenize('"a # b" # c\n')
        assert toks[0].value == "a # b"
        assert [t.kind for t in toks] == ["STRING", NEWLINE, EOF]

    @pytest.mark.parametrize(
        ("source", "message"),
        [
            ('"abc\n', "unterminated string"),
            ('"\\q"\n', "unknown escape"),
            ('"\\x4"\n', "two hex digits"),
            ('"\\u{D800}"\n', "not a Unicode scalar value"),
            ("a $ b\n", "unexpected character '$'"),
            ("12abc\n", "invalid numeric literal"),
            ("0x1.8\n", "needs a binary exponent"),
            ("1__0\n", "invalid numeric literal"),
        ],
    )
    def test_lexical_errors(self, source: str, message: str):
        assert message in str(syntax_error(source))

    def test_error_excerpt_has_a_caret(self):
        err = syntax_error("spec a\nfn f()\n  ensures a $ b\n")
        text = str(err)
        assert "t.spec:3:13: error: unexpected character '$'" in text
        assert " 3 |   ensures a $ b\n   |             ^" in text


class TestNumbers:
    @pytest.mark.parametrize(
        ("text", "value"),
        [
            ("0", 0),
            ("42", 42),
            ("1_000_000", 1000000),
            ("007", 7),
            ("0xff", 255),
            ("0XFF", 255),
            ("0xdead_beef", 0xDEADBEEF),
            ("1.5", Fraction(3, 2)),
            ("0.1", Fraction(1, 10)),
            ("1e3", Fraction(1000)),
            ("1E-3", Fraction(1, 1000)),
            ("2.5e+2", Fraction(250)),
            ("1.0", Fraction(1)),
            ("0x1p-26", Fraction(1, 2**26)),
            ("0x1p20", Fraction(2**20)),
            ("0x1.8p3", Fraction(12)),
            ("0x1.8p-1", Fraction(3, 4)),
            ("0x.8p1", None),
            ("0x1.fffffffffffffp1023", Fraction(2**53 - 1) * 2 ** (1023 - 52)),
            ("0x0.0000000000001p-1022", Fraction(1, 2**1074)),
            ("0x1P+4", Fraction(16)),
        ],
    )
    def test_values_are_exact(self, text: str, value: object):
        if value is None:
            with pytest.raises(ValueError):
                parse_number(text)
            return
        got = parse_number(text)
        assert got == value
        assert type(got) is type(value)

    def test_integers_are_ints_and_the_rest_fractions(self):
        assert type(parse_number("12")) is int
        assert type(parse_number("0x10")) is int
        assert type(parse_number("12.0")) is Fraction
        assert type(parse_number("0x10p0")) is Fraction

    @pytest.mark.parametrize("text", ["0", "17", "0x7f", "1.25", "6.02e23", "0x1.8p3", "0x1p-1074"])
    def test_round_trip_through_the_lexer(self, text: str):
        tok = tokenize(text + "\n")[0]
        assert tok.kind == "NUMBER"
        assert tok.text == text
        assert tok.value == parse_number(text)

    def test_negative_hex_float_is_unary_minus(self):
        assert kinds("-0x1p-26\n")[:2] == ["-", "0x1p-26"]

    def test_digits_after_a_dot_are_a_tuple_index(self):
        toks = tokenize("p.0.1\n")
        assert [t.text for t in toks[:5]] == ["p", ".", "0", ".", "1"]
        assert toks[2].value == 0 and toks[4].value == 1
