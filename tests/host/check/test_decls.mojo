from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check import types as ty
from check.spec import Spec
from check.testkit import count_errors, fails, ok
from syntax import ast


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
    assert_equal(pop.kind, ast.METHOD)
    assert_equal(pop.owner, 1)
    assert_equal(spec.types.text(pop.result), "T")
    assert_equal(spec.types.text(pop.params[0].type), "Q<T>")
    assert_equal(spec.types.text(spec.fns[q.methods[1]].result), "unit")
    var empty = spec.fns[q.ctors[0]].copy()
    assert_equal(empty.kind, ast.CTOR)
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
    assert_equal(spec.clauses[3].kind, ast.ENSURES)
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


def test_unsupported_declarations() raises:
    fails("use \"other.spec\"\n", "use is not supported yet")
    fails("prelude \"x.prelude\"\n", "prelude is not supported yet")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
