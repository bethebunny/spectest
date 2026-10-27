from std.testing import assert_equal, TestSuite

from syntax.lexer import tokens


def kinds(source: String) raises -> String:
    """Tokens as words: layout tokens by name, strings and perf text quoted."""
    var out = String()
    for t in tokens(source, "t.spec"):
        if out.byte_length() > 0:
            out += " "
        if t.kind == .NEWLINE:
            out += "NEWLINE"
        elif t.kind == .INDENT:
            out += "INDENT"
        elif t.kind == .DEDENT:
            out += "DEDENT"
        elif t.kind == .EOF:
            out += "EOF"
        elif t.kind == .STRING:
            out += '"' + t.text + '"'
        elif t.kind == .PERF:
            out += "PERF(" + t.text + ")"
        else:
            out += t.text
    return out^


def test_flat_lines() raises:
    assert_equal(kinds("spec a\nerror E\n"), "spec a NEWLINE error E NEWLINE EOF")


def test_block_after_opener() raises:
    assert_equal(
        kinds("spec a\nfn f(x: int)\n  requires x > 0\n  ensures true\nerror E\n"),
        "spec a NEWLINE fn f ( x : int ) NEWLINE INDENT requires x > 0 NEWLINE"
        " ensures true NEWLINE DEDENT error E NEWLINE EOF",
    )


def test_continuation_lines_join_the_clause() raises:
    assert_equal(
        kinds("fn f()\n  ensures a and\n    b and\n      c\n  ensures d\n"),
        "fn f ( ) NEWLINE INDENT ensures a and b and c NEWLINE ensures d NEWLINE"
        " DEDENT EOF",
    )


def test_top_level_continuation() raises:
    assert_equal(
        kinds("type Row =\n  list<f64>\nerror E\n"),
        "type Row = list < f64 > NEWLINE error E NEWLINE EOF",
    )


def test_brackets_ignore_newlines() raises:
    assert_equal(
        kinds("enum E {\nA,\n  B\n}\n"), "enum E { A , B } NEWLINE EOF"
    )


def test_comments_and_blank_lines() raises:
    assert_equal(
        kinds("# top\n\nfn f() # trailing\n\n  # inside\n  ensures true\n"),
        "fn f ( ) NEWLINE INDENT ensures true NEWLINE DEDENT EOF",
    )


def test_nested_blocks_dedent_together() raises:
    assert_equal(
        kinds("fn f()\n  partition x\n    a = 1\nerror E\n"),
        "fn f ( ) NEWLINE INDENT partition x NEWLINE INDENT a = 1 NEWLINE DEDENT"
        " DEDENT error E NEWLINE EOF",
    )


def test_perf_takes_the_rest_of_the_line() raises:
    assert_equal(
        kinds("fn f()\n  perf O(n) # not a comment\n    more \"x\"\n  ensures a\n"),
        'fn f ( ) NEWLINE INDENT perf PERF(O(n) # not a comment) PERF(more "x")'
        " NEWLINE ensures a NEWLINE DEDENT EOF",
    )


def test_operators() raises:
    assert_equal(
        kinds("a ** b << c >> d -> e == f != g <= h >= i // j"),
        "a ** b << c >> d -> e == f != g <= h >= i // j NEWLINE EOF",
    )


def test_numbers() raises:
    assert_equal(
        kinds("0 255 0xff 1.5 1e-3 1_000 0x1p-26 0x1.8p3 0XAB_cd 2E+4"),
        "0 255 0xff 1.5 1e-3 1_000 0x1p-26 0x1.8p3 0XAB_cd 2E+4 NEWLINE EOF",
    )


def test_tuple_fields_are_digits_only() raises:
    assert_equal(kinds("p.0.1"), "p . 0 . 1 NEWLINE EOF")


def test_strings_and_escapes() raises:
    assert_equal(
        kinds('"a\\nb" "q\\"q" "\\\\" "\\x41\\u00e9\\u{1F600}"'),
        '"a\nb" "q"q" "\\" "Aé😀" NEWLINE EOF',
    )


def test_spans() raises:
    var toks = tokens('spec a\n  # c\nfn f("é" x)\n', "t.spec")
    # spec a NEWLINE fn f ( "é" x ) NEWLINE EOF
    assert_equal(toks[2].span.line, 1)
    assert_equal(toks[2].span.column, 7)
    assert_equal(toks[3].span.line, 3)
    assert_equal(toks[3].span.column, 1)
    assert_equal(toks[4].span.column, 4)
    assert_equal(toks[6].span.column, 6)
    assert_equal(toks[6].end_column, 9)
    # Columns count code points; offsets count bytes.
    assert_equal(toks[7].span.column, 10)
    assert_equal(toks[7].span.start, 13 + 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
