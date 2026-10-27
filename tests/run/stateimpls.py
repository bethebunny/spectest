"""Code under test for the stateful tests: a deque-like class and seeded bugs."""

from __future__ import annotations

import weakref


class Deque:
    """A double-ended queue with an optional bound. Appending to a full bounded deque
    drops an item from the opposite end."""

    def __init__(self, iterable=(), maxlen=None):
        self._maxlen = maxlen
        self._items = []
        for x in iterable:
            self.append(x)

    @classmethod
    def bounded(cls, n):
        return cls((), n)

    @property
    def items(self):
        return list(self._items)

    @property
    def maxlen(self):
        return self._maxlen

    def append(self, x):
        self._items.append(x)
        if self._maxlen is not None and len(self._items) > self._maxlen:
            del self._items[0]

    def appendleft(self, x):
        self._items.insert(0, x)
        if self._maxlen is not None and len(self._items) > self._maxlen:
            del self._items[-1]

    def pop(self):
        return self._items.pop()

    def popleft(self):
        return self._items.pop(0)

    def rotate(self, n=1):
        if self._items:
            k = n % len(self._items)
            self._items = self._items[len(self._items) - k :] + self._items[: len(self._items) - k]

    def peek(self):
        return self._items[-1]


class PopWrongEnd(Deque):
    def pop(self):
        return self._items.pop(0)


class NoEvict(Deque):
    """A bounded append that doesn't evict."""

    def append(self, x):
        self._items.append(x)


class RotateOffByOne(Deque):
    def rotate(self, n=1):
        if self._items:
            k = (n + 1) % len(self._items)
            self._items = self._items[len(self._items) - k :] + self._items[: len(self._items) - k]


class Leaky(Deque):
    """Popping empties every other deque."""

    _all: weakref.WeakSet = weakref.WeakSet()

    def __init__(self, iterable=(), maxlen=None):
        super().__init__(iterable, maxlen)
        Leaky._all.add(self)

    def pop(self):
        value = self._items.pop()
        for other in list(Leaky._all):
            if other is not self:
                other._items.clear()
        return value


class PeekMutates(Deque):
    def peek(self):
        value = self._items[-1]
        self._items.insert(0, self._items.pop())
        return value
