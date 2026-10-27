"""Code under test for the driver tests."""

import dataclasses
import enum
import threading
import typing

CONSTANT = 42
NEVER = threading.Event()


def add(a, b):
    return a + b


def block():
    NEVER.wait(30)


def boom(msg):
    raise ValueError(msg)


def ident(x):
    return x


def make_big(n):
    return list(range(n))


class Color(enum.Enum):
    RED = 1
    BLUE = 2


class Point(typing.NamedTuple):
    x: int
    y: int


@dataclasses.dataclass
class Box:
    label: str
    items: list


class Slow:
    def wait(self):
        NEVER.wait(30)


class Counter:
    class Inner:
        def __init__(self, n=0):
            self.n = n

    def __init__(self, n=0):
        self.n = n

    def plus(self, k):
        return Counter(self.n + k)

    @property
    def double(self):
        return self.n * 2

    @staticmethod
    def static(a):
        return a + 1

    @classmethod
    def make(cls, n):
        return cls(n)


class Day:
    def __init__(self, n):
        self.n = n


class SubDay(Day):
    pass


_shared = Counter(7)


def shared():
    return _shared
