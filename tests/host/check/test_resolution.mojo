from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check import types as ty
from check.spec import (
    R_CLASS,
    R_ENUM_MEMBER,
    R_FIELD,
    R_OBSERVER,
    R_OLD,
    R_PARAM,
    R_PRELUDE,
    R_RECORD_FIELD,
    R_RESULT,
    R_SELF,
    R_SET_CTOR,
    R_SPEC_FN,
    R_TYPE_CONST,
    Spec,
)
from check.testkit import (
    clause_expr,
    descendants,
    named,
    nodes_of,
    ok,
    parents,
    type_text,
)
from prelude.names import prelude_id
from syntax import ast


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
    var found = named(spec, root, ast.NAME, text)
    assert_equal(len(found), 1)
    return found[0]


def test_params_fields_types_and_enums() raises:
    var spec = ok(SRC)
    var a = clause_expr(spec, "f.a")
    var p = only_name(spec, a, "p")
    assert_equal(res_kind(spec, p), Int(R_PARAM))
    assert_equal(spec.resolution(p).value().index, 2)
    assert_equal(spec.resolution(only_name(spec, a, "c")).value().index, 3)
    var xs = named(spec, a, ast.ATTR, "x")
    assert_equal(len(xs), 1)
    var field = spec.resolution(xs[0]).value().copy()
    assert_equal(field.kind, R_RECORD_FIELD)
    assert_equal(field.index, 0)
    assert_equal(spec.types.text(field.owner), "Pt")
    var green = named(spec, a, ast.ATTR, "Green")[0]
    assert_equal(spec.resolution(green).value().kind, R_ENUM_MEMBER)
    assert_equal(spec.resolution(green).value().index, 1)
    assert_equal(type_text(spec, green), "Color")
    var maxes = named(spec, a, ast.ATTR, "max")
    assert_equal(len(maxes), 2)
    assert_equal(res_kind(spec, maxes[0]), Int(R_TYPE_CONST))
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
    assert_equal(spec.resolution(red).value().kind, R_ENUM_MEMBER)
    assert_equal(spec.resolution(red).value().index, 0)
    assert_equal(spec.types.text(spec.resolution(red).value().owner), "Color")


def test_observers_and_prelude() raises:
    var spec = ok(SRC)
    var b = clause_expr(spec, "f.b")
    var calls = nodes_of(spec, b, ast.CALL)
    var cell = -1
    for c in calls:
        var callee = spec.ast.kid(c, 0)
        if spec.ast.nodes[callee].kind == ast.ATTR and spec.ast.nodes[callee].text == "cell":
            cell = c
    assert_true(cell > 0)
    var r = spec.resolution(cell).value().copy()
    assert_equal(r.kind, R_OBSERVER)
    assert_equal(r.index, 1)
    assert_equal(r.owner, spec.model_named("Frame").value())
    assert_equal(type_text(spec, cell), "option<f64>")
    assert_equal(type_text(spec, spec.ast.kid(cell, 0)), "(u64, string) -> option<f64>")
    var columns = named(spec, b, ast.ATTR, "columns")[0]
    assert_equal(spec.resolution(columns).value().kind, R_OBSERVER)
    assert_equal(spec.resolution(columns).value().index, 0)
    var is_none = calls[0]
    assert_equal(spec.resolution(is_none).value().kind, R_PRELUDE)
    assert_equal(spec.resolution(is_none).value().index, prelude_id("is_none").value())
    assert_equal(spec.resolution(is_none).value().name, "is_none")


def test_mp_result_qe_and_cr() raises:
    var spec = ok(SRC)
    var m = clause_expr(spec, "f.m")
    var result = only_name(spec, m, "result")
    assert_equal(res_kind(spec, result), Int(R_RESULT))
    var mp = -1
    for c in nodes_of(spec, m, ast.CALL):
        if spec.resolution(c).value().name == "mp.cos":
            mp = c
    assert_true(mp > 0)
    assert_equal(type_text(spec, mp), "real")
    assert_equal(spec.resolution(spec.ast.kid(mp, 0)).value().kind, R_PRELUDE)
    var q = clause_expr(spec, "f.q")
    assert_equal(type_text(spec, q), "bool")
    var qe = spec.ast.kid(q, 0)
    assert_equal(type_text(spec, qe), "qerr")
    assert_equal(spec.resolution(qe).value().name, "qe")
    var cr = spec.ast.kid(spec.ast.kid(qe, 3), 0)
    assert_equal(type_text(spec, cr), "f64")
    assert_equal(spec.resolution(cr).value().name, "cr.cos")


def test_old() raises:
    var spec = ok(SRC)
    var o = clause_expr(spec, "f.o")
    var old = spec.ast.kid(o, 0)
    assert_equal(res_kind(spec, old), Int(R_OLD))
    assert_equal(type_text(spec, old), "list<string>")


def test_spec_fn_calls_in_relates() raises:
    var spec = ok(SRC)
    var r = clause_expr(spec, "f.r")
    var g = spec.ast.kid(spec.ast.kid(r, 2), 0)
    var res = spec.resolution(g).value().copy()
    assert_equal(res.kind, R_SPEC_FN)
    assert_equal(res.index, spec.fn_named("g").value())
    assert_equal(type_text(spec, g), "f64")
    assert_equal(type_text(spec, spec.ast.kid(spec.ast.kid(g, 2), 0)), "f64")


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
    assert_equal(nan.kind, R_TYPE_CONST)
    assert_equal(nan.name, "nan")
    var nan_ref = only_name(spec, part.classes[2].expr, "nan")
    var small_ref = only_name(spec, part.classes[2].expr, "small")
    assert_equal(spec.resolution(nan_ref).value().kind, R_CLASS)
    assert_equal(spec.resolution(nan_ref).value().index, part.classes[0].node)
    assert_equal(spec.resolution(small_ref).value().index, part.classes[1].node)
    var rng = nodes_of(spec, part.classes[1].expr, ast.CALL)
    assert_equal(len(rng), 1)
    assert_equal(spec.resolution(rng[0]).value().kind, R_SET_CTOR)
    assert_equal(spec.resolution(rng[0]).value().name, "range")


def test_invariant_fields_and_self() raises:
    var spec = ok(SRC)
    var uniq = clause_expr(spec, "Frame.uniq")
    var columns = named(spec, uniq, ast.NAME, "columns")
    assert_equal(len(columns), 2)
    var r = spec.resolution(columns[0]).value().copy()
    assert_equal(r.kind, R_FIELD)
    assert_equal(r.index, 0)
    assert_equal(r.owner, spec.model_named("Frame").value())
    var cells = clause_expr(spec, "Frame.cells")
    var cell_call = -1
    for c in nodes_of(spec, cells, ast.CALL):
        if spec.resolution(c).value().name == "cell":
            cell_call = c
    assert_equal(spec.resolution(cell_call).value().kind, R_FIELD)
    var ok_inv = clause_expr(spec, "Q.ok")
    var items = named(spec, ok_inv, ast.NAME, "items")
    assert_equal(res_kind(spec, items[0]), Int(R_FIELD))
    var self_ = only_name(spec, ok_inv, "self")
    assert_equal(res_kind(spec, self_), Int(R_SELF))
    assert_equal(spec.resolution(self_).value().owner, spec.model_named("Q").value())
    var push = clause_expr(spec, "Q.push.p")
    assert_equal(res_kind(spec, named(spec, push, ast.NAME, "self")[0]), Int(R_SELF))
    var attr = named(spec, push, ast.ATTR, "items")
    assert_equal(spec.resolution(attr[0]).value().kind, R_OBSERVER)
    var e = clause_expr(spec, "Q.empty.e")
    assert_equal(res_kind(spec, only_name(spec, e, "result")), Int(R_RESULT))


def test_every_name_call_and_attribute_is_resolved() raises:
    var spec = ok(SRC)
    var parent = parents(spec)
    for cl in spec.clauses:
        if cl.expr == 0:
            continue
        for n in descendants(spec, cl.expr):
            var k = spec.ast.nodes[n].kind
            if k == ast.CALL or k == ast.ATTR:
                if k == ast.ATTR and not Bool(spec.resolution(n)):
                    # Only the base of a call to a namespace member can lack one.
                    assert_equal(spec.ast.nodes[parent[n]].kind, ast.CALL)
                else:
                    assert_true(Bool(spec.resolution(n)), spec.ast.source_text(n))
            elif k == ast.NAME:
                var p = parent[n]
                var base_of_resolved = (
                    spec.ast.nodes[p].kind == ast.ATTR or spec.ast.nodes[p].kind == ast.CALL
                ) and Bool(spec.resolution(p))
                assert_true(
                    Bool(spec.resolution(n)) or base_of_resolved,
                    spec.ast.source_text(n),
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
