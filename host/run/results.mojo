"""The results of a run, in the shape of docs/v2/host-api.md, and their conversion to
a `Value` tree (maps with string keys, lists, ints, strings, bools and f64 floats)
that the bridge turns into Python dicts and lists."""

from std.memory import bitcast

from numeric.formats import F64
from wire.value import Value


struct Obj(Movable):
    """An ordered map under construction."""

    var keys: List[Value]
    var vals: List[Value]

    def __init__(out self):
        self.keys = []
        self.vals = []

    def put(mut self, key: String, var value: Value):
        self.keys.append(Value.string(key))
        self.vals.append(value^)

    def text(mut self, key: String, value: String):
        self.put(key, Value.string(value))

    def num(mut self, key: String, value: Int):
        self.put(key, Value.int(value))

    def flag(mut self, key: String, value: Bool):
        self.put(key, Value.bool(value))

    def real(mut self, key: String, value: Float64):
        self.put(key, Value.float(F64, bitcast[DType.uint64](value)))

    def build(deinit self) raises -> Value:
        return Value.map(self.keys^, self.vals^)


def strings(items: List[String]) -> Value:
    return Value.list([Value.string(s) for s in items])


def counted(names: List[String], counts: List[Int]) raises -> Value:
    var o = Obj()
    for name, count in zip(names, counts):
        o.num(name, count)
    return o^.build()


def _texts(names: List[String], values: List[String]) raises -> Value:
    var o = Obj()
    for name, value in zip(names, values):
        o.text(name, value)
    return o^.build()


def _string_pairs(firsts: List[String], seconds: List[String]) -> Value:
    return Value.list([Value.list([Value.string(a), Value.string(b)]) for a, b in zip(firsts, seconds)])


struct Counterexample(Copyable, Movable):
    var input_names: List[String]
    var input_values: List[String]
    var observation: String
    var part_names: List[String]
    var part_classes: List[String]
    var expl_source: List[String]
    var expl_value: List[String]
    var seed: Int
    var reproduce: String

    def __init__(out self):
        self.input_names = []
        self.input_values = []
        self.observation = ""
        self.part_names = []
        self.part_classes = []
        self.expl_source = []
        self.expl_value = []
        self.seed = 0
        self.reproduce = ""

    def to_value(self) raises -> Value:
        var o = Obj()
        o.put("inputs", _texts(self.input_names, self.input_values))
        o.text("observation", self.observation)
        o.put("partitions", _texts(self.part_names, self.part_classes))
        o.put("explanation", _string_pairs(self.expl_source, self.expl_value))
        o.num("seed", self.seed)
        o.text("reproduce", self.reproduce)
        return o^.build()


struct AggregateSummary(Copyable, Movable):
    var value: String
    var bound: String
    var evaluated: Int
    var skipped: Int
    var total: Int
    var sampled: Bool
    var worst_members: List[String]
    var worst_terms: List[String]

    def __init__(out self):
        self.value = ""
        self.bound = ""
        self.evaluated = 0
        self.skipped = 0
        self.total = 0
        self.sampled = False
        self.worst_members = []
        self.worst_terms = []

    def to_value(self) raises -> Value:
        var o = Obj()
        o.text("value", self.value)
        o.text("bound", self.bound)
        o.num("evaluated", self.evaluated)
        o.num("skipped", self.skipped)
        o.num("total", self.total)
        o.flag("sampled", self.sampled)
        o.put("worst", _string_pairs(self.worst_members, self.worst_terms))
        return o^.build()


struct ClauseResult(Copyable, Movable):
    var clause_id: String
    var clause_text: String
    var kind: String
    var decl: String
    var instantiation_names: List[String]
    var instantiation_types: List[String]
    var mode: String
    var passed: Int
    var failed: Int
    var skipped: Int
    var spec_error: Int
    var inconclusive: Int
    var coverage_names: List[String]
    var coverage_counts: List[Int]
    var counterexample: Optional[Counterexample]
    var failing_inputs: Int
    var spec_errors: List[String]
    var aggregate: Optional[AggregateSummary]
    var replayed: Bool
    var skip_names: List[String]
    var skip_counts: List[Int]
    var duration: Float64

    def __init__(out self, var clause_id: String, var clause_text: String, var kind: String, var decl: String):
        self.clause_id = clause_id^
        self.clause_text = clause_text^
        self.kind = kind^
        self.decl = decl^
        self.instantiation_names = []
        self.instantiation_types = []
        self.mode = "hypothesis"
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.spec_error = 0
        self.inconclusive = 0
        self.coverage_names = []
        self.coverage_counts = []
        self.counterexample = None
        self.failing_inputs = 0
        self.spec_errors = []
        self.aggregate = None
        self.replayed = False
        self.skip_names = []
        self.skip_counts = []
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
        o.put("instantiation", _texts(self.instantiation_names, self.instantiation_types))
        o.text("mode", self.mode)
        o.put("counts", counts^.build())
        o.put("coverage", counted(self.coverage_names, self.coverage_counts))
        o.put("counterexample", self.counterexample.value().to_value() if self.counterexample is not None else Value.none())
        o.num("failing_inputs", self.failing_inputs)
        o.put("spec_errors", strings(self.spec_errors))
        o.put("failing_examples", Value.list(List[Value]()))
        o.put("aggregate", self.aggregate.value().to_value() if self.aggregate is not None else Value.none())
        o.flag("replayed", self.replayed)
        o.put("skips", counted(self.skip_names, self.skip_counts))
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
