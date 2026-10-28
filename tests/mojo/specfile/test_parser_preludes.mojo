from std.testing import assert_equal, TestSuite

from syntax_testkit import prelude_dump, prelude_error


def test_empty_prelude() raises:
    assert_equal(prelude_dump(""), "(prelude_file)")
    assert_equal(prelude_dump("# only a comment\n\n"), "(prelude_file)")


def test_definitions_and_uses() raises:
    assert_equal(
        prelude_dump(
            "use \"base.prelude\"\n"
            "\n"
            "# helpers\n"
            "fn is_sorted(xs: list<int>) -> bool = all(i in range(1, len(xs)): xs[i - 1] <= xs[i])\n"
            "fn twice<T>(x: T) -> (T, T) = (x, x)\n"
            "fn clamp(x: int, lo: int, hi: int) -> int =\n"
            "  if x < lo then lo else if x > hi then hi else x\n"
        ),
        '(prelude_file (use "base.prelude")'
        ' (def "is_sorted" (tparams) (params (param "xs" (type "list" (type "int")) _))'
        ' (type "bool") (comprehension all "i"'
        ' (call (name "range") (typeargs) (arg (num "1")) (arg (call (name "len") (typeargs) (arg (name "xs")))))'
        ' (binary <= (index (name "xs") (binary - (name "i") (num "1"))) (index (name "xs") (name "i")))))'
        ' (def "twice" (tparams (tparam "T")) (params (param "x" (type "T") _))'
        ' (tuple_type (type "T") (type "T")) (tuple (name "x") (name "x")))'
        ' (def "clamp" (tparams) (params (param "x" (type "int") _) (param "lo" (type "int") _)'
        ' (param "hi" (type "int") _)) (type "int")'
        ' (if (binary < (name "x") (name "lo")) (name "lo")'
        ' (if (binary > (name "x") (name "hi")) (name "hi") (name "x")))))',
    )


def test_definitions_use_qualified_names_in_bodies() raises:
    assert_equal(
        prelude_dump("fn width(s: bitpattern.IntSet) -> int = bitpattern.IntSet.width(s)\n"),
        '(prelude_file (def "width" (tparams)'
        ' (params (param "s" (type "bitpattern.IntSet") _)) (type "int")'
        ' (call (attr "width" (attr "IntSet" (name "bitpattern"))) (typeargs) (arg (name "s")))))',
    )


def test_prelude_errors() raises:
    assert_equal(
        prelude_error("fn f() -> int\n"),
        "t.prelude:1:1: a prelude holds definitions: fn name(...) -> type = expression",
    )
    assert_equal(
        prelude_error("error E\n"),
        "t.prelude:1:1: expected a definition ('fn name(...) -> type = expression')"
        " or 'use', found 'error'",
    )
    assert_equal(
        prelude_error("fn f(x: int) -> int = x +\n"),
        "t.prelude:1:26: expected an expression, found end of line",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
