"""Test-run profiles: the dev loop and the full-strength CI run.

``uv run pytest`` is the dev loop. It runs tests/ on 4 pytest-xdist workers under the
"dev" Hypothesis profile (few examples, no deadline), with the small budgets that tests
read from tests/budget.py, and it deselects the tests marked ``slow`` (those over half a
second at the dev budgets). ``--slow`` keeps them (at the dev budgets), and naming a slow
test by its node ID runs it. A run that names files or tests stays in one process;
``-n N`` overrides either.

``uv run pytest --ci`` runs everything at full strength: tests/ under the "ci"
profile (Hypothesis's default budgets, no deadline) with the slow tests included, and
every example at its own spectest budget, under pytest-xdist.

``--hypothesis-profile=ci`` gives full strength in one process, without the examples.
"""

from __future__ import annotations

import os

import pytest
from hypothesis import settings

settings.register_profile("dev", max_examples=10, deadline=None)
settings.register_profile("ci", deadline=None)
settings.load_profile("dev")

if os.environ.get("PYTEST_XDIST_WORKER"):
    # A polars thread pool per worker would oversubscribe the cores.
    os.environ.setdefault("POLARS_MAX_THREADS", "1")

CI_PATHS = ["tests", "examples"]

# Workers for the whole dev suite: past 4, this laptop's 2 performance cores gain little.
DEV_WORKERS = 4


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--ci",
        action="store_true",
        default=False,
        help="run tests/ and examples/ at full strength under pytest-xdist",
    )
    parser.addoption(
        "--slow",
        action="store_true",
        default=False,
        help="in the dev loop, also run the tests marked slow (at the dev budgets)",
    )


def is_ci(config: pytest.Config) -> bool:
    return bool(config.getoption("ci"))


def full_strength(config: pytest.Config) -> bool:
    return is_ci(config) or settings.get_current_profile_name() != "dev"


def ci_workers() -> int:
    """The default worker count of --ci: one per logical CPU (on a 12-thread laptop, 12
    workers finish about 6% sooner than 8 although each test runs a third slower)."""
    return max(1, os.cpu_count() or 1)


@pytest.hookimpl(tryfirst=True)
def pytest_cmdline_main(config: pytest.Config) -> None:
    """--ci and a bare ``uv run pytest`` run on pytest-xdist workers unless -n says
    otherwise; a run that names files or tests stays in one process, which starts sooner."""
    option = config.option
    if hasattr(config, "workerinput") or not hasattr(option, "numprocesses"):
        return
    if option.numprocesses is not None or option.collectonly or option.usepdb:
        return
    if is_ci(config):
        option.numprocesses = ci_workers()
    elif config.args_source == pytest.Config.ArgsSource.TESTPATHS:
        option.numprocesses = DEV_WORKERS


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line(
        "markers", "slow: a heavy test that only the full-strength runs include"
    )
    if is_ci(config):
        if not config.getoption("hypothesis_profile", None):
            settings.load_profile("ci")
        if config.args_source == pytest.Config.ArgsSource.TESTPATHS:
            config.args = list(CI_PATHS)


def _named(item: pytest.Item, args: list[str]) -> bool:
    """Whether a command-line argument names the item itself (a node ID, not a file)."""
    for arg in args:
        if "::" in arg:
            arg = arg.removeprefix("./")
            if item.nodeid == arg or item.nodeid.startswith((arg + "[", arg + "::")):
                return True
    return False


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """In the dev loop, deselect the slow tests the command line does not name, unless
    --slow keeps them or a -m expression chooses tests."""
    if not (full_strength(config) or config.option.markexpr or config.getoption("slow")):
        deselect_slow(config, items)


def deselect_slow(config: pytest.Config, items: list[pytest.Item]) -> None:
    args = [str(a) for a in config.invocation_params.args]
    slow = [i for i in items if i.get_closest_marker("slow") and not _named(i, args)]
    if slow:
        dropped = set(slow)
        config.hook.pytest_deselected(items=slow)
        items[:] = [i for i in items if i not in dropped]

