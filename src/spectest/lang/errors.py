"""Errors raised by the front end. Each carries one or more diagnostics."""

from __future__ import annotations

from collections.abc import Iterable

from spectest.ast import Span
from spectest.lang.spec import Diagnostic
from spectest.values import SpecError


class SpecLangError(SpecError):
    """Base of front-end errors; ``diagnostics`` are sorted by position."""

    def __init__(self, diagnostics: Iterable[Diagnostic]) -> None:
        self.diagnostics = sorted(diagnostics, key=lambda d: (d.path, d.span.line, d.span.col))
        super().__init__("\n".join(str(d) for d in self.diagnostics))

    @classmethod
    def at(cls, path: str, source: str, span: Span, message: str) -> SpecLangError:
        return cls([Diagnostic.at(path, source, span, message)])

    @property
    def messages(self) -> list[str]:
        return [d.message for d in self.diagnostics]


class SpecSyntaxError(SpecLangError):
    """The source does not lex or parse. Reports the first error."""


class SpecCheckError(SpecLangError):
    """The file parses but breaks a static rule. Reports every error found."""


__all__ = ["Diagnostic", "SpecCheckError", "SpecLangError", "SpecSyntaxError"]
