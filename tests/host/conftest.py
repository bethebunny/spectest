"""Runs the Mojo test files under tests/host as pytest items, one item per file.

A test file is a Mojo program named ``test_*.mojo`` whose ``main`` runs a
``TestSuite``. It is built with the venv's ``mojo``, with ``host/``, the vendored
bitpattern core and ``tests/host/lib`` (test-only helpers) on the include path, so
``from wire.value import Value`` and ``from arena import Arena`` both work, and then
run. A compile error or a failing test fails the item, with mojo's output as the
report.

Each binary compiles everything it imports from scratch, so when a run selects
several files of one directory, they share one binary: a runner generated in
``.mojo-tests/`` that imports each test file of the directory and runs the one that
``SPECTEST_MODULE`` names. A run of one file of a directory builds that file alone,
which is quicker.

Binaries are kept in ``.mojo-tests/``, keyed by a hash of the compiler's version, the
runner and every ``.mojo`` module the tests import, directly or through other
modules. A rerun with nothing changed runs the kept binary at once; a change to a
module rebuilds the binaries that use it (several seconds to a minute each). Each
process first builds the binaries of the run that no other process is building, so
xdist workers build in parallel. A failed build is kept for the run, so each of its
items reports it without building again.

The test runs with ``SPECTEST_STRENGTH`` set to ``dev`` in the dev loop and ``full``
under ``--ci`` or a non-dev Hypothesis profile, so a Mojo test can scale its own
sample counts the way the Python tests' budgets do.

``uv run pytest tests/host/wire`` runs one package's tests.
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import subprocess
import sys
import uuid
from collections import Counter
from collections.abc import Generator, Iterator
from contextlib import contextmanager, suppress
from functools import cache
from importlib.metadata import version
from pathlib import Path

import pytest
from hypothesis import settings

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "host"
# Test-only modules (helpers shared by test files) live in tests/host/lib, outside host/.
INCLUDES = [ROOT / "src", HOST, ROOT / "src" / "vendor" / "bitpattern", ROOT / "tests" / "host" / "lib"]
BUILDS = ROOT / ".mojo-tests"
# A cold build of a large test file plus its run, with room to spare.
TIMEOUT = 600
# Names this run's failed builds, which its xdist workers share.
RUN = os.environ.get("PYTEST_XDIST_TESTRUNUID") or uuid.uuid4().hex
TEST = re.compile(r"^def (test_\w+)\(", re.MULTILINE)


# `from wire.value import Value`, `from .x import (a, b)`, `import check.types`.
FROM_IMPORT = re.compile(
    r"^\s*from\s+([.\w]+)\s+import\s+(\([^)]*\)|[^\n]*)", re.MULTILINE
)
PLAIN_IMPORT = re.compile(r"^\s*import\s+([\w.]+)", re.MULTILINE)


def module_files(dotted: str, base: Path | None) -> list[Path]:
    """The files that importing a module loads: the module itself and the __init__.mojo
    of each enclosing package. Relative names (`.x`) resolve from `base`'s directory."""
    if dotted.startswith("."):
        if base is None:
            return []
        up = len(dotted) - len(dotted.lstrip("."))
        roots = [base.parents[up - 1]]
        dotted = dotted.lstrip(".")
    else:
        roots = INCLUDES
    parts = [p for p in dotted.split(".") if p]
    for root in roots:
        found = []
        for k in range(1, len(parts) + 1):
            init = root.joinpath(*parts[:k], "__init__.mojo")
            if init.is_file():
                found.append(init)
        module = root.joinpath(*parts).with_suffix(".mojo") if parts else None
        if module is not None and module.is_file():
            return [*found, module]
        if found and (root.joinpath(*parts).is_dir() or not parts):
            return found
    return []


@cache
def imported_files(path: Path) -> frozenset[Path]:
    """The Mojo files that `path` imports directly, std left out."""
    text = path.read_text()
    files: set[Path] = set()
    for match in FROM_IMPORT.finditer(text):
        module = match.group(1)
        if module.split(".")[0] == "std":
            continue
        files.update(module_files(module, path))
        # `from syntax import ast` imports a submodule by name.
        for name in re.findall(r"\w+", match.group(2).replace(" as ", " ")):
            sub = module + name if module.endswith(".") else f"{module}.{name}"
            files.update(f for f in module_files(sub, path) if f.stem == name)
    for match in PLAIN_IMPORT.finditer(text):
        if match.group(1).split(".")[0] != "std":
            files.update(module_files(match.group(1), path))
    return frozenset(files)


@cache
def closure(path: Path) -> frozenset[Path]:
    """`path`'s imports, transitively."""
    seen: set[Path] = set()
    todo = list(imported_files(path))
    while todo:
        f = todo.pop()
        if f not in seen:
            seen.add(f)
            todo.extend(imported_files(f) - seen)
    return frozenset(seen)


# A unit is what one binary builds: a test file, or a directory of them.


def stem(unit: Path) -> str:
    return "__".join(unit.relative_to(ROOT).with_suffix("").parts)


def tests(unit: Path) -> list[Path]:
    return sorted(unit.glob("test_*.mojo")) if unit.is_dir() else [unit]


# Runs the test file that SPECTEST_MODULE names. It registers each test by name, as
# `__functions_in_module()` sees only the main file, and gives each suite its file's
# name for the report.
RUNNER = """\
from std.os import getenv
from std.reflection import SourceLocation
from std.testing import TestSuite

{imports}


def main() raises:
    var module = getenv("SPECTEST_MODULE")
{suites}    raise Error("no test file " + module)
"""
SUITE = """\
    if module == "{module}":
        var suite = TestSuite(location=SourceLocation(line=1, col=1, file_name="{path}"))
{tests}        suite^.run()
        return
"""


def runner(unit: Path) -> str:
    suites = [
        SUITE.format(
            module=t.stem,
            path=t.relative_to(ROOT),
            tests="".join(
                f"        suite.test[{t.stem}.{f}]()\n"
                for f in TEST.findall(t.read_text())
            ),
        )
        for t in tests(unit)
    ]
    imports = "\n".join(f"import {t.stem}" for t in tests(unit))
    return RUNNER.format(imports=imports, suites="".join(suites))


@cache
def binary(unit: Path) -> Path:
    """Where `unit` is built, by a hash of the compiler's version, the runner and
    every file it builds on."""
    h = hashlib.sha256(version("mojo-compiler").encode())
    if unit.is_dir():
        h.update(runner(unit).encode())
    for f in sorted({f for t in tests(unit) for f in (t, *closure(t))}):
        h.update(str(f.relative_to(ROOT)).encode())
        h.update(f.read_bytes())
    return BUILDS / f"{stem(unit)}-{h.hexdigest()[:16]}"


@contextmanager
def locked(unit: Path, *, wait: bool) -> Generator[bool]:
    """Whether this process holds `unit`'s build lock, waiting for it if `wait`."""
    BUILDS.mkdir(exist_ok=True)
    with (BUILDS / f"{stem(unit)}.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True


def build(unit: Path) -> Path:
    """`unit`'s binary, built unless a build of the same sources is kept. The caller
    holds `unit`'s lock."""
    out = binary(unit)
    failed = out.with_name(f"{out.name}.{RUN}.failed")
    if out.exists():
        return out
    if failed.exists():
        raise MojoTestFailed(failed.read_text())
    main, includes = unit, INCLUDES
    if unit.is_dir():
        main, includes = BUILDS / f"{stem(unit)}.mojo", [*INCLUDES, unit]
        main.write_text(runner(unit))
    partial = out.with_name(f".partial-{out.name}")
    proc = subprocess.run(
        [
            str(Path(sys.executable).parent / "mojo"),
            "build",
            *(arg for p in includes for arg in ("-I", str(p))),
            "-strip-file-prefix",
            f"{ROOT}/",
            str(main),
            "-o",
            str(partial),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=TIMEOUT,
        cwd=ROOT,
    )
    if proc.returncode != 0:
        partial.unlink(missing_ok=True)
        failed.write_text(proc.stdout + proc.stderr)
        raise MojoTestFailed(proc.stdout + proc.stderr)
    for old in BUILDS.glob(f"{stem(unit)}-*"):
        old.unlink(missing_ok=True)
    partial.rename(out)
    return out


@cache
def units(session: pytest.Session) -> dict[Path, Path]:
    """Each selected test file's unit: its directory when the selection holds several
    of its files."""
    paths = [i.path for i in session.items if isinstance(i, MojoTest)]
    selected = Counter(p.parent for p in paths)
    return {p: p.parent if selected[p.parent] > 1 else p for p in paths}


@cache
def build_all(session: pytest.Session) -> None:
    """Builds the selection's units that no other process is building, so workers
    build in parallel rather than wait on one unit."""
    for unit in dict.fromkeys(units(session).values()):
        with locked(unit, wait=False) as held, suppress(MojoTestFailed):
            if held:
                build(unit)


def strength(config: pytest.Config) -> str:
    full = config.getoption("ci", False) or settings.get_current_profile_name() != "dev"
    return "full" if full else "dev"


def pytest_collect_file(
    parent: pytest.Collector, file_path: Path
) -> pytest.File | None:
    if file_path.suffix == ".mojo" and file_path.name.startswith("test_"):
        return MojoFile.from_parent(parent, path=file_path)
    return None


class MojoFile(pytest.File):
    def collect(self) -> Iterator[pytest.Item]:
        yield MojoTest.from_parent(self, name=self.path.stem)


class MojoTestFailed(Exception):
    pass


class MojoTest(pytest.Item):
    def setup(self) -> None:
        build_all(self.session)

    def runtest(self) -> None:
        with locked(unit := units(self.session)[self.path], wait=True):
            program = build(unit)
        env = dict(
            os.environ,
            SPECTEST_STRENGTH=strength(self.config),
            SPECTEST_MODULE=self.path.stem,
        )
        proc = subprocess.run(
            [str(program)],
            capture_output=True,
            text=True,
            check=False,
            timeout=TIMEOUT,
            cwd=ROOT,
            env=env,
        )
        if proc.returncode != 0:
            raise MojoTestFailed(proc.stdout + proc.stderr)

    def repr_failure(self, excinfo: pytest.ExceptionInfo[BaseException]) -> str:
        if isinstance(excinfo.value, MojoTestFailed):
            return str(excinfo.value)
        return super().repr_failure(excinfo)

    def reportinfo(self) -> tuple[Path, int, str]:
        return self.path, 0, f"mojo {self.path.name}"
