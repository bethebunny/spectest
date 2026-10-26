"""``python -m spectest.lang FILE...``: check spec files and print diagnostics or "ok"."""

from __future__ import annotations

import sys

from spectest.lang.errors import SpecLangError
from spectest.lang.loader import load


def main(argv: list[str] | None = None) -> int:
    paths = sys.argv[1:] if argv is None else argv
    if not paths:
        print("usage: python -m spectest.lang FILE.spec ...", file=sys.stderr)
        return 2
    status = 0
    for path in paths:
        try:
            spec = load(path)
        except SpecLangError as e:
            for d in e.diagnostics:
                print(d)
            status = 1
        except OSError as e:
            print(f"{path}: error: {e.strerror or e}")
            status = 1
        else:
            for w in spec.warnings:
                print(w)
            print(f"{path}: ok")
    return status


if __name__ == "__main__":
    sys.exit(main())
