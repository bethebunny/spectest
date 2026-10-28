from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check.spec import Spec
from numeric.digits import hex_digits
from run.items import items_of
from run.load import fnv, load, load_source
from run.options import RunOptions
from run.results import (
    AggregateSummary,
    ClauseResult,
    Counterexample,
    Obj,
    RunResult,
)
from wire.format import format_value
from wire.value import Value

comptime SPEC = """spec t

model pkg.Box
  observe items: list<i32>
  build pkg.make_box(items: list<i32>)
  invariant nonneg: len(items) >= 0

fn pkg.clamp(x: i16, lo: i16, hi: i16) -> i16
  requires lo <= hi
  ensures in_range: lo <= result and result <= hi
  raises ValueError when lo > hi
  may_raise KeyError
  impl_defined detail

fn pkg.concat(a: pkg.Box, b: pkg.Box) -> pkg.Box
  ensures joined: result.items == a.items + b.items
  relates twice: pkg.concat(a, b).items == pkg.concat(a, b).items

fn pkg.grow(b: pkg.Box)
  modifies b
  aggregate none_left: sum(v in i8.range(0, 4): v) <= 100
"""


def has(text: String, fragment: String) raises:
    assert_true(fragment in text, "'" + fragment + "' not in '" + text + "'")


def test_fnv_is_the_standard_hash() raises:
    assert_equal(fnv(""), UInt64(0xCBF29CE484222325))
    assert_equal(fnv("a"), UInt64(0xAF63DC4C8601EC8C))
    assert_equal(hex_digits(UInt64(0xAF63DC4C8601EC8C), width=16), "af63dc4c8601ec8c")
    assert_equal(hex_digits(UInt64(255), width=16), "00000000000000ff")


def test_load_keeps_the_spec_its_sets_and_a_hash() raises:
    var a = load_source(SPEC, "t.spec")
    var b = load_source(SPEC, "t.spec")
    var c = load_source(SPEC + "\n# a comment\n", "t.spec")
    assert_equal(a.hash.byte_length(), 32)
    assert_equal(a.hash, b.hash)
    assert_true(a.hash != c.hash)
    assert_equal(len(a.spec.fns), 3)
    assert_equal(a.path, "t.spec")


def test_load_reads_a_file() raises:
    var l = load("examples/libm/libm.spec")
    assert_equal(l.spec.name, "libm")
    assert_true(l.spec.fn_named("cos").__bool__())
    # The partition sets are compiled: cos has one partition of seven classes.
    assert_equal(l.sets.class_count(0, 0), 7)


def test_load_errors_are_diagnostics() raises:
    try:
        _ = load_source("spec bad\n\nfn f(x: i32) -> i32\n  ensures e: result == y\n", "bad.spec")
        assert_true(False)
    except e:
        var text = String(e)
        assert_true(text.startswith("bad.spec:4:"), text)
    try:
        _ = load_source(
            "spec bad\n\nfn f(x: u8) -> u8\n  partition x\n    low = u8.range(0, 10)\n    high = u8.range(5, 256)\n",
            "bad.spec",
        )
        assert_true(False)
    except e:
        has(String(e), "bad.spec:")


def test_items_list_the_judged_clauses_in_source_order() raises:
    var l = load_source(SPEC, "t.spec")
    var items = items_of(l)
    var ids = List[String]()
    for it in items:
        assert_true(it.kind == .MAP)
        var text = format_value(it)
        has(text, '"decl"')
        ids.append(text)
    var all = String()
    for t in ids:
        all += t + "\n"
    # requires, may_raise and freedoms are not items; the built-ins and the invariant are.
    has(all, '"clause_id": "pkg.clamp.in_range"')
    has(all, '"clause_id": "pkg.clamp#3"')
    has(all, '"kind": "raises"')
    has(all, '"clause_id": "pkg.clamp#type"')
    has(all, '"clause_id": "pkg.clamp#raises"')
    has(all, '"clause_id": "pkg.concat:pkg.Box.nonneg"')
    has(all, '"clause_id": "pkg.concat#frame"')
    has(all, '"kind": "aggregate"')
    has(all, '"kind": "modifies"')
    has(all, '"text": "ensures in_range: lo <= result and result <= hi"')
    assert_false('"kind": "requires"' in all)
    assert_false('"kind": "may_raise"' in all)
    assert_false('"kind": "impl_defined"' in all)
    # The modifies clause suppresses the frame item of grow.
    assert_false("pkg.grow#frame" in all)
    assert_true("pkg.grow#type" in all)
    assert_equal(len(items), 15)


def test_options_default_to_the_documented_values() raises:
    var o = RunOptions()
    assert_equal(Int(o.seed), 0)
    assert_equal(o.max_examples, 100)
    assert_equal(o.exhaustive_limit, 65536)
    assert_false(o.store.__bool__())
    assert_equal(o.strength, "dev")
    assert_equal(o.settings("pkg.f").max_shrink_steps, 5000)
    o.strength = "full"
    assert_equal(o.settings("pkg.f").max_shrink_steps, 20000)
    assert_equal(o.settings("pkg.f").seed, fnv("0:pkg.f"))


def test_store_keys_name_the_instantiation() raises:
    var o = RunOptions()
    assert_equal(o.store_key("h", "pkg.f.c"), "h/pkg.f.c")
    o.instantiation["T"] = "i64"
    o.instantiation["U"] = "list<i8>"
    assert_equal(o.store_key("h", "pkg.f.c"), "h/pkg.f.c[T=i64][U=list<i8>]")


def test_results_convert_to_nested_maps() raises:
    var run = RunResult("pkg.f")
    run.examples = 3
    var c = ClauseResult("pkg.f.c", "ensures c: true", "ensures", "pkg.f")
    c.passed = 2
    c.failed = 1
    c.coverage.append(("x: a", 3))
    c.skips.append(("requires", 2))
    var cx = Counterexample()
    cx.inputs.append(("x", "1"))
    cx.observation = "result = 2"
    cx.explanation.append(("result", "2"))
    cx.partitions.append(("x", "a"))
    cx.seed = 5
    cx.reproduce = "seed=5"
    c.counterexample = cx^
    run.clauses.append(c^)
    var agg = ClauseResult("pkg.f.agg", "aggregate agg: ...", "aggregate", "pkg.f")
    var summary = AggregateSummary()
    summary.value = "3"
    summary.bound = "4"
    summary.worst.append(("1", "3"))
    agg.aggregate = summary^
    run.clauses.append(agg^)
    var v = run.to_value()
    assert_true(v.kind == .MAP)
    var text = format_value(v)
    has(text, '"decl": "pkg.f"')
    has(text, '"mode": "search"')
    has(text, '"counts": {"pass": 2, "fail": 1, "skip": 0, "spec_error": 0, "inconclusive": 0}')
    has(text, '"coverage": {"x: a": 3}')
    has(text, '"skips": {"requires": 2}')
    has(text, '"inputs": {"x": "1"}')
    has(text, '"explanation": [["result", "2"]]')
    has(text, '"partitions": {"x": "a"}')
    has(text, '"aggregate": {"value": "3", "bound": "4"')
    has(text, '"worst": [["1", "3"]]')
    has(text, '"counterexample": none')


def test_obj_keeps_the_order_of_its_keys() raises:
    var o = Obj()
    o.num("b", 1)
    o.text("a", "x")
    o.flag("c", True)
    var v = o^.build()
    assert_equal(format_value(v), '{"b": 1, "a": "x", "c": true}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
