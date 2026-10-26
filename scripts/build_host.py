"""Builds the extension module ``spectest._host`` from ``host/bridge/module.mojo``.

Run it with ``uv run python scripts/build_host.py``. It does nothing when no ``.mojo``
file under ``host/`` is newer than the module. The module is set up the way
bitpattern's editable build is: the Mojo runtime libraries it needs are copied next to
it and found through an ``$ORIGIN`` rpath, so it loads without the compiler's
environment.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from importlib.metadata import distribution
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "host" / "bridge" / "module.mojo"
MODULE = ROOT / "src" / "spectest" / "_host.abi3.so"
INCLUDES = [ROOT / "host", ROOT / "host" / "vendor" / "bitpattern"]
RUNTIME = ["libKGENCompilerRTShared", "libAsyncRTRuntimeGlobals", "libMSupportGlobals"]
SUFFIX = ".dylib" if sys.platform == "darwin" else ".so"
ORIGIN = "@loader_path" if sys.platform == "darwin" else "$ORIGIN"


def newest_source() -> float:
    return max(p.stat().st_mtime for p in (ROOT / "host").rglob("*.mojo"))


def up_to_date() -> bool:
    if not MODULE.exists():
        return False
    if any(not (MODULE.parent / f"{n}{SUFFIX}").exists() for n in RUNTIME):
        return False
    return MODULE.stat().st_mtime >= newest_source()


def build() -> bool:
    """Builds the module unless it is current. Returns whether it ran a build."""
    if up_to_date():
        return False
    mojo = Path(sys.executable).parent / "mojo"
    lib = distribution("mojo-compiler").locate_file("modular/lib")
    for name in RUNTIME:
        copy = MODULE.parent / f"{name}{SUFFIX}"
        copy.unlink(missing_ok=True)
        shutil.copy(str(lib / copy.name), copy)
    flags = [arg for p in INCLUDES for arg in ("-I", str(p))]
    flags += ["-strip-file-prefix", f"{ROOT}/"]
    if sys.platform == "darwin":
        flags += ["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]
        flags += ["-Xlinker", "-install_name", "-Xlinker", "@rpath/_host.abi3.so"]
    env = dict(
        os.environ,
        MODULAR_MOJO_MAX_SHARED_LIBS=f"-Xlinker,-rpath,-Xlinker,{ORIGIN}",
    )
    started = time.perf_counter()
    subprocess.run(
        [
            str(mojo),
            "build",
            str(SOURCE),
            "--emit",
            "shared-lib",
            "-o",
            str(MODULE),
            *flags,
        ],
        check=True,
        env=env,
        cwd=ROOT,
    )
    print(f"built {MODULE.relative_to(ROOT)} in {time.perf_counter() - started:.1f} s")
    return True


def main() -> None:
    if not build():
        print(f"{MODULE.relative_to(ROOT)} is up to date")


if __name__ == "__main__":
    main()
