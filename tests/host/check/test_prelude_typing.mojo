from std.testing import assert_equal, TestSuite

from check.testkit import ensures_ty, fails, ok


def want(params: String, expr: String, expected: String) raises:
    assert_equal(ensures_ty(params, expr), expected)


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
