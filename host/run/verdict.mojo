"""What judging a clause on one example gave, and a clause's counts over a run."""

from mcheck import property as mcheck

from .results import ClauseResult, Counterexample

comptime CAUSE_COUNT = 7
comptime CAUSE_NAMES: Array[StaticString, CAUSE_COUNT] = [
    "requires",
    "raised",
    "raise due",
    "wrong type",
    "unrepresentable",
    "planned call",
    "other",
]


__enum Cause(ImplicitlyCopyable, Writable):
    """Why a clause was skipped on an example."""

    case REQUIRES
    case RAISED
    case RAISE_DUE
    case WRONG_TYPE
    case UNREPRESENTABLE
    case PLANNED_CALL
    case OTHER

    def index(self) -> Int:
        return Int(self._get_enum_discriminant())

    def write_to(self, mut writer: Some[Writer]):
        writer.write(materialize[CAUSE_NAMES]()[self.index()])


__enum Verdict(ImplicitlyCopyable):
    """What judging a clause on one example gave. A failure carries what failed, and a
    spec error its message."""

    case PASS
    case FAIL(String)
    case SKIP(Cause)
    case ERROR(String)
    case TIMEOUT
    """A call ran past its time limit, so the example judged nothing."""

    def failed(self) -> Bool:
        match self:
            case .FAIL(_):
                return True
            case _:
                return False

    def note(self) -> String:
        match self:
            case .FAIL(note):
                return note
            case .ERROR(message):
                return message
            case _:
                return ""

    def outcome(self) -> mcheck.Verdict:
        """For mcheck: a skip, a spec error and a timeout neither pass nor fail."""
        match self:
            case .PASS:
                return mcheck.PASSED
            case .FAIL(_):
                return mcheck.FAILED
            case _:
                return mcheck.SKIPPED


struct Tally(Copyable):
    """The verdicts of one clause over a run."""

    var passed: Int
    var failed: Int
    var skipped: Int
    var spec_error: Int
    var inconclusive: Int
    var causes: List[Int]
    """The skips of each cause, by `Cause.index`."""
    var coverage: List[Int]
    """The judged examples in each partition class."""
    var replayed: Bool
    """Whether the first failure came from a stored example."""

    def __init__(out self, *, classes: Int = 0):
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.spec_error = 0
        self.inconclusive = 0
        self.causes = List[Int](length=CAUSE_COUNT, fill=0)
        self.coverage = List[Int](length=classes, fill=0)
        self.replayed = False

    def count(mut self, verdict: Verdict, *, is_replay: Bool):
        match verdict:
            case .PASS:
                self.passed += 1
            case .FAIL(_):
                self.replayed = self.replayed or (is_replay and self.failed == 0)
                self.failed += 1
            case .SKIP(cause):
                self.skipped += 1
                self.causes[cause.index()] += 1
            case .ERROR(_):
                self.spec_error += 1
            case .TIMEOUT:
                self.inconclusive += 1

    def fill(self, mut result: ClauseResult, var counterexample: Optional[Counterexample], failure: String):
        """Puts the counts and the counterexample in `result`, and `failure`, an error
        that stopped the run, as one more spec error."""
        result.passed = self.passed
        result.failed = self.failed
        result.skipped = self.skipped
        result.spec_error = self.spec_error
        result.inconclusive = self.inconclusive
        var names = materialize[CAUSE_NAMES]()
        result.skips = [(String(names[i]), count) for i, count in enumerate(self.causes) if count > 0]
        result.replayed = self.replayed
        result.failing_inputs = max(1, self.failed) if counterexample is not None else self.failed
        result.counterexample = counterexample^
        if failure:
            result.spec_error += 1
            result.spec_errors.append(failure)
