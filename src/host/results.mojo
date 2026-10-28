"""The results of a run, in the shape of docs/v2/host-api.md, and their conversion to
a `Value` tree (maps with string keys, lists, ints, strings, bools and f64 floats)
that the bridge turns into Python dicts and lists."""

from std.memory import bitcast

from value.float_formats import F64
from value.value import Value


struct Obj(Defaultable, Movable):
    """An ordered map under construction."""

    var keys: List[Value]
    var values: List[Value]

    def put(mut self, key: String, var value: Value):
        self.keys.append(Value.string(key))
        self.values.append(value^)

    def text(mut self, key: String, value: String):
        self.put(key, Value.string(value))

    def num(mut self, key: String, value: Int):
        self.put(key, Value.int(value))

    def flag(mut self, key: String, value: Bool):
        self.put(key, Value.bool(value))

    def real(mut self, key: String, value: Float64):
        self.put(key, Value.float(F64, bitcast[DType.uint64](value)))

    def build(deinit self) raises -> Value:
        return Value.map(self.keys^, self.values^)


def strings(items: List[String]) -> Value:
    return Value.list([Value.string(s) for s in items])


def _texts(pairs: List[Tuple[String, String]]) raises -> Value:
    var o = Obj()
    for key, text in pairs:
        o.text(key, text)
    return o^.build()


def _counts(pairs: List[Tuple[String, Int]]) raises -> Value:
    var o = Obj()
    for key, count in pairs:
        o.num(key, count)
    return o^.build()


def _pair_list(pairs: List[Tuple[String, String]]) -> Value:
    return Value.list([Value.list([Value.string(a), Value.string(b)]) for a, b in pairs])


struct Counterexample(Copyable, Defaultable):
    var inputs: List[Tuple[String, String]]
    """Each parameter and its value."""
    var observation: String
    var partitions: List[Tuple[String, String]]
    """Each partitioned parameter and the class of its value."""
    var explanation: List[Tuple[String, String]]
    """Each subexpression and its value."""
    var seed: Int
    var reproduce: String

    def to_value(self) raises -> Value:
        var o = Obj()
        o.put("inputs", _texts(self.inputs))
        o.text("observation", self.observation)
        o.put("partitions", _texts(self.partitions))
        o.put("explanation", _pair_list(self.explanation))
        o.num("seed", self.seed)
        o.text("reproduce", self.reproduce)
        return o^.build()


struct AggregateSummary(Copyable, Defaultable):
    var value: String
    var bound: String
    var evaluated: Int
    var skipped: Int
    var total: Int
    var sampled: Bool
    var worst: List[Tuple[String, String]]
    """The members with the largest terms, and their terms."""

    def to_value(self) raises -> Value:
        var o = Obj()
        o.text("value", self.value)
        o.text("bound", self.bound)
        o.num("evaluated", self.evaluated)
        o.num("skipped", self.skipped)
        o.num("total", self.total)
        o.flag("sampled", self.sampled)
        o.put("worst", _pair_list(self.worst))
        return o^.build()


struct ClauseResult(Copyable, Movable):
    var clause_id: String
    var clause_text: String
    var kind: String
    var decl: String
    var instantiation: List[Tuple[String, String]]
    """Each type parameter and the type the run gave it."""
    var mode: String
    var passed: Int
    var failed: Int
    var skipped: Int
    var spec_error: Int
    var inconclusive: Int
    var coverage: List[Tuple[String, Int]]
    """Each partition class, as `param: class`, and its count."""
    var counterexample: Optional[Counterexample]
    var failing_inputs: Int
    var spec_errors: List[String]
    var aggregate: Optional[AggregateSummary]
    var replayed: Bool
    var skips: List[Tuple[String, Int]]
    """Each skip cause and its count."""
    var duration: Float64

    def __init__(out self, var clause_id: String, var clause_text: String, var kind: String, var decl: String):
        self.clause_id = clause_id^
        self.clause_text = clause_text^
        self.kind = kind^
        self.decl = decl^
        self.instantiation = []
        self.mode = "hypothesis"
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.spec_error = 0
        self.inconclusive = 0
        self.coverage = []
        self.counterexample = None
        self.failing_inputs = 0
        self.spec_errors = []
        self.aggregate = None
        self.replayed = False
        self.skips = []
        self.duration = 0.0

    def to_value(self) raises -> Value:
        var counts = Obj()
        counts.num("pass", self.passed)
        counts.num("fail", self.failed)
        counts.num("skip", self.skipped)
        counts.num("spec_error", self.spec_error)
        counts.num("inconclusive", self.inconclusive)
        var o = Obj()
        o.text("item_id", "")
        o.text("clause_id", self.clause_id)
        o.text("clause_text", self.clause_text)
        o.text("kind", self.kind)
        o.text("decl", self.decl)
        o.put("instantiation", _texts(self.instantiation))
        o.text("mode", self.mode)
        o.put("counts", counts^.build())
        o.put("coverage", _counts(self.coverage))
        o.put("counterexample", self.counterexample.value().to_value() if self.counterexample is not None else Value.none())
        o.num("failing_inputs", self.failing_inputs)
        o.put("spec_errors", strings(self.spec_errors))
        o.put("failing_examples", Value.list([]))
        o.put("aggregate", self.aggregate.value().to_value() if self.aggregate is not None else Value.none())
        o.flag("replayed", self.replayed)
        o.put("skips", _counts(self.skips))
        o.real("duration", self.duration)
        return o^.build()


struct RunResult(Movable):
    var decl: String
    var mode: String
    """"search", "exhaustive" or "replay"."""
    var examples: Int
    var invalid: Int
    var seconds: Float64
    var clauses: List[ClauseResult]

    def __init__(out self, var decl: String):
        self.decl = decl^
        self.mode = "search"
        self.examples = 0
        self.invalid = 0
        self.seconds = 0.0
        self.clauses = []

    def to_value(self) raises -> Value:
        var o = Obj()
        o.text("decl", self.decl)
        o.text("mode", self.mode)
        o.num("examples", self.examples)
        o.num("invalid", self.invalid)
        o.real("seconds", self.seconds)
        o.put("clauses", Value.list([c.to_value() for c in self.clauses]))
        return o^.build()
