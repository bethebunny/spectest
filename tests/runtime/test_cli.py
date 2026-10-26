"""The spectest command line: check and report."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from spectest import cli
from spectest.runtime.report import ClauseResult, Counterexample, Report, dump_reports

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = sorted(ROOT.glob("examples/*/*.spec"))


def test_check_example_specs(capsys):
    assert len(EXAMPLES) >= 6
    assert cli.main(["check", *map(str, EXAMPLES)]) == 0
    out = capsys.readouterr().out.splitlines()
    assert out == [f"{p}: ok" for p in EXAMPLES]


def test_check_reports_errors(tmp_path, capsys):
    bad = tmp_path / "bad.spec"
    bad.write_text("spec bad\n\nfn f(x: f64) -> f64\n  ensures result == x\n  ensures y > 0\n")
    good = EXAMPLES[0]
    assert cli.main(["check", str(bad), str(good)]) == 1
    out = capsys.readouterr().out
    assert f"{bad}:4:" in out and f"{bad}:5:" in out
    assert "error:" in out and " | " in out
    assert f"{bad}: 2 error(s)" in out
    assert f"{good}: ok" in out


def test_check_syntax_error(tmp_path, capsys):
    bad = tmp_path / "syntax.spec"
    bad.write_text("spec s\n\nfn f(x: ) -> i64\n")
    assert cli.main(["check", str(bad)]) == 1
    assert f"{bad}:3:" in capsys.readouterr().out


def test_check_missing_file(tmp_path, capsys):
    missing = tmp_path / "missing.spec"
    assert cli.main(["check", str(missing)]) == 1
    assert f"{missing}: error:" in capsys.readouterr().out


def test_check_needs_a_file(capsys):
    with pytest.raises(SystemExit) as e:
        cli.main(["check"])
    assert e.value.code == 2


def sample_report() -> Report:
    r = ClauseResult(
        item_id="test_libm.py::test_math::cos.accurate",
        clause_id="cos.accurate",
        clause_text="ensures accurate: ulp_error(result, mp.cos(x)) <= 1",
        kind="ensures",
        decl="cos",
        counts={"pass": 9, "fail": 1},
        counterexample=Counterexample(inputs={"x": "1e+300"}, observation="result = 0.5"),
        failing_inputs=1,
    )
    return Report("libm", "a" * 64, "0.1.0.dev0", "6.170.9", [r])


def test_report_prints_markdown(tmp_path, capsys):
    p = tmp_path / "report.json"
    p.write_text(sample_report().to_json())
    assert cli.main(["report", str(p)]) == 0
    out = capsys.readouterr().out
    assert out.startswith("# spectest report: libm\n")
    assert "## Counterexamples" in out and "  x = 1e+300" in out


def test_report_accepts_a_list(tmp_path, capsys):
    p = tmp_path / "reports.json"
    p.write_text(dump_reports([sample_report(), sample_report()]))
    assert cli.main(["report", str(p)]) == 0
    assert capsys.readouterr().out.startswith("# spectest report\n")


def test_report_errors(tmp_path, capsys):
    assert cli.main(["report", str(tmp_path / "nope.json")]) == 1
    assert "nope.json: error:" in capsys.readouterr().err
    junk = tmp_path / "junk.json"
    junk.write_text('{"not": "a report"}')
    assert cli.main(["report", str(junk)]) == 1
    assert "not a spectest JSON report" in capsys.readouterr().err


def test_version(capsys):
    with pytest.raises(SystemExit) as e:
        cli.main(["--version"])
    assert e.value.code == 0
    assert capsys.readouterr().out.strip() == "spectest 0.1.0.dev0"


def test_module_entry_point():
    out = subprocess.run(
        [sys.executable, "-m", "spectest.cli", "check", str(EXAMPLES[0])],
        capture_output=True,
        text=True,
        check=False,
    )
    assert out.returncode == 0 and out.stdout.strip() == f"{EXAMPLES[0]}: ok"
