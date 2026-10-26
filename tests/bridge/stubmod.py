"""Functions and classes the stub driver resolves in the bridge tests."""


def nothing() -> None:
    return None


def add(a: int, b: int) -> int:
    return a + b


def identity(x):
    return x


def boom(message: str = "bang"):
    raise ValueError(message)


class Counter:
    def __init__(self, start: int = 0) -> None:
        self.count = start

    def bump(self, by: int = 1) -> int:
        self.count += by
        return self.count


def make_counter(start: int = 0) -> Counter:
    return Counter(start)
