"""The pytest plugin: collects module-level Conformance objects and runs their items.

A Conformance bound to a name starting with ``test`` becomes a collector with
one item per judged clause (and one per interface instantiation). Failing
items show the counterexample, spec errors are labelled SPEC ERROR, clauses in
``expect_fail`` are strict xfails (plain failures under ``--runxfail``), and
the session ends with a "spectest" summary and, on request, the Markdown and
JSON reports. ``--spectest-clause`` selects clauses by name or ID,
``--spectest-store`` / ``--spectest-no-store`` place or turn off the
counterexample store, and ``--spectest-profile`` picks the budgets (``ci``, or
``dev`` for iterating on a spec).

Under pytest-xdist each item's results travel in its test report, so the
controller writes the same reports and summary as a serial run.

The module imports only pytest at load time, so it costs nothing in sessions
that collect no Conformance.
"""

from __future__ import annotations

import contextlib
import dataclasses
import functools
import hashlib
import json
import re
import sys
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import TYPE_CHECKING, Any

import pytest

if TYPE_CHECKING:
    from spectest.runtime.report import ClauseResult, Report
    from spectest.runtime.runner import Item as SpecItem
    from spectest.runtime.runner import Runner


DEV_EXAMPLES = 25

# Run options per profile; command-line options override them.
PROFILES: dict[str, dict[str, Any]] = {
    "ci": {},
    "dev": {"max_examples": DEV_EXAMPLES, "exhaustive_limit": 4096, "aggregate_samples": 1000},
}


def pytest_addoption(parser: pytest.Parser) -> None:
    group = parser.getgroup("spectest", "spectest: spec conformance tests")
    group.addoption(
        "--spectest-seed",
        type=int,
        default=0,
        metavar="N",
        help="base seed for every spectest item (mixed with each item's ID; default 0)",
    )
    group.addoption(
        "--spectest-max-examples",
        type=int,
        default=None,
        metavar="N",
        help="Hypothesis examples per item, overriding each conformance's max_examples",
    )
    group.addoption(
        "--spectest-exhaustive-limit",
        type=int,
        default=None,
        metavar="N",
        help="run a function on every input when it has at most N (default: the conformance's)",
    )
    group.addoption(
        "--spectest-aggregate-samples",
        type=int,
        default=None,
        metavar="N",
        help="members sampled from a set larger than the exhaustive limit (default 10000)",
    )
    group.addoption(
        "--spectest-timeout",
        type=float,
        default=None,
        metavar="SECONDS",
        help="per-call time limit; a call that exceeds it is inconclusive, never a failure",
    )
    group.addoption(
        "--spectest-report",
        default=None,
        metavar="PATH.md",
        help="write the full Markdown report of every spectest item",
    )
    group.addoption(
        "--spectest-json",
        default=None,
        metavar="PATH.json",
        help="write the report as JSON",
    )
    group.addoption(
        "--spectest-clause",
        action="append",
        default=[],
        metavar="GLOB[,GLOB...]",
        help="run only the spectest clauses whose name (sort[T=i64].ordered) or ID "
        "(sort.ordered) matches a glob; * and ? are wildcards, brackets are literal",
    )
    group.addoption(
        "--spectest-store",
        default=None,
        metavar="DIR",
        help="the counterexample store's directory (default: .spectest under the rootdir)",
    )
    group.addoption(
        "--spectest-no-store",
        action="store_true",
        default=False,
        help="neither replay nor save counterexamples",
    )
    group.addoption(
        "--spectest-profile",
        default=None,
        choices=sorted(PROFILES),
        help="budgets: 'ci' (default) runs every conformance at its own; 'dev' runs "
        f"{DEV_EXAMPLES} examples per item and samples instead of exhausting large domains, "
        "for iterating on a spec (explicit --spectest-* options win)",
    )
    group.addoption(
        "--spectest-module",
        action="append",
        default=[],
        metavar="NAME=REPLACEMENT",
        help="run v2 specs against another module: names under NAME resolve under "
        "REPLACEMENT (repeatable)",
    )
    parser.addini(
        "spectest_profile",
        "the spectest profile when --spectest-profile is not given (ci or dev)",
        default="ci",
    )


class _State:
    """Per-session plugin state: the runner, the items this process ran, and every item's
    results as its test report carried them (``payloads``: under pytest-xdist the
    controller gets every worker's)."""

    def __init__(self, config: pytest.Config) -> None:
        self.config = config
        self._runner: Runner | None = None
        self.ran: list[SpectestItem] = []
        self.payloads: list[dict[str, Any]] = []
        self.written: list[str] = []
        self.bound: dict[int, dict[str, str]] = {}
        self.loaded: list[tuple[Any, int]] = []  # (host, spec handle) of each v2 spec
        self.runs: dict[tuple[int, str, str], dict[str, Any]] = {}  # v2 runs, one per key

    def unload_specs(self) -> None:
        loaded, self.loaded = self.loaded, []
        self.runs.clear()
        for host, handle in loaded:
            with contextlib.suppress(Exception):  # freeing at exit must not fail the session
                host.unload(handle)

    def pytest_runtest_logreport(self, report: pytest.TestReport) -> None:
        text = getattr(report, "spectest", None)
        if report.when == "call" and isinstance(text, str):
            self.payloads.append(json.loads(text))

    def bound_packages(self, conf: Any) -> dict[str, str]:
        """The installed packages a conformance's bound callables come from (cached)."""
        key = id(conf)
        if key not in self.bound:
            self.bound[key] = package_versions([conf], recorded=False)
        return self.bound[key]

    @property
    def seed(self) -> int:
        return int(self.config.getoption("spectest_seed"))

    @property
    def profile(self) -> str:
        return profile_name(self.config)

    @property
    def store(self) -> Path | None:
        """The counterexample store's root: --spectest-store, else .spectest under the
        rootdir; None with --spectest-no-store."""
        if self.config.getoption("spectest_no_store"):
            return None
        return _target(self.config, "spectest_store") or Path(self.config.rootpath) / ".spectest"

    @property
    def runner(self) -> Runner:
        if self._runner is None:
            from spectest.runtime.runner import (
                DEFAULT_AGGREGATE_SAMPLES,
                Runner,
                RunOptions,
            )

            opt = self.config.getoption
            budgets = PROFILES[self.profile]

            def chosen(name: str, default: Any = None) -> Any:
                value = opt(f"spectest_{name}")
                return budgets.get(name, default) if value is None else value

            self._runner = Runner(
                RunOptions(
                    seed=self.seed,
                    max_examples=chosen("max_examples"),
                    exhaustive_limit=chosen("exhaustive_limit"),
                    aggregate_samples=chosen("aggregate_samples", DEFAULT_AGGREGATE_SAMPLES),
                    timeout=opt("spectest_timeout"),
                    store=self.store,
                )
            )
        return self._runner


def profile_name(config: pytest.Config) -> str:
    """The session's spectest profile: --spectest-profile, else the spectest_profile ini
    setting, else ci."""
    name = config.getoption("spectest_profile") or config.getini("spectest_profile") or "ci"
    if name not in PROFILES:
        raise pytest.UsageError(
            f"spectest_profile = {name!r}: the profiles are {', '.join(sorted(PROFILES))}"
        )
    return str(name)


STATE = pytest.StashKey[_State]()


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line("markers", "spectest: an item collected from a spectest Conformance")
    if getattr(config.option, "dist", None) == "load":
        # a v2 declaration's items share one run, so they go to one worker
        config.option.dist = "loadgroup"
    state = config.stash[STATE] = _State(config)
    config.pluginmanager.register(state, "spectest-state")


def is_worker(config: pytest.Config) -> bool:
    """This process is a pytest-xdist worker (its controller writes the reports)."""
    return hasattr(config, "workerinput")


def _is_conformance(obj: Any) -> bool:
    cls = type(obj)
    return cls.__name__ == "Conformance" and cls.__module__ == "spectest.runtime.binding"


def clause_globs(values: Iterable[str]) -> list[str]:
    """The globs of ``--spectest-clause`` options, each of which may list several."""
    return [g.strip() for v in values for g in v.split(",") if g.strip()]


def glob_match(name: str, pattern: str) -> bool:
    """Shell-style matching where only ``*`` and ``?`` are special (names contain brackets)."""
    regex = "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pattern)
    return re.fullmatch(regex, name, re.DOTALL) is not None


def pytest_collection_modifyitems(
    session: pytest.Session, config: pytest.Config, items: list[pytest.Item]
) -> None:
    _select_clauses(config, items)
    index = 0
    for item in items:
        if isinstance(item, SPECTEST_ITEMS):
            item.spectest_index = index
            index += 1


def _select_clauses(config: pytest.Config, items: list[pytest.Item]) -> None:
    globs = clause_globs(config.getoption("spectest_clause") or [])
    if not globs:
        return
    selected: list[pytest.Item] = []
    deselected: list[pytest.Item] = []
    for item in items:
        if not isinstance(item, SPECTEST_ITEMS):
            selected.append(item)
            continue
        chosen = {
            cid
            for cid, name in item.clause_names().items()
            if any(glob_match(name, g) or glob_match(cid, g) for g in globs)
        }
        if chosen:
            item.chosen = frozenset(chosen)
            selected.append(item)
        else:
            deselected.append(item)
    if deselected:
        config.hook.pytest_deselected(items=deselected)
        items[:] = selected


@pytest.hookimpl(tryfirst=True)
def pytest_pycollect_makeitem(
    collector: pytest.Collector, name: str, obj: Any
) -> pytest.Collector | None:
    if name.startswith("test") and _is_conformance(obj):
        return ConformanceCollector.from_parent(collector, name=name, conf=obj)
    if name.startswith("test") and _is_check(obj):
        return CheckCollector.from_parent(collector, name=name, check_obj=obj)
    return None


def pytest_collect_file(file_path: Path, parent: pytest.Collector) -> pytest.Collector | None:
    """A ``.spec`` file is collected only when the command line names it, so that the
    specs v1 conformances load from a test directory are left alone."""
    if file_path.suffix == ".spec" and file_path.resolve() in _named_files(parent.config):
        return SpecFile.from_parent(parent, path=file_path)
    return None


def _named_files(config: pytest.Config) -> set[Path]:
    base = Path(config.invocation_params.dir)
    named = set()
    for arg in config.invocation_params.args:
        text = str(arg).split("::", 1)[0]
        if text.endswith(".spec"):
            named.add((base / text).resolve())
    return named


class SpectestOutcome(Exception):
    """A spectest item's non-passing outcome, carrying the text to display."""

    def __init__(self, text: str) -> None:
        super().__init__(text)
        self.text = text


class SpecErrorOutcome(SpectestOutcome):
    """The item hit spec errors (and no failure): the spec's or the binding's fault."""


class ConformanceCollector(pytest.Collector):
    """The items of one Conformance object."""

    def __init__(self, *, conf: Any, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self.conf = conf

    def collect(self) -> Iterator[pytest.Item]:
        from spectest.runtime.runner import collect_items
        from spectest.values import SpecError

        self.conf.name = self.name
        try:
            items = collect_items(self.conf)
        except SpecError as exc:
            raise self.CollectError(f"spectest: cannot plan {self.name}: {exc}") from exc
        for it in items:
            yield SpectestItem.from_parent(self, name=it.name, spec_item=it)

    def repr_failure(self, excinfo: pytest.ExceptionInfo[BaseException]) -> Any:
        if isinstance(excinfo.value, self.CollectError):
            return str(excinfo.value.args[0])
        return super().repr_failure(excinfo)

    def reportinfo(self) -> tuple[Any, int | None, str]:
        return self.path, None, self.name


class SpectestItem(pytest.Item):
    """One spectest item: a clause of a function (or an interface's state machine)."""

    def __init__(self, *, spec_item: SpecItem, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self.spec_item = spec_item
        self.spectest_index = 0
        self.results: list[ClauseResult] = []
        self.spectest_outcome: str | None = None
        self.chosen: frozenset[str] | None = None
        self.done = False
        self.add_marker("spectest")

    def reproduce(self) -> str:
        seed = self.config.stash[STATE].seed
        return f"uv run pytest '{self.nodeid}' --spectest-seed={seed}"

    def payload(self) -> dict[str, Any]:
        """The item's results and what the reports need to place them, for its test report
        (JSON-safe, so pytest-xdist can carry it to the controller)."""
        conf = self.spec_item.conf
        spec = conf.spec
        state = self.config.stash[STATE]
        return {
            "nodeid": self.nodeid,
            "index": self.spectest_index,
            "conformance": self.parent.nodeid if self.parent is not None else "",
            "outcome": self.spectest_outcome or "skipped",
            "spec": {"name": spec.name, "hash": spec.hash, "path": spec.path},
            "imported": package_versions([], recorded=True),
            "bound": state.bound_packages(conf),
            "results": [dataclasses.asdict(r) for r in self.results],
        }

    def clause_names(self) -> dict[str, str]:
        """The item's clause IDs with their printed names (the item's own name for a
        function item; "Deque[T=i64].pop#1" for the clauses of an interface item)."""
        from spectest.runtime.report import clause_name

        it = self.spec_item
        if it.kind != "interface":
            return {it.key or self.name: self.name}
        inst = {n: str(t) for n, t in it.plan.tenv.items()}
        return {k.key: clause_name(k.key, inst) for k in it.plan.keys}

    def expected_names(self, failed: frozenset[str] = frozenset()) -> list[str]:
        """The expected clauses that did not fail, by their printed names."""
        if self.spec_item.kind != "interface":
            return [self.name]
        names = self.clause_names()
        return [names.get(cid, cid) for cid in sorted(self.expected() - failed)]

    def expected(self) -> frozenset[str]:
        expected = self.spec_item.expected
        return expected if self.chosen is None else expected & self.chosen

    def runtest(self) -> None:
        state = self.config.stash[STATE]
        results = state.runner.run(self.spec_item, self.nodeid, self.reproduce())
        if self.chosen is not None and self.spec_item.kind == "interface":
            results = [r for r in results if r.clause_id in self.chosen]
        self.results = results
        self.done = True
        state.ran.append(self)
        outcome = item_outcome(self.spec_item, self.results, self.expected())
        runxfail = bool(getattr(self.config.option, "runxfail", False))
        if runxfail and outcome == "xfailed":
            outcome = "failed"
        elif runxfail and outcome == "xpassed":
            outcome = "passed"
        self.spectest_outcome = outcome
        if outcome == "failed":
            shown = [r for r in self.results if r.failed and not r.expected_fail]
            if runxfail and not shown:
                failed = [r for r in self.results if r.failed]
                shown = [dataclasses.replace(r, expected_fail=False) for r in failed]
            raise SpectestOutcome(_texts(shown or self.results))
        if outcome == "error":
            shown = [r for r in self.results if r.has_spec_errors]
            raise SpecErrorOutcome(
                "SPEC ERROR (the spec's or the binding's fault)\n" + _texts(shown)
            )
        if outcome == "xfailed":
            failed = [r for r in self.results if r.failed]
            pytest.xfail("; ".join(one_line(r) for r in failed))
        if outcome == "xpassed":
            failed = frozenset(r.clause_id for r in self.results if r.failed)
            expected = ", ".join(self.expected_names(failed))
            shown = [r for r in self.results if r.expected_fail and not r.failed] or self.results
            raise SpectestOutcome(
                f"[XPASS(strict)] expected to fail: {expected}, but no example failed\n"
                + _texts(shown)
            )
        if outcome == "inconclusive":
            pytest.skip(f"inconclusive: {_reason(self.results)}")
        if outcome == "skipped":
            pytest.skip(f"no example applied: {_reason(self.results)}")

    def repr_failure(self, excinfo: pytest.ExceptionInfo[BaseException], style: Any = None) -> Any:
        if isinstance(excinfo.value, SpectestOutcome):
            return excinfo.value.text
        return super().repr_failure(excinfo, style=style)

    def reportinfo(self) -> tuple[Any, int | None, str]:
        owner = f"{self.parent.name}::" if self.parent is not None else ""
        return self.path, None, f"spectest {owner}{self.name}"


def item_outcome(
    item: SpecItem, results: list[ClauseResult], expected: frozenset[str] | None = None
) -> str:
    """passed, failed, xfailed, xpassed, error, inconclusive or skipped."""
    if item.kind == "interface":
        from spectest.runtime.stateful import interface_outcome

        return interface_outcome(results, item.expected if expected is None else expected)
    return results[0].outcome


def _texts(results: list[ClauseResult]) -> str:
    from spectest.runtime.report import render_failure

    return "\n".join(render_failure(r) for r in results).rstrip()


def _reason(results: list[ClauseResult]) -> str:
    total: dict[str, int] = {}
    for r in results:
        for v, n in r.counts.items():
            total[v] = total.get(v, 0) + n
    parts = [f"{n} {v.replace('_', ' ')}" for v, n in total.items() if n]
    return ", ".join(parts) or "no examples ran"


def one_line(result: ClauseResult) -> str:
    """A counterexample in one line: "cos#raises: x = inf -> raised ValueError ..."."""
    cx = result.counterexample
    if cx is None:
        if result.aggregate is not None:
            return f"{result.label}: {result.aggregate.value} (bound {result.aggregate.bound})"
        return f"{result.label}: failed"
    inputs = ", ".join(f"{k} = {v}" for k, v in cx.inputs.items())
    lines = [ln.strip() for ln in cx.observation.splitlines() if ln.strip()]
    if lines and lines[0] == "steps:":
        steps = [ln for ln in lines[1:] if ln[:1].isdigit()]
        observed = f"{len(steps)} steps, last {steps[-1]}" if steps else ""
    else:
        observed = lines[0] if lines else ""
    text = f"{result.label}: {inputs}" if inputs else result.label
    return f"{text} -> {observed}" if observed else text


@pytest.hookimpl(wrapper=True)
def pytest_runtest_makereport(item: pytest.Item, call: pytest.CallInfo[None]) -> Any:
    report = yield
    if isinstance(item, SPECTEST_ITEMS) and call.when == "call":
        report.spectest_outcome = item.spectest_outcome  # type: ignore[attr-defined]
        if item.done:
            text = json.dumps(item.payload(), ensure_ascii=False)
            report.spectest = text  # type: ignore[attr-defined]
    return report


def pytest_report_teststatus(report: pytest.TestReport, config: pytest.Config) -> Any:
    if report.when == "call" and getattr(report, "spectest_outcome", None) == "error":
        return "failed", "E", ("SPEC ERROR", {"red": True, "bold": True})
    return None


# ---------------------------------------------------------------------------
# Session end: reports and the terminal summary


def build_reports(items: Iterable[SpectestItem | dict[str, Any]]) -> list[Report]:
    """One Report per spec with the results of every item that ran, in collection order:
    from the items, or from their payloads (``SpectestItem.payload``), as an xdist
    controller has them, which gives the same reports."""
    import hypothesis

    import spectest
    from spectest.runtime.report import ClauseResult, Report

    payloads = [it.payload() if isinstance(it, SPECTEST_ITEMS) else it for it in items]
    payloads.sort(key=lambda p: p["index"])
    imported: dict[str, str] = {}
    for p in payloads:
        imported.update(p.get("imported", {}))
    recorded = {n: imported[n] for n in _recorded_order(imported)}
    reports: dict[str, Report] = {}
    for p in payloads:
        spec = p["spec"]
        report = reports.get(spec["hash"])
        if report is None:
            report = reports[spec["hash"]] = Report(
                spec_name=spec["name"],
                spec_hash=spec["hash"],
                harness_version=spectest.__version__,
                hypothesis_version=hypothesis.__version__,
                spec_path=spec["path"],
                platform=platform_facts(),
                packages=dict(recorded),
            )
        for name, version in p.get("bound", {}).items():
            report.packages.setdefault(name, version)
        report.results.extend(ClauseResult.from_dict(r) for r in p["results"])
        report.items[p["nodeid"]] = p["outcome"]
    return list(reports.values())


def _recorded_order(imported: dict[str, str]) -> list[str]:
    """Distribution names of ``RECORDED_PACKAGES`` in that order, then any others."""
    order = {n: i for i, n in enumerate(RECORDED_PACKAGES)}
    return sorted(imported, key=lambda n: order.get(n.lower(), len(order)))


RECORDED_PACKAGES = ("numpy", "pandas", "polars", "gmpy2", "ml_dtypes")


def platform_facts() -> dict[str, str]:
    """The Python version and implementation, the machine and the OS of this run."""
    import platform

    os_name = " ".join(x for x in (platform.system(), platform.release()) if x)
    return {
        "implementation": platform.python_implementation(),
        "python": platform.python_version(),
        "machine": platform.machine(),
        "os": os_name,
    }


def package_versions(confs: Iterable[Any], *, recorded: bool = True) -> dict[str, str]:
    """Versions of the already imported libraries that verdicts may depend on, by
    distribution name.

    These are the packages in ``RECORDED_PACKAGES`` (unless ``recorded`` is false)
    and the installed packages that a bound implementation, constructor, method
    or observer comes from. The standard library, local modules and spectest
    itself are left out.
    """
    modules = [n for n in RECORDED_PACKAGES if n in sys.modules] if recorded else []
    for conf in confs:
        for obj in _bound_callables(conf):
            top = _top_module(obj)
            if top and top not in modules and top in sys.modules:
                modules.append(top)
    out: dict[str, str] = {}
    for module in modules:
        found = _distribution(module)
        if found is not None and found[0] != "spectest":
            out.setdefault(*found)
    return out


def _bound_callables(conf: Any) -> Iterator[Any]:
    yield from conf.impls.values()
    for mb in conf.models.values():
        yield from (mb.observers or {}).values()
        yield mb.concretize
    for ib in conf.interfaces.values():
        yield from ib.constructors.values()
        yield from (ib.methods or {}).values()
        yield from (ib.observers or {}).values()


def _top_module(obj: Any) -> str | None:
    while hasattr(obj, "func") and callable(obj.func):
        obj = obj.func
    module = getattr(obj, "__module__", None)
    if not isinstance(module, str):
        owner = getattr(obj, "__objclass__", None) or type(obj)
        module = getattr(owner, "__module__", None)
    if not isinstance(module, str) or module in ("builtins", "__main__"):
        return None
    return module.split(".", 1)[0]


@functools.cache
def _distribution(module: str) -> tuple[str, str] | None:
    """The name and version of the installed distribution that provides a top-level
    module (None for the standard library and for local modules)."""
    from importlib import metadata

    for dist in _distributions().get(module, []):
        try:
            found = metadata.distribution(dist)
        except metadata.PackageNotFoundError:
            continue
        return found.metadata["Name"] or dist, found.version
    return None


_DISTRIBUTIONS: dict[str, list[str]] | None = None


def _distributions() -> dict[str, list[str]]:
    global _DISTRIBUTIONS
    if _DISTRIBUTIONS is None:
        from importlib import metadata

        _DISTRIBUTIONS = dict(metadata.packages_distributions())
    return _DISTRIBUTIONS


def _target(config: pytest.Config, option: str) -> Path | None:
    value = config.getoption(option)
    if not value:
        return None
    path = Path(value)
    return path if path.is_absolute() else Path(config.invocation_params.dir) / path


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    state = session.config.stash.get(STATE, None)
    if state is not None:
        state.unload_specs()
    if state is None or is_worker(session.config) or not state.payloads:
        return
    from spectest.runtime.report import dump_reports, render_markdown

    reports = build_reports(state.payloads)
    md = _target(session.config, "spectest_report")
    if md is not None:
        md.parent.mkdir(parents=True, exist_ok=True)
        md.write_text(render_markdown(reports), encoding="utf-8")
        state.written.append(str(md))
    js = _target(session.config, "spectest_json")
    if js is not None:
        js.parent.mkdir(parents=True, exist_ok=True)
        js.write_text(dump_reports(reports) + "\n", encoding="utf-8")
        state.written.append(str(js))


_SUMMARY_ORDER = [
    ("passed", "passed", "passed"),
    ("failed", "failed", "failed"),
    ("xfailed", "expected failure", "expected failures"),
    ("xpassed", "unexpected pass", "unexpected passes"),
    ("error", "spec error", "spec errors"),
    ("inconclusive", "inconclusive", "inconclusive"),
    ("skipped", "skipped", "skipped"),
]


def pytest_terminal_summary(terminalreporter: Any, exitstatus: int, config: pytest.Config) -> None:
    state = config.stash.get(STATE, None)
    if state is None or not state.payloads:
        return
    from spectest.runtime.report import ClauseResult

    tr = terminalreporter
    tr.write_sep("=", "spectest")
    groups: dict[str, list[dict[str, Any]]] = {}
    for p in sorted(state.payloads, key=lambda p: p["index"]):
        groups.setdefault(p["conformance"], []).append(p)
    for nodeid, payloads in groups.items():
        counts: dict[str, int] = {}
        for p in payloads:
            counts[p["outcome"]] = counts.get(p["outcome"], 0) + 1
        summary = ", ".join(
            f"{n} {one if n == 1 else many}"
            for k, one, many in _SUMMARY_ORDER
            if (n := counts.get(k, 0))
        )
        tr.write_line(f"{nodeid} (spec {payloads[0]['spec']['name']}): {summary}")
        results = [
            (p["outcome"], ClauseResult.from_dict(r)) for p in payloads for r in p["results"]
        ]
        expected = [r for o, r in results if o == "xfailed" and r.failed and r.expected_fail]
        for r in expected:
            tr.write_line(f"  expected failure {one_line(r)}")
        errors = [r for o, r in results if o == "error" and r.has_spec_errors]
        for r in errors:
            first = (r.spec_errors or ["spec error"])[0].splitlines()[0]
            tr.write_line(f"  SPEC ERROR {r.label}: {first}", red=True)
    for path in state.written:
        tr.write_line(f"report written to {path}")


# ---------------------------------------------------------------------------
# v2 specs: spectest.check objects and .spec files, run through spectest._host


def _is_check(obj: Any) -> bool:
    cls = type(obj)
    return cls.__name__ == "SpecCheck" and cls.__module__ == "spectest.specs"


def parse_module_mappings(values: Iterable[str]) -> dict[str, str]:
    """The ``--spectest-module NAME=REPLACEMENT`` options as a mapping."""
    out: dict[str, str] = {}
    for value in values:
        name, sep, replacement = value.partition("=")
        if not sep or not name.strip() or not replacement.strip():
            raise pytest.UsageError(f"--spectest-module {value!r}: expected NAME=REPLACEMENT")
        out[name.strip()] = replacement.strip()
    return out


def spec_clause_name(clause_id: str, decl: str, instantiation: dict[str, str]) -> str:
    """The printed name of a clause: the instantiation follows the declaration's name
    (``sort[T=i64].ordered``, ``math.cos[T=f64]#type``). For a one-part declaration this is
    v1's ``clause_name``."""
    from spectest.runtime.report import clause_name, inst_text

    if not instantiation:
        return clause_id
    if "." not in decl:
        return clause_name(clause_id, instantiation)
    if not clause_id.startswith(decl):
        return clause_id
    return f"{decl}[{inst_text(instantiation)}]{clause_id[len(decl) :]}"


def _load_host() -> Any:
    try:
        import spectest._host as host
    except ImportError as exc:
        raise pytest.UsageError(
            f"spectest: the host module spectest._host is not available ({exc}); "
            "build it with `uv run python scripts/build_host.py`"
        ) from exc
    return host


class _SpecCollectorMixin:
    """Loads a spec through the host and makes one item per clause and instantiation."""

    spec_path: Path
    options: Any  # spectest.specs.SpecCheck

    def collect(self) -> Iterator[pytest.Item]:
        from spectest.driver import Driver
        collector: pytest.Collector = self  # type: ignore[assignment]
        config = collector.config
        state = config.stash[STATE]
        host = _load_host()
        mapping = dict(self.options.modules)
        mapping.update(parse_module_mappings(config.getoption("spectest_module") or []))
        try:
            handle = host.load(str(self.spec_path), Driver(module_map=mapping))
        except Exception as exc:
            raise collector.CollectError(
                f"spectest: cannot load {self.spec_path.name}:\n{exc}"
            ) from exc
        state.loaded.append((host, handle))
        self.handle = handle
        self.spec_hash = hashlib.sha256(self.spec_path.read_bytes()).hexdigest()[:16]
        expect_fail = self.options.expect_fail
        group_base = collector.nodeid
        for entry in host.items(handle):
            decl = entry["decl"]
            tparams = list(entry.get("tparams") or [])
            if not tparams:
                insts: list[dict[str, str] | None] = [{}]
            else:
                given = self.options.instantiations.get(decl)
                insts = list(given) if given else [None]
            for inst in insts:
                name = spec_clause_name(entry["clause_id"], decl, inst or {})
                item = SpecClauseItem.from_parent(
                    collector,
                    name=name,
                    entry=entry,
                    instantiation=inst,
                    owner=self,
                    expected_fail=entry["clause_id"] in expect_fail or name in expect_fail,
                )
                key = f"{group_base}::{spec_clause_name(decl, decl, inst or {})}"
                item.add_marker(pytest.mark.xdist_group(name=key))
                yield item

    def repr_failure(self, excinfo: pytest.ExceptionInfo[BaseException]) -> Any:
        collector: pytest.Collector = self  # type: ignore[assignment]
        if isinstance(excinfo.value, collector.CollectError):
            return str(excinfo.value.args[0])
        return super().repr_failure(excinfo)  # type: ignore[misc]


class CheckCollector(_SpecCollectorMixin, pytest.Collector):
    """The items of one ``spectest.check`` object bound in a test module."""

    def __init__(self, *, check_obj: Any, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self.options = check_obj
        self.spec_path = (Path(str(self.path)).parent / check_obj.path).resolve()

    def reportinfo(self) -> tuple[Any, int | None, str]:
        return self.path, None, self.name


class SpecFile(_SpecCollectorMixin, pytest.File):
    """A ``.spec`` file named on the command line, run with default options."""

    def __init__(self, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        from spectest.specs import check

        self.spec_path = Path(str(self.path))
        self.options = check(self.spec_path.name)


class SpecClauseItem(pytest.Item):
    """One clause of a declaration (under one instantiation) of a v2 spec."""

    def __init__(
        self,
        *,
        entry: dict[str, Any],
        instantiation: dict[str, str] | None,
        owner: Any,
        expected_fail: bool,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self.entry = entry
        self.instantiation = instantiation
        self.owner = owner
        self.expected_fail = expected_fail
        self.spectest_index = 0
        self.results: list[ClauseResult] = []
        self.spectest_outcome: str | None = None
        self.chosen: frozenset[str] | None = None
        self.done = False
        self.add_marker("spectest")

    def clause_names(self) -> dict[str, str]:
        return {self.entry["clause_id"]: self.name}

    def reproduce(self) -> str:
        seed = self.config.stash[STATE].seed
        return f"uv run pytest '{self.nodeid}' --spectest-seed={seed}"

    def payload(self) -> dict[str, Any]:
        spec = self.owner.spec_path
        return {
            "nodeid": self.nodeid,
            "index": self.spectest_index,
            "conformance": self.parent.nodeid if self.parent is not None else "",
            "outcome": self.spectest_outcome or "skipped",
            "spec": {"name": spec.stem, "hash": self.owner.spec_hash, "path": str(spec)},
            "imported": package_versions([], recorded=True),
            "bound": {},
            "results": [dataclasses.asdict(r) for r in self.results],
        }

    def run_options(self) -> dict[str, Any]:
        config = self.config
        state = config.stash[STATE]
        opts = self.owner.options
        budgets = PROFILES[state.profile]
        strength = "full" if (config.getoption("ci", False) or _explicit_ci(config)) else "dev"
        out: dict[str, Any] = {
            "seed": opts.seed if opts.seed is not None else state.seed,
            "store": str(state.store) if state.store is not None else None,
            "strength": strength,
        }
        max_examples = config.getoption("spectest_max_examples")
        if max_examples is None:
            max_examples = opts.max_examples
        if max_examples is None:
            max_examples = budgets.get("max_examples")
        if max_examples is not None:
            out["max_examples"] = max_examples
        limit = config.getoption("spectest_exhaustive_limit")
        if limit is None:
            limit = budgets.get("exhaustive_limit")
        if limit is not None:
            out["exhaustive_limit"] = limit
        decl = self.entry["decl"]
        if self.instantiation:
            out["instantiation"] = dict(self.instantiation)
        examples = opts.examples.get(decl)
        if examples:
            out["examples"] = [dict(e) for e in examples]
        return out

    def declaration_run(self) -> dict[str, Any]:
        """The result of this item's declaration, run once per instantiation per process."""
        state = self.config.stash[STATE]
        inst = spec_clause_name(self.entry["decl"], self.entry["decl"], self.instantiation or {})
        key = (self.owner.handle, self.entry["decl"], inst)
        run = state.runs.get(key)
        if run is None:
            host = _load_host()
            run = host.run(self.owner.handle, self.entry["decl"], self.run_options())
            state.runs[key] = run
        return run

    def result(self) -> ClauseResult:
        from spectest.runtime.report import ClauseResult

        run = self.declaration_run()
        clause_id = self.entry["clause_id"]
        found = next((c for c in run.get("clauses", []) if c.get("clause_id") == clause_id), None)
        data = dict(found) if found is not None else {
            "clause_id": clause_id,
            "clause_text": self.entry.get("text", ""),
            "kind": self.entry.get("kind", ""),
            "decl": self.entry["decl"],
        }
        data["item_id"] = self.nodeid
        data["instantiation"] = dict(self.instantiation or {})
        data["expected_fail"] = self.expected_fail
        return ClauseResult.from_dict(data)

    def runtest(self) -> None:
        if self.instantiation is None:
            tparams = ", ".join(self.entry.get("tparams") or [])
            self.spectest_outcome = "error"
            raise SpecErrorOutcome(
                f"SPEC ERROR (the test's fault)\n{self.entry['decl']} is generic ({tparams}): "
                f"add instantiations={{{self.entry['decl']!r}: [{{...}}]}} to spectest.check "
                "to say which types to run it with"
            )
        state = self.config.stash[STATE]
        self.results = [self.result()]
        self.done = True
        state.ran.append(self)  # type: ignore[arg-type]
        outcome = self.results[0].outcome
        runxfail = bool(getattr(self.config.option, "runxfail", False))
        if runxfail and outcome == "xfailed":
            outcome = "failed"
        elif runxfail and outcome == "xpassed":
            outcome = "passed"
        self.spectest_outcome = outcome
        result = self.results[0]
        if outcome == "failed":
            shown = result
            if runxfail and result.expected_fail:
                shown = dataclasses.replace(result, expected_fail=False)
            raise SpectestOutcome(_texts([shown]))
        if outcome == "error":
            raise SpecErrorOutcome(
                "SPEC ERROR (the spec's or the binding's fault)\n" + _texts([result])
            )
        if outcome == "xfailed":
            pytest.xfail(one_line(result))
        if outcome == "xpassed":
            raise SpectestOutcome(
                f"[XPASS(strict)] expected to fail: {self.name}, but no example failed\n"
                + _texts([result])
            )
        if outcome == "inconclusive":
            pytest.skip(f"inconclusive: {_reason(self.results)}")
        if outcome == "skipped":
            pytest.skip(f"no example applied: {_reason(self.results)}")

    def repr_failure(self, excinfo: pytest.ExceptionInfo[BaseException], style: Any = None) -> Any:
        if isinstance(excinfo.value, SpectestOutcome):
            return excinfo.value.text
        return super().repr_failure(excinfo, style=style)

    def reportinfo(self) -> tuple[Any, int | None, str]:
        return self.path, self.entry.get("line"), f"spectest {self.name}"


def _explicit_ci(config: pytest.Config) -> bool:
    return config.getoption("spectest_profile") == "ci"


SPECTEST_ITEMS = (SpectestItem, SpecClauseItem)

__all__ = [
    "DEV_EXAMPLES",
    "PROFILES",
    "RECORDED_PACKAGES",
    "SPECTEST_ITEMS",
    "CheckCollector",
    "ConformanceCollector",
    "SpecClauseItem",
    "SpecErrorOutcome",
    "SpecFile",
    "SpectestItem",
    "SpectestOutcome",
    "build_reports",
    "clause_globs",
    "glob_match",
    "is_worker",
    "item_outcome",
    "one_line",
    "package_versions",
    "platform_facts",
    "profile_name",
]
