"""Specs in several files: user preludes and `use`, diagnostics naming each file."""

from std.testing import assert_equal, assert_true, TestSuite

from check.checker import check_source_with
from check.files import Files
from spec.spec import ResolutionKind
from spec.spec import Spec
from spec.ast import Op

comptime MATH = "fn twice(x: int) -> int = x + x\nfn quad(x: int) -> int = twice(twice(x))\n"
comptime SPEC_A = 'spec a\nprelude "math.prelude"\nfn f(x: int) -> int\n  requires twice(x) > 0\n  ensures big: quad(x) >= x\n'


def files() -> Files:
    var f = Files(disk=False)
    f.add("math.prelude", MATH)
    return f^


def messages(source: String, path: String, fs: Files) -> List[String]:
    var out = List[String]()
    try:
        _ = check_source_with(source, path, fs)
    except e:
        for line in String(e).split("\n"):
            out.append(String(line))
    return out^


def has(lines: List[String], expected: String) -> Bool:
    for l in lines:
        if l == expected:
            return True
    return False


def show(lines: List[String]) -> String:
    var s = String()
    for l in lines:
        s += "\n  " + l
    return s^


def test_a_spec_uses_the_definitions_of_its_prelude() raises:
    var spec = check_source_with(SPEC_A, "a.spec", files())
    assert_equal(len(spec.defs), 2)
    assert_equal(spec.defs[0].name, "twice")
    assert_equal(spec.defs[1].name, "quad")
    # The requires and the ensures clause resolve the call to the definition.
    var found = 0
    for kv in spec.resolutions.items():
        if kv.value.kind == .DEF:
            found += 1
    assert_true(found >= 4, String(found))
    assert_equal(spec.clauses[spec.clause_named("f.big").value()].kind, Op.ENSURES)


def test_a_definition_calls_another_across_files() raises:
    var fs = Files(disk=False)
    fs.add("base.prelude", "fn inc(x: int) -> int = x + 1\n")
    fs.add("top.prelude", 'use "base.prelude"\nfn inc2(x: int) -> int = inc(inc(x))\n')
    var src = 'spec s\nprelude "top.prelude"\nfn f(x: int) -> int\n  ensures r: inc2(x) == x + 2\n'
    var spec = check_source_with(src, "s.spec", fs)
    assert_equal(len(spec.defs), 2)
    assert_equal(len(spec.ast.files), 3)


def test_two_specs_share_one_prelude() raises:
    var fs = files()
    fs.add("b.spec", 'spec b\nprelude "math.prelude"\nfn g(x: int) -> int\n  ensures twice(x) == x + x\n')
    # The shared prelude is read once and its definitions exist once.
    var src = 'spec a\nuse "b.spec"\nprelude "math.prelude"\nfn f(x: int) -> int\n  ensures big: quad(x) >= x\n'
    var spec = check_source_with(src, "a.spec", fs)
    assert_equal(len(spec.ast.files), 2 + 1)
    assert_equal(len(spec.defs), 2)
    assert_equal(len(spec.fns), 2)
    # Separately, each spec checks against the same prelude.
    _ = check_source_with(SPEC_A, "a.spec", fs)
    _ = check_source_with(
        'spec b\nprelude "math.prelude"\nfn g(x: int) -> int\n  ensures twice(x) == x + x\n',
        "b.spec",
        fs,
    )


def test_used_specs_bring_their_declarations() raises:
    var fs = Files(disk=False)
    fs.add("lib/types.spec", "spec types\nerror lib.Oops\nenum Color { Red, Blue }\n")
    var src = 'spec s\nuse "lib/types.spec"\nfn f(c: Color) -> Color\n  raises lib.Oops when c == Color.Red\n'
    var spec = check_source_with(src, "s.spec", fs)
    assert_equal(len(spec.errors), 1)
    assert_equal(len(spec.enums), 1)


def test_paths_are_relative_to_the_file_that_names_them() raises:
    var fs = Files(disk=False)
    fs.add("d/e/inner.prelude", "fn one() -> int = 1\n")
    fs.add("d/mid.spec", 'spec mid\nprelude "e/inner.prelude"\n')
    var spec = check_source_with(
        'spec s\nuse "d/mid.spec"\nfn f()\n  ensures one() == 1\n', "s.spec", fs
    )
    assert_equal(len(spec.defs), 1)


def test_diagnostics_in_a_prelude_name_its_file_and_line() raises:
    var fs = Files(disk=False)
    fs.add(
        "sub/bad.prelude",
        "fn ok(x: int) -> int = x\n\nfn bad(x: int) -> bool = x + 1\n",
    )
    var lines = messages('spec s\nprelude "bad.prelude"\n', "sub/s.spec", fs)
    assert_equal(len(lines), 1, show(lines))
    assert_true(lines[0].startswith("sub/bad.prelude:3:"), lines[0])


def test_a_spec_error_after_a_prelude_error_names_its_own_file() raises:
    var fs = Files(disk=False)
    fs.add("bad.prelude", "fn bad(x: int) -> bool = x + 1\n")
    var lines = messages(
        'spec s\nprelude "bad.prelude"\nfn f()\n  ensures nope\n', "s.spec", fs
    )
    assert_equal(len(lines), 2, show(lines))
    assert_true(lines[0].startswith("s.spec:4:"), show(lines))
    assert_true(lines[1].startswith("bad.prelude:1:"), show(lines))


def test_a_system_prelude_name_cannot_be_reused() raises:
    var fs = Files(disk=False)
    fs.add("p.prelude", "\nfn sorted(x: int) -> int = x\n")
    var lines = messages('spec s\nprelude "p.prelude"\n', "s.spec", fs)
    assert_true(
        has(lines, "p.prelude:2:1: sorted is a prelude function and cannot be redefined"),
        show(lines),
    )


def test_a_doubled_slash_names_the_same_directory() raises:
    var fs = Files(disk=False)
    fs.add("dir/b.spec", "spec b\n")
    var spec = check_source_with('spec s\nuse "b.spec"\n', "dir//s.spec", fs)
    assert_equal(spec.ast.files[1].path, "dir/b.spec")


def test_a_missing_prelude_file() raises:
    var lines = messages('spec s\nprelude "gone.prelude"\n', "dir/s.spec", Files(disk=False))
    assert_true(
        has(lines, "dir/s.spec:2:1: cannot read prelude file gone.prelude (dir/gone.prelude)"),
        show(lines),
    )
    var again = messages('spec s\nuse "gone.spec"\n', "s.spec", Files(disk=False))
    assert_true(
        has(again, "s.spec:2:1: cannot read use file gone.spec (gone.spec)"), show(again)
    )


def test_a_use_cycle_is_an_error() raises:
    var fs = Files(disk=False)
    fs.add("b.spec", 'spec b\nuse "c.spec"\n')
    fs.add("c.spec", 'spec c\nuse "b.spec"\n')
    var lines = messages('spec a\nuse "b.spec"\n', "a.spec", fs)
    assert_equal(len(lines), 1, show(lines))
    assert_equal(lines[0], "c.spec:2:1: use cycle: b.spec -> c.spec -> b.spec")


def test_a_spec_that_uses_itself_is_a_cycle() raises:
    var lines = messages('spec a\nuse "./a.spec"\n', "a.spec", Files(disk=False))
    assert_equal(len(lines), 1, show(lines))
    assert_equal(lines[0], "a.spec:2:1: use cycle: a.spec -> a.spec")


def test_preludes_can_not_form_a_cycle() raises:
    var fs = Files(disk=False)
    fs.add("x.prelude", 'use "y.prelude"\nfn x() -> int = 1\n')
    fs.add("y.prelude", 'use "x.prelude"\nfn y() -> int = 2\n')
    var lines = messages('spec s\nprelude "x.prelude"\n', "s.spec", fs)
    assert_true(has(lines, "y.prelude:1:1: use cycle: x.prelude -> y.prelude -> x.prelude"), show(lines))


def test_a_diamond_is_not_a_cycle() raises:
    var fs = Files(disk=False)
    fs.add("base.prelude", "fn base() -> int = 0\n")
    fs.add("l.prelude", 'use "base.prelude"\nfn l() -> int = base()\n')
    fs.add("r.prelude", 'use "base.prelude"\nfn r() -> int = base()\n')
    var spec = check_source_with(
        'spec s\nprelude "l.prelude"\nprelude "r.prelude"\n', "s.spec", fs
    )
    assert_equal(len(spec.defs), 3)
    assert_equal(len(spec.ast.files), 4)


def test_the_wrong_kind_of_file() raises:
    var fs = files()
    fs.add("o.spec", "spec o\n")
    var lines = messages('spec s\nprelude "o.spec"\nuse "math.prelude"\n', "s.spec", fs)
    assert_true(has(lines, "s.spec:2:1: o.spec is a spec, not a prelude file"), show(lines))
    assert_true(
        has(lines, "s.spec:3:1: math.prelude is a prelude file, not a spec: attach it with prelude"),
        show(lines),
    )


def test_two_preludes_defining_one_name() raises:
    var fs = Files(disk=False)
    fs.add("a.prelude", "fn dup() -> int = 1\n")
    fs.add("b.prelude", "\nfn dup() -> int = 2\n")
    var lines = messages('spec s\nprelude "a.prelude"\nprelude "b.prelude"\n', "s.spec", fs)
    assert_true(
        has(lines, "b.prelude:2:1: dup is already declared at a.prelude, line 1"), show(lines)
    )


def test_the_spec_own_definition_wins_over_the_prelude() raises:
    var fs = Files(disk=False)
    fs.add("p.prelude", "fn val() -> int = 1\n")
    var spec = check_source_with(
        'spec s\nprelude "p.prelude"\nfn val() -> int = 2\nfn f()\n  ensures val() == 2\n',
        "s.spec",
        fs,
    )
    assert_equal(len(spec.defs), 1)
    assert_equal(spec.ast.path_of(spec.defs[0].node), "s.spec")


def test_a_syntax_error_in_a_prelude_names_it() raises:
    var fs = Files(disk=False)
    fs.add("p.prelude", "fn ok() -> int = 1\nfn (\n")
    var lines = messages('spec s\nprelude "p.prelude"\n', "s.spec", fs)
    assert_equal(len(lines), 1, show(lines))
    assert_true(lines[0].startswith("p.prelude:2:"), lines[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
