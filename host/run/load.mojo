"""Loading a spec: parse, check, compile partitions."""

from std.pathlib import Path

from check.checker import check_source
from check.spec import Spec
from partitions.check import PartitionSets, compile_partitions
from sets import SetContext

from gen.sizes import Sizes


def fnv(text: String, seed: UInt64 = 0xCBF29CE484222325) -> UInt64:
    """FNV-1a over the bytes of `text`; stable across runs, unlike a process hash."""
    var h = seed
    for b in text.as_bytes():
        h = (h ^ UInt64(b)) * 0x100000001B3
    return h


def hex16(v: UInt64) -> String:
    var digits = "0123456789abcdef"
    var out = String()
    for i in range(15, -1, -1):
        var d = Int((v >> UInt64(4 * i)) & 15)
        out += digits[byte=d : d + 1]
    return out^


struct Loaded(Movable):
    """A checked spec with its partition sets, ready to run."""

    var path: String
    var hash: String
    """A hash of the source text, in the keys of the failure store."""
    var spec: Spec
    var ctx: SetContext
    var sets: PartitionSets
    var sizes: Sizes

    def __init__(
        out self,
        var path: String,
        var hash: String,
        var spec: Spec,
        var ctx: SetContext,
        var sets: PartitionSets,
    ):
        self.path = path^
        self.hash = hash^
        self.spec = spec^
        self.ctx = ctx^
        self.sets = sets^
        self.sizes = Sizes()


def load_source(source: String, path: String) raises -> Loaded:
    """Check `source` and compile its partitions. Raises with the diagnostics, one
    `path:line:col: message` per line."""
    var spec = check_source(source, path)
    var ctx = SetContext()
    var sets = compile_partitions(ctx, spec)
    var hash = hex16(fnv(source)) + hex16(fnv(source, 0x84222325CBF29CE4))
    return Loaded(path, hash^, spec^, ctx^, sets^)


def load(path: String) raises -> Loaded:
    """Parse and check the spec file at `path` and compile its partitions."""
    return load_source(Path(path).read_text(), path)
