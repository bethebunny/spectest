from std.testing import assert_equal, assert_true, TestSuite

from check import types as ty
from check.spec import R_LOCAL, R_PARAM
from check.testkit import (
    clause_expr,
    ensures_ty,
    fails,
    fails2,
    nodes_of,
    ok,
    type_text,
)
from syntax import ast


def want(params: String, expr: String, expected: String) raises:
    assert_equal(ensures_ty(params, expr), expected)


def test_arithmetic_types() raises:
    want("a: i32, b: u8", "a + b", "int")
    want("a: i32", "a * 2 - 1", "int")
    want("a: i32", "a // 2", "int")
    want("a: i32", "a % 3", "int")
    want("a: i32", "a / 2", "real")
    want("a: int, b: int", "a / b", "real")
    want("x: f64", "x + 1", "real")
    want("x: f64, y: f32", "x * y", "real")
    want("x: f64", "-x", "f64")
    want("x: f32", "- -x", "f32")
    want("a: i8", "-a", "int")
    want("a: int", "-a", "int")
    want("x: f64", "real(x) - 1", "real")
    want("", "1", "int")
    want("", "1.5", "real")
    want("", "0x1p-26", "real")
    want("", "-0x1p-26", "real")
    want("xs: list<int>, ys: list<int>", "xs + ys", "list<int>")
    want("xs: list<u8>", "xs + [1]", "list<int>")
    want("s: string", 's + "x"', "string")
    want("b: bytes", "b + b", "bytes")
    want('m: "a" | "b"', 'm + "c"', "string")
    want("xs: list<int>", "xs + []", "list<int>")


def test_integer_operators() raises:
    want("a: i32, b: u8", "a ** b", "int")
    want("a: i32", "a << 3", "int")
    want("a: u64", "a >> 1", "int")
    want("a: u8, b: i64", "a & b", "int")
    want("a: u8, b: u8", "a | b", "int")
    fails("fn f(x: f64)\n  ensures (x << 1) == 0\n", "<< takes integers")
    fails("fn f(x: real)\n  ensures true\n", "real is clause-only")
    fails("fn f(a: int)\n  ensures a ** 0.5 == 1\n", "** takes integers")
    fails("fn f(a: int)\n  ensures a ** -1 == 1\n", "non-negative exponent")


def test_floor_division_needs_integers() raises:
    fails("fn f(x: f64)\n  ensures x // 2 == 0\n", "// takes integers")


def test_mixed_operands() raises:
    fails("fn f(s: string)\n  ensures s + 1 == s\n", "cannot apply + to string and int")
    fails(
        "fn f(xs: list<int>, ys: list<string>)\n  ensures len(xs + ys) == 0\n",
        "cannot concatenate list<int> and list<string>",
    )
    fails("fn f(b: bool)\n  ensures -b\n", "unary - needs a number")


def test_canonical_types_compare() raises:
    var spec = ok(
        "fn f(a: i32, b: u64, s: string, xs: list<option<u8>>, t: (int, string)) -> u64\n"
        '  ensures a == b and s != "x" and xs == [some(1), none] and t == (1, s)\n'
        "  ensures result == a\n"
        '  ensures a in [1, 2] and s in [s] and "a" in s\n'
    )
    assert_equal(type_text(spec, spec.clauses[0].expr), "bool")


def test_float_equality_is_rejected_with_the_alternatives() raises:
    var src = "fn f(x: f64) -> f64\n  ensures result == x\n"
    fails(src, "same(a, b)")
    fails(src, "ieee_eq(a, b)")
    fails(src, "real(a) == real(b)")
    fails(src, "eq(a, b")
    fails(src, "f64")


def test_floats_anywhere_in_the_operands() raises:
    for expr in [
        "x != 1",
        "x == 0.5",
        "[x] == [x]",
        "some(x) == none",
        "(x, 1) == (x, 1)",
        "x in [x]",
    ]:
        fails("fn f(x: f64)\n  ensures " + String(expr) + "\n", "floats have no implicit equality")


def test_models_compare_through_observers() raises:
    fails2(
        "model M\n  observe n: int\nfn f(a: M, b: M)\n  ensures a == b\n",
        "handles",
        "eq(a, b, ...)",
    )
    _ = ok("model M\n  observe n: int\nfn f(a: M, b: M)\n  ensures a.n == b.n\n")


def test_in_on_a_handle_is_a_type_error() raises:
    fails(
        "model M\n  observe n: int\nfn f(a: M, x: int)\n  ensures x in a\n",
        "in needs a list, map or string on the right, but it is M",
    )


def test_type_parameters_need_eq() raises:
    fails("fn f<T>(x: T, y: T)\n  ensures x == y\n", "declare it as T: Eq")
    _ = ok("fn f<T: Eq>(x: T, y: T)\n  ensures x == y\n")
    _ = ok("fn f<T: Ord>(x: T, y: T)\n  ensures x != y\n")


def test_real_comparison_is_canonical() raises:
    _ = ok("fn f(x: f64, y: f64)\n  ensures is_finite(x) implies real(x) == real(y)\n")


def test_incompatible_operands() raises:
    fails("fn f(s: string, n: int)\n  ensures s == n\n", "cannot compare string with int")


def test_unknown_types_cannot_decide() raises:
    fails("fn f()\n  ensures [] == []\n", "cannot tell the type")
    _ = ok("fn f(xs: list<int>)\n  ensures xs == [] or xs != []\n")


def test_literal_union_compares_with_its_members() raises:
    _ = ok('fn f(how: "any" | "all")\n  ensures how == "any" or how != "all"\n')
    fails(
        'fn f(how: "any" | "all")\n  ensures how == "anyy"\n',
        '"anyy" is not one of "any" | "all"',
    )


def test_none_unifies_with_any_option() raises:
    _ = ok("fn f(o: option<list<f64>>, p: option<u8>)\n  ensures is_none(o) and p != none\n")


def test_in_on_maps_and_strings() raises:
    _ = ok('fn f(m: map<string, f64>, s: string)\n  ensures s in m and "ab" in s\n')
    fails("fn f(s: string)\n  ensures 1 in s\n", "looks for a substring")
    fails("fn f(n: int)\n  ensures 1 in n\n", "in needs a list, map or string")


def test_ordering() raises:
    _ = ok(
        "fn f(x: f64, n: u8, s: string, b: bytes, xs: list<int>, t: (int, string), "
        "flag: bool)\n"
        '  ensures -1 <= x and x < n and s < "z" and b >= b and xs <= [1] and '
        't > (0, "") and flag >= false\n'
    )
    fails("fn f<T: Eq>(a: T, b: T)\n  ensures a < b\n", "declare it as T: Ord")
    fails("fn f(a: option<int>, b: option<int>)\n  ensures a < b\n", "no total order")
    fails("fn f(s: string)\n  ensures s < 1\n", "cannot compare string with int")
    fails("fn f(xs: list<f64>)\n  ensures xs < xs\n", "no total order")


def test_if_and_let() raises:
    assert_equal(
        ensures_ty("c: bool, o: option<f64>, x: f64", "if c then some(x) else o"),
        "option<f64>",
    )
    assert_equal(ensures_ty("c: bool, a: u8, b: i64", "if c then a else b"), "int")
    assert_equal(ensures_ty("c: bool, a: int", "if c then a else 0.5"), "real")
    fails(
        "fn f(c: bool, x: f64)\n  ensures if c then x else 0\n",
        "branches of if have different types: f64 and int",
    )
    fails(
        "fn f(c: int)\n  ensures if c then true else false\n",
        "condition of if must be a bool",
    )


def test_let_scoping() raises:
    var spec = ok("fn f(x: int)\n  ensures e: let x = [x] in len(x) == 1\n")
    var let = clause_expr(spec, "f.e")
    var inner = List[Int]()
    for n in nodes_of(spec, let, ast.NAME):
        if spec.ast.nodes[n].text == "x":
            inner.append(n)
    # let x = [x]: the value's x is the parameter, the body's x the local.
    assert_equal(len(inner), 2)
    assert_equal(spec.resolution(inner[0]).value().kind, R_PARAM)
    assert_equal(type_text(spec, inner[1]), "list<int>")
    assert_equal(spec.resolution(inner[1]).value().kind, R_LOCAL)
    assert_equal(spec.resolution(inner[1]).value().index, let)
    fails("fn f()\n  ensures (let y = 1 in y == 1) and y == 1\n", "unknown name y")


def test_comprehensions() raises:
    assert_equal(ensures_ty("xs: list<u8>", "count(x in xs: x > 1)"), "int")
    assert_equal(ensures_ty("xs: list<u8>", "sum(x in xs: x)"), "int")
    assert_equal(ensures_ty("xs: list<f32>", "sum(x in xs: x)"), "real")
    assert_equal(ensures_ty("xs: list<u8>", "map(x in xs: [x])"), "list<list<u8>>")
    assert_equal(ensures_ty("xs: list<u8>", "filter(x in xs: x > 1)"), "list<u8>")
    assert_equal(ensures_ty("s: string", "map(c in s: c)"), "list<string>")
    assert_equal(ensures_ty("b: bytes", "map(c in b: c)"), "list<int>")
    assert_equal(ensures_ty("m: map<string, f64>", "map(k in m: k)"), "list<string>")
    assert_equal(ensures_ty("", "map(i in range(0, 3): i * 2)"), "list<int>")
    fails("fn f(xs: list<int>)\n  ensures all(x in xs: x)\n", "body of all(...) must be a bool")
    fails("fn f(n: int)\n  ensures all(x in n: true)\n", "ranges over a list")
    fails("fn f(xs: list<string>)\n  ensures sum(x in xs: x) == 0\n", "adds numbers")


def test_comprehension_variable_is_local() raises:
    var spec = ok("fn f(xs: list<int>)\n  ensures e: all(x in xs: x > 0)\n")
    var comp = clause_expr(spec, "f.e")
    var xs = List[Int]()
    for n in nodes_of(spec, comp, ast.NAME):
        if spec.ast.nodes[n].text == "x":
            xs.append(n)
    assert_equal(len(xs), 1)
    assert_equal(spec.resolution(xs[0]).value().kind, R_LOCAL)
    assert_equal(spec.resolution(xs[0]).value().index, comp)
    assert_equal(type_text(spec, xs[0]), "int")


def test_indexing_and_slicing() raises:
    assert_equal(ensures_ty("xs: list<u8>", "xs[0]"), "u8")
    assert_equal(ensures_ty("s: string", "s[1]"), "string")
    assert_equal(ensures_ty("b: bytes", "b[1]"), "int")
    assert_equal(ensures_ty("m: map<string, f64>", 'm["k"]'), "f64")
    assert_equal(ensures_ty("xs: list<u8>", "xs[1:len(xs)]"), "list<u8>")
    assert_equal(ensures_ty("s: string", "s[0:1]"), "string")
    assert_equal(ensures_ty("b: bytes", "b[0:1]"), "bytes")
    assert_equal(ensures_ty("t: (int, string)", "t.1"), "string")
    fails("fn f(xs: list<int>)\n  ensures xs[0.5] == 0\n", "an index must be an integer")
    fails("fn f(t: (int, int))\n  ensures t[0] == 0\n", "selected with .0")
    fails("fn f(t: (int, int))\n  ensures t.2 == 0\n", "out of range")
    fails("fn f(n: int)\n  ensures n.0 == 0\n", "needs a tuple")
    fails("fn f(n: int)\n  ensures n[0] == 0\n", "cannot index a int")
    fails("fn f(m: map<f64, int>, x: f64)\n  ensures m[x] == 0\n", "map lookup")


def test_list_literals_and_tuples() raises:
    assert_equal(ensures_ty("a: u8", "[a, a]"), "list<u8>")
    assert_equal(ensures_ty("a: u8", "[a, 300]"), "list<int>")
    assert_equal(ensures_ty("", "[[1], []]"), "list<list<int>>")
    fails('fn f()\n  ensures len([1, "a"]) == 2\n', "elements of a list have one type")
    assert_equal(ensures_ty("x: f64", "(x, 1)"), "(f64, int)")


def test_logic_operands_are_bool() raises:
    fails("fn f(n: int)\n  ensures n and true\n", "left operand of and must be a bool")
    fails("fn f(n: int)\n  ensures not n\n", "operand of not must be a bool")
    fails("fn f(n: int)\n  ensures n + 1\n", "the ensures clause must be a bool")


def test_bitwise_operators() raises:
    fails("fn f(a: bool, b: bool)\n  ensures a | b\n", "for booleans write or")
    fails("fn f(a: int, b: string)\n  ensures (a & b) == 0\n", "two integers or two partition sets")
    _ = ok("fn f(a: int, b: int)\n  ensures (a & b) == 0\n")


def test_every_expression_gets_a_type() raises:
    var spec = ok(
        "model M\n  observe n: u8\n  observe at(i: int): f64\n"
        "fn f(m: M, xs: list<f64>) -> M\n"
        "  ensures a: let k = m.n in all(i in range(0, k): is_finite(m.at(i))) and "
        'eq(result, m, float="bits") and len(map(x in xs: real(x))) == k\n'
    )
    var expr = clause_expr(spec, "f.a")
    for n in nodes_of(spec, expr, ast.CALL):
        assert_true(spec.node_types[n] != 0)
    for n in nodes_of(spec, expr, ast.NAME):
        var found = spec.resolution(n)
        assert_true(Bool(found))
        assert_true(spec.node_types[n] != 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
