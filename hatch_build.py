"""Compiles spectest._host from spectest/_host/module.mojo, for wheels.

Editable installs leave the module to scripts/build_host.py, which builds it in place.
"""

import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# The module runs on any CPU of the architecture, not just the build machine's.
TARGET_CPUS = {
    "x86_64": "x86-64-v2",
    "aarch64": "generic",  # any ARMv8-A, eg. Graviton or Raspberry Pi
    "arm64": "apple-m1",  # every Apple Silicon Mac
}
if sys.platform == "darwin":
    # macOS 13, the oldest that mojo-compiler runs on. The triple sets it for the
    # compiler, and MACOSX_DEPLOYMENT_TARGET for the linker.
    PLATFORM_TAG = "macosx_13_0_arm64"
    TARGET_FLAGS = ["--target-triple", "arm64-apple-macosx13.0"]
    BUILD_ENV = {"MACOSX_DEPLOYMENT_TARGET": "13.0"}
    # Python's symbols resolve when Python loads the module, as on Linux.
    LINK_FLAGS = ["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]
    # A fixed install name, so a build doesn't depend on where it ran.
    LINK_FLAGS += ["-Xlinker", "-install_name", "-Xlinker", "@rpath/__init__.abi3.so"]
    STRIP_FLAGS = ["-Xlinker", "-x"]  # drops local symbols
    ORIGIN = "@loader_path"
else:
    # The module needs glibc 2.34 (for dlsym), as does mojo-compiler, and the f16
    # conversions of GCC 12's libgcc_s, which manylinux_2_35 is the first to promise.
    PLATFORM_TAG = f"manylinux_2_35_{platform.machine()}"
    TARGET_FLAGS = []
    BUILD_ENV = {}
    LINK_FLAGS = []
    STRIP_FLAGS = ["-Xlinker", "--strip-all"]
    ORIGIN = "$ORIGIN"


class MojoBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if version == "editable":
            return
        root = Path(self.root)
        includes = [root / "src", root / "src/vendor/bitpattern", root / "spectest"]
        flags = [arg for p in includes for arg in ("-I", str(p))]
        # Source paths in the module are the project's, so a build doesn't depend on
        # where it ran.
        flags += ["-strip-file-prefix", f"{root}/"]
        flags += TARGET_FLAGS + LINK_FLAGS + STRIP_FLAGS
        if cpu := TARGET_CPUS.get(platform.machine()):
            flags += ["--target-cpu", cpu]
        # Built outside the project, so a wheel doesn't replace a dev build's module.
        self.build_dir = tempfile.TemporaryDirectory()
        module = Path(self.build_dir.name) / "__init__.abi3.so"
        build_data["force_include"][str(module)] = "spectest/_host/__init__.abi3.so"
        # site-packages/modular/lib, where mojo-compiler (a dependency) puts the runtime
        # libraries, two directories above the module. The flag replaces mojo's default
        # rpath into this build environment, which an isolated build deletes.
        rpath = f"{ORIGIN}/../../modular/lib"
        shared_libs = f"-Xlinker,-rpath,-Xlinker,{rpath}"
        env = dict(os.environ, **BUILD_ENV, MODULAR_MOJO_MAX_SHARED_LIBS=shared_libs)
        source = root / "spectest" / "_host" / "module.mojo"
        # The build environment's mojo, which pip and uv put first on PATH.
        build = ["mojo", "build", source, "--emit", "shared-lib", "-o", module, *flags]
        subprocess.run(build, check=True, env=env)
        build_data["pure_python"] = False
        # The stable ABI from CPython 3.12 on (vectorcall): one wheel per platform.
        build_data["tag"] = f"cp312-abi3-{PLATFORM_TAG}"

    def finalize(
        self, version: str, build_data: dict[str, Any], artifact_path: str
    ) -> None:
        if version != "editable":
            self.build_dir.cleanup()
