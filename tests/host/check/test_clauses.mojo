from std.testing import assert_equal, assert_true, TestSuite

from check.testkit import count_errors, fails, fails2, ok


def test_result_is_not_available_before_the_call() raises:
    fails("fn f(x: int) -> int\n  requires result > 0\n", "result is not available in requires")
    fails(
        "error E\nfn f(x: int) -> int\n  raises E when result > 0\n",
        "result is not available in raises",
    )
    fails(
        "error E\nfn f(x: int) -> int\n  may_raise E when result > 0\n",
        "result is not available in may_raise",
    )


def test_no_result_for_unit() raises:
    fails("fn f(x: int)\n  ensures result == 1\n", "f returns nothing")
    fails(
        "interface Q\n  observe n: int\n  method m(self)\n    ensures result == 1\n",
        "Q.m returns nothing",
    )


def test_old_needs_ensures_and_state() raises:
    fails(
        "fn f(x: int) -> int\n  ensures result == old(x)\n",
        "old(...) needs state that the call can change, but f has no handle parameter",
    )
    fails(
        "model M\n  observe n: int\nfn f(m: M)\n  requires old(m.n) == 0\n",
        "old(...) is only allowed in ensures",
    )
    fails(
        "model M\n  observe n: int\nfn f(m: M) -> int\n  relates old(m.n) == result\n",
        "old(...) is only allowed in ensures",
    )
    fails(
        "model M\n  observe n: int\nfn f(m: M)\n  ensures old(old(m.n)) == 0\n",
        "cannot be nested",
    )
    fails(
        "model M\n  observe n: int\nfn f(m: M) -> int\n  ensures old(result) == 0\n",
        "result does not exist before the call",
    )
    fails(
        "model M\n  observe n: int\nfn f(m: M)\n  ensures old(m.n, 1) == 0\n",
        "old takes one expression",
    )
    _ = ok("model M\n  observe n: int\nfn f(m: M) -> int\n  ensures result == old(m.n)\n")
    _ = ok("model M\n  observe n: int\nfn f(ms: list<M>)\n  ensures len(old(ms)) == len(ms)\n")


def test_old_cannot_use_locals_bound_inside() raises:
    fails(
        "model M\n  observe n: int\nfn f(m: M)\n  ensures let k = 1 in old(k) == 1\n",
        "old(...) is evaluated before the call, so it cannot use k, which let binds",
    )


def test_old_in_interfaces() raises:
    _ = ok("interface Q\n  observe n: int\n  method m(self)\n    ensures self.n >= old(self.n)\n")
    fails(
        "interface Q\n  observe n: int\n  new e() -> Q\n    ensures old(1) == 1\n",
        "Q.e has no handle parameter or self",
    )
    fails(
        "interface Q\n  observe n: int\n  invariant old(n) == n\n",
        "old(...) is only allowed in ensures",
    )


def test_spec_function_calls_in_clauses() raises:
    var base = "fn g(x: int) -> int\n"
    _ = ok(base + "fn f(x: int) -> int\n  relates g(x) == result\n")
    _ = ok(base + "fn f(x: int) -> int\n  ensures g(x) == result\n")
    _ = ok(base + "model M\n  observe n: int\n  invariant g(n) == 1\n")
    fails2(
        base + "fn f(x: int) -> int\n  requires g(x) == 1\n",
        "calls the spec function g",
        "only allowed in ensures, relates, invariant and aggregate",
    )
    fails(
        base + "error E\nfn f(x: int) -> int\n  raises E when g(x) == 1\n",
        "calls the spec function g",
    )
    fails(
        base + "fn f(xs: list<int>)\n  partition xs\n    a = g(1) == 1\n",
        "calls the spec function g",
    )
    fails("fn len(x: int) -> int\n  requires len([x]) == 1\n", "shadows the prelude function")


def test_relates_arguments() raises:
    var base = 'fn g(x: i32, s: string = "a") -> i32\n'
    _ = ok(base + 'fn f(x: i32) -> i32\n  relates g(x + 1) == result and g(x * 2, s="b") >= 0\n')
    _ = ok(base + "fn f(x: i8) -> i32\n  relates g(-x) == result and g(x / 2) == 0\n")
    fails(
        base + 'fn f(x: i32) -> i32\n  relates g("a") == result\n',
        "argument x of g is a i32, but this is string",
    )
    fails(base + "fn f(x: i32) -> i32\n  relates g() == result\n", "g needs argument x")
    fails(
        base + 'fn f(x: i32) -> i32\n  relates g(1, "a", 2) == result\n',
        "g takes 2 argument(s)",
    )
    fails(
        base + 'fn f(x: i32) -> i32\n  relates g(1, t="a") == result\n',
        "g has no parameter named t",
    )
    fails(base + "fn f(x: i32) -> i32\n  relates g(1, x=2) == result\n", "given twice")


def test_relates_float_arguments() raises:
    var base = "fn g(x: f32) -> f32\n"
    _ = ok(base + "fn f(x: f32) -> f32\n  relates same(g(-x), result) and is_nan(g(0.5))\n")
    fails(
        base + "fn f(x: f32) -> f32\n  relates same(g(x), 1)\n",
        "same compares two values of one type",
    )


def test_generic_spec_function_calls() raises:
    var base = "fn sort<T: Ord>(xs: list<T>) -> list<T>\n"
    var spec = ok(base + "fn f<U: Ord>(xs: list<U>) -> list<U>\n  relates r: sort(xs) == result\n")
    var expr = spec.clauses[spec.clause_named("f.r").value()].expr
    assert_equal(spec.types.text(spec.node_types[spec.ast.kid(expr, 0)]), "list<U>")
    _ = ok(base + "fn f(xs: list<i64>) -> list<i64>\n  relates sort(xs + [1]) == result\n")
    fails(
        base + "fn f(xs: list<f64>)\n  relates len(sort(xs)) == 0\n",
        "f64 does not satisfy T: Ord",
    )
    fails(
        base + "fn f<U: Eq>(xs: list<U>)\n  relates len(sort(xs)) == 0\n",
        "U does not satisfy T: Ord",
    )


def test_invariants_see_fields_only() raises:
    _ = ok("model M\n  observe xs: list<int>\n  observe n: u64\n  invariant n == len(xs)\n")
    fails(
        "model M\n  observe n: int\n  invariant result == 1\n",
        "an invariant describes an object's state",
    )
    fails(
        "model M\n  observe n: int\n  observe at(i: int): int\n  invariant at == 1\n",
        "at takes arguments",
    )
    fails("model M\n  observe n: int\n  invariant m == 1\n", "unknown name m")
    fails("model M\n  observe n: int\n  invariant n\n", "an invariant must be a bool")
    fails("model M\n  observe n: int\n  invariant at(1) == 1\n", "unknown function at")


def test_fields_are_not_bare_names_in_methods() raises:
    fails(
        "interface Q\n  observe items: list<int>\n  method m(self)\n"
        "    ensures len(items) == 0\n",
        "did you mean self.items?",
    )
    fails(
        "model M\n  observe rows: list<int>\nfn f(df: M)\n  ensures len(rows) == 0\n",
        "did you mean df.rows?",
    )


def test_self() raises:
    fails("fn f()\n  ensures self == self\n", "self is only available in methods")
    fails(
        "interface Q\n  observe n: int\n  new e() -> Q\n    ensures self.n == 0\n",
        "a constructor has no self",
    )


def test_modifies() raises:
    var model = "model M\n  observe n: int\n"
    _ = ok(model + "fn f(m: M, k: M)\n  modifies m, k\n")
    _ = ok("interface Q\n  observe n: int\n  method m(self)\n    modifies self\n")
    fails(
        model + "fn f(m: M, x: int)\n  modifies x\n",
        "modifies names handle parameters (models or interfaces) or self; x is a int",
    )
    fails(model + "fn f(m: M)\n  modifies q\n", "f has no parameter q")
    fails(model + "fn f(m: M)\n  modifies self\n", "self is only available in methods")
    fails(model + "fn f(m: M)\n  modifies m, m\n", "lists m twice")


def test_errors_are_qualified_and_need_no_declaration() raises:
    var spec = ok(
        "fn f(x: int)\n  raises Oops when x > 0\n  may_raise Oops\n"
        "  may_raise pkg.Other when x < 0\n"
    )
    assert_equal(spec.clauses[0].error, "builtins.Oops")
    assert_equal(spec.clauses[1].error, "builtins.Oops")
    assert_equal(spec.clauses[2].error, "pkg.Other")
    assert_equal(spec.clauses[1].expr, 0)
    assert_true(spec.clauses[0].expr != 0)


def test_clause_placement() raises:
    fails("fn f(x: int)\n  invariant x > 0\n", "invariant belongs to a model or interface")
    fails(
        "model M\n  observe n: int\n  requires n > 0\n",
        "requires belongs to a function, constructor or method, not to model M",
    )
    fails("interface Q\n  observe n: int\n  ensures n > 0\n", "not to interface Q")
    _ = ok("model M\n  observe n: int\n  unspecified order\n  perf whatever\n")


def test_freedoms_cannot_be_observed() raises:
    var frame = "model F\n  observe n: int\n  observe layout: int\n"
    fails(
        frame
        + "fn f(df: F) -> F\n  ensures not shares_memory(result, df)\n"
        "  unspecified shares_memory\n",
        "observes shares_memory, which f declares unspecified",
    )
    fails(
        frame + "fn f(df: F) -> F\n  ensures result.layout == 0\n  impl_defined layout\n",
        "observes layout",
    )
    fails(
        frame + "fn f(df: F)\n  unspecified a\n  impl_defined a\n",
        "a is already declared a freedom of f",
    )
    _ = ok(frame + "fn f(df: F) -> F\n  ensures fresh(result)\n  unspecified shares_memory\n")


def test_duplicate_declarations_report_once() raises:
    assert_equal(
        count_errors("fn f(x: int)\n  ensures a: x > 0\nfn f(x: int)\n  ensures a: y > 0\n"), 1
    )


def test_all_errors_are_reported_together() raises:
    assert_equal(
        count_errors(
            "fn f(x: f64) -> int\n  requires result > 0\n  ensures x == x\n  ensures nope\n"
        ),
        3,
    )


def test_errors_come_in_source_order() raises:
    from check.testkit import error_lines

    var lines = error_lines("fn f(x: f64)\n  ensures nope\n  ensures x == x\n  requires zz\n")
    assert_equal(len(lines), 3)
    assert_true(lines[0].startswith("t.spec:3:"))
    assert_true(lines[1].startswith("t.spec:4:"))
    assert_true(lines[2].startswith("t.spec:5:"))
    assert_equal(lines[0], "t.spec:3:11: unknown name nope")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
