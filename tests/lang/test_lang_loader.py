import sys
import types
from pathlib import Path

import pytest

from spectest.ast import Span
from spectest.lang import Diagnostic, SpecCheckError, SpecSyntaxError, load, load_source
from spectest.lang.__main__ import main
from spectest.types import INT, ModelT

SHARED = """\
spec shared
error Missing
model Frame
  observe n: int
  invariant pos: n >= 0
fn helper(x: int) -> int
  ensures h: result == x
"""

MAIN = """\
spec main
use "lib/shared.spec"
fn count(df: Frame) -> int
  raises Missing when df.n == 0
  ensures result == df.n
"""


def write(root: Path, files: dict[str, str]) -> None:
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


class TestUse:
    def test_used_declarations_are_visible(self, tmp_path: Path):
        write(tmp_path, {"lib/shared.spec": SHARED, "main.spec": MAIN})
        spec = load(tmp_path / "main.spec")
        assert set(spec.fns) == {"count"}
        assert "Frame" in spec.models and "Missing" in spec.errors
        assert spec.signature[spec.fns["count"]].params == (ModelT("Frame"),)
        assert "Frame.pos" in spec.clause_ids
        assert "helper.h" not in spec.clause_ids
        (used,) = spec.uses
        assert used.name == "shared"
        assert spec.signature[spec.models["Frame"].observers[0]].result == INT
        assert spec.hash != used.hash

    def test_hash_covers_used_files(self, tmp_path: Path):
        write(tmp_path, {"lib/shared.spec": SHARED, "main.spec": MAIN})
        before = load(tmp_path / "main.spec").hash
        write(tmp_path, {"lib/shared.spec": SHARED + "error Other\n"})
        assert load(tmp_path / "main.spec").hash != before

    def test_used_fns_are_not_callable(self, tmp_path: Path):
        write(tmp_path, {
            "lib/shared.spec": SHARED,
            "main.spec": MAIN + "fn g(x: int) -> int\n  relates helper(x) == result\n",
        })  # fmt: skip
        with pytest.raises(SpecCheckError, match="unknown function helper"):
            load(tmp_path / "main.spec")

    def test_redeclaring_a_used_name(self, tmp_path: Path):
        write(tmp_path, {"lib/shared.spec": SHARED, "main.spec": MAIN + "model Frame\n"})
        with pytest.raises(SpecCheckError, match="Frame is already declared in"):
            load(tmp_path / "main.spec")

    def test_missing_file(self, tmp_path: Path):
        write(tmp_path, {"main.spec": MAIN})
        with pytest.raises(SpecCheckError) as info:
            load(tmp_path / "main.spec")
        (d,) = info.value.diagnostics
        assert "cannot find 'lib/shared.spec'" in d.message
        assert (d.span.line, d.span.col) == (2, 1)

    def test_cycle(self, tmp_path: Path):
        write(tmp_path, {
            "a.spec": 'spec a\nuse "b.spec"\n',
            "b.spec": 'spec b\nuse "a.spec"\n',
        })  # fmt: skip
        with pytest.raises(SpecCheckError, match="makes a cycle"):
            load(tmp_path / "a.spec")

    def test_diamond_loads_each_file_once(self, tmp_path: Path):
        write(tmp_path, {
            "base.spec": "spec base\nerror E\n",
            "l.spec": 'spec l\nuse "base.spec"\nmodel L\n',
            "r.spec": 'spec r\nuse "base.spec"\nmodel R\n',
            "top.spec": 'spec top\nuse "l.spec"\nuse "r.spec"\nfn f(a: L, b: R)\n'
                        "  raises E when true\n",
        })  # fmt: skip
        spec = load(tmp_path / "top.spec")
        assert spec.uses[0].uses[0] is spec.uses[1].uses[0]

    def test_errors_in_a_used_file_name_that_file(self, tmp_path: Path):
        write(
            tmp_path,
            {"lib/shared.spec": SHARED + "fn bad(x: f64)\n  ensures x == x\n", "main.spec": MAIN},
        )
        with pytest.raises(SpecCheckError) as info:
            load(tmp_path / "main.spec")
        assert "shared.spec:9:" in str(info.value)


class TestLoadSource:
    def test_load_source(self, tmp_path: Path):
        write(tmp_path, {"lib/shared.spec": SHARED})
        spec = load_source(MAIN, "inline.spec", base=tmp_path)
        assert spec.path == "inline.spec" and "count" in spec.fns

    def test_syntax_errors_propagate(self):
        with pytest.raises(SpecSyntaxError):
            load_source("spec s\nfn f(\n")


class TestPartitionHook:
    def install(self, monkeypatch: pytest.MonkeyPatch, diags: list[object]) -> None:
        module = types.ModuleType("spectest.sets")
        module.check_partitions = lambda spec: diags  # type: ignore[attr-defined]
        monkeypatch.setitem(sys.modules, "spectest.sets", module)
        import spectest

        monkeypatch.setattr(spectest, "sets", module, raising=False)

    def test_errors_raise_with_excerpts(self, monkeypatch: pytest.MonkeyPatch):
        class D:
            span = Span(2, 1, 2, 3)
            message = "classes overlap"
            severity = "error"

        self.install(monkeypatch, [D()])
        with pytest.raises(SpecCheckError) as info:
            load_source("spec s\nfn f(x: f64)\n", "s.spec")
        (d,) = info.value.diagnostics
        assert d.message == "classes overlap" and d.path == "s.spec"
        assert "s.spec:2:1: error: classes overlap" in str(info.value)
        assert "^^" in d.excerpt

    def test_warnings_are_kept(self, monkeypatch: pytest.MonkeyPatch):
        warning = Diagnostic("", Span(2, 1, 2, 3), "class is empty", severity="warning")
        self.install(monkeypatch, [warning])
        spec = load_source("spec s\nfn f(x: f64)\n", "s.spec")
        (w,) = spec.warnings
        assert w.severity == "warning" and w.path == "s.spec"
        assert str(w).startswith("s.spec:2:1: warning: class is empty")

    def test_missing_sets_module_is_skipped(self, monkeypatch: pytest.MonkeyPatch):
        import spectest

        monkeypatch.setitem(sys.modules, "spectest.sets", None)
        monkeypatch.delattr(spectest, "sets", raising=False)
        assert load_source("spec s\nfn f(x: f64)\n").fns


class TestCli:
    def test_ok(self, tmp_path: Path, capsys: pytest.CaptureFixture[str]):
        write(tmp_path, {"lib/shared.spec": SHARED, "main.spec": MAIN})
        assert main([str(tmp_path / "main.spec")]) == 0
        assert capsys.readouterr().out.strip().endswith("main.spec: ok")

    def test_errors(self, tmp_path: Path, capsys: pytest.CaptureFixture[str]):
        write(tmp_path, {"bad.spec": "spec b\nfn f(x: f64)\n  ensures x == x\n  ensures y\n"})
        assert main([str(tmp_path / "bad.spec")]) == 1
        out = capsys.readouterr().out
        assert "bad.spec:3:11: error: == is not defined on f64" in out
        assert "bad.spec:4:11: error: unknown name y" in out
        assert " 3 |   ensures x == x" in out

    def test_missing_file_and_usage(self, tmp_path: Path, capsys: pytest.CaptureFixture[str]):
        assert main([str(tmp_path / "nope.spec")]) == 1
        assert "error" in capsys.readouterr().out
        assert main([]) == 2

    def test_examples(self, capsys: pytest.CaptureFixture[str]):
        root = Path(__file__).resolve().parents[2]
        paths = [str(p) for p in sorted((root / "examples").glob("*/*.spec"))]
        assert main(paths) == 0
        assert capsys.readouterr().out.count(": ok") == len(paths)
