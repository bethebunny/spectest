"""The options of a run (docs/v2/host-api.md, Options)."""

from wire.value import Value


struct RunOptions(Copyable, Movable):
    var seed: UInt64
    var max_examples: Int
    var exhaustive_limit: Int
    var store: Optional[String]
    var inst_names: List[String]
    var inst_types: List[String]
    """Type arguments of a generic declaration, as the spec writes the types."""
    var examples: List[Value]
    """Explicit inputs, judged before the search: each a MAP from parameter name to
    wire value."""
    var strength: String
    var aggregate_samples: Int
    var steps: Int
    """Calls per step sequence of an interface."""
    var max_handles: Int
    """Objects live at once in a step sequence."""

    def __init__(out self):
        self.seed = 0
        self.max_examples = 100
        self.exhaustive_limit = 65536
        self.store = None
        self.inst_names = List[String]()
        self.inst_types = List[String]()
        self.examples = List[Value]()
        self.strength = String("dev")
        self.aggregate_samples = 10000
        self.steps = 30
        self.max_handles = 2

    def shrink_steps(self) -> Int:
        return 20000 if self.strength == "full" else 5000
