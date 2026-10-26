"""Small hand-written deques for the deque spec: a correct baseline and five seeded bugs.

``ListDeque`` keeps its items in a Python list and behaves like
``collections.deque``. Three bug classes override one method of it; ``SlotDeque``
keeps its items in a dict of numbered slots and forgets one emptiness check;
``RebuildingDeque`` wraps a ``collections.deque`` and loses its bound in
``rotate``. Each bug is one a hand-written deque plausibly has.
"""

from __future__ import annotations

import collections
from collections.abc import Iterator
from typing import Any


class ListDeque:
    """A deque over a list, bounded when ``maxlen`` is given (the correct baseline)."""

    def __init__(self, maxlen: int | None = None) -> None:
        self._items: list[Any] = []
        self.maxlen = maxlen

    def __iter__(self) -> Iterator[Any]:
        return iter(self._items)

    def __len__(self) -> int:
        return len(self._items)

    def __repr__(self) -> str:
        return f"{type(self).__name__}({self._items!r}, maxlen={self.maxlen!r})"

    def _full(self) -> bool:
        return self.maxlen is not None and len(self._items) > self.maxlen

    def append(self, x: Any) -> None:
        self._items.append(x)
        if self._full():
            del self._items[0]

    def appendleft(self, x: Any) -> None:
        self._items.insert(0, x)
        if self._full():
            del self._items[-1]

    def pop(self) -> Any:
        if not self._items:
            raise IndexError("pop from an empty deque")
        return self._items.pop()

    def popleft(self) -> Any:
        if not self._items:
            raise IndexError("pop from an empty deque")
        return self._items.pop(0)

    def rotate(self, n: int = 1) -> None:
        """Rotate n steps to the right (to the left when n is negative)."""
        if self._items:
            cut = len(self._items) - n % len(self._items)
            self._items[:] = self._items[cut:] + self._items[:cut]


class WrongEndDeque(ListDeque):
    """(a) appendleft trims a full deque at the left, as append does: it drops the item it
    just added instead of the rightmost one."""

    def appendleft(self, x: Any) -> None:
        self._items.insert(0, x)
        if self._full():
            del self._items[0]


class BackwardRotateDeque(ListDeque):
    """(b) rotate(n) moves the items n steps to the left: the sign convention is reversed."""

    def rotate(self, n: int = 1) -> None:
        if self._items:
            cut = n % len(self._items)
            self._items[:] = self._items[cut:] + self._items[:cut]


class PopleftNoneDeque(ListDeque):
    """(c) popleft on an empty deque returns None instead of raising IndexError."""

    def popleft(self) -> Any:
        if not self._items:
            return None
        return self._items.pop(0)


class SlotDeque:
    """(d) A deque over a dict of slots numbered ``lo`` to ``hi - 1``.

    ``popleft`` checks for an empty deque, but ``pop`` does not, so on an empty
    deque the dict's KeyError escapes instead of IndexError.
    """

    def __init__(self, maxlen: int | None = None) -> None:
        self._slots: dict[int, Any] = {}
        self._lo = 0
        self._hi = 0
        self.maxlen = maxlen

    def __iter__(self) -> Iterator[Any]:
        return (self._slots[i] for i in range(self._lo, self._hi))

    def __len__(self) -> int:
        return self._hi - self._lo

    def __repr__(self) -> str:
        return f"SlotDeque({list(self)!r}, maxlen={self.maxlen!r})"

    def _full(self) -> bool:
        return self.maxlen is not None and len(self) > self.maxlen

    def append(self, x: Any) -> None:
        self._slots[self._hi] = x
        self._hi += 1
        if self._full():
            del self._slots[self._lo]
            self._lo += 1

    def appendleft(self, x: Any) -> None:
        self._lo -= 1
        self._slots[self._lo] = x
        if self._full():
            self._hi -= 1
            del self._slots[self._hi]

    def pop(self) -> Any:
        x = self._slots.pop(self._hi - 1)
        self._hi -= 1
        return x

    def popleft(self) -> Any:
        if self._lo == self._hi:
            raise IndexError("pop from an empty deque")
        x = self._slots.pop(self._lo)
        self._lo += 1
        return x

    def rotate(self, n: int = 1) -> None:
        items = list(self)
        if items:
            cut = len(items) - n % len(items)
            items = items[cut:] + items[:cut]
        self._slots = dict(zip(range(self._lo, self._hi), items, strict=True))


class RebuildingDeque:
    """(e) A wrapper over collections.deque whose rotate rebuilds the wrapped deque from the
    rotated items and forgets to pass maxlen, so a bounded deque becomes unbounded."""

    def __init__(self, maxlen: int | None = None) -> None:
        self._d: collections.deque[Any] = collections.deque(maxlen=maxlen)

    @property
    def maxlen(self) -> int | None:
        return self._d.maxlen

    def __iter__(self) -> Iterator[Any]:
        return iter(self._d)

    def __len__(self) -> int:
        return len(self._d)

    def __repr__(self) -> str:
        return f"RebuildingDeque({list(self._d)!r}, maxlen={self.maxlen!r})"

    def append(self, x: Any) -> None:
        self._d.append(x)

    def appendleft(self, x: Any) -> None:
        self._d.appendleft(x)

    def pop(self) -> Any:
        return self._d.pop()

    def popleft(self) -> Any:
        return self._d.popleft()

    def rotate(self, n: int = 1) -> None:
        items = list(self._d)
        if items:
            cut = len(items) - n % len(items)
            items = items[cut:] + items[:cut]
        self._d = collections.deque(items)
