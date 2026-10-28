"""The options of a run (docs/v2/host-api.md, Options)."""

from mcheck.settings import Settings
from value.value import Value

from .load import fnv


struct RunOptions(Copyable, Movable):
    var seed: UInt64
    var max_examples: Int
    var exhaustive_limit: Int
    var store: Optional[String]
    var instantiation: Dict[String, String]
    """Each type parameter of a generic declaration and its type, as the spec writes types."""
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
        self.instantiation = {}
        self.examples = []
        self.strength = "dev"
        self.aggregate_samples = 10000
        self.steps = 30
        self.max_handles = 2

    def settings(self, decl: String) -> Settings:
        """The search settings of a run of `decl`, seeded by the run's seed and the name."""
        var settings = Settings()
        settings.seed = fnv(String(self.seed, ":", decl))
        settings.max_examples = self.max_examples
        settings.max_shrink_steps = 20000 if self.strength == "full" else 5000
        return settings^

    def store_key(self, spec_hash: String, clause_id: String) -> String:
        """Where the failure store keeps a failure of the clause under this instantiation."""
        var key = String(spec_hash, "/", clause_id)
        for e in self.instantiation.items():
            key += String(t"[{e.key}={e.value}]")
        return key^
