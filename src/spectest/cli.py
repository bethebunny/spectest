"""The ``spectest`` command: ``spectest check FILE.spec...`` and ``spectest report REPORT.json``.

Also runnable as ``python -m spectest.cli``.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path


def check(paths: Sequence[str]) -> int:
    """Load each spec; print its diagnostics (warnings too) or "<path>: ok". 1 on any error."""
    from spectest.lang import SpecLangError, load

    status = 0
    for path in paths:
        try:
            spec = load(path)
        except SpecLangError as e:
            for d in e.diagnostics:
                print(d)
            print(f"{path}: {len(e.diagnostics)} error(s)")
            status = 1
        except OSError as e:
            print(f"{path}: error: {e.strerror or e}")
            status = 1
        else:
            for w in spec.warnings:
                print(w)
            print(f"{path}: ok")
    return status


def report(path: str) -> int:
    """Print the Markdown rendering of a JSON report (one report or a list). 1 if unreadable."""
    from spectest.runtime.report import load_reports, render_markdown

    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as e:
        print(f"{path}: error: {e.strerror or e}", file=sys.stderr)
        return 1
    try:
        reports = load_reports(text)
    except (ValueError, KeyError, TypeError) as e:
        print(f"{path}: error: not a spectest JSON report ({e})", file=sys.stderr)
        return 1
    sys.stdout.write(render_markdown(reports))
    return 0


def parser() -> argparse.ArgumentParser:
    from spectest import __version__

    p = argparse.ArgumentParser(prog="spectest", description="Check spec files and render reports.")
    p.add_argument("--version", action="version", version=f"spectest {__version__}")
    sub = p.add_subparsers(dest="command", required=True, metavar="COMMAND")
    c = sub.add_parser("check", help="parse and check spec files")
    c.add_argument("files", nargs="+", metavar="FILE.spec")
    r = sub.add_parser("report", help="print a JSON report as Markdown")
    r.add_argument("file", metavar="REPORT.json")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.command == "check":
        return check(args.files)
    return report(args.file)


if __name__ == "__main__":
    sys.exit(main())
