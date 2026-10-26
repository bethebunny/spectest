"""The spec language front end: lexing, parsing, checking and loading."""

from spectest.lang.checker import check, resolve_type
from spectest.lang.errors import SpecCheckError, SpecLangError, SpecSyntaxError
from spectest.lang.loader import load, load_source
from spectest.lang.parser import parse, parse_expr, parse_type
from spectest.lang.signatures import PRELUDE_SIGNATURES
from spectest.lang.spec import RESOLUTION_KINDS, Diagnostic, Resolution, Spec

__all__ = [
    "PRELUDE_SIGNATURES",
    "RESOLUTION_KINDS",
    "Diagnostic",
    "Resolution",
    "Spec",
    "SpecCheckError",
    "SpecLangError",
    "SpecSyntaxError",
    "check",
    "load",
    "load_source",
    "parse",
    "parse_expr",
    "parse_type",
    "resolve_type",
]
