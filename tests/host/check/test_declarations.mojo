from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check_testkit import (
    error_lines,
    clause_expr,
    count_errors,
    descendants,
    fails,
    fails2,
    named,
    nodes_of,
    ok,
    parents,
    type_text,
)
from spec import types as ty
from spec import ast
from spec.prelude_names import prelude_id
from spec.spec import ResolutionKind, Spec


def test_spec_tables() raises:
    var spec = ok(
        "error E\nenum Color { Red }\nrecord R { a: int, b: list<f64> }\n"
        "type Row = list<option<f64>>\n"
        "model M<T>\n  observe items: list<T>\n  observe at(i: int): T\n"
        "interface Q<T: Ord>\n  observe items: list<T>\n  new empty() -> Q\n"
        "  new of(xs: list<T>) -> Q<T>\n  method pop(self) -> T\n  method clear(self)\n"
        "fn f<K: Eq>(m: M<K>, r: R, row: Row) -> option<K>\n"
        "fn g()\n"
    )
    assert_equal(spec.name, "t")
    assert_equal(len(spec.errors), 1)
    assert_equal(spec.errors[0], "builtins.E")
    assert_equal(len(spec.enums), 1)
    assert_equal(spec.types.text(spec.enums[0]), "Color")
    assert_equal(spec.types.infos[spec.enums[0]].names[0], "Red")
    assert_equal(len(spec.records), 1)
    var r = spec.types.infos[spec.records[0]].copy()
    assert_equal(r.name, "R")
    assert_equal(r.names[1], "b")
    assert_equal(spec.types.text(r.args[1]), "list<f64>")
    assert_equal(spec.types.text(spec.aliases.get("Row").value()), "list<option<f64>>")
    assert_equal(len(spec.models), 2)
    assert_false(spec.models[0].is_interface)
    assert_true(spec.models[1].is_interface)
    assert_equal(spec.types.text(spec.models[0].type), "M<T>")
    assert_equal(spec.types.text(spec.models[1].type), "Q<T>")
    assert_equal(spec.models[1].bounds[0], "Ord")
    var m = spec.models[0].copy()
    assert_equal(spec.types.text(m.observers[0].type), "list<T>")
    assert_equal(len(m.observers[1].params), 1)
    assert_equal(m.observers[1].params[0].name, "i")
    var q = spec.models[1].copy()
    assert_equal(len(q.ctors), 2)
    assert_equal(len(q.methods), 2)
    var pop = spec.fns[q.methods[0]].copy()
    assert_equal(pop.name, "pop")
    assert_equal(pop.target, "Q.pop")
    assert_equal(pop.decl_id, "Q.pop")
    assert_true(pop.receiver)
    assert_equal(pop.kind, ast.NodeKind.METHOD)
    assert_equal(pop.owner, 1)
    assert_equal(spec.types.text(pop.result), "T")
    assert_equal(spec.types.text(pop.params[0].type), "Q<T>")
    assert_equal(spec.types.text(spec.fns[q.methods[1]].result), "unit")
    var empty = spec.fns[q.ctors[0]].copy()
    assert_equal(empty.kind, ast.NodeKind.CTOR)
    assert_equal(spec.types.text(empty.result), "Q<T>")
    assert_false(empty.receiver)
    assert_equal(spec.types.text(spec.fns[q.ctors[1]].params[0].type), "list<T>")
    var f = spec.fns[spec.fn_named("f").value()].copy()
    assert_equal(f.tparams[0], "K")
    assert_equal(f.bounds[0], "Eq")
    assert_equal(spec.types.text(f.params[0].type), "M<K>")
    assert_equal(spec.types.text(f.params[1].type), "R")
    assert_equal(spec.types.text(f.params[2].type), "list<option<f64>>")
    assert_equal(spec.types.text(f.result), "option<K>")
    assert_equal(f.target, "f")
    assert_equal(f.owner, -1)
    assert_equal(spec.types.text(spec.fns[spec.fn_named("g").value()].result), "unit")


def decl_error(body: String, message: String) raises:
    fails(body, message)


def test_declaration_errors() raises:
    decl_error("fn f(x: float)\n", "unknown type float (did you mean f64?)")
    decl_error("fn f(x: Nope)\n", "unknown type Nope")
    decl_error("fn f(x: list)\n", "list takes 1 type argument")
    decl_error("fn f(x: map<int>)\n", "map takes 2 type arguments")
    decl_error("fn f(x: f64<int>)\n", "f64 takes no type arguments")
    decl_error("model M<T>\nfn f(x: M)\n", "M takes 1 type argument(s): M<T>")
    decl_error("interface Q<T: Eq>\nfn f(q: Q<f64>)\n", "f64 does not satisfy T: Eq of Q")
    decl_error("model M<T: Ord>\nfn f<U: Eq>(m: M<U>)\n", "U does not satisfy T: Ord")
    decl_error("fn f<T: Num>(x: T)\n", "unknown bound Num")
    decl_error("fn f<T, T>(x: T)\n", "type parameter T is declared twice")
    decl_error("fn f(x: int, x: int)\n", "parameter x is declared twice")
    decl_error("fn f(result: int)\n", "result is reserved")
    decl_error("fn f()\nfn f()\n", "f is already declared at line 2")
    decl_error(
        "fn f(x: int)\n  ensures x > 0\nfn f(x: int)\n  ensures x > 0\n", "already declared"
    )
    decl_error("error f64\n", "f64 is a built-in type")
    decl_error("model old\n", "old is reserved")
    decl_error("type A = B\ntype B = A\n", "defined in terms of itself")
    decl_error("record R { r: R }\n", "record R contains itself")
    decl_error("record R { a: int, a: int }\n", "two fields named a")
    decl_error("enum E { A, A }\n", "lists a member twice")
    decl_error("fn f(x: set<f64>)\n", "set is not a type")
    decl_error("fn f(x: list<real>)\n", "real is clause-only")
    decl_error("interface Q\n  new e() -> int\n", "a constructor returns its interface")
    decl_error(
        "interface Q\n  observe a: int\n  method a(self)\n", "already has a member named a"
    )
    decl_error("fn f(x: (int, Nope))\n", "unknown type Nope")
    decl_error("fn f(x: int, self)\n", "self is the receiver")


def test_default_errors() raises:
    decl_error('fn f(how: "any" | "all" = "anyy")\n', '"anyy" is not one of')
    decl_error("fn f(n: u8 = 300)\n", "300 is not a u8 value")
    decl_error("fn f(n: i8 = -129)\n", "-129 is not a i8 value")
    decl_error("fn f(x: f64 = 0.1)\n", "not exactly representable as f64")
    decl_error("fn f(x: f16 = 0x1p-25)\n", "not exactly representable as f16")
    decl_error('fn f(n: int = "a")\n', "the default of n must be a int")
    decl_error("fn f(n: int = m)\n", "unknown name m")


def test_good_defaults() raises:
    _ = ok(
        'fn f(how: "any" | "all" = "any", n: u8 = 255, k: i8 = -128, x: f64 = 0.5, '
        "y: f16 = 0x1p-24, z: f64 = -0x1p-1074, w: i32 = i32.max, o: option<u8> = none, "
        "xs: list<u8> = [1, 2])\n"
    )


def test_clause_ids() raises:
    var spec = ok(
        "error E\n"
        "model M\n  observe n: int\n  invariant pos: n >= 0\n  invariant n < 10\n"
        "fn f(x: int) -> int\n  requires x > 0\n  ensures big: result > x\n"
        "  raises E when x > 9\n  impl_defined order\n"
        "interface Q\n  observe n: int\n  invariant n >= 0\n"
        "  new make() -> Q\n    ensures z: result.n == 0\n"
        "  method inc(self)\n    modifies self\n    ensures up: self.n == old(self.n) + 1\n"
    )
    var want = [
        "M.pos", "M#2", "f#1", "f.big", "f#3", "f#4", "Q#1", "Q.make.z", "Q.inc#1",
        "Q.inc.up",
    ]
    assert_equal(len(spec.clauses), len(want))
    for i in range(len(want)):
        assert_equal(spec.clauses[i].id, want[i])
        assert_equal(spec.clause_named(want[i]).value(), i)
    assert_equal(spec.clauses[1].label, "")
    assert_equal(spec.clauses[0].label, "pos")
    assert_equal(spec.clauses[0].owner_fn, -1)
    assert_equal(spec.clauses[0].owner_model, 0)
    assert_equal(spec.clauses[3].owner_fn, spec.fn_named("f").value())
    assert_equal(spec.clauses[3].kind, ast.Op.ENSURES)
    assert_equal(spec.clauses[4].error, "builtins.E")
    assert_equal(spec.clauses[5].names[0], "order")
    assert_equal(spec.clauses[8].names[0], "self")
    assert_equal(spec.clauses[8].expr, 0)
    assert_equal(len(spec.models[0].clauses), 2)
    assert_equal(spec.fns[spec.fn_named("f").value()].clauses[1], 3)


def test_labels_are_unique_per_declaration() raises:
    fails(
        "fn f(x: int)\n  ensures a: x > 0\n  ensures a: x > 1\n",
        "clause label a is already used in f (line 3)",
    )
    _ = ok("fn f(x: int)\n  ensures a: x > 0\nfn g(x: int)\n  ensures a: x > 0\n")


def test_labels_and_names_share_nothing() raises:
    _ = ok("fn f(x: int)\n  ensures len: x > 0\n  ensures x: len([x]) == 1\n")


def test_type_clause_labels_cannot_take_a_member_id() raises:
    for pair in [("make", "constructor"), ("inc", "method"), ("n", "observer")]:
        var label = String(pair[0])
        var kind = String(pair[1])
        var src = (
            "interface Q\n  observe n: int\n  invariant "
            + label
            + ": n >= 0\n  new make() -> Q\n  method inc(self)\n    modifies self\n"
        )
        fails(
            src,
            "clause label "
            + label
            + " gives the ID Q."
            + label
            + ", which already names the "
            + kind
            + " Q."
            + label
            + ": rename the label (e.g. invariant "
            + label
            + "_holds:)",
        )
    fails(
        "model M\n  observe n: int\n  invariant n: n >= 0\n",
        "clause label n gives the ID M.n, which already names the observer M.n",
    )
    var spec = ok(
        "interface Q\n  observe n: int\n  invariant positive: n >= 0\n"
        "  new make() -> Q\n  method inc(self)\n    modifies self\n"
    )
    assert_equal(spec.clauses[0].id, "Q.positive")
    assert_equal(spec.clauses[1].id, "Q.inc#1")
    _ = ok("interface Q\n  observe n: int\n  new make() -> Q\n    ensures make: result.n == 0\n")


def test_missing_files() raises:
    fails("use \"other.spec\"\n", "cannot read use file other.spec")
    fails("prelude \"x.prelude\"\n", "cannot read prelude file x.prelude")


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
    assert_equal(spec.types.text(spec.node_types[spec.ast.child(expr, 0)]), "list<U>")
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
    var lines = error_lines("fn f(x: f64)\n  ensures nope\n  ensures x == x\n  requires zz\n")
    assert_equal(len(lines), 3)
    assert_true(lines[0].startswith("t.spec:3:"))
    assert_true(lines[1].startswith("t.spec:4:"))
    assert_true(lines[2].startswith("t.spec:5:"))
    assert_equal(lines[0], "t.spec:3:11: unknown name nope")


def test_fixed_width_classes_are_sets() raises:
    var spec = ok(
        "fn f(x: i64, y: u8, b: bool, z: f32)\n"
        "  partition x\n"
        "    lo = i64.range(none, i32.min)\n"
        "    mid = i64.range(i32.min, i32.max + 1)\n"
        "    hi = i64.all - lo - mid\n"
        "  partition y\n"
        "    small = {0, 1, 2}\n"
        "    big = u8.all - small\n"
        "  partition b\n"
        "    t = {true}\n"
        "    f = bool.all - t\n"
        "  partition z\n"
        "    special = f32.nan | f32.inf | {0, f32.max, -f32.max}\n"
        '    pat = f32.pattern("0 11111111 0*")\n'
        "    other = f32.all - special - pat\n"
    )
    var fun = spec.fns[spec.fn_named("f").value()].copy()
    assert_equal(len(fun.partitions), 4)
    var want = ["set<i64>", "set<u8>", "set<bool>", "set<f32>"]
    var counts = [3, 2, 2, 3]
    for i in range(4):
        assert_equal(len(fun.partitions[i].classes), counts[i])
        assert_equal(fun.partitions[i].param, i)
        for cls in fun.partitions[i].classes:
            assert_equal(type_text(spec, cls.expr), want[i])
    var lo = fun.partitions[0].classes[0].expr
    var none = spec.ast.child(spec.ast.child(lo, 2), 0)
    assert_equal(spec.ast.nodes[none].kind, ast.NodeKind.NONE)
    assert_equal(type_text(spec, none), "option<?>")


def test_predicate_classes() raises:
    var spec = ok(
        "model M\n  observe n: int\n"
        "fn f(xs: list<int>, s: string, m: M)\n"
        "  partition xs\n"
        "    empty = len(xs) == 0\n"
        "    one = len(xs) == 1\n"
        "    more = not empty and not one\n"
        "  partition m\n"
        "    zero = m.n == 0\n"
        "    other = m.n != 0\n"
    )
    var fun = spec.fns[spec.fn_named("f").value()].copy()
    var part = fun.partitions[0].copy()
    var more = part.classes[2].expr
    var empty_ref = named(spec, more, ast.NodeKind.NAME, "empty")[0]
    var one_ref = named(spec, more, ast.NodeKind.NAME, "one")[0]
    assert_equal(spec.resolution(empty_ref).value().kind, ResolutionKind.CLASS)
    assert_equal(spec.resolution(empty_ref).value().index, part.classes[0].node)
    assert_equal(spec.resolution(one_ref).value().index, part.classes[1].node)
    for p in fun.partitions:
        for cls in p.classes:
            assert_equal(type_text(spec, cls.expr), "bool")
    assert_equal(fun.partitions[1].param, 2)


def partition_error(body: String, message: String) raises:
    fails(body, message)


def test_partition_errors() raises:
    partition_error(
        "fn f(x: f64)\n  partition x\n    nan = is_nan(x)\n",
        "classes of the fixed-width parameter x are sets of values, so x cannot appear",
    )
    partition_error("fn f(x: f64)\n  partition x\n    a = x > 0\n", "x cannot appear in them")
    partition_error(
        "fn f(x: i64)\n  partition x\n    a = i32.all\n",
        "class a of the i64 parameter x must be a set of i64 values",
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f32.nan | f64.nan\n",
        "cannot combine a set of f32 with a set of f64",
    )
    partition_error("fn f(x: f64)\n  partition x\n    a = 1\n", "must be a set of f64 values")
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = b\n    b = f64.nan\n", "unknown name b"
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.nan\n    a = f64.inf\n",
        "already has a class named a",
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.all\n  partition x\n    b = f64.all\n",
        "x is already partitioned at line 3",
    )
    partition_error("fn f(x: f64)\n  partition y\n    a = f64.all\n", "f has no parameter y")
    partition_error(
        "fn f(x: f64)\n  partition x\n    x = f64.all\n",
        "class x has the name of a parameter",
    )
    partition_error('fn f(x: f64)\n  partition x\n    a = {"s"}\n', "a member of a set of f64")
    partition_error("fn f(x: u8)\n  partition x\n    a = {0.5}\n", "a member of a set of u8")
    partition_error("fn f(x: f64)\n  partition x\n    a = f64.range(0)\n", "takes two bounds")
    partition_error(
        'fn f(x: f64)\n  partition x\n    a = f64.range("a", none)\n',
        "a bound of f64.range must be a number or none",
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.pattern(1)\n", "takes one string literal"
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.bogus\n", "f64 has no constant bogus"
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.range\n", "f64.range is called"
    )
    partition_error("fn f(x: i8)\n  partition x\n    a = i8.nan\n", "i8 has no constant nan")
    partition_error(
        "fn f(x: bool)\n  partition x\n    a = bool.range(0, 1)\n", "bool has no range"
    )
    partition_error(
        "fn f(xs: list<int>, n: int)\n  partition xs\n    a = len(xs) == n\n",
        "a class of partition xs may only refer to xs, not to n",
    )
    partition_error(
        "fn f(xs: list<int>)\n  partition xs\n    a = len(xs)\n",
        "class a (a predicate over xs) must be a bool",
    )
    partition_error(
        "fn f(xs: list<int>)\n  partition xs\n    a = f64.nan\n", "f64.nan is a partition set"
    )
    partition_error(
        "fn f(xs: list<int>)\n  partition xs\n    a = {1}\n", "{...} is a partition set"
    )
    partition_error(
        "interface Q\n  observe n: int\n  method m(self)\n    partition self\n      a = true\n",
        "self cannot be partitioned",
    )
    partition_error(
        "fn f(x: f64) -> f64\n  partition x\n    a = f64.range(0, result)\n",
        "a partition class describes an input",
    )


def test_sets_outside_partitions() raises:
    fails(
        "fn f(x: f64)\n  requires x in f64.nan\n",
        "f64.nan is a partition set",
    )
    fails("fn f(x: f64)\n  requires x in f64.nan\n", "test the value with is_nan(x)")
    fails(
        "fn f(x: f64)\n  ensures f64.range(0, 1) == f64.range(0, 1)\n",
        "f64.range(...) is a partition set",
    )


comptime SRC = (
    "error Boom\n"
    "enum Color { Red, Green }\n"
    "record Pt { x: int, y: f64 }\n"
    "model Frame\n"
    "  observe columns: list<string>\n"
    "  observe cell(i: u64, name: string): option<f64>\n"
    "  invariant uniq: distinct(columns) and len(columns) >= 0\n"
    '  invariant cells: all(i in range(0, 3): is_none(cell(i, "a")) or true)\n'
    "fn g(x: f64) -> f64\n"
    "fn f(x: f64, df: Frame, p: Pt, c: Color) -> f64\n"
    "  partition x\n"
    "    nan  = f64.nan\n"
    "    small = f64.range(-1, 1) & f64.finite - nan\n"
    "    rest = f64.all - nan - small\n"
    "  raises Boom when c == Red\n"
    "  ensures a: p.x == 1 and c != Color.Green and i32.max > 0 and same(f64.max, x)\n"
    '  ensures b: is_none(df.cell(0, "a")) and len(df.columns) == 0\n'
    "  ensures m: is_finite(x) implies real(result) <= mp.cos(x) + 1\n"
    "  ensures q: qe(result, cr.cos(x)) <= 1\n"
    "  ensures o: old(df.columns) == df.columns\n"
    "  relates r: same(g(-x), result)\n"
    "interface Q<T: Eq>\n"
    "  observe items: list<T>\n"
    "  invariant ok: len(items) >= 0 and len(self.items) >= 0\n"
    "  new empty() -> Q\n"
    "    ensures e: len(result.items) == 0\n"
    "  method push(self, x: T)\n"
    "    ensures p: self.items == old(self.items) + [x]\n"
)


def res_kind(spec: Spec, n: Int) -> Int:
    var r = spec.resolution(n)
    return Int(r.value().kind) if r else -1


def only_name(spec: Spec, root: Int, text: String) raises -> Int:
    var found = named(spec, root, ast.NodeKind.NAME, text)
    assert_equal(len(found), 1)
    return found[0]


def test_params_fields_types_and_enums() raises:
    var spec = ok(SRC)
    var a = clause_expr(spec, "f.a")
    var p = only_name(spec, a, "p")
    assert_equal(res_kind(spec, p), Int(ResolutionKind.PARAM))
    assert_equal(spec.resolution(p).value().index, 2)
    assert_equal(spec.resolution(only_name(spec, a, "c")).value().index, 3)
    var xs = named(spec, a, ast.NodeKind.ATTR, "x")
    assert_equal(len(xs), 1)
    var field = spec.resolution(xs[0]).value().copy()
    assert_equal(field.kind, ResolutionKind.RECORD_FIELD)
    assert_equal(field.index, 0)
    assert_equal(spec.types.text(field.owner), "Pt")
    var green = named(spec, a, ast.NodeKind.ATTR, "Green")[0]
    assert_equal(spec.resolution(green).value().kind, ResolutionKind.ENUM_MEMBER)
    assert_equal(spec.resolution(green).value().index, 1)
    assert_equal(type_text(spec, green), "Color")
    var maxes = named(spec, a, ast.NodeKind.ATTR, "max")
    assert_equal(len(maxes), 2)
    assert_equal(res_kind(spec, maxes[0]), Int(ResolutionKind.TYPE_CONST))
    assert_equal(spec.types.text(spec.resolution(maxes[0]).value().index), "i32")
    assert_equal(spec.types.text(spec.resolution(maxes[1]).value().index), "f64")
    assert_equal(type_text(spec, maxes[0]), "int")
    assert_equal(type_text(spec, maxes[1]), "f64")


def test_bare_enum_member_and_error() raises:
    var spec = ok(SRC)
    var fi = spec.fn_named("f").value()
    var raises_clause = spec.clauses[spec.fns[fi].clauses[0]].copy()
    assert_equal(raises_clause.error, "builtins.Boom")
    var red = only_name(spec, raises_clause.expr, "Red")
    assert_equal(spec.resolution(red).value().kind, ResolutionKind.ENUM_MEMBER)
    assert_equal(spec.resolution(red).value().index, 0)
    assert_equal(spec.types.text(spec.resolution(red).value().owner), "Color")


def test_observers_and_prelude() raises:
    var spec = ok(SRC)
    var b = clause_expr(spec, "f.b")
    var calls = nodes_of(spec, b, ast.NodeKind.CALL)
    var cell = -1
    for c in calls:
        var callee = spec.ast.child(c, 0)
        if spec.ast.nodes[callee].kind == .ATTR and spec.ast.nodes[callee].text == "cell":
            cell = c
    assert_true(cell > 0)
    var r = spec.resolution(cell).value().copy()
    assert_equal(r.kind, ResolutionKind.OBSERVER)
    assert_equal(r.index, 1)
    assert_equal(r.owner, spec.model_named("Frame").value())
    assert_equal(type_text(spec, cell), "option<f64>")
    assert_equal(type_text(spec, spec.ast.child(cell, 0)), "(u64, string) -> option<f64>")
    var columns = named(spec, b, ast.NodeKind.ATTR, "columns")[0]
    assert_equal(spec.resolution(columns).value().kind, ResolutionKind.OBSERVER)
    assert_equal(spec.resolution(columns).value().index, 0)
    var is_none = calls[0]
    assert_equal(spec.resolution(is_none).value().kind, ResolutionKind.PRELUDE)
    assert_equal(spec.resolution(is_none).value().index, prelude_id("is_none").value())
    assert_equal(spec.resolution(is_none).value().name, "is_none")


def test_mp_result_qe_and_cr() raises:
    var spec = ok(SRC)
    var m = clause_expr(spec, "f.m")
    var result = only_name(spec, m, "result")
    assert_equal(res_kind(spec, result), Int(ResolutionKind.RESULT))
    var mp = -1
    for c in nodes_of(spec, m, ast.NodeKind.CALL):
        if spec.resolution(c).value().name == "mp.cos":
            mp = c
    assert_true(mp > 0)
    assert_equal(type_text(spec, mp), "real")
    assert_equal(spec.resolution(spec.ast.child(mp, 0)).value().kind, ResolutionKind.PRELUDE)
    var q = clause_expr(spec, "f.q")
    assert_equal(type_text(spec, q), "bool")
    var qe = spec.ast.child(q, 0)
    assert_equal(type_text(spec, qe), "qerr")
    assert_equal(spec.resolution(qe).value().name, "qe")
    var cr = spec.ast.child(spec.ast.child(qe, 3), 0)
    assert_equal(type_text(spec, cr), "f64")
    assert_equal(spec.resolution(cr).value().name, "cr.cos")


def test_old() raises:
    var spec = ok(SRC)
    var o = clause_expr(spec, "f.o")
    var old = spec.ast.child(o, 0)
    assert_equal(res_kind(spec, old), Int(ResolutionKind.OLD))
    assert_equal(type_text(spec, old), "list<string>")


def test_spec_fn_calls_in_relates() raises:
    var spec = ok(SRC)
    var r = clause_expr(spec, "f.r")
    var g = spec.ast.child(spec.ast.child(r, 2), 0)
    var res = spec.resolution(g).value().copy()
    assert_equal(res.kind, ResolutionKind.SPEC_FN)
    assert_equal(res.index, spec.fn_named("g").value())
    assert_equal(type_text(spec, g), "f64")
    assert_equal(type_text(spec, spec.ast.child(spec.ast.child(g, 2), 0)), "f64")


def test_partition_classes() raises:
    var spec = ok(SRC)
    var fi = spec.fn_named("f").value()
    var part = spec.fns[fi].partitions[0].copy()
    assert_equal(part.param, 0)
    assert_equal(len(part.classes), 3)
    for cls in part.classes:
        assert_equal(type_text(spec, cls.expr), "set<f64>")
    assert_equal(part.classes[0].name, "nan")
    var nan = spec.resolution(part.classes[0].expr).value().copy()
    assert_equal(nan.kind, ResolutionKind.TYPE_CONST)
    assert_equal(nan.name, "nan")
    var nan_ref = only_name(spec, part.classes[2].expr, "nan")
    var small_ref = only_name(spec, part.classes[2].expr, "small")
    assert_equal(spec.resolution(nan_ref).value().kind, ResolutionKind.CLASS)
    assert_equal(spec.resolution(nan_ref).value().index, part.classes[0].node)
    assert_equal(spec.resolution(small_ref).value().index, part.classes[1].node)
    var rng = nodes_of(spec, part.classes[1].expr, ast.NodeKind.CALL)
    assert_equal(len(rng), 1)
    assert_equal(spec.resolution(rng[0]).value().kind, ResolutionKind.SET_CTOR)
    assert_equal(spec.resolution(rng[0]).value().name, "range")


def test_invariant_fields_and_self() raises:
    var spec = ok(SRC)
    var uniq = clause_expr(spec, "Frame.uniq")
    var columns = named(spec, uniq, ast.NodeKind.NAME, "columns")
    assert_equal(len(columns), 2)
    var r = spec.resolution(columns[0]).value().copy()
    assert_equal(r.kind, ResolutionKind.FIELD)
    assert_equal(r.index, 0)
    assert_equal(r.owner, spec.model_named("Frame").value())
    var cells = clause_expr(spec, "Frame.cells")
    var cell_call = -1
    for c in nodes_of(spec, cells, ast.NodeKind.CALL):
        if spec.resolution(c).value().name == "cell":
            cell_call = c
    assert_equal(spec.resolution(cell_call).value().kind, ResolutionKind.FIELD)
    var ok_inv = clause_expr(spec, "Q.ok")
    var items = named(spec, ok_inv, ast.NodeKind.NAME, "items")
    assert_equal(res_kind(spec, items[0]), Int(ResolutionKind.FIELD))
    var self_ = only_name(spec, ok_inv, "self")
    assert_equal(res_kind(spec, self_), Int(ResolutionKind.SELF))
    assert_equal(spec.resolution(self_).value().owner, spec.model_named("Q").value())
    var push = clause_expr(spec, "Q.push.p")
    assert_equal(res_kind(spec, named(spec, push, ast.NodeKind.NAME, "self")[0]), Int(ResolutionKind.SELF))
    var attr = named(spec, push, ast.NodeKind.ATTR, "items")
    assert_equal(spec.resolution(attr[0]).value().kind, ResolutionKind.OBSERVER)
    var e = clause_expr(spec, "Q.empty.e")
    assert_equal(res_kind(spec, only_name(spec, e, "result")), Int(ResolutionKind.RESULT))


def test_every_name_call_and_attribute_is_resolved() raises:
    var spec = ok(SRC)
    var parent = parents(spec)
    for cl in spec.clauses:
        if cl.expr == 0:
            continue
        for n in descendants(spec, cl.expr):
            var k = spec.ast.nodes[n].kind
            if k == .CALL or k == .ATTR:
                if k == .ATTR and not Bool(spec.resolution(n)):
                    # Only the base of a call to a namespace member can lack one.
                    assert_equal(spec.ast.nodes[parent[n]].kind, ast.NodeKind.CALL)
                else:
                    assert_true(Bool(spec.resolution(n)), spec.ast.source_text(n))
            elif k == .NAME:
                var p = parent[n]
                var base_of_resolved = (
                    spec.ast.nodes[p].kind == .ATTR or spec.ast.nodes[p].kind == .CALL
                ) and Bool(spec.resolution(p))
                assert_true(
                    Bool(spec.resolution(n)) or base_of_resolved,
                    spec.ast.source_text(n),
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
