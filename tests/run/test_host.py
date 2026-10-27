"""What the evaluator asks of the host: constants, identity, reading expressions, and
failures of the driver."""

from __future__ import annotations

import pytest

from support import load

SPEC = """\
spec host

const runimpls.LIMIT: i32

model runimpls.Box
  observe items: list<i32>
  observe total: int = builtins.sum(self.items)
  observe copy: list<i32> = builtins.list(self.items)
  build runimpls.make_box(items: list<i32>)

fn runimpls.clip_to_limit(x: i32) -> i32
  ensures bounded: result <= runimpls.LIMIT
  ensures identity: x <= runimpls.LIMIT implies result == x

fn runimpls.same_box(b: runimpls.Box) -> runimpls.Box
  ensures alias: same_object(result, b)
  ensures not_fresh: not fresh(result)
  ensures read: result.total == sum(x in b.items: x) and result.copy == b.items

fn runimpls.new_box(items: list<i32>) -> runimpls.Box
  ensures made: fresh(result)
  ensures read: result.total == sum(x in items: x)

fn runimpls.pick_first(a: runimpls.Box, b: runimpls.Box) -> runimpls.Box
  ensures first: same_object(result, a)
  ensures second: same_object(result, b)

fn runimpls.missing(x: i32) -> i32
  ensures anything: true
"""


@pytest.fixture(scope="module")
def spec(tmp_path_factory):
    loaded = load(tmp_path_factory.mktemp("host"), SPEC)
    yield loaded
    loaded.close()


def test_constants_come_from_the_driver(spec):
    r = spec.run("runimpls.clip_to_limit", max_examples=200)
    assert r.passed_all(), r.data
    assert r["runimpls.clip_to_limit.bounded"]["counts"]["pass"] == 200


def test_identity_questions_use_handle_ids(spec):
    r = spec.run("runimpls.same_box", max_examples=30)
    assert r.passed_all(), r.data
    r = spec.run("runimpls.new_box", max_examples=30)
    assert r.passed_all(), r.data


def test_the_same_object_compares_handles(spec):
    r = spec.run("runimpls.pick_first", max_examples=30)
    assert r.failed() == ["runimpls.pick_first.second"]
    assert r["runimpls.pick_first.first"]["counts"]["pass"] == r.examples


def test_an_observer_with_a_reading_expression_calls_the_library(spec):
    # total and copy have no attribute of that name: they are read by evaluating the
    # expression with self bound to the object, calling builtins.sum and builtins.list.
    r = spec.run("runimpls.new_box", max_examples=30)
    assert r["runimpls.new_box.read"]["counts"]["pass"] == 30


def test_a_name_that_does_not_resolve_is_a_spec_error_of_every_clause(spec):
    r = spec.run("runimpls.missing", max_examples=5)
    assert r.failed() == []
    assert r["runimpls.missing.anything"]["counts"]["spec_error"] >= 1
    assert "no attribute missing" in r["runimpls.missing.anything"]["spec_errors"][0]


def test_unloading_a_spec_frees_its_handle(tmp_path):
    from spectest import _host

    loaded = load(tmp_path, SPEC)
    handle = loaded.handle
    loaded.close()
    with pytest.raises(TypeError):
        _host.items(handle)


def test_a_spec_with_errors_raises_with_the_diagnostics(tmp_path):
    from spectest import _host
    from spectest.driver import Driver

    path = tmp_path / "bad.spec"
    path.write_text("spec bad\n\nfn f(x: i32) -> i32\n  ensures e: result == y\n")
    with pytest.raises(ValueError) as caught:
        _host.load(str(path), Driver())
    message = str(caught.value)
    assert message.startswith(f"{path}:4:")
    assert "y" in message
