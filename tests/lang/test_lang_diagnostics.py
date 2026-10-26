import pytest

from spectest.ast import NO_SPAN, Span
from spectest.lang import Diagnostic, SpecCheckError, load_source
from spectest.lang.spec import excerpt
from spectest.values import SpecError

SOURCE = "spec s\nfn f(x: f64)\n  ensures x == x and\n    true\n"


def test_excerpt_single_line():
    assert excerpt(SOURCE, Span(3, 11, 3, 17)) == (
        " 3 |   ensures x == x and\n   |           ^^^^^^"
    )


def test_excerpt_multi_line_span_runs_to_the_end_of_the_first_line():
    text = excerpt(SOURCE, Span(3, 11, 4, 9))
    assert text.endswith("|           " + "^" * len("x == x and"))


def test_excerpt_outside_the_source():
    assert excerpt(SOURCE, NO_SPAN) == ""
    assert excerpt(SOURCE, Span(99, 1, 99, 2)) == ""


def test_rendering():
    d = Diagnostic.at("s.spec", SOURCE, Span(3, 11, 3, 17), "bad")
    assert d.location == "s.spec:3:11"
    assert str(d).splitlines()[0] == "s.spec:3:11: error: bad"
    assert Diagnostic("", Span(1, 1, 1, 2), "m").location == "<string>:1:1"


def test_coerce_and_with_source():
    class Foreign:
        span = Span(2, 1, 2, 3)
        message = "m"
        severity = "warning"

    d = Diagnostic.coerce(Foreign(), "s.spec", SOURCE)
    assert (d.path, d.severity, d.message) == ("s.spec", "warning", "m")
    assert "^^" in d.excerpt
    bare = Diagnostic("", Span(2, 1, 2, 3), "m").with_source(SOURCE, "s.spec")
    assert bare.path == "s.spec" and bare.excerpt


def test_check_errors_are_spec_errors_sorted_by_position():
    with pytest.raises(SpecCheckError) as info:
        load_source("spec s\nfn f(x: f64)\n  ensures nope\n  ensures x == x\n  requires zz\n")
    err = info.value
    assert isinstance(err, SpecError)
    assert [d.span.line for d in err.diagnostics] == [3, 4, 5]
    assert err.messages[0] == "unknown name nope"
    assert str(err).count("error:") == 3
