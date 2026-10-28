"""Bounds on generated values."""


struct Sizes(Copyable, Movable):
    """Bounds on generated collections: top-level lists, nested lists, text, bytes.

    A `long_share` of top-level lists, strings and bytes (arguments and build
    arguments, not their elements) is long: from twice the short bound plus one up to
    the `long_*` bound. `long_share = 0` turns long values off.
    """

    var max_list: Int
    var max_inner: Int
    var max_text: Int
    var max_bytes: Int
    var long_list: Int
    var long_text: Int
    var long_bytes: Int
    var long_share: Float64
    var max_model_depth: Int
    """How deep a build argument of model type may nest before builds without one are
    preferred."""

    def __init__(out self):
        self.max_list = 8
        self.max_inner = 4
        self.max_text = 12
        self.max_bytes = 16
        self.long_list = 100
        self.long_text = 100
        self.long_bytes = 100
        self.long_share = 1.0 / 16.0
        self.max_model_depth = 3

    def long_lo(self, short: Int) -> Int:
        return 2 * short + 1

    def has_long(self, short: Int, *, long: Int) -> Bool:
        return self.long_share > 0.0 and long >= self.long_lo(short)
