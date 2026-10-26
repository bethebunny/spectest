from std.testing import assert_equal, TestSuite

from syntax.testkit import spec_error, prelude_error


def check(source: String, expected: String) raises:
    assert_equal(spec_error(source), expected)



def test_lexical_errors() raises:
    check('spec s\n	fn f()\n',
          't.spec:2:1: tab in indentation: indent with spaces')
    check('spec s\nfn f()\n	ensures true\n',
          't.spec:3:1: tab in indentation: indent with spaces')
    check('  spec a\n',
          't.spec:1:3: unexpected indentation')
    check('spec a)\n',
          't.spec:1:7: unmatched \')\'')
    check('spec a\nfn f(\n',
          't.spec:2:5: \'(\' is never closed')
    check('spec a\nfn f(]\n',
          't.spec:2:6: \']\' does not match \'(\' at 2:5')
    check('spec a\nfn f(x: int)\n  ensures {1, 2]\n',
          't.spec:3:16: \']\' does not match \'{\' at 3:11')
    check('spec a\nfn f()\n  ensures "abc\n',
          't.spec:3:11: unterminated string')
    check('spec a\nfn f()\n  ensures "\\q"\n',
          't.spec:3:12: unknown escape \\q')
    check('spec a\nfn f()\n  ensures "\\xZ1"\n',
          't.spec:3:12: \\x needs two hex digits')
    check('spec a\nfn f()\n  ensures "\\u12"\n',
          't.spec:3:12: \\u needs {hex} or four hex digits')
    check('spec a\nfn f()\n  ensures "\\u{d800}"\n',
          't.spec:3:12: \\ud800 is not a Unicode scalar value')
    check('spec a\nfn f()\n  ensures "\\u{110000}"\n',
          't.spec:3:12: \\u110000 is not a Unicode scalar value')
    check('spec a\nfn f()\n  ensures 12ab\n',
          't.spec:3:11: invalid numeric literal \'12ab\'')
    check('spec a\nfn f()\n  ensures 1e\n',
          't.spec:3:11: invalid numeric literal \'1e\'')
    check('spec a\nfn f()\n  ensures 0x\n',
          't.spec:3:11: hexadecimal literal needs digits after 0x')
    check('spec a\nfn f()\n  ensures 0x1.8\n',
          't.spec:3:11: hexadecimal float 0x1.8 needs a binary exponent, e.g. 0x1.8p0')
    check('spec a\nfn f()\n  ensures p.0x1\n',
          't.spec:3:13: a tuple field is a decimal index, e.g. p.0')
    check('spec a\nfn f()\n  ensures a $ b\n',
          't.spec:3:13: unexpected character \'$\'')
    check('spec a\nfn f()\n  ensures "é" ? b\n',
          't.spec:3:15: unexpected character \'?\'')
    check('spec a\nfn f()\n  ensures a\n requires b\n',
          't.spec:4:2: indentation does not match any enclosing block')
    check('fn f()\n',
          't.spec:1:1: expected \'spec <name>\' at the start of the file, found \'fn\'')


def test_declaration_errors() raises:
    check('',
          't.spec:1:1: expected \'spec <name>\' at the start of the file, found end of file')
    check('spec s\nensures true\n',
          't.spec:2:1: \'ensures\' must be indented under a declaration (fn, model or interface)')
    check('spec s\nfoo bar\n',
          't.spec:2:1: expected a declaration (fn, model, interface, error, enum, record, type, const, prelude or use), found \'foo\'')
    check('spec s\nfn f()\n  bogus x\n',
          't.spec:3:3: expected a clause (requires, ensures, raises, ...) or \'partition\', found \'bogus\'')
    check('spec s\nfn f(x int)\n',
          't.spec:2:8: expected \':\' and the type of x, found \'int\'')
    check('spec s\nmodel M\n  fn f()\n',
          't.spec:3:3: expected \'observe\', \'build\' or a clause such as \'invariant\', found \'fn\'')
    check('spec s\ninterface I\n  method m(x: int)\n',
          't.spec:3:12: expected \'self\' as the first parameter of a method, found \'x\'')
    check('spec s\ninterface I\n  new e()\n',
          't.spec:3:10: expected \'->\' and the interface name, found end of line')
    check('spec s\nfn f()\n  raises E\n',
          't.spec:3:11: expected \'when\' and the condition under which it raises, found end of line')
    check('spec s\nfn f()\n  partition x\n',
          't.spec:4:1: expected an indented list of classes (\'name = expr\'), found end of block')
    check('spec s\nfn f()\n  partition x\n    a f64.nan\n',
          't.spec:4:7: expected \'=\' and the class expression, found \'f64\'')
    check('spec s\nfn f()\n  ensures a b\n',
          't.spec:3:13: expected end of line, found \'b\'')
    check('spec s\nfn f()\n  ensures\n',
          't.spec:3:10: expected an expression, found end of line')
    check('spec s\nuse other\n',
          't.spec:2:5: expected a file name in quotes, e.g. use "other", found \'other\'')
    check('spec s\nprelude 3\n',
          't.spec:2:9: expected a file name in quotes, e.g. prelude "other", found \'3\'')
    check('spec s\nfn f(let: int)\n',
          't.spec:2:6: \'let\' is a reserved word and cannot be a parameter name')
    check('spec s\nenum E { A, }\n',
          't.spec:2:13: expected an enum member, found \'}\'')
    check('spec s\nfn f()\n  ensures let x = 1 x\n',
          't.spec:3:21: expected \'in\' after the value bound by let, found \'x\'')


def test_expression_errors() raises:
    check('spec s\nfn f()\n  ensures a < b < c\n',
          't.spec:3:17: comparisons do not chain: write \'a < b and b < c\'')
    check('spec s\nfn f()\n  ensures a == b != c\n',
          't.spec:3:18: comparisons do not chain: write \'a == b and b != c\'')
    check('spec s\nfn f()\n  ensures if a then b\n',
          't.spec:3:22: expected \'else\' (every if has an else branch), found end of line')
    check('spec s\nfn f()\n  ensures if a b\n',
          't.spec:3:16: expected \'then\', found \'b\'')
    check('spec s\nfn f()\n  ensures wrap<u32> + 1\n',
          't.spec:3:21: expected \'(\' and the arguments of wrap<...>, found \'+\'')
    check('spec s\nfn f()\n  ensures f(a=1, b)\n',
          't.spec:3:18: positional arguments must come before named ones')
    check('spec s\nfn f()\n  ensures f(a=1, a=2)\n',
          't.spec:3:18: argument a is given twice')
    check('spec s\nfn f()\n  ensures xs[:b]\n',
          't.spec:3:14: expected an expression, found \':\'')
    check('spec s\nfn f()\n  ensures then\n',
          't.spec:3:11: expected an expression, found \'then\'')
    check('spec s\nfn f()\n  ensures ()\n',
          't.spec:3:12: expected an expression, found \')\'')
    check('spec s\nfn f()\n  ensures a.\n',
          't.spec:3:13: expected a field name or tuple index after \'.\', found end of line')
    check('spec s\nfn f()\n  ensures all(x xs: x)\n',
          't.spec:3:17: expected \',\' or \')\', found \'xs\'')


def test_v2_errors() raises:
    check('spec s\ntype T = (int)\n',
          't.spec:2:10: a tuple type has at least two elements')
    check('spec s\ntype T = "a" | 3\n',
          't.spec:2:16: expected a string literal or a constant name in the choice, found \'3\'')
    check('spec s\ntype T = list<int\n',
          't.spec:2:18: expected \'>\', found end of line')
    check('spec s\nconst c\n',
          't.spec:2:8: expected \':\' and the type of the constant, found end of line')
    check('spec s\nmodel M\n  build f\n',
          't.spec:3:10: expected \'(\' and the parameters, found end of line')
    check('spec s\nfn f() =\n',
          't.spec:2:8: a definition needs a return type: fn name(...) -> type = expression')
    check('spec s\nfn f() = 1\n',
          't.spec:2:8: a definition needs a return type: fn name(...) -> type = expression')
    check('spec s\nfn a.f() -> int = 1\n',
          't.spec:2:17: a definition\'s name is a single name, not a qualified one')
    check('spec s\nfn f() -> int = 1 2\n',
          't.spec:2:19: expected end of line, found \'2\'')
    check('spec s\nfn f(x: int) -> int\n  ensures true\n    ensures false\n',
          't.spec:4:5: expected end of line, found \'ensures\'')
    check('spec s\nfn f() -> int\n  modifies\n',
          't.spec:3:11: expected a parameter name or self, found end of line')
    check('spec s\nfn f() -> int\n  unspecified\n',
          't.spec:3:14: expected the name of the freedom, found end of line')


def test_prelude_errors() raises:
    assert_equal(prelude_error('fn f() -> int\n'),
                 't.prelude:1:1: a prelude holds definitions: fn name(...) -> type = expression')
    assert_equal(prelude_error('model M\n'),
                 't.prelude:1:1: expected a definition (\'fn name(...) -> type = expression\') or \'use\', found \'model\'')
    assert_equal(prelude_error('spec s\n'),
                 't.prelude:1:1: expected a definition (\'fn name(...) -> type = expression\') or \'use\', found \'spec\'')
    assert_equal(prelude_error('fn a.f() -> int = 1\n'),
                 't.prelude:1:17: a definition\'s name is a single name, not a qualified one')
    assert_equal(prelude_error('  fn f() -> int = 1\n'),
                 't.prelude:1:3: unexpected indentation')


def test_first_error_is_reported() raises:
    # Lexical errors come before parse errors, wherever the parse error is.
    assert_equal(
        spec_error("spec s\nfn f(x int)\nfn g()\n  ensures $\n"),
        "t.spec:4:11: unexpected character '$'",
    )
    assert_equal(spec_error("spec s\nfn f(x int)\nfn g(y int)\n"), "t.spec:2:8: expected ':' and the type of x, found 'int'")


def test_valid_sources_give_no_error() raises:
    assert_equal(spec_error("spec s\n"), "")
    assert_equal(spec_error("spec s\r\nfn f()\r\n  ensures true\r\n"), "")
    assert_equal(spec_error("# comment\nspec s # more\n\n\nfn f() # x\n"), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
