"""Properties and the outcome of running one example against them."""

from .source import Source

comptime PASSED = 0
comptime FAILED = 1
comptime SKIPPED = 2


struct Outcome(Copyable, Movable):
    """What one example did to each property, by integer property id."""

    var is_invalid: Bool
    var ids: List[Int]
    var results: List[Int]

    def __init__(out self, is_invalid: Bool = False):
        self.is_invalid = is_invalid
        self.ids = List[Int]()
        self.results = List[Int]()

    @staticmethod
    def invalid() -> Self:
        return Self(True)

    @staticmethod
    def single(id: Int, result: Int) -> Self:
        var o = Self()
        o.add(id, result)
        return o^

    def add(mut self, id: Int, result: Int):
        self.ids.append(id)
        self.results.append(result)


trait Property:
    def run(mut self, mut src: Source) raises -> Outcome:
        ...
