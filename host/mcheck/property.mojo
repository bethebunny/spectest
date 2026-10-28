"""Properties and the outcome of running one example against them."""

from .source import Source


__enum Verdict(Equatable, ImplicitlyCopyable, Writable):
    """What one example did to one property."""

    case PASSED
    case FAILED
    case SKIPPED

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()


comptime PASSED = Verdict.PASSED
comptime FAILED = Verdict.FAILED
comptime SKIPPED = Verdict.SKIPPED


struct Outcome(Copyable):
    """What one example did to each property, by integer property id."""

    var is_invalid: Bool
    var verdicts: List[Tuple[Int, Verdict]]
    """A property id and its verdict, in the order they were added."""

    def __init__(out self, is_invalid: Bool = False):
        self.is_invalid = is_invalid
        self.verdicts = []

    @staticmethod
    def invalid() -> Self:
        return Self(True)

    @staticmethod
    def single(id: Int, verdict: Verdict) -> Self:
        var o = Self()
        o.add(id, verdict)
        return o^

    def add(mut self, id: Int, verdict: Verdict):
        self.verdicts.append((id, verdict))

    def failed(self, id: Int) -> Bool:
        return (id, FAILED) in self.verdicts


trait Property:
    def run(mut self, mut src: Source) raises -> Outcome:
        ...


def run_example[P: Property](mut prop: P, mut src: Source) raises -> Optional[Outcome]:
    """The outcome of the example `src` is set up for; none when it is invalid."""
    try:
        var out = prop.run(src)
        if not out.is_invalid:
            return out^
    except e:
        if not src.invalid:
            raise e^
    return None
