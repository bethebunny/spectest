"""A recorded sequence of choices and the spans that mark its structure."""


@fieldwise_init
struct Span(Copyable, Movable, ImplicitlyCopyable):
    """A half-open range [start, end) of choice positions with an integer label."""

    var start: Int
    var end: Int
    var label: Int

    def length(self) -> Int:
        return self.end - self.start


struct Choices(Copyable, Movable):
    """Each choice is a value in [0, bound]; shrinking moves values toward 0."""

    var values: List[UInt64]
    var bounds: List[UInt64]
    var spans: List[Span]

    def __init__(out self):
        self.values = List[UInt64]()
        self.bounds = List[UInt64]()
        self.spans = List[Span]()

    def __init__(out self, var values: List[UInt64]):
        """Choices with unknown (maximal) bounds, as stored or hand-written."""
        self.bounds = List[UInt64]()
        for _ in range(len(values)):
            self.bounds.append(UInt64.MAX)
        self.values = values^
        self.spans = List[Span]()

    def __len__(self) -> Int:
        return len(self.values)

    def clear(mut self):
        self.values.clear()
        self.bounds.clear()
        self.spans.clear()

    def push(mut self, value: UInt64, bound: UInt64):
        self.values.append(value)
        self.bounds.append(bound)
