"""Settings for search, shrinking and enumeration."""


struct Settings(Copyable, Movable):
    var seed: UInt64
    var max_examples: Int
    var max_shrink_steps: Int
    var max_choices: Int
    var max_exhaustive: Int
    var store_dir: Optional[String]
    """Where failures are saved and loaded; none means no store."""
    var keys: List[String]
    """Store keys. Search replays what is stored under every key first, and saves
    the shrunk failure of property `i` under `keys[i]` (when there is one)."""

    def __init__(out self):
        self.seed = 0
        self.max_examples = 100
        self.max_shrink_steps = 1000
        self.max_choices = 10000
        self.max_exhaustive = 100000
        self.store_dir = None
        self.keys = List[String]()
