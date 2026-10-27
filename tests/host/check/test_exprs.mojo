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


def test_types() raises:
    want("x: f16", "is_subnormal(x)", "bool")
    want("x: bf16", "bits(x)", "int")
    want("x: f32", "next_up(x)", "f32")
    want("x: f64", "next_down(x)", "f64")
    want("x: f64", "ulp<f32>(real(x))", "real")
    want("x: f64, y: f64", "qe(x, y)", "qerr")
    want("x: f16", "qe<f16>(x, 0.5)", "qerr")
    want("x: f16", "qe<f16>(1, real(x))", "qerr")
    want("x: f64, y: f64", "steps(qe(x, y))", "int")
    want("x: f64, y: f64", "nans(qe(x, y)) + 1", "int")
    want("x: f64, y: f64", "qe(x, y) + qe(y, x)", "qerr")
    want("x: bf16", "cr.exp(x)", "bf16")
    want("x: f32", "cr.sqrt(cr.log(x))", "f32")
    want("x: f64", "round<f32>(mp.exp(x))", "f32")
    want("n: i64", "wrap<u8>(n * 3)", "u8")
    want("n: i64", "fits<i32>(n)", "bool")
    want("x: f64", "fits<f32>(x)", "bool")
    want("r: f64", "fits<u8>(real(r) / 2)", "bool")
    want("b: bytes", "le_uint(b)", "int")
    want("m: map<string, u8>", "keys(m)", "list<string>")
    want("m: map<string, u8>", "values(m)", "list<u8>")
    want("xs: list<string>", "sorted(xs)", "list<string>")
    want("xs: list<string>", 'index_of(xs, "a")', "int")
    want("xs: list<u8>", "is_subsequence(xs, [1])", "bool")
    want("x: u8", "some(x)", "option<u8>")
    want("o: option<list<u8>>", "unwrap(o)", "list<u8>")
    want("b: bytes", "valid_utf8(b)", "bool")
    want("xs: list<f64>", 'eq(xs, xs, float="nan_any", order="ignore")', "bool")
    want("x: f64, y: f64", "ieee_eq(x, y)", "bool")
    want("x: u8", "mp.atan(x)", "real")
    want("x: f64, y: f64", "same(x, y)", "bool")
    want("s: string", "codepoints(s)", "list<int>")
    want("n: u64", "bit_length(n)", "int")
    want("xs: list<u32>", "from_codepoints(xs)", "string")
    want("x: f64, y: f64", "qe(x, y).steps + qe(x, y).nans", "int")
    want("x: f64, y: f64", "let e = qe(x, y) in e.steps", "int")


def err(params: String, expr: String, message: String) raises:
    fails("fn f(" + params + ")\n  ensures let v = " + expr + " in true\n", message)


def test_errors() raises:
    err("n: int", "is_nan(n)", "is_nan takes a float, but argument 1 is int")
    err("n: int", "bits(n)", "bits takes a float")
    err("x: f64", "wrap<f64>(1)", "the type argument must be a fixed-width integer type")
    err("x: f64", "round<i32>(x)", "the type argument must be a float type")
    err("x: f64", "wrap(x)", "wrap needs a type argument")
    err("x: f64", "wrap<i8>(x)", "wrap takes an integer, but argument 1 is f64")
    err("x: f64", "wrap<i8, i16>(1)", "wrap takes 1 type argument(s)")
    err("x: f64", "qe(x)", "qe takes 2 arguments")
    err("x: f64", "qe(x, 1)", "qe compares two floats of one format, but argument 2 is int")
    err("x: f64", "qe(x, mp.cos(x))", "round a real first")
    err("x: f64, y: f32", "qe(x, y)", "but got f64 and f32")
    err("x: f64", "qe<f32>(x, 1)", "qe<f32> compares f32 values, but argument 1 is f64")
    err("x: f64", 'qe<f64>(x, "a")', "qe<f64> takes f64 values or numbers")
    err("x: f64", "qe<i32>(x, x)", "the type argument must be a float type")
    err("x: f64", "qe<f64, f64>(x, x)", "qe takes 1 type argument(s)")
    err("x: f64", "steps(x)", "steps takes a qerr")
    err("n: int", "nans(n)", "nans takes a qerr")
    err("n: int", "cr.cos(n)", "cr.cos rounds in the format of its argument")
    err("n: int", "cr.cos(n)", "for a real use mp.cos")
    err("x: f64", "cr.cos(x, x)", "cr.cos takes 1 argument")
    err("n: int", "len(n)", "len takes a list, string, bytes or map")
    err("xs: list<f64>", "sorted(xs)", "sorted needs ordered elements")
    err("xs: list<f64>", "is_sorted(xs)", "map them to real(x) first")
    err("xs: list<f64>", "distinct(xs)", "distinct compares elements with ==")
    err("xs: list<f64>", "is_permutation(xs, xs)", "no canonical equality")
    err("xs: list<int>, ys: list<string>", "is_permutation(xs, ys)", "two lists of one")
    err("xs: list<string>", "index_of(xs, 1)", "index_of looks for a string")
    err("x: f64", "eq([x], [x])", 'float="bits"')
    err("x: f64", 'eq(x, x, float="exact")', 'float= must be one of "bits"')
    err("x: f64", 'eq(x, x, float="bits", order="any")', "order= must be one of")
    err("x: f64", 'eq(x, x, floats="bits")', "eq has no argument named floats")
    err("x: f64", "same(x, 1)", "same compares two values of one type")
    err("n: int", "fresh(n)", "fresh takes a model or interface handle")
    err("x: f64", "range(0, x)", "range takes an integer")
    err("s: string", "mp.cos(s)", "mp.cos takes a number")
    err("n: int", "unwrap(n)", "unwrap takes an option")
    err("n: int", "le_uint(n)", "le_uint takes bytes")
    err("n: int", "len(n, n)", "len takes 1 argument")
    err("x: f64", "bit_length(x)", "bit_length takes an integer")
    err("xs: list<string>", "from_codepoints(xs)", "from_codepoints takes a list of integers")
    err("n: int", "n.steps", "int has no field steps")
    err("x: f64, y: f64", "qe(x, y).other", "qerr has no part other")


def test_eq_needs_float_mode_through_models() raises:
    var frame = "model F\n  observe rows: list<list<option<f64>>>\n"
    fails(frame + "fn f(a: F, b: F)\n  ensures eq(a, b)\n", "which contain floats")
    _ = ok(frame + 'fn f(a: F, b: F)\n  ensures eq(a, b, float="bits")\n')
    _ = ok("model G\n  observe n: int\nfn f(a: G, b: G)\n  ensures eq(a, b)\n")


def test_identity_functions() raises:
    _ = ok(
        "model M\n  observe n: int\nfn f(a: M) -> M\n"
        "  ensures fresh(result) and not same_object(a, result) and "
        "not shares_memory(a, result)\n"
    )


def test_unknown_functions_and_names() raises:
    fails(
        "fn f(x: f64)\n  ensures cos(x) == 1\n",
        "unknown function cos (did you mean mp.cos or cr.cos?)",
    )
    fails("fn f(x: f64)\n  ensures mp.cosh(x) == 1\n", "unknown function mp.cosh: mp holds")
    fails("fn f(x: f64)\n  ensures cr.cosh(x) == 1\n", "unknown function cr.cosh: cr holds")
    fails("fn f(x: f64)\n  ensures mp.cos == 1\n", "mp.cos is a function: call it")
    fails("fn f(x: f64)\n  ensures same(cr.cos, x)\n", "cr.cos is a function: call it")
    fails("fn f(x: f64)\n  ensures cr\n", "cr is the namespace of the correctly rounded")
    fails("fn f(cr: f64)\n", "cr is reserved")
    fails("fn f(x: f64)\n  ensures x(1)\n", "x is a value, not a function")
    fails("fn f(x: f64)\n  ensures len\n", "len is a function")
    fails("fn f(x: f64)\n  ensures f64\n", "f64 is a type, not a value")
    fails("fn f(x: f64)\n  ensures nope\n", "unknown name nope")
    fails("fn f(x: f64)\n  ensures old\n", "old is called as old(e)")
    fails("fn f(x: f64)\n  ensures let result = 1 in true\n", "result is reserved")
    fails("fn f(x: f64)\n  ensures x.foo\n", "f64 has no field foo")
    fails("fn f(t: (int, int))\n  ensures t.a == 1\n", "tuple fields are numbered")
    fails(
        "model M\n  observe n: int\nfn f(m: M)\n  ensures m.q == 1\n",
        "M has no observer q (its observers: n)",
    )
    fails(
        "model M\n  observe n: int\nfn f(m: M)\n  ensures m.n(1) == 1\n",
        "n is a field of M and takes no arguments",
    )
    fails(
        "model M\n  observe at(i: int): int\nfn f(m: M)\n  ensures m.at == 1\n",
        "at takes arguments: at(i)",
    )
    fails(
        'model M\n  observe at(i: int): int\nfn f(m: M)\n  ensures m.at("a") == 1\n',
        "argument i of M.at is a int, but this is string",
    )
    fails("record R { a: int }\nfn f(r: R)\n  ensures r.b == 1\n", "record R has no field b")
    fails("enum E { A }\nfn f(e: E)\n  ensures e == E.B\n", "enum E has no member B")
    fails(
        "enum E { A }\nenum G { A }\nfn f(e: E)\n  ensures e == A\n",
        "A is a member of several enums",
    )


def test_type_constants() raises:
    assert_equal(ensures_ty("", "i32.max"), "int")
    assert_equal(ensures_ty("", "u64.min"), "int")
    assert_equal(ensures_ty("", "f64.max"), "f64")
    assert_equal(ensures_ty("", "-f16.min"), "f16")


def test_literal_union_and_maps_and_records() raises:
    var spec = ok('fn f(how: "any" | "all" = "any")\n  ensures how == "all" or true\n')
    assert_equal(spec.types.text(spec.fns[0].params[0].type), '"any" | "all"')
    var spec2 = ok(
        "record P { k: string, v: u8 }\nfn f(m: map<string, P>) -> u8\n"
        "  ensures e: all(k in keys(m): m[k].v <= 255) and result >= 0\n"
    )
    assert_equal(spec2.types.text(spec2.fns[0].params[0].type), "map<string, P>")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
