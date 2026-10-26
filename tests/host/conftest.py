"""Runs the Mojo test files under tests/host as pytest items, one item per file.

A test file is a Mojo program named ``test_*.mojo`` whose ``main`` runs a
``TestSuite``. It is built with the venv's ``mojo``, with ``host/`` and the vendored
bitpattern core on the include path, so ``from wire.value import Value`` and ``from
arena import Arena`` both work, and then run. A compile error or a failing test fails
the item, with mojo's output as the report.

Built tests are kept in ``.mojo-tests/``, keyed by a hash of the test file, every
``.mojo`` file under ``host/`` and the compiler's version. A rerun with nothing
changed runs the kept binary at once; a change under ``host/`` rebuilds each test
the next time it runs (several seconds each).

The test runs with ``SPECTEST_STRENGTH`` set to ``dev`` in the dev loop and ``full``
under ``--ci`` or a non-dev Hypothesis profile, so a Mojo test can scale its own
sample counts the way the Python tests' budgets do.

``uv run pytest tests/host/wire`` runs one package's tests.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from collections.abc import Iterator
from functools import cache
from importlib.metadata import version
from pathlib import Path

import pytest
from hypothesis import settings

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "host"
INCLUDES = [HOST, HOST / "vendor" / "bitpattern"]
BUILDS = ROOT / ".mojo-tests"
# A cold build of a large test file plus its run, with room to spare.
TIMEOUT = 600


@cache
def host_digest() -> str:
    """A hash of the compiler's version and every Mojo source under host/."""
    h = hashlib.sha256(version("mojo-compiler").encode())
    for path in sorted(HOST.rglob("*.mojo")):
        h.update(str(path.relative_to(HOST)).encode())
        h.update(path.read_bytes())
    return h.hexdigest()


def build(path: Path) -> Path:
    """The built test, building it first unless a build of the same sources is kept."""
    digest = hashlib.sha256((host_digest() + path.read_text()).encode()).hexdigest()[:16]
    stem = "__".join(path.relative_to(ROOT).with_suffix("").parts)
    binary = BUILDS / f"{stem}-{digest}"
    if binary.exists():
        return binary
    BUILDS.mkdir(exist_ok=True)
    mojo = Path(sys.executable).parent / "mojo"
    includes = [arg for p in INCLUDES for arg in ("-I", str(p))]
    partial = BUILDS / f".partial-{os.getpid()}-{binary.name}"
    proc = subprocess.run(
        [str(mojo), "build", *includes, str(path), "-o", str(partial)],
        capture_output=True,
        text=True,
        check=False,
        timeout=TIMEOUT,
        cwd=ROOT,
    )
    if proc.returncode != 0:
        partial.unlink(missing_ok=True)
        raise MojoTestFailed(proc.stdout + proc.stderr)
    for old in BUILDS.glob(f"{stem}-*"):
        old.unlink(missing_ok=True)
    partial.rename(binary)
    return binary


def strength(config: pytest.Config) -> str:
    full = config.getoption("ci", False) or settings.get_current_profile_name() != "dev"
    return "full" if full else "dev"


def pytest_collect_file(parent: pytest.Collector, file_path: Path) -> pytest.File | None:
    if file_path.suffix == ".mojo" and file_path.name.startswith("test_"):
        return MojoFile.from_parent(parent, path=file_path)
    return None


class MojoFile(pytest.File):
    def collect(self) -> Iterator[pytest.Item]:
        yield MojoTest.from_parent(self, name=self.path.stem)


class MojoTestFailed(Exception):
    pass


class MojoTest(pytest.Item):
    def runtest(self) -> None:
        binary = build(self.path)
        env = dict(os.environ, SPECTEST_STRENGTH=strength(self.config))
        proc = subprocess.run(
            [str(binary)],
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
