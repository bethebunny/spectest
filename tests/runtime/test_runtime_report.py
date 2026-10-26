"""Report model, failure text, Markdown and JSON."""

from __future__ import annotations

import json

import pytest

from spectest.runtime.report import (
    VERDICTS,
    AggregateSummary,
    ClauseResult,
    Counterexample,
    Report,
    dump_reports,
    load_reports,
    render_failure,
    render_markdown,
)

CLAUSE = "ensures accurate: is_finite(x) implies ulp_error(result, mp.cos(x)) <= 1"


def cos_failure(**overrides) -> ClauseResult:
    kwargs = {
        "item_id": "test_libm.py::test_math::cos.accurate",
        "clause_id": "cos.accurate",
        "clause_text": CLAUSE,
        "kind": "ensures",
        "decl": "cos",
        "instantiation": {},
        "mode": "hypothesis",
        "counts": {"pass": 87, "fail": 1, "skip": 12},
        "coverage": {"x.nan": 10, "x.huge": 30, "x.zero": 0},
        "counterexample": Counterexample(
            inputs={"x": "1e+300 (0x7e37e43c8800759c)"},
            observation="result = 0.5 (0x3fe0000000000000)",
            partitions={"x": "huge"},
            explanation=[("mp.cos(x)", "~0.17"), ("ulp_error(result, mp.cos(x))", "~1.2e15")],
            seed=12345,
            reproduce="pytest 'test_libm.py::test_math::cos.accurate' --spectest-seed=12345",
        ),
        "failing_inputs": 1,
        "spec_errors": [],
        "expected_fail": False,
        "duration": 0.25,
    }
    kwargs.update(overrides)
    return ClauseResult(**kwargs)


def passing(**overrides) -> ClauseResult:
    kwargs = {
        "item_id": "test_libm.py::test_math::cos.bounded",
        "clause_id": "cos.bounded",
        "clause_text": "ensures bounded: is_finite(x) implies is_finite(result)",
        "kind": "ensures",
        "decl": "cos",
        "mode": "hypothesis",
        "counts": {"pass": 100},
        "coverage": {"x.nan": 12, "x.huge": 28, "x.zero": 3},
    }
    kwargs.update(overrides)
    return ClauseResult(**kwargs)


def exhaustive_failure() -> ClauseResult:
    return ClauseResult(
        item_id="test_libm.py::test_explore::cos16.correctly_rounded",
        clause_id="cos16.correctly_rounded",
        clause_text="ensures correctly_rounded: is_finite(x) implies same(result, round<f16>(mp.cos(x)))",
        kind="ensures",
        decl="cos16",
        mode="exhaustive",
        counts={"pass": 63000, "fail": 488, "skip": 2048},
        counterexample=Counterexample(
            inputs={"x": "0.5 (0x3800)"},
            observation="result = 0.8774 (0x3b05)",
            seed=None,
            reproduce="pytest 'test_libm.py::test_explore::cos16.correctly_rounded'",
        ),
        failing_inputs=488,
        failing_examples=[{"x": f"{i}.0"} for i in range(1, 9)],
    )


def report(*results: ClauseResult, **kw) -> Report:
    return Report(
        spec_name="libm",
        spec_hash="f" * 64,
        harness_version="0.1.0.dev0",
        hypothesis_version="6.170.9",
        results=list(results),
        spec_path="examples/libm/libm.spec",
        **kw,
    )


# ---------------------------------------------------------------------------
# Model


def test_counts_are_normalized():
    r = cos_failure()
    assert list(r.counts) == list(VERDICTS)
    assert r.counts == {"pass": 87, "fail": 1, "skip": 12, "spec_error": 0, "inconclusive": 0}
    assert r.total == 100
    with pytest.raises(ValueError, match="unknown verdict"):
        cos_failure(counts={"passed": 1})


def test_verdicts_and_outcomes():
    assert cos_failure().verdict == "fail" and cos_failure().outcome == "failed"
    assert cos_failure(expected_fail=True).outcome == "xfailed"
    assert passing().verdict == "pass" and passing().outcome == "passed"
    assert passing(expected_fail=True).outcome == "xpassed"
    err = passing(counts={"pass": 3, "spec_error": 2}, spec_errors=["mp.exp: too large"])
    assert err.verdict == "spec_error" and err.outcome == "error"
    assert passing(counts={"skip": 5}).outcome == "skipped"
    assert passing(counts={"inconclusive": 1}).outcome == "inconclusive"
    assert passing(counts={"inconclusive": 1}).verdict == "inconclusive"
    both = cos_failure(counts={"fail": 1, "spec_error": 1})
    assert both.verdict == "fail"


def test_instantiation_is_text():
    from spectest.types import FixedIntT

    r = passing(instantiation={"T": FixedIntT(64, True)}, clause_id="sort.ordered")
    assert r.instantiation == {"T": "i64"}
    assert r.label == "sort[T=i64].ordered"


# ---------------------------------------------------------------------------
# Failure text


def test_render_failure_key_lines():
    text = render_failure(cos_failure())
    lines = text.splitlines()
    assert lines[0] == "cos.accurate (ensures) failed"
    assert lines[1] == f"  {CLAUSE}"
    assert lines[2] == "  in cos"
    for expected in [
        "inputs:",
        "  x = 1e+300 (0x7e37e43c8800759c)",
        "observed:",
        "  result = 0.5 (0x3fe0000000000000)",
        "partitions:",
        "  x: huge",
        "explanation:",
        "  mp.cos(x) = ~0.17",
        "  ulp_error(result, mp.cos(x)) = ~1.2e15",
        "verdicts: 87 pass, 1 fail, 12 skip (hypothesis)",
        "seed: 12345",
        "reproduce: pytest 'test_libm.py::test_math::cos.accurate' --spectest-seed=12345",
    ]:
        assert expected in lines
    assert lines.index("inputs:") < lines.index("observed:") < lines.index("explanation:")
    assert lines[-1].startswith("reproduce:")


def test_render_failure_exhaustive():
    text = render_failure(exhaustive_failure())
    lines = text.splitlines()
    assert (
        "failed on 488 of 65536 inputs (exhaustive: every input was tried); the first failing input:"
    ) in lines
    assert lines.index("inputs:") == lines.index("  in cos16") + 3
    assert "more failing inputs:" in lines
    assert "  x = 1.0" in lines and "  x = 5.0" in lines and "  x = 6.0" not in lines
    assert "  ... and 482 more" in lines
    assert "seed:" not in text
    assert "verdicts: 63000 pass, 488 fail, 2048 skip (exhaustive)" in lines


def test_render_failure_expected_and_unexpected():
    assert render_failure(cos_failure(expected_fail=True)).splitlines()[0] == (
        "cos.accurate (ensures) failed as expected (expect_fail)"
    )
    first = render_failure(passing(expected_fail=True)).splitlines()[0]
    assert (
        first == "cos.bounded (ensures) was expected to fail (expect_fail), but no example failed"
    )


def test_render_failure_spec_errors():
    r = passing(
        counts={"pass": 3, "spec_error": 2},
        spec_errors=["evaluating cos.bounded: mp.exp: result too large\n  x = 1e6"],
    )
    lines = render_failure(r).splitlines()
    assert lines[0] == "cos.bounded (ensures) spec error"
    assert "spec errors (1), the spec's or the binding's fault:" in lines
    assert "  evaluating cos.bounded: mp.exp: result too large" in lines
    assert "    x = 1e6" in lines


def test_render_failure_with_instantiation_and_raised_observation():
    r = cos_failure(
        clause_id="sort.ordered",
        decl="sort",
        instantiation={"T": "string"},
        counterexample=Counterexample(
            inputs={"xs": '["b", "a"]'}, observation="raised TypeError: '<' not supported"
        ),
    )
    lines = render_failure(r).splitlines()
    assert lines[0] == "sort[T=string].ordered (ensures) failed"
    assert "  in sort with T=string" in lines
    assert "  raised TypeError: '<' not supported" in lines
    assert not any(line.startswith("partitions") for line in lines)


# ---------------------------------------------------------------------------
# Markdown


def test_render_markdown_sections():
    md = render_markdown(report(cos_failure(), passing(), exhaustive_failure()))
    lines = md.splitlines()
    assert lines[0] == "# spectest report: libm"
    assert "- **Spec:** `libm` (`examples/libm/libm.spec`)" in lines
    assert f"- **Spec hash:** `{'f' * 64}`" in lines
    assert "- **Harness:** spectest 0.1.0.dev0, Hypothesis 6.170.9" in lines
    assert "- **Items:** 3: 1 passed, 2 failed" in lines
    assert "- **Clause results:** 3: 1 passed, 2 failed" in lines
    assert "## Spec errors" not in lines
    assert "## Results" in lines
    header = (
        "| Item | Clause | Kind | Mode | Verdict | pass | fail | skip | spec error | inconclusive "
        "| Time |"
    )
    assert header in lines
    assert (
        "| `test_libm.py::test_math::cos.accurate` | `cos.accurate` | ensures | hypothesis "
        "| **FAIL** | 87 | 1 | 12 | 0 | 0 | 0.25s |"
    ) in lines
    assert any(
        line.startswith(
            "| `test_libm.py::test_math::cos.bounded` | `cos.bounded` | ensures | hypothesis "
            "| pass |"
        )
        for line in lines
    )
    assert any("| exhaustive | **FAIL** | 63000 | 488 | 2048 |" in line for line in lines)
    assert "## Coverage" in lines
    assert "### `cos`" in lines
    assert "| Clause | x.nan | x.huge | x.zero |" in lines
    assert "| `test_math::cos.accurate` | 10 | 30 | **0** |" in lines
    assert "| `test_math::cos.bounded` | 12 | 28 | 3 |" in lines
    assert "## Counterexamples" in lines
    assert "### `test_math::cos.accurate`" in lines
    assert "### `test_explore::cos16.correctly_rounded`" in lines
    assert "### `test_math::cos.bounded`" not in lines
    block = md[md.index("### `test_math::cos.accurate`") :]
    assert block.split("\n", 3)[2] == "```text"
    assert "  x = 1e+300 (0x7e37e43c8800759c)" in block


def test_render_markdown_lists_expected_failures_and_spec_errors_first():
    err = passing(
        item_id="t::m::sqrt.monotone",
        clause_id="sqrt.monotone",
        decl="sqrt",
        counts={"pass": 1, "spec_error": 4},
        spec_errors=["evaluating sqrt.monotone: real: cannot promote NaN"],
        coverage={},
    )
    md = render_markdown(report(cos_failure(expected_fail=True), err, errors=["binding: boom"]))
    lines = md.splitlines()
    assert "- **Items:** 2: 1 expected failure, 1 spec error" in lines
    errors_at = lines.index("## Spec errors")
    assert errors_at < lines.index("## Results")
    assert "- binding: boom" in lines
    assert (
        "- `sqrt.monotone` (`t::m::sqrt.monotone`): evaluating sqrt.monotone: real: cannot promote NaN"
    ) in lines
    assert "### `test_math::cos.accurate` (expected failure)" in lines
    assert any("| expected fail |" in line for line in lines)
    assert any("| **SPEC ERROR** |" in line for line in lines)


def test_render_markdown_escapes_pipes():
    r = passing(item_id="t::m::dropna.rows", clause_id="dropna.rows", decl="dropna", kind="ensures",
                coverage={'how="any" | "all"': 2})  # fmt: skip
    md = render_markdown(report(r))
    assert '| Clause | how="any" \\| "all" |' in md


def test_render_markdown_several_reports():
    other = Report("deque", "0" * 64, "0.1.0.dev0", "6.170.9", [passing(item_id="d::x")])
    md = render_markdown([report(passing()), other])
    lines = md.splitlines()
    assert lines[0] == "# spectest report"
    assert "## spectest report: libm" in lines and "## spectest report: deque" in lines
    assert "### Results" in lines


def test_render_markdown_unexpected_pass():
    md = render_markdown(report(passing(expected_fail=True)))
    assert "**UNEXPECTED PASS**" in md
    assert "- **Items:** 1: 1 unexpected pass" in md


# ---------------------------------------------------------------------------
# JSON


def test_json_round_trip():
    rep = report(
        cos_failure(), passing(instantiation={"T": "i64"}), exhaustive_failure(), errors=["x"]
    )
    text = rep.to_json()
    json.loads(text)
    back = Report.from_json(text)
    assert back == rep
    cx = back.results[0].counterexample
    assert isinstance(cx, Counterexample)
    assert cx.explanation == [("mp.cos(x)", "~0.17"), ("ulp_error(result, mp.cos(x))", "~1.2e15")]
    assert all(isinstance(p, tuple) for p in cx.explanation)
    assert Report.from_json(json.loads(text)) == rep
    assert back.results[1].counterexample is None
    assert render_markdown(back) == render_markdown(rep)


def test_json_is_lenient_about_missing_optional_fields():
    minimal = {
        "spec_name": "s",
        "spec_hash": "h",
        "harness_version": "v",
        "hypothesis_version": "h",
        "results": [{"item_id": "i", "clause_id": "f.c", "counts": {"pass": 1}, "future": 1}],
    }
    rep = Report.from_json(json.dumps(minimal))
    assert rep.results[0].counts["pass"] == 1 and rep.results[0].counterexample is None


def test_several_reports_as_json():
    reps = [report(passing()), report(cos_failure())]
    assert load_reports(dump_reports(reps)) == reps
    assert load_reports(reps[0].to_json()) == [reps[0]]


def aggregate_result(**overrides) -> ClauseResult:
    kwargs = {
        "item_id": "test_libm.py::test_math::cos16.budget",
        "clause_id": "cos16.budget",
        "clause_text": "aggregate budget: sum(x in f16.finite: steps(qe(cos16(x), cr.cos(x)))) <= 100",
        "kind": "aggregate",
        "decl": "cos16",
        "mode": "exhaustive",
        "counts": {"fail": 1},
        "aggregate": AggregateSummary(
            value="130",
            bound="100",
            evaluated=63486,
            skipped=2,
            total=63488,
            sampled=False,
            worst=[("x = 0.5 (0x3800)", "3"), ("x = 1.5 (0x3e00)", "2")],
        ),
    }
    kwargs.update(overrides)
    return ClauseResult(**kwargs)


def test_render_failure_aggregate():
    lines = render_failure(aggregate_result()).splitlines()
    assert lines[0] == "cos16.budget (aggregate) failed"
    assert "value: 130 (bound 100)" in lines
    assert "members: 63486 evaluated, 2 skipped, of 63488 (every member)" in lines
    assert "largest terms:" in lines and "  x = 0.5 (0x3800): 3" in lines
    sampled = aggregate_result(
        counts={"pass": 1},
        mode="sampled",
        aggregate=AggregateSummary("12", "100", evaluated=4096, total=2**64, sampled=True),
        expected_fail=True,
    )
    lines = render_failure(sampled).splitlines()
    assert f"members: 4096 evaluated, of {2**64} (a seeded sample)" in lines


def test_render_markdown_aggregates():
    md = render_markdown(report(aggregate_result(), passing()))
    lines = md.splitlines()
    assert "## Aggregates" in lines
    assert "| Clause | Verdict | Value | Bound | Members |" in lines
    assert (
        "| `test_math::cos16.budget` | **FAIL** | 130 | 100 "
        "| 63486 evaluated, 2 skipped, of 63488 (every member) |"
    ) in lines
    assert "### `test_math::cos16.budget`" in lines


def test_aggregate_json_round_trip():
    rep = report(aggregate_result())
    back = Report.from_json(rep.to_json())
    assert back == rep
    assert back.results[0].aggregate.worst[0] == ("x = 0.5 (0x3800)", "3")
    as_dict = aggregate_result(aggregate={"value": "1", "bound": "2", "worst": [["a", "b"]]})
    assert as_dict.aggregate == AggregateSummary("1", "2", worst=[("a", "b")])


def test_spec_errors_are_deduplicated_and_capped():
    errs = ["same problem"] * 3 + [f"problem {i}" for i in range(12)]
    r = passing(counts={"spec_error": 15}, spec_errors=errs)
    lines = render_failure(r).splitlines()
    assert "spec errors (13), the spec's or the binding's fault:" in lines
    assert lines.count("  same problem") == 1
    assert "  ... and 3 more" in lines
    md = render_markdown(report(r))
    assert md.count("same problem") == 1


# ---------------------------------------------------------------------------
# One name per clause result, per item and per conformance


@pytest.mark.parametrize(
    ("clause_id", "inst", "name"),
    [
        ("cos.accurate", {}, "cos.accurate"),
        ("sort_by.stable", {"K": "i64", "V": "string"}, "sort_by[K=i64,V=string].stable"),
        ("first#type", {"T": "i64"}, "first[T=i64]#type"),
        ("wrap:Box.nonneg", {"T": "i64"}, "wrap[T=i64]:Box.nonneg"),
        ("Deque.pop#1", {"T": "string"}, "Deque[T=string].pop#1"),
        ("Deque.bounded", {"T": "i64"}, "Deque[T=i64].bounded"),
        ("pairs.ok", {"T": "(i64, string)"}, "pairs[T=(i64,string)].ok"),
    ],
)
def test_clause_names_put_the_instantiation_where_node_ids_do(clause_id, inst, name):
    from spectest.runtime.report import clause_name

    assert clause_name(clause_id, inst) == name
    r = passing(clause_id=clause_id, instantiation=inst, item_id=f"t.py::test_it::{name}")
    assert r.label == name
    assert r.conformance == "test_it"
    assert r.qualified == f"test_it::{name}"


def interface_results() -> list[ClauseResult]:
    item = "test_deque.py::test_deque::Deque[T=i64]"

    def clause(cid: str, kind: str, **kw) -> ClauseResult:
        return ClauseResult(
            item_id=item,
            clause_id=cid,
            kind=kind,
            decl=cid.rsplit(".", 1)[0] if cid.count(".") > 1 else "Deque",
            instantiation={"T": "i64"},
            mode="stateful",
            **kw,
        )

    return [
        clause("Deque.pop#1", "raises", counts={"pass": 40}),
        clause("Deque.pop.items", "ensures", counts={"pass": 30, "skip": 10}),
        clause(
            "Deque.rotate.items",
            "ensures",
            counts={"pass": 5, "fail": 1},
            expected_fail=True,
            counterexample=Counterexample(observation="steps:\n1. d1 = Deque.empty()"),
        ),
    ]


def test_results_table_names_each_clause_of_an_interface_item():
    md = render_markdown(report(*interface_results(), cos_failure()))
    lines = md.splitlines()
    rows = [ln for ln in lines if ln.startswith("| `test_deque.py::test_deque::Deque[T=i64]` |")]
    assert [row.split(" | ")[1] for row in rows] == [
        "`Deque[T=i64].pop#1`",
        "`Deque[T=i64].pop.items`",
        "`Deque[T=i64].rotate.items`",
    ]
    assert "### `test_deque::Deque[T=i64].rotate.items` (expected failure)" in lines


def test_items_line_counts_pytest_items_and_clause_results_separately():
    derived = report(*interface_results(), passing())
    lines = render_markdown(derived).splitlines()
    assert "- **Items:** 2: 1 passed, 1 expected failure" in lines
    assert "- **Clause results:** 4: 3 passed, 1 expected failure" in lines
    recorded = report(
        *interface_results(),
        passing(),
        items={
            "test_deque.py::test_deque::Deque[T=i64]": "failed",
            "test_libm.py::test_math::cos.bounded": "passed",
        },
    )
    assert "- **Items:** 2: 1 passed, 1 failed" in render_markdown(recorded).splitlines()


def test_an_interface_item_whose_expected_clause_passed_is_an_unexpected_pass():
    from spectest.runtime.report import group_outcome

    results = interface_results()
    results[0].expected_fail = True
    assert group_outcome(results) == "xpassed"
    assert group_outcome(interface_results()) == "xfailed"
    results = interface_results()
    results[1].counts["fail"] = 1
    assert group_outcome(results) == "failed"


def test_two_conformances_of_one_spec_get_distinct_headings_and_coverage_rows():
    a = cos_failure(expected_fail=True)
    b = cos_failure(item_id="test_libm.py::test_seeded::cos.accurate", expected_fail=True)
    lines = render_markdown(report(a, b)).splitlines()
    assert "### `test_math::cos.accurate` (expected failure)" in lines
    assert "### `test_seeded::cos.accurate` (expected failure)" in lines
    assert "| `test_math::cos.accurate` | 10 | 30 | **0** |" in lines
    assert "| `test_seeded::cos.accurate` | 10 | 30 | **0** |" in lines
    same_name = cos_failure(item_id="explore_libm.py::test_math::cos.accurate")
    lines = render_markdown(report(a, same_name)).splitlines()
    assert "### `test_libm.py::test_math::cos.accurate` (expected failure)" in lines
    assert "### `explore_libm.py::test_math::cos.accurate`" in lines


def test_report_records_the_platform_and_packages():
    rep = report(
        passing(),
        platform={
            "implementation": "CPython",
            "python": "3.13.9",
            "machine": "x86_64",
            "os": "Linux 6.18",
        },
        packages={"numpy": "2.5.4", "gmpy2": "2.3.2"},
    )
    lines = render_markdown(rep).splitlines()
    assert "- **Platform:** CPython 3.13.9, Linux 6.18, x86_64" in lines
    assert "- **Packages:** numpy 2.5.4, gmpy2 2.3.2" in lines
    assert Report.from_json(rep.to_json()) == rep
    bare = render_markdown(report()).splitlines()
    assert not any(ln.startswith(("- **Platform:**", "- **Packages:**")) for ln in bare)


def test_skip_column_breaks_skips_down_by_cause():
    r = passing(counts={"pass": 74, "skip": 26}, skips={"requires": 20, "raised": 6})
    one = passing(
        item_id="test_libm.py::test_math::cos#type",
        clause_id="cos#type",
        counts={"pass": 98, "skip": 2},
        skips={"raised": 2},
    )
    lines = render_markdown(report(r, one)).splitlines()
    assert any("| pass | 74 | 0 | 26 (20 requires, 6 raised) | 0 | 0 |" in ln for ln in lines)
    assert any("| pass | 98 | 0 | 2 (raised) | 0 | 0 |" in ln for ln in lines)
    (legend,) = [ln for ln in lines if ln.startswith("Skips by cause:")]
    assert "requires: requires was false" in legend and "raised: the call raised" in legend
    assert "raise due" not in legend
    assert ClauseResult.from_dict(json.loads(json.dumps(r.__dict__, default=str))).skips == {
        "requires": 20,
        "raised": 6,
    }


def test_replayed_items_are_marked_in_results_and_coverage():
    r = cos_failure(replayed=True, counts={"fail": 1})
    lines = render_markdown(report(r, passing())).splitlines()
    assert any(
        "| `cos.accurate` | ensures | hypothesis, replayed | **FAIL** |" in ln for ln in lines
    )
    assert "| `test_math::cos.accurate` (replayed) | 10 | 30 | **0** |" in lines
    assert "| `test_math::cos.bounded` | 12 | 28 | 3 |" in lines
    assert any("ran its stored counterexample" in ln for ln in lines)
    assert Report.from_json(report(r).to_json()).results[0].replayed
