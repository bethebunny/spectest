"""The v2 front end end to end: spectest.check objects and .spec files in a scratch
project, run against the fake host."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fake_spec_host import FakeHost, item, make_test

pytest_plugins = ["pytester"]

from spectest.runtime.report import load_reports

ARGS = ("-p", "no:cacheprovider", "-p", "no:randomly")


def ids(result: pytest.RunResult) -> list[str]:
    return [ln for ln in result.outlines if "::" in ln]


def collect(project: pytest.Pytester, *args: str) -> list[str]:
    return ids(project.runpytest("--collect-only", "-q", *ARGS, *args))


# -- collection ---------------------------------------------------------------


def test_a_check_object_is_collected_from_a_test_module(project: pytest.Pytester) -> None:
    make_test(project, 'test_math = spectest.check("demo.spec")\nnot_collected = test_math\n')
    assert collect(project) == [
        "test_demo.py::test_math::math.cos.accurate",
        "test_demo.py::test_math::math.cos#type",
        "test_demo.py::test_math::math.sqrt.exact",
    ]


def test_a_spec_argument_is_collected_with_default_options(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    assert collect(project, "demo.spec") == [
        "demo.spec::math.cos.accurate",
        "demo.spec::math.cos#type",
        "demo.spec::math.sqrt.exact",
    ]
    result = project.runpytest("demo.spec", *ARGS)
    result.assert_outcomes(passed=3)
    assert [d for d, _ in fake_host.runs()] == ["math.cos", "math.sqrt"]


def test_spec_files_in_a_directory_are_not_collected(project: pytest.Pytester) -> None:
    assert collect(project) == []


def test_the_check_path_is_relative_to_the_test_module(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    fake_host.specs["inner"] = [item("pkg.f", "ok")]
    sub = project.mkdir("sub")
    (sub / "inner.spec").write_text("spec inner\n")
    (sub / "test_inner.py").write_text('import spectest\ntest_x = spectest.check("inner.spec")\n')
    assert collect(project, "sub") == ["sub/test_inner.py::test_x::pkg.f.ok"]


def test_instantiations_make_one_item_each(project: pytest.Pytester) -> None:
    make_test(
        project,
        """
        test_g = spectest.check(
            "generic.spec", instantiations={"sort": [{"T": "i64"}, {"T": "string"}]}
        )
        """,
    )
    assert collect(project) == [
        "test_demo.py::test_g::sort[T=i64].ordered",
        "test_demo.py::test_g::sort[T=string].ordered",
        "test_demo.py::test_g::sort[T=i64].stable",
        "test_demo.py::test_g::sort[T=string].stable",
        "test_demo.py::test_g::first.head",
    ]


def test_a_generic_declaration_without_instantiations_errors(project: pytest.Pytester) -> None:
    make_test(project, 'test_g = spectest.check("generic.spec")\n')
    assert collect(project) == [
        "test_demo.py::test_g::sort.ordered",
        "test_demo.py::test_g::sort.stable",
        "test_demo.py::test_g::first.head",
    ]
    result = project.runpytest(*ARGS)
    result.assert_outcomes(passed=1, failed=2)
    out = result.stdout.str()
    assert "sort is generic (T)" in out
    assert "instantiations=" in out


def test_a_qualified_generic_declaration_is_named_before_its_clause(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    fake_host.specs["generic"] = [item("lib.sort", "ordered", tparams=("T",))]
    make_test(
        project, 'test_g = spectest.check("generic.spec", instantiations={"lib.sort": [{"T": "i64"}]})\n'
    )
    assert collect(project) == ["test_demo.py::test_g::lib.sort[T=i64].ordered"]


def test_a_qualified_generic_failure_prints_its_label(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    fake_host.specs["generic"] = [item("lib.sort", "ordered", tparams=("T",))]
    fake_host.verdicts["lib.sort.ordered"] = "fail"
    make_test(
        project, 'test_g = spectest.check("generic.spec", instantiations={"lib.sort": [{"T": "i64"}]})\n'
    )
    result = project.runpytest(*ARGS)
    result.assert_outcomes(failed=1)
    assert "lib.sort[T=i64].ordered (ensures) failed" in result.stdout.str()


# -- runs ---------------------------------------------------------------------


def test_items_of_a_declaration_share_one_run(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    make_test(
        project,
        """
        test_g = spectest.check(
            "generic.spec", instantiations={"sort": [{"T": "i64"}, {"T": "string"}]}
        )
        """,
    )
    project.runpytest(*ARGS).assert_outcomes(passed=5)
    runs = [(d, o.get("instantiation")) for d, o in fake_host.runs()]
    assert runs == [("sort", {"T": "i64"}), ("sort", {"T": "string"}), ("first", None)]


def test_the_specs_are_unloaded_at_the_end(project: pytest.Pytester, fake_host: FakeHost) -> None:
    make_test(project, 'test_math = spectest.check("demo.spec")\n')
    project.runpytest(*ARGS).assert_outcomes(passed=3)
    kinds = [c[0] for c in fake_host.calls]
    assert kinds[0] == "load" and kinds[-1] == "unload"


def test_items_of_a_declaration_form_an_xdist_group(project: pytest.Pytester) -> None:
    make_test(project, 'test_math = spectest.check("demo.spec")\n')
    items = project.inline_genitems()[0]
    groups = [
        (i.name, [m.kwargs["name"] for m in i.iter_markers("xdist_group")]) for i in items
    ]
    assert next(g for _, g in groups) == [g for _, g in groups][1]
    assert groups[0][1] != groups[2][1]
    assert groups[0][1][0].endswith("::math.cos")


def test_run_options_come_from_the_session_and_the_check(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    make_test(
        project,
        """
        test_math = spectest.check(
            "demo.spec", max_examples=7, examples={"math.cos": [{"x": 0.5}]}
        )
        """,
    )
    project.runpytest(
        "--spectest-seed=5", "--spectest-no-store", "--spectest-exhaustive-limit=99", *ARGS
    ).assert_outcomes(passed=3)
    (_cos, cos_opts), (_sqrt, sqrt_opts) = fake_host.runs()
    assert cos_opts == {
        "seed": 5,
        "store": None,
        "strength": "dev",
        "max_examples": 7,
        "exhaustive_limit": 99,
        "examples": [{"x": 0.5}],
    }
    assert "examples" not in sqrt_opts


def test_the_command_line_overrides_max_examples(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    make_test(project, 'test_math = spectest.check("demo.spec", max_examples=7, seed=3)\n')
    project.runpytest("--spectest-max-examples=2", *ARGS).assert_outcomes(passed=3)
    options = fake_host.runs()[0][1]
    assert options["max_examples"] == 2
    assert options["seed"] == 3
    assert options["store"].endswith(".spectest")


def test_ci_is_full_strength(project: pytest.Pytester, fake_host: FakeHost) -> None:
    make_test(project, 'test_math = spectest.check("demo.spec")\n')
    project.runpytest("--spectest-profile=ci", *ARGS).assert_outcomes(passed=3)
    assert fake_host.runs()[0][1]["strength"] == "full"


# -- outcomes -----------------------------------------------------------------


def outcome_project(project: pytest.Pytester, fake_host: FakeHost, extra: str = "") -> None:
    make_test(project, f'test_math = spectest.check("demo.spec"{extra})\n')


def test_every_outcome(project: pytest.Pytester, fake_host: FakeHost) -> None:
    fake_host.verdicts = {
        "math.cos.accurate": "fail",
        "math.cos#type": "error",
        "math.sqrt.exact": "skip",
    }
    outcome_project(project, fake_host)
    result = project.runpytest("-rA", *ARGS)
    result.assert_outcomes(failed=2, skipped=1)
    out = result.stdout.str()
    # v1's failure rendering
    assert "math.cos.accurate (ensures) failed" in out
    assert "x = 0.5" in out
    assert "result = 0.8775825618903728" in out
    assert "SPEC ERROR (the spec's or the binding's fault)" in out
    assert "cr.cos is undefined" in out
    assert "no example applied: 5 skip" in out
    assert any(ln.startswith("SPEC ERROR test_demo.py") for ln in result.outlines)


def test_an_inconclusive_item_is_skipped(project: pytest.Pytester, fake_host: FakeHost) -> None:
    fake_host.verdicts = {"math.sqrt.exact": "inconclusive"}
    outcome_project(project, fake_host)
    result = project.runpytest("-rs", *ARGS)
    result.assert_outcomes(passed=2, skipped=1)
    assert "inconclusive: 2 inconclusive" in result.stdout.str()


def test_expect_fail_makes_a_failure_an_xfail(project: pytest.Pytester, fake_host: FakeHost) -> None:
    fake_host.verdicts = {"math.cos.accurate": "fail"}
    outcome_project(project, fake_host, ', expect_fail={"math.cos.accurate"}')
    result = project.runpytest("-rx", *ARGS)
    result.assert_outcomes(passed=2, xfailed=1)
    assert "x = 0.5" in result.stdout.str()


def test_expect_fail_that_passes_is_an_xpass(project: pytest.Pytester, fake_host: FakeHost) -> None:
    outcome_project(project, fake_host, ', expect_fail={"math.cos.accurate"}')
    result = project.runpytest(*ARGS)
    result.assert_outcomes(passed=2, failed=1)
    assert "[XPASS(strict)] expected to fail: math.cos.accurate" in result.stdout.str()


def test_runxfail_turns_an_xfail_into_a_failure(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    fake_host.verdicts = {"math.cos.accurate": "fail"}
    outcome_project(project, fake_host, ', expect_fail={"math.cos.accurate"}')
    result = project.runpytest("--runxfail", *ARGS)
    result.assert_outcomes(passed=2, failed=1)


def test_expect_fail_names_an_instantiated_clause(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    fake_host.verdicts = {"sort.ordered": "fail"}
    make_test(
        project,
        """
        test_g = spectest.check(
            "generic.spec",
            instantiations={"sort": [{"T": "i64"}]},
            expect_fail={"sort[T=i64].ordered"},
        )
        """,
    )
    project.runpytest(*ARGS).assert_outcomes(passed=2, xfailed=1)


# -- module mapping ---------------------------------------------------------


def test_modules_option_reaches_the_driver(project: pytest.Pytester, fake_host: FakeHost) -> None:
    make_test(
        project, 'test_math = spectest.check("demo.spec", modules={"math": "examples.libm.buggy"})\n'
    )
    project.runpytest(*ARGS).assert_outcomes(passed=3)
    (driver,) = fake_host.drivers
    assert driver.module_map == {"math": "examples.libm.buggy"}


def test_the_module_option_adds_to_the_mapping(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    make_test(project, 'test_math = spectest.check("demo.spec", modules={"math": "a.b", "x": "y"})\n')
    project.runpytest(
        "--spectest-module", "math=c.d", "--spectest-module=z=w", *ARGS
    ).assert_outcomes(passed=3)
    (driver,) = fake_host.drivers
    assert driver.module_map == {"math": "c.d", "x": "y", "z": "w"}


def test_the_module_option_applies_to_spec_arguments(
    project: pytest.Pytester, fake_host: FakeHost
) -> None:
    project.runpytest("demo.spec", "--spectest-module=math=statistics", *ARGS).assert_outcomes(
        passed=3
    )
    assert fake_host.drivers[0].module_map == {"math": "statistics"}
    assert fake_host.drivers[0].resolve("math.mean") > 0


def test_a_malformed_module_option_is_a_usage_error(project: pytest.Pytester) -> None:
    make_test(project, 'test_math = spectest.check("demo.spec")\n')
    result = project.runpytest("--spectest-module=math", *ARGS)
    assert "expected NAME=REPLACEMENT" in result.stderr.str() + result.stdout.str()


# -- clause selection --------------------------------------------------------


def test_clause_selection_by_name_and_id(project: pytest.Pytester, fake_host: FakeHost) -> None:
    make_test(
        project,
        """
        test_g = spectest.check(
            "generic.spec", instantiations={"sort": [{"T": "i64"}, {"T": "string"}]}
        )
        """,
    )
    result = project.runpytest("--spectest-clause", "sort[T=i64].*", *ARGS)
    result.assert_outcomes(passed=2, deselected=3)
    assert [o["instantiation"] for _, o in fake_host.runs()] == [{"T": "i64"}]
    result = project.runpytest("--spectest-clause=first.head,sort.stable", *ARGS)
    result.assert_outcomes(passed=3, deselected=2)


# -- reports -----------------------------------------------------------------


def test_the_markdown_and_json_reports(project: pytest.Pytester, fake_host: FakeHost) -> None:
    fake_host.verdicts = {"math.cos.accurate": "fail"}
    outcome_project(project, fake_host)
    result = project.runpytest("--spectest-report=r.md", "--spectest-json=r.json", *ARGS)
    result.assert_outcomes(passed=2, failed=1)
    md = (project.path / "r.md").read_text()
    assert "math.cos.accurate" in md
    assert "x = 0.5" in md
    (report,) = load_reports((project.path / "r.json").read_text())
    assert report.spec_name == "demo"
    assert [r.clause_id for r in report.results] == [
        "math.cos.accurate",
        "math.cos#type",
        "math.sqrt.exact",
    ]
    assert report.results[0].item_id == "test_demo.py::test_math::math.cos.accurate"
    assert report.items["test_demo.py::test_math::math.cos.accurate"] == "failed"
    result.stdout.fnmatch_lines(["*spectest*", "*test_demo.py::test_math (spec demo): 2 passed, 1 failed*"])
    assert json.loads((project.path / "r.json").read_text())


# -- spec errors -------------------------------------------------------------


def test_a_spec_that_does_not_load_fails_collection(project: pytest.Pytester) -> None:
    make_test(project, 'test_bad = spectest.check("broken.spec")\n')
    result = project.runpytest(*ARGS)
    result.assert_outcomes(errors=1)
    out = result.stdout.str()
    assert "broken.spec:2:5: unknown name 'frobnicate'" in out
    assert "broken.spec:7:1: bad clause" in out


def test_a_spec_argument_that_does_not_load_fails_collection(project: pytest.Pytester) -> None:
    result = project.runpytest("broken.spec", *ARGS)
    result.assert_outcomes(errors=1)
    assert "unknown name 'frobnicate'" in result.stdout.str()


def test_a_missing_host_module_is_a_usage_error(project: pytest.Pytester, fake_host: FakeHost) -> None:
    import sys

    make_test(project, 'test_math = spectest.check("demo.spec")\n')
    sys.modules["spectest._host"] = None  # type: ignore[assignment]
    result = project.runpytest(*ARGS)
    assert "spectest._host is not available" in result.stdout.str() + result.stderr.str()


@pytest.mark.slow
def test_an_xdist_run_runs_each_declaration_once(
    project: pytest.Pytester, fake_host: FakeHost, monkeypatch: pytest.MonkeyPatch
) -> None:
    pytest.importorskip("xdist")
    log = project.path / "runs.log"
    monkeypatch.setenv("FAKE_HOST_LOG", str(log))
    monkeypatch.setenv("PYTHONPATH", str(Path(__file__).parent))
    project.makeconftest(
        """
        import sys
        from fake_spec_host import FakeHost
        sys.modules["spectest._host"] = FakeHost()
        """
    )
    make_test(
        project,
        """
        test_g = spectest.check(
            "generic.spec", instantiations={"sort": [{"T": "i64"}, {"T": "string"}]}
        )
        """,
    )
    result = project.runpytest_subprocess("-n", "2", "--spectest-report=r.md", *ARGS)
    result.assert_outcomes(passed=5)
    assert "ordered" in (project.path / "r.md").read_text()
    assert sorted(log.read_text().splitlines()) == [
        "first []",
        "sort [('T', 'i64')]",
        "sort [('T', 'string')]",
    ]
