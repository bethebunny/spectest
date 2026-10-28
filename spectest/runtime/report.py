"""Verdict tallies, counterexamples and their rendering as text, Markdown and JSON.

The runner fills one ``ClauseResult`` per function item, and one per clause
for an interface item. ``render_failure`` is what a failing item prints;
``render_markdown`` is the full ``--spectest-report``.

Every clause result prints under one name, ``ClauseResult.label``: the clause
ID with the instantiation after the declaration's name, as in pytest node IDs
(``sort_by_first[K=i64,V=string].stable``, ``Deque[T=i64].pop#1``).
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import asdict, dataclass, field
from typing import Any, Literal

Verdict = Literal["pass", "fail", "skip", "spec_error", "inconclusive"]
VERDICTS: tuple[Verdict, ...] = ("pass", "fail", "skip", "spec_error", "inconclusive")
VERDICT_LABELS = {
    "pass": "pass",
    "fail": "fail",
    "skip": "skip",
    "spec_error": "spec error",
    "inconclusive": "inconclusive",
}
Outcome = Literal["passed", "failed", "xfailed", "xpassed", "error", "skipped", "inconclusive"]
SHOWN_FAILING_INPUTS = 5
SHOWN_SPEC_ERRORS = 10
SKIP_CAUSES = {
    "requires": "requires was false",
    "raised": "the call raised",
    "raise due": "an error was due, so the clause did not apply",
    "wrong type": "the result was not of its declared type",
    "unrepresentable": "the binding could not build the input",
    "rejected": "a generated model broke a model invariant",
    "planned call": "a planned call was outside its requires or raised",
    "other": "another reason",
}
_DECL_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def inst_text(instantiation: Mapping[str, Any]) -> str:
    """``T=i64`` or ``K=i64,V=string``: an instantiation as node IDs print it."""
    return ",".join(f"{k}={str(v).replace(' ', '')}" for k, v in instantiation.items())


def clause_name(clause_id: str, instantiation: Mapping[str, Any] | None = None) -> str:
    """The printed name of a clause under an instantiation.

    The instantiation follows the declaration's name, as in node IDs:
    ``sort_by_first[K=i64,V=string].stable``, ``first[T=i64]#type``,
    ``wrap[T=i64]:Box.nonneg`` and, for an interface's clauses,
    ``Deque[T=i64].pop#1``.
    """
    if not instantiation:
        return clause_id
    m = _DECL_NAME.match(clause_id)
    end = m.end() if m else len(clause_id)
    return f"{clause_id[:end]}[{inst_text(instantiation)}]{clause_id[end:]}"


@dataclass
class Counterexample:
    """One failing example, already formatted for display.

    ``inputs`` and ``partitions`` map parameter names to text; ``observation``
    is what the implementation did ("result = 0.5 (0x3fe0000000000000)", or
    "raised ValueError: math domain error"); ``explanation`` pairs
    sub-expressions of the clause with their values.
    """

    inputs: dict[str, str] = field(default_factory=dict)
    observation: str = ""
    partitions: dict[str, str] = field(default_factory=dict)
    explanation: list[tuple[str, str]] = field(default_factory=list)
    seed: int | None = None
    reproduce: str = ""

    def __post_init__(self) -> None:
        self.explanation = [(str(a), str(b)) for a, b in self.explanation]

    @classmethod
    def from_dict(cls, d: Mapping[str, Any]) -> Counterexample:
        return cls(
            inputs=dict(d.get("inputs", {})),
            observation=d.get("observation", ""),
            partitions=dict(d.get("partitions", {})),
            explanation=[(a, b) for a, b in d.get("explanation", [])],
            seed=d.get("seed"),
            reproduce=d.get("reproduce", ""),
        )


@dataclass
class AggregateSummary:
    """An ``aggregate`` clause's value against its bound, formatted for display.

    ``evaluated`` + ``skipped`` members were visited out of ``total``; when
    ``sampled``, the visited members were a seeded sample of the set. ``worst``
    pairs members with their terms, largest first.
    """

    value: str
    bound: str
    evaluated: int = 0
    skipped: int = 0
    total: int = 0
    sampled: bool = False
    worst: list[tuple[str, str]] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.worst = [(str(a), str(b)) for a, b in self.worst]

    @classmethod
    def from_dict(cls, d: Mapping[str, Any]) -> AggregateSummary:
        known = set(cls.__dataclass_fields__)
        return cls(**{k: v for k, v in d.items() if k in known})


@dataclass
class ClauseResult:
    """The outcome of one item: one clause of one declaration under one instantiation.

    ``kind`` is the clause kind ("ensures", "raises", "relates", "invariant",
    "modifies", or "type" / "raises" for the built-in clauses); ``decl`` is
    "cos" or "Deque.pop"; ``mode`` is "hypothesis", "exhaustive" or
    "stateful"; ``coverage`` counts the examples the item judged (pass or
    fail) per partition class (keys such as "x: nan"); ``skips`` counts its
    skips by cause (keys of ``SKIP_CAUSES``); ``failing_inputs`` counts failing
    inputs (all of them in exhaustive mode); ``failing_examples`` holds the
    first few failing inputs after the counterexample; ``aggregate``
    summarizes an ``aggregate`` clause (mode "exhaustive" or "sampled");
    ``replayed`` is set when the item replayed a stored counterexample instead
    of searching, so its counts come from that replay.
    """

    item_id: str
    clause_id: str
    clause_text: str = ""
    kind: str = ""
    decl: str = ""
    instantiation: dict[str, str] = field(default_factory=dict)
    mode: str = "hypothesis"
    counts: dict[str, int] = field(default_factory=dict)
    coverage: dict[str, int] = field(default_factory=dict)
    counterexample: Counterexample | None = None
    failing_inputs: int = 0
    spec_errors: list[str] = field(default_factory=list)
    expected_fail: bool = False
    duration: float = 0.0
    failing_examples: list[dict[str, str]] = field(default_factory=list)
    aggregate: AggregateSummary | None = None
    replayed: bool = False
    skips: dict[str, int] = field(default_factory=dict)
    label_decl: str = ""

    def __post_init__(self) -> None:
        unknown = [k for k in self.counts if k not in VERDICTS]
        if unknown:
            raise ValueError(f"unknown verdict(s) {unknown}: verdicts are {', '.join(VERDICTS)}")
        self.counts = {v: int(self.counts.get(v, 0)) for v in VERDICTS}
        self.instantiation = {str(k): str(v) for k, v in self.instantiation.items()}
        self.skips = {str(k): int(n) for k, n in self.skips.items() if n}
        if isinstance(self.counterexample, Mapping):
            self.counterexample = Counterexample.from_dict(self.counterexample)
        if isinstance(self.aggregate, Mapping):
            self.aggregate = AggregateSummary.from_dict(self.aggregate)

    @property
    def total(self) -> int:
        return sum(self.counts.values())

    @property
    def failed(self) -> bool:
        return self.counts["fail"] > 0 or self.failing_inputs > 0

    @property
    def has_spec_errors(self) -> bool:
        return self.counts["spec_error"] > 0 or bool(self.spec_errors)

    @property
    def verdict(self) -> Verdict:
        """The item's verdict: fail over spec error over pass over inconclusive over skip."""
        if self.failed:
            return "fail"
        if self.has_spec_errors:
            return "spec_error"
        if self.counts["pass"]:
            return "pass"
        if self.counts["inconclusive"]:
            return "inconclusive"
        return "skip"

    @property
    def outcome(self) -> Outcome:
        """The test outcome, with ``expect_fail`` applied strictly."""
        if self.failed:
            return "xfailed" if self.expected_fail else "failed"
        if self.has_spec_errors:
            return "error"
        if self.expected_fail:
            return "xpassed"
        if self.counts["pass"]:
            return "passed"
        if self.counts["inconclusive"]:
            return "inconclusive"
        return "skipped"

    @property
    def label(self) -> str:
        """The clause's printed name: "sort[T=i64].ordered", "Deque[T=i64].pop#1".

        For a function item it is the last part of the item's node ID. ``label_decl``,
        when set, is the name the instantiation follows (a qualified declaration such as
        ``lib.sort``); otherwise it follows the clause ID's first name.
        """
        decl = self.label_decl
        if decl and self.instantiation and self.clause_id.startswith(decl):
            rest = self.clause_id[len(decl) :]
            return f"{decl}[{inst_text(self.instantiation)}]{rest}"
        return clause_name(self.clause_id, self.instantiation)

    @property
    def conformance(self) -> str:
        """The name of the Conformance that ran it, from the item ID ("test_numpy")."""
        parts = self.item_id.split("::")
        return parts[-2] if len(parts) > 1 else ""

    @property
    def qualified(self) -> str:
        """The conformance and the clause's name: "test_numpy::cos.accurate"."""
        return f"{self.conformance}::{self.label}" if self.conformance else self.label

    @classmethod
    def from_dict(cls, d: Mapping[str, Any]) -> ClauseResult:
        data = dict(d)
        cx = data.get("counterexample")
        data["counterexample"] = Counterexample.from_dict(cx) if cx is not None else None
        data["failing_examples"] = [dict(x) for x in data.get("failing_examples", [])]
        agg = data.get("aggregate")
        data["aggregate"] = AggregateSummary.from_dict(agg) if agg is not None else None
        known = set(cls.__dataclass_fields__)
        return cls(**{k: v for k, v in data.items() if k in known})


@dataclass
class Report:
    """All items of one spec's run, from every Conformance of that spec.

    ``items`` maps each pytest item ID to its outcome as pytest reported it
    (an interface item holds several clause results); ``platform`` records
    the Python version and implementation, the machine and the OS;
    ``packages`` the versions of the libraries the implementations used.
    """

    spec_name: str
    spec_hash: str
    harness_version: str
    hypothesis_version: str
    results: list[ClauseResult] = field(default_factory=list)
    spec_path: str = ""
    errors: list[str] = field(default_factory=list)
    items: dict[str, str] = field(default_factory=dict)
    platform: dict[str, str] = field(default_factory=dict)
    packages: dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        for r in d["results"]:
            cx = r.get("counterexample")
            if cx is not None:
                cx["explanation"] = [list(p) for p in cx["explanation"]]
            agg = r.get("aggregate")
            if agg is not None:
                agg["worst"] = [list(p) for p in agg["worst"]]
        return d

    def to_json(self, indent: int | None = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)

    @classmethod
    def from_dict(cls, d: Mapping[str, Any]) -> Report:
        return cls(
            spec_name=d["spec_name"],
            spec_hash=d["spec_hash"],
            harness_version=d["harness_version"],
            hypothesis_version=d["hypothesis_version"],
            results=[ClauseResult.from_dict(r) for r in d.get("results", [])],
            spec_path=d.get("spec_path", ""),
            errors=list(d.get("errors", [])),
            items=dict(d.get("items", {})),
            platform=dict(d.get("platform", {})),
            packages=dict(d.get("packages", {})),
        )

    @classmethod
    def from_json(cls, text: str | bytes | Mapping[str, Any]) -> Report:
        data = text if isinstance(text, Mapping) else json.loads(text)
        return cls.from_dict(data)

    def tally(self) -> dict[str, int]:
        """Clause results per outcome."""
        out: dict[str, int] = {}
        for r in self.results:
            out[r.outcome] = out.get(r.outcome, 0) + 1
        return out

    def item_outcomes(self) -> dict[str, str]:
        """The outcome of each pytest item: as recorded, else derived from its results."""
        if self.items:
            return dict(self.items)
        groups: dict[str, list[ClauseResult]] = {}
        for r in self.results:
            groups.setdefault(r.item_id, []).append(r)
        return {item_id: group_outcome(rs) for item_id, rs in groups.items()}

    def item_tally(self) -> dict[str, int]:
        """Pytest items per outcome."""
        out: dict[str, int] = {}
        for outcome in self.item_outcomes().values():
            out[outcome] = out.get(outcome, 0) + 1
        return out


def group_outcome(results: Sequence[ClauseResult]) -> str:
    """The outcome of an item from its clause results, with ``expect_fail`` applied strictly."""
    if len(results) == 1:
        return results[0].outcome
    failing = {r.clause_id for r in results if r.failed}
    expected = {r.clause_id for r in results if r.expected_fail}
    if failing - expected:
        return "failed"
    if any(r.has_spec_errors for r in results):
        return "error"
    if expected - failing:
        return "xpassed"
    if failing:
        return "xfailed"
    if any(r.counts["pass"] for r in results):
        return "passed"
    if any(r.counts["inconclusive"] for r in results):
        return "inconclusive"
    return "skipped"


def dump_reports(reports: Sequence[Report], indent: int | None = 2) -> str:
    """Several reports as one JSON document (a list)."""
    return json.dumps([r.to_dict() for r in reports], indent=indent, ensure_ascii=False)


def load_reports(text: str | bytes) -> list[Report]:
    """Reports from JSON holding one report or a list of them."""
    data = json.loads(text)
    if isinstance(data, list):
        return [Report.from_dict(d) for d in data]
    return [Report.from_dict(data)]


# ---------------------------------------------------------------------------
# Text


def _inst(inst: Mapping[str, str]) -> str:
    return ", ".join(f"{k}={v}" for k, v in inst.items())


def _indent(text: str, prefix: str = "  ") -> str:
    return "\n".join(prefix + line if line else line for line in text.splitlines() or [""])


def _counts_line(result: ClauseResult) -> str:
    parts = [f"{result.counts[v]} {VERDICT_LABELS[v]}" for v in VERDICTS if result.counts[v]]
    return ", ".join(parts) or "no examples"


def _assignments(values: Mapping[str, str]) -> str:
    return ", ".join(f"{k} = {v}" for k, v in values.items()) or "(no inputs)"


def _counterexample_lines(cx: Counterexample) -> list[str]:
    lines = ["inputs:"]
    lines += [f"  {k} = {v}" for k, v in cx.inputs.items()] or ["  (none)"]
    if cx.observation:
        lines += ["observed:", _indent(cx.observation)]
    if cx.partitions:
        lines += ["partitions:"] + [f"  {k}: {v}" for k, v in cx.partitions.items()]
    if cx.explanation:
        lines += ["explanation:"] + [f"  {e} = {v}" for e, v in cx.explanation]
    return lines


def _members_line(a: AggregateSummary) -> str:
    how = "a seeded sample" if a.sampled else "every member"
    skipped = f", {a.skipped} skipped" if a.skipped else ""
    return f"{a.evaluated} evaluated{skipped}, of {a.total} ({how})"


def _aggregate_lines(a: AggregateSummary) -> list[str]:
    lines = [f"value: {a.value} (bound {a.bound})", f"members: {_members_line(a)}"]
    if a.worst:
        lines.append("largest terms:")
        lines += [f"  {member}: {term}" for member, term in a.worst]
    return lines


def render_failure(result: ClauseResult) -> str:
    """The text a failing (or erroring, or unexpectedly passing) item shows.

    Clause ID and text, inputs, observation, partitions, explanation, verdict
    counts, seed and the command that reproduces it. In exhaustive mode it
    states how many inputs failed out of all of them and lists the first few.
    """
    head = f"{result.label} ({result.kind})" if result.kind else result.label
    if result.failed:
        status = "failed as expected (expect_fail)" if result.expected_fail else "failed"
    elif result.has_spec_errors:
        status = "spec error"
    elif result.expected_fail:
        status = "was expected to fail (expect_fail), but no example failed"
    else:
        status = result.verdict
    lines = [f"{head} {status}"]
    if result.clause_text:
        lines.append(f"  {result.clause_text}")
    where = [f"in {result.decl}"] if result.decl else []
    if result.instantiation:
        where.append(f"with {_inst(result.instantiation)}")
    if where:
        lines.append(f"  {' '.join(where)}")
    lines.append("")
    if result.mode == "exhaustive" and result.failed and result.aggregate is None:
        lines.append(
            f"failed on {result.failing_inputs} of {result.total} inputs (exhaustive: every input "
            "was tried); the first failing input:"
        )
    if result.counterexample is not None:
        lines += _counterexample_lines(result.counterexample)
    if result.failing_examples:
        shown = result.failing_examples[:SHOWN_FAILING_INPUTS]
        lines.append("more failing inputs:")
        lines += [f"  {_assignments(x)}" for x in shown]
        rest = result.failing_inputs - 1 - len(shown)
        if rest > 0:
            lines.append(f"  ... and {rest} more")
    if result.aggregate is not None:
        lines += _aggregate_lines(result.aggregate)
    if result.spec_errors:
        unique = list(dict.fromkeys(result.spec_errors))
        lines.append(f"spec errors ({len(unique)}), the spec's or the binding's fault:")
        lines += [_indent(e, "  ") for e in unique[:SHOWN_SPEC_ERRORS]]
        if len(unique) > SHOWN_SPEC_ERRORS:
            lines.append(f"  ... and {len(unique) - SHOWN_SPEC_ERRORS} more")
    lines.append(f"verdicts: {_counts_line(result)} ({result.mode})")
    cx = result.counterexample
    if cx is not None and cx.seed is not None:
        lines.append(f"seed: {cx.seed}")
    if cx is not None and cx.reproduce:
        lines.append(f"reproduce: {cx.reproduce}")
    return "\n".join(lines).rstrip() + "\n"


# ---------------------------------------------------------------------------
# Markdown


_OUTCOME_LABELS = {
    "passed": "pass",
    "failed": "**FAIL**",
    "xfailed": "expected fail",
    "xpassed": "**UNEXPECTED PASS**",
    "error": "**SPEC ERROR**",
    "skipped": "skip",
    "inconclusive": "inconclusive",
}


def _cell(text: Any) -> str:
    return str(text).replace("|", "\\|").replace("\n", "<br>")


def _code(text: Any) -> str:
    s = str(text)
    fence = "``" if "`" in s else "`"
    pad = " " if s.startswith("`") or s.endswith("`") else ""
    return f"{fence}{pad}{s}{pad}{fence}"


def _table(header: Sequence[str], rows: Iterable[Sequence[Any]], align: str = "") -> list[str]:
    out = ["| " + " | ".join(_cell(c) for c in header) + " |"]
    out.append(
        "| "
        + " | ".join("---:" if c == "r" else "---" for c in align.ljust(len(header), "l"))
        + " |"
    )
    out += ["| " + " | ".join(_cell(c) for c in row) + " |" for row in rows]
    return out


def _decl_key(r: ClauseResult) -> tuple[str, str]:
    return (r.decl or r.clause_id.split(".")[0], _inst(r.instantiation))


_TALLY_WORDS = [
    ("passed", "passed", "passed"),
    ("failed", "failed", "failed"),
    ("xfailed", "expected failure", "expected failures"),
    ("xpassed", "unexpected pass", "unexpected passes"),
    ("error", "spec error", "spec errors"),
    ("inconclusive", "inconclusive", "inconclusive"),
    ("skipped", "skipped", "skipped"),
]


def _tally_text(tally: Mapping[str, int]) -> str:
    total = sum(tally.values())
    summary = ", ".join(
        f"{n} {one if n == 1 else many}"
        for key, one, many in _TALLY_WORDS
        if (n := tally.get(key, 0))
    )
    return f"{total}" + (f": {summary}" if summary else "")


def _display_names(results: Sequence[ClauseResult]) -> dict[int, str]:
    """Each result's name in headings and tables: the conformance and the clause's name,
    or the whole item path where two conformances of different files share a name."""
    owners: dict[str, set[str]] = {}
    for r in results:
        owners.setdefault(r.qualified, set()).add(r.item_id)
    out: dict[int, str] = {}
    for r in results:
        if len(owners[r.qualified]) > 1:
            prefix = r.item_id.rsplit("::", 1)[0] if "::" in r.item_id else r.item_id
            out[id(r)] = f"{prefix}::{r.label}"
        else:
            out[id(r)] = r.qualified
    return out


def _mode_cell(r: ClauseResult) -> str:
    return f"{r.mode}, replayed" if r.replayed else r.mode


def _skip_cell(r: ClauseResult) -> str:
    n = r.counts["skip"]
    causes = [(c, k) for c, k in _ordered_skips(r.skips) if k]
    if not n or not causes:
        return str(n)
    if len(causes) == 1 and causes[0][1] == n:
        return f"{n} ({causes[0][0]})"
    return f"{n} ({', '.join(f'{k} {c}' for c, k in causes)})"


def _ordered_skips(skips: Mapping[str, int]) -> list[tuple[str, int]]:
    known = [(c, skips[c]) for c in SKIP_CAUSES if c in skips]
    return known + [(c, k) for c, k in skips.items() if c not in SKIP_CAUSES]


def _platform_line(platform: Mapping[str, str]) -> str:
    python = " ".join(x for x in (platform.get("implementation"), platform.get("python")) if x)
    rest = [x for x in (platform.get("os"), platform.get("machine")) if x]
    return ", ".join([python, *rest] if python else rest)


def _render_one(report: Report, level: int) -> list[str]:
    h = "#" * level
    out = [f"{h} spectest report: {report.spec_name}", ""]
    names = _display_names(report.results)
    spec = _code(report.spec_name) + (f" ({_code(report.spec_path)})" if report.spec_path else "")
    out += [
        f"- **Spec:** {spec}",
        f"- **Spec hash:** {_code(report.spec_hash)}",
        f"- **Harness:** spectest {report.harness_version}, Hypothesis {report.hypothesis_version}",
    ]
    if report.platform:
        out.append(f"- **Platform:** {_platform_line(report.platform)}")
    if report.packages:
        packages = ", ".join(f"{name} {v}" for name, v in report.packages.items())
        out.append(f"- **Packages:** {packages}")
    out += [
        f"- **Items:** {_tally_text(report.item_tally())}",
        f"- **Clause results:** {_tally_text(report.tally())}",
        "",
    ]

    erroring = [r for r in report.results if r.has_spec_errors]
    if report.errors or erroring:
        out += [f"{h}# Spec errors", ""]
        out.append(
            "These are faults of the spec or the binding, never of the implementation. "
            "Their clauses were not judged on the affected examples."
        )
        out.append("")
        out += [f"- {_one_line(e)}" for e in report.errors]
        for r in erroring:
            msgs = list(dict.fromkeys(r.spec_errors)) or [
                f"{r.counts['spec_error']} example(s) had a spec error"
            ]
            out += [f"- {_code(r.label)} ({_code(r.item_id)}): {_one_line(m)}" for m in msgs]
        out.append("")

    out += [f"{h}# Results", ""]
    header = ["Item", "Clause", "Kind", "Mode", "Verdict", *[VERDICT_LABELS[v] for v in VERDICTS]]
    out += _table(
        [*header, "Time"],
        [
            [
                _code(r.item_id),
                _code(r.label),
                r.kind,
                _mode_cell(r),
                _OUTCOME_LABELS[r.outcome],
                *[_skip_cell(r) if v == "skip" else r.counts[v] for v in VERDICTS],
                f"{r.duration:.2f}s",
            ]
            for r in report.results
        ],
        "lllll" + "r" * (len(VERDICTS) + 1),
    )
    out.append("")
    notes = []
    causes = [c for c in SKIP_CAUSES if any(c in r.skips for r in report.results)]
    if causes:
        notes.append(
            "Skips by cause: " + "; ".join(f"{c}: {SKIP_CAUSES[c]}" for c in causes) + "."
        )
    if any(r.replayed for r in report.results):
        notes.append(
            "A replayed item ran its stored counterexample from `.spectest/` instead of a "
            "search, so its counts and coverage come from that replay alone."
        )
    if notes:
        out += [*notes, ""] if len(notes) == 1 else [*(f"- {n}" for n in notes), ""]

    aggregates = [r for r in report.results if r.aggregate is not None]
    if aggregates:
        out += [f"{h}# Aggregates", ""]
        out += _table(
            ["Clause", "Verdict", "Value", "Bound", "Members"],
            [
                [
                    _code(names[id(r)]),
                    _OUTCOME_LABELS[r.outcome],
                    r.aggregate.value,
                    r.aggregate.bound,
                    _members_line(r.aggregate),
                ]
                for r in aggregates
                if r.aggregate is not None
            ],
        )
        out.append("")

    covered = [r for r in report.results if r.coverage]
    if covered:
        out += [f"{h}# Coverage", ""]
        out.append(
            "Examples each clause judged (pass or fail), per partition class; a class with "
            "0 examples was never exercised by that clause."
        )
        out.append("")
        groups: dict[tuple[str, str], list[ClauseResult]] = {}
        for r in covered:
            groups.setdefault(_decl_key(r), []).append(r)
        for (decl, inst), rs in groups.items():
            title = _code(decl) + (f" with {inst}" if inst else "")
            classes: list[str] = []
            for r in rs:
                classes += [c for c in r.coverage if c not in classes]
            out += [f"{h}## {title}", ""]
            out += _table(
                ["Clause", *classes],
                [
                    [
                        _code(names[id(r)]) + (" (replayed)" if r.replayed else ""),
                        *[_count_cell(r.coverage.get(c, 0)) for c in classes],
                    ]
                    for r in rs
                ],
                "l" + "r" * len(classes),
            )
            out.append("")

    with_cx = [r for r in report.results if r.counterexample is not None or r.failed]
    if with_cx:
        out += [f"{h}# Counterexamples", ""]
        for r in with_cx:
            note = " (expected failure)" if r.expected_fail else ""
            out += [f"{h}## {_code(names[id(r)])}{note}", ""]
            out += ["```text", render_failure(r).rstrip(), "```", ""]
    return out


def _count_cell(n: int) -> str:
    return "**0**" if n == 0 else str(n)


def _one_line(text: str) -> str:
    lines = [ln.strip() for ln in str(text).splitlines() if ln.strip()]
    return " / ".join(lines)


def render_markdown(report: Report | Sequence[Report]) -> str:
    """The full report: summary table, spec errors, coverage and every counterexample."""
    reports = [report] if isinstance(report, Report) else list(report)
    if len(reports) == 1:
        return "\n".join(_render_one(reports[0], 1)).rstrip() + "\n"
    out = ["# spectest report", ""]
    for r in reports:
        out += _render_one(r, 2)
    return "\n".join(out).rstrip() + "\n"


__all__ = [
    "SKIP_CAUSES",
    "VERDICTS",
    "AggregateSummary",
    "ClauseResult",
    "Counterexample",
    "Outcome",
    "Report",
    "Verdict",
    "clause_name",
    "dump_reports",
    "group_outcome",
    "inst_text",
    "load_reports",
    "render_failure",
    "render_markdown",
]
