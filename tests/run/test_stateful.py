"""Interfaces: step sequences on a deque-like class, modeled on examples/deque."""

from __future__ import annotations

import pytest

from support import load

SPEC = """\
spec stateful

error IndexError

interface {cls}<T: Eq>
  observe items: list<T>
  observe maxlen: option<u8>
  invariant within_bound: is_none(maxlen) or len(items) <= unwrap(maxlen)

  new __init__(iterable: list<T>, maxlen: option<u8>) -> {cls}
    ensures maxlen: result.maxlen == maxlen
    ensures bound: is_none(maxlen) or len(result.items) <= unwrap(maxlen)

  new bounded(n: u8) -> {cls}
    ensures items: len(result.items) == 0
    ensures maxlen: result.maxlen == some(n)

  method append(self, x: T)
    modifies self
    ensures items: let ys = old(self.items) + [x] in
      self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen)
                     then ys[len(ys) - unwrap(self.maxlen):len(ys)] else ys)
    ensures maxlen: self.maxlen == old(self.maxlen)

  method appendleft(self, x: T)
    modifies self
    ensures items: let ys = [x] + old(self.items) in
      self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen)
                     then ys[0:unwrap(self.maxlen)] else ys)

  method pop(self) -> T
    raises IndexError when len(self.items) == 0
    modifies self
    ensures value: result == old(self.items)[len(old(self.items)) - 1]
    ensures items: self.items == old(self.items)[0:len(old(self.items)) - 1]

  method popleft(self) -> T
    raises IndexError when len(self.items) == 0
    modifies self
    ensures value: result == old(self.items)[0]
    ensures items: self.items == old(self.items)[1:len(old(self.items))]

  method rotate(self, n: i8)
    modifies self
    ensures items: let xs = old(self.items) in
      self.items == (if len(xs) == 0 then xs
                     else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)])

  method peek(self) -> T
    raises IndexError when len(self.items) == 0
    ensures value: result == old(self.items)[len(old(self.items)) - 1]
"""


def spec_for(cls: str) -> str:
    return SPEC.format(cls=f"stateimpls.{cls}")


def run(tmp_path, cls: str, **options):
    spec = load(tmp_path, spec_for(cls))
    try:
        options.setdefault("instantiation", {"T": "i64"})
        return spec.run(f"stateimpls.{cls}", **options)
    finally:
        spec.close()


def steps_of(cx) -> list[str]:
    lines = cx["observation"].split("\n")
    assert lines[0] == "steps:"
    out = []
    for line in lines[1:]:
        head, _, rest = line.partition(". ")
        if not head.isdigit():
            break
        out.append(rest)
    return out


def test_smoke(tmp_path):
    r = run(tmp_path, "Deque")
    print(r.data)
    assert r.passed_all()
