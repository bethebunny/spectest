from std.ffi import external_call
from std.pathlib import Path
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.time import perf_counter_ns

from check_testkit import (
    clause_expr,
    fails,
    fails_at,
    named,
    nodes_of,
    ok,
    type_text,
)
from spec import ast
from spec.spec import ResolutionKind, Spec
from specfile.checker import check, check_source
from specfile.parser import parse_spec


comptime CLOCK_THREAD_CPUTIME_ID = Int32(3)


@fieldwise_init
struct Timespec(Copyable, Movable):
    var sec: Int64
    var nsec: Int64


def thread_cpu_ns() -> Int:
    var ts = Timespec(0, 0)
    _ = external_call["clock_gettime", Int32](CLOCK_THREAD_CPUTIME_ID, UnsafePointer(to=ts))
    return Int(ts.sec) * 1_000_000_000 + Int(ts.nsec)


def sample() raises -> Spec:
    var src = Path("tests/mojo/specfile/data/v2.spec").read_text()
    return check_source(src, "tests/mojo/specfile/data/v2.spec")


def test_the_sample_checks() raises:
    var spec = sample()
    assert_equal(spec.name, "v2sample")
    assert_equal(len(spec.fns), 11)
    assert_equal(len(spec.models), 3)
    assert_equal(len(spec.defs), 5)
    assert_equal(len(spec.consts), 2)
    assert_equal(len(spec.errors), 2)
    assert_equal(spec.errors[0], "bitpattern.PatternError")
    assert_equal(spec.errors[1], "builtins.ValueError")


def test_qualified_methods_belong_to_their_model() raises:
    var spec = sample()
    var or_ = spec.fns[spec.fn_named("bitpattern.IntSet.__or__").value()].copy()
    assert_true(or_.receiver)
    assert_equal(or_.owner, spec.model_named("bitpattern.IntSet").value())
    assert_equal(or_.params[0].name, "self")
    assert_equal(spec.types.text(or_.params[0].type), "bitpattern.IntSet")
    assert_equal(or_.params[1].name, "other")
    assert_equal(or_.target, "bitpattern.IntSet.__or__")
    assert_equal(or_.decl_id, "bitpattern.IntSet.__or__")
    var range = spec.fns[spec.fn_named("bitpattern.IntSet.range").value()].copy()
    assert_false(range.receiver)
    assert_equal(range.owner, -1)
    # self is the receiver inside the clauses: resolved, with the model's type.
    var union = clause_expr(spec, "bitpattern.IntSet.__or__.union")
    var selfs = named(spec, union, ast.NodeKind.NAME, "self")
    assert_equal(len(selfs), 1)
    assert_equal(type_text(spec, selfs[0]), "bitpattern.IntSet")


def test_interface_members_have_qualified_targets() raises:
    var spec = sample()
    var deque = spec.model_named("pkg.Deque").value()
    assert_true(spec.models[deque].is_interface)
    var empty = spec.fns[spec.models[deque].ctors[0]].copy()
    assert_equal(empty.name, "empty")
    assert_equal(empty.target, "pkg.Deque.empty")
    assert_equal(empty.decl_id, "pkg.Deque.empty")
    var push = spec.fns[spec.models[deque].methods[0]].copy()
    assert_equal(push.target, "pkg.Deque.push")
    assert_true(spec.clause_named("pkg.Deque.push#1").__bool__())


def test_planned_calls_in_clauses() raises:
    var spec = sample()
    var contains = spec.fn_named("bitpattern.IntSet.__contains__").value()
    var or_ = spec.fn_named("bitpattern.IntSet.__or__").value()
    var has = clause_expr(spec, "bitpattern.IntSet.__or__.has")
    var found = 0
    for c in nodes_of(spec, has, ast.NodeKind.CALL):
        var r = spec.resolution(c)
        if r and r.value().kind == .SPEC_FN:
            assert_equal(r.value().index, contains)
            assert_equal(type_text(spec, c), "bool")
            found += 1
    assert_equal(found, 2)
    var commutes = clause_expr(spec, "bitpattern.IntSet.__or__.commutes")
    var recursive = nodes_of(spec, commutes, ast.NodeKind.CALL)
    var is_or = False
    for c in recursive:
        var r = spec.resolution(c)
        if r and r.value().kind == .SPEC_FN and r.value().index == or_:
            is_or = True
            assert_equal(type_text(spec, c), "bitpattern.IntSet")
    assert_true(is_or)
    # An invariant of a model may call a planned function too.
    var counted = clause_expr(spec, "bitpattern.IntSet.counted")
    var len_calls = 0
    for c in nodes_of(spec, counted, ast.NodeKind.CALL):
        var r = spec.resolution(c)
        if r and r.value().kind == .SPEC_FN:
            len_calls += 1
    assert_equal(len_calls, 1)


def test_requires_calls_definitions() raises:
    var spec = sample()
    var req = clause_expr(spec, "bitpattern.encode#1")
    var defs = 0
    for c in nodes_of(spec, req, ast.NodeKind.CALL):
        var r = spec.resolution(c)
        if r and r.value().kind == .DEF:
            defs += 1
            assert_equal(type_text(spec, c), "int")
    assert_equal(defs, 2)
    assert_equal(spec.defs[0].name, "pow2")
    assert_equal(spec.types.text(spec.defs[0].result), "int")
    assert_equal(spec.defs[1].name, "mask")
    assert_equal(type_text(spec, spec.defs[1].body), "int")


def test_errors_are_qualified() raises:
    var spec = sample()
    var range = spec.fns[spec.fn_named("bitpattern.IntSet.range").value()].copy()
    assert_equal(spec.clauses[range.clauses[1]].error, "builtins.ValueError")
    assert_equal(spec.clauses[range.clauses[2]].error, "bitpattern.PatternError")
    assert_true(spec.clauses[range.clauses[2]].expr != 0)


def test_constants_and_choice_types() raises:
    var spec = sample()
    assert_equal(spec.consts[0].name, "bitpattern.codecs.int8")
    assert_equal(spec.types.text(spec.consts[0].type), "bitpattern.Codec")
    var enc = spec.fns[spec.fn_named("bitpattern.encode").value()].copy()
    assert_equal(
        spec.types.text(enc.params[0].type),
        "bitpattern.codecs.int8 | bitpattern.codecs.uint16",
    )
    var width = clause_expr(spec, "bitpattern.encode.width")
    var chains = 0
    for n in nodes_of(spec, width, ast.NodeKind.ATTR):
        var r = spec.resolution(n)
        if r and r.value().kind == .CONST:
            chains += 1
            assert_equal(type_text(spec, n), "bitpattern.Codec")
        elif r:
            assert_equal(r.value().kind, ResolutionKind.OBSERVER)
            assert_equal(type_text(spec, n), "int")
    assert_equal(chains, 2)


def test_builds_and_observer_expressions() raises:
    var spec = sample()
    var s = spec.models[spec.model_named("bitpattern.IntSet").value()].copy()
    assert_equal(len(s.builds), 2)
    assert_equal(s.builds[0].target, "bitpattern.IntSet.range")
    assert_equal(len(s.builds[0].params), 2)
    assert_equal(spec.types.text(s.builds[1].params[0].type), "list<int>")
    assert_true(s.builds[1].params[1].default != 0)
    assert_equal(s.observers[0].expr, 0)
    var members = s.observers[1].copy()
    assert_equal(members.name, "members")
    var call = members.expr
    assert_equal(spec.resolution(call).value().kind, ResolutionKind.EXTERN)
    assert_equal(spec.resolution(call).value().name, "builtins.list")
    assert_equal(type_text(spec, call), "list<int>")
    assert_equal(type_text(spec, s.observers[2].expr), "int")
    assert_equal(type_text(spec, s.observers[3].expr), "bool")


def test_new_operators_and_parts() raises:
    var spec = sample()
    assert_equal(type_text(spec, spec.defs[0].body), "int")
    assert_equal(type_text(spec, spec.defs[2].body), "int")
    assert_equal(type_text(spec, spec.defs[3].body), "int")
    assert_equal(type_text(spec, spec.defs[4].body), "int")
    var close = clause_expr(spec, "near.close")
    var parts = 0
    for n in nodes_of(spec, close, ast.NodeKind.ATTR):
        var r = spec.resolution(n)
        if r and r.value().kind == .QERR_PART:
            parts += 1
            assert_equal(type_text(spec, n), "int")
    assert_equal(parts, 2)
    var both = clause_expr(spec, "near.parts")
    assert_equal(type_text(spec, both), "bool")
    assert_equal(type_text(spec, clause_expr(spec, "text_roundtrip.back")), "bool")


# -- one error per v2 rule, with message and position ------------------------------


comptime S = (
    "model m.S\n  observe n: int\n  observe items: list<int>\n"
    "fn m.S.__len__(self) -> int\n"
)


def test_a_method_needs_its_model() raises:
    fails_at(
        "fn nomodel.Thing.go(self)\n",
        "t.spec:2:21: nomodel.Thing.go takes self, but there is no model or interface"
        " named nomodel.Thing to be its receiver",
    )
    fails_at(
        "fn go(self)\n",
        "t.spec:2:7: go takes self, but it is not named after a model: write"
        " fn Model.go(self, ...)",
    )


def test_requires_cannot_make_planned_calls() raises:
    fails_at(
        String(S) + "fn f(s: m.S)\n  requires m.S.__len__(s) == 1\n",
        "t.spec:7:12: m.S.__len__(...) calls the spec function m.S.__len__; calls to"
        " spec functions are only allowed in ensures, relates, invariant and aggregate"
        " clauses, where each one is a planned implementation call",
    )
    _ = ok(String(S) + "fn f(s: m.S)\n  ensures m.S.__len__(s) == 1\n")


def test_a_modifying_function_cannot_be_called_in_a_clause() raises:
    fails_at(
        String(S) + "fn m.S.add(self)\n  modifies self\nfn f(s: m.S)\n  ensures m.S.add(s)\n",
        "t.spec:9:11: m.S.add modifies its arguments, so it cannot be called in a clause:"
        " a planned call must leave its inputs unchanged",
    )


def test_operators_belong_to_the_host() raises:
    fails_at(
        String(S) + "fn f(s: m.S, x: int)\n  ensures x in s\n",
        "t.spec:7:11: in needs a list, map or string on the right, but it is m.S",
    )
    fails(
        String(S) + "fn f(s: m.S, t: m.S)\n  ensures s < t\n",
        "m.S has no total order",
    )
    fails(String(S) + "fn f(s: m.S, t: m.S)\n  ensures s | t\n", "two integers or two partition sets")
    fails(String(S) + "fn f(s: m.S, t: m.S)\n  ensures s + t == s\n", "cannot apply + to m.S and m.S")


def test_choice_types_need_declared_constants_of_one_type() raises:
    fails_at(
        "const a.x: int\nconst a.y: string\nfn f(c: a.x | a.y)\n",
        "t.spec:4:15: the alternatives of a choice are declared with one type, but a.y is"
        " string and an earlier one is int",
    )
    fails_at(
        "const a.x: int\nfn f(c: a.x | a.z)\n",
        "t.spec:3:15: unknown constant a.z: declare it with 'const a.z: T'",
    )
    fails_at(
        'const a.x: int\nfn f(c: a.x | "s")\n',
        "t.spec:3:9: a choice is either string literals or library constants, not both",
    )


def test_a_choice_argument_is_one_of_its_constants() raises:
    var base = (
        "const a.x: int\nconst a.y: int\nconst a.z: int\n"
        "fn g(c: a.x | a.y) -> int\nfn f() -> int\n"
    )
    _ = ok(base + "  relates g(a.x) == g(a.y)\n")
    fails(
        base + "  relates g(a.z) == result\n",
        "argument c of g is a a.x | a.y, but this is int",
    )


def test_build_parameters_are_typed() raises:
    fails_at(
        "model M\n  build M.make(x: Nope)\n", "t.spec:3:19: unknown type Nope"
    )
    var spec = ok("model M\n  build M.make(x: u8, ys: list<f64> = [])\n")
    assert_equal(spec.types.text(spec.models[0].builds[0].params[1].type), "list<f64>")


def test_labels_cannot_take_a_qualified_member_id() raises:
    fails(
        "model m.S\n  observe n: int\n  invariant __len__: n >= 0\nfn m.S.__len__(self) -> int\n",
        "clause label __len__ gives the ID m.S.__len__, which already names the method"
        " m.S.__len__",
    )
    fails(
        "model m.S\n  observe n: int\n  invariant range: n >= 0\nfn m.S.range() -> int\n",
        "which already names the function m.S.range",
    )


def test_observer_expressions_have_the_declared_type() raises:
    fails_at(
        "model M\n  observe n: int = 1.5\n",
        "t.spec:3:20: the reading expression of n is a real, but n is declared int",
    )
    fails_at("model M\n  observe n: int = nope\n", "t.spec:3:20: unknown name nope")


def test_definitions_are_typed() raises:
    fails_at(
        "fn d(x: int) -> int = x == 1\n",
        "t.spec:2:23: the body of d is a bool, but it is declared to return int",
    )
    fails_at("fn len(x: int) -> int = x\n", "t.spec:2:1: len is a prelude function and cannot be redefined")


def test_definitions_cannot_be_recursive() raises:
    fails_at("fn d(x: int) -> int = d(x)\n", "t.spec:2:1: definition d calls itself")
    fails_at(
        "fn d(x: int) -> int = e(x)\nfn e(x: int) -> int = d(x)\n",
        "t.spec:2:1: definitions cannot call each other in a cycle: d -> e -> d",
    )
    _ = ok("fn d(x: int) -> int = x\nfn e(x: int) -> int = d(x) + d(1)\n")


def test_integer_operators() raises:
    fails_at(
        "fn f(a: int)\n  ensures a ** -1 == 1\n",
        "t.spec:3:11: ** needs a non-negative exponent: a negative power is not an integer",
    )
    fails_at(
        "fn f(a: int)\n  ensures (a << 1.5) == 1\n", "t.spec:3:12: << takes integers, but got int and real"
    )
    fails_at(
        "fn f(a: int)\n  ensures bit_length(2.5) == 1\n",
        "t.spec:3:22: bit_length takes an integer, but argument 1 is real (use // for"
        " integer division)",
    )


def test_qerr_parts() raises:
    fails_at("fn f(a: int)\n  ensures a.steps == 1\n", "t.spec:3:11: int has no field steps")


def test_unknown_qualified_names() raises:
    fails_at(
        "fn f(a: int)\n  ensures builtins.list(a) == 1\n",
        "t.spec:3:11: unknown function builtins.list",
    )
    fails_at(
        "const a.x: int\nfn f()\n  ensures a.x == 1 and a.y == 2\n",
        "t.spec:4:24: unknown name a",
    )


def test_other_files_must_exist() raises:
    fails_at(
        'use "no_such_dir/x.spec"\nfn f()\n',
        "t.spec:2:1: cannot read use file no_such_dir/x.spec (no_such_dir/x.spec)",
    )
    fails_at(
        'prelude "x.prelude"\n',
        "t.spec:2:1: cannot read prelude file x.prelude (x.prelude)",
    )


def check_file(path: String) raises -> Spec:
    return check(parse_spec(Path(path).read_text(), path))


def test_the_examples_check() raises:
    var files = [
        "examples/binary/binary.spec",
        "examples/deque/deque.spec",
        "examples/frames/frames.spec",
        "examples/libm/explore.spec",
        "examples/libm/libm.spec",
        "examples/sorting/sorting.spec",
    ]
    for path in files:
        var spec = check_file(String(path))
        assert_true(len(spec.fns) > 0, String(path))
        assert_true(len(spec.clauses) > 0, String(path))


def test_libm_clauses() raises:
    var spec = check_file("examples/libm/libm.spec")
    var cos = spec.fn_named("cos").value()
    assert_equal(len(spec.fns[cos].partitions), 1)
    assert_true(Bool(spec.clause_named("cos.accurate")))
    assert_equal(spec.types.text(spec.fns[cos].result), "f64")


def test_deque_interface() raises:
    var spec = check_file("examples/deque/deque.spec")
    var deque = spec.model_named("Deque").value()
    assert_true(spec.models[deque].is_interface)
    assert_true(len(spec.models[deque].methods) >= 2)


def test_bitpattern_checks_fast() raises:
    var source = Path("trials/bitpattern/bitpattern.spec").read_text()
    var ast = parse_spec(source, "trials/bitpattern/bitpattern.spec")
    var wall_start = perf_counter_ns()
    var cpu_start = thread_cpu_ns()
    var spec = check(ast^)
    var cpu = thread_cpu_ns() - cpu_start
    var wall = perf_counter_ns() - wall_start
    print("bitpattern.spec checked in", Float64(cpu) / 1.0e6, "ms cpu,", Float64(wall) / 1.0e6, "ms wall")
    assert_equal(len(spec.fns), 236)
    assert_true(cpu < 50_000_000, "checking bitpattern.spec took 50 ms of CPU time or more")


def test_aggregate_shapes() raises:
    var base = "fn g(x: f16) -> f16\n"
    _ = ok(base + "fn f()\n  aggregate a: sum(v in f16.finite: qe(g(v), v).steps) <= 3\n")
    _ = ok(base + "fn f()\n  aggregate a: sum(v in f16.all: qe(g(v), v).steps) == 0\n")
    _ = ok(base + "fn f()\n  aggregate a: max(v in f16.all: qe(g(v), v).steps) < 2 * 4\n")
    _ = ok(base + "fn f()\n  aggregate a: all(v in f16.all: is_finite(g(v)) or is_nan(v))\n")
    fails(
        base + "fn f()\n  aggregate a: sum(v in f16.all: 1) > 3\n",
        "an aggregate clause has one of the shapes",
    )
    fails(
        base + "fn f()\n  aggregate a: sum(v in f16.all: 1) == 2\n",
        "sum(...) == c is an aggregate shape only for c = 0",
    )
    fails(
        base + "fn f(n: int)\n  aggregate a: sum(v in f16.all: 1) <= n\n",
        "an aggregate clause cannot use the parameter n of f",
    )
    fails(
        base + "fn f(n: int)\n  aggregate a: sum(v in f16.all: n) <= 3\n",
        "an aggregate clause cannot use the parameter n of f",
    )
    fails(
        base + "fn f()\n  aggregate a: sum(v in [1, 2]: 1) <= len([1])\n",
        "the bound of an aggregate clause must be a constant",
    )
    fails(
        base + "fn f() -> int\n  aggregate a: sum(v in f16.all: result) <= 3\n",
        "an aggregate clause is evaluated once over a set of inputs",
    )
    fails(
        "interface Q\n  observe n: int\n  new e() -> Q\n    aggregate a: all(v in [1]: true)\n",
        "aggregate clauses belong to functions (fn), not to a constructor",
    )
    fails(
        "fn f(xs: list<f16>)\n  ensures all(v in f16.all: true)\n",
        "ranges over a set such as f16.all only as the top comprehension of an aggregate",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
