"""Specs in several files: user preludes and `use`, end to end through the runner."""

from __future__ import annotations

import pytest
from support import Loaded, write_spec

PRELUDE = """\
fn same_as(a: i32, b: i32) -> bool = a == b
fn near(a: i32, b: i32) -> bool = same_as(a, b) or same_as(a + 1, b)
"""

SPEC = """\
spec pre
prelude "helpers.prelude"

fn runimpls.ident_plus_one_from_five(x: i32) -> i32
  requires near(x, x)
  ensures same_value: same_as(result, x)

fn runimpls.clamp(x: i16, lo: i16, hi: i16) -> i16
  requires lo <= hi
  ensures in_range: lo <= result and result <= hi
"""


def test_a_failing_clause_quotes_its_own_file(tmp_path):
    write_spec(tmp_path, PRELUDE, "helpers.prelude")
    spec = Loaded(write_spec(tmp_path, SPEC))
    try:
        r = spec.run("runimpls.ident_plus_one_from_five")
        assert "runimpls.ident_plus_one_from_five.same_value" in r.failed()
        c = r["runimpls.ident_plus_one_from_five.same_value"]
        assert c["clause_text"] == "ensures same_value: same_as(result, x)"
        cx = r.cx("runimpls.ident_plus_one_from_five.same_value")
        assert int(cx["inputs"]["x"]) == 5
        text = str(cx["explanation"])
        assert "same_as(result, x)" in text
        # The definitions of the prelude ran: the clause held for every other input.
        assert c["counts"]["pass"] > 0
        assert r.spec_errors() == []
    finally:
        spec.close()


def test_two_specs_share_one_prelude(tmp_path):
    write_spec(tmp_path, PRELUDE, "helpers.prelude")
    other = """\
spec other
prelude "helpers.prelude"

fn runimpls.clamp(x: i16, lo: i16, hi: i16) -> i16
  requires lo <= hi
  ensures inside: near(result, result)
"""
    a = Loaded(write_spec(tmp_path, SPEC, "a.spec"))
    b = Loaded(write_spec(tmp_path, other, "b.spec"))
    try:
        assert a.run("runimpls.clamp").passed_all()
        assert b.run("runimpls.clamp").passed_all()
        assert {i["decl"] for i in b.items()} == {"runimpls.clamp"}
    finally:
        a.close()
        b.close()


def test_use_brings_the_declarations_of_another_spec(tmp_path):
    write_spec(tmp_path, PRELUDE, "helpers.prelude")
    write_spec(tmp_path, SPEC, "base.spec")
    top = 'spec top\nuse "base.spec"\n\nfn runimpls.clamp_identity_bug(x: i16, lo: i16, hi: i16) -> i16\n  requires lo <= hi\n  ensures in_range: lo <= result and result <= hi\n'
    spec = Loaded(write_spec(tmp_path, top, "top.spec"))
    try:
        items = spec.items()
        decls = {i["decl"] for i in items}
        # Each item names the file its clause is written in.
        files = {i["decl"]: i["file"] for i in items}
        assert files["runimpls.clamp_identity_bug"].endswith("top.spec")
        assert files["runimpls.clamp"].endswith("base.spec")
        assert decls == {
            "runimpls.ident_plus_one_from_five",
            "runimpls.clamp",
            "runimpls.clamp_identity_bug",
        }
        assert spec.run("runimpls.clamp").passed_all()
        # A clause of the used spec quotes that file's text, not the first file's.
        r = spec.run("runimpls.ident_plus_one_from_five")
        c = r["runimpls.ident_plus_one_from_five.same_value"]
        assert c["clause_text"] == "ensures same_value: same_as(result, x)"
        assert c["counts"]["fail"] > 0
    finally:
        spec.close()


def test_a_spec_error_in_a_prelude_names_that_file_and_line(tmp_path):
    write_spec(tmp_path, "fn ok(a: i32) -> bool = a == a\n\nfn bad(a: i32) -> bool = a + 1\n", "helpers.prelude")
    with pytest.raises(ValueError) as e:
        Loaded(write_spec(tmp_path, SPEC))
    lines = str(e.value).splitlines()
    helper = str(tmp_path / "helpers.prelude")
    assert any(l.startswith(f"{helper}:3:") for l in lines), lines


def test_a_missing_prelude_file_is_a_spec_error(tmp_path):
    with pytest.raises(ValueError) as e:
        Loaded(write_spec(tmp_path, SPEC))
    assert "cannot read prelude file helpers.prelude" in str(e.value)


def test_a_use_cycle_is_a_spec_error(tmp_path):
    write_spec(tmp_path, 'spec a\nuse "b.spec"\n', "a.spec")
    write_spec(tmp_path, 'spec b\nuse "a.spec"\n', "b.spec")
    with pytest.raises(ValueError) as e:
        Loaded(tmp_path / "a.spec")
    assert "use cycle" in str(e.value)


def test_a_system_prelude_name_is_a_spec_error(tmp_path):
    write_spec(tmp_path, "fn sorted(a: i32) -> bool = true\n", "helpers.prelude")
    with pytest.raises(ValueError) as e:
        Loaded(write_spec(tmp_path, SPEC))
    assert "sorted is a prelude function and cannot be redefined" in str(e.value)
