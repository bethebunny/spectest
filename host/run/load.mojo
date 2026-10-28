"""Loading a spec: parse, check, compile partitions."""

from std.pathlib import Path

from specfile.checker import check_source_with
from specfile.files import Files
from spec.spec import Spec
from gen.sizes import Sizes
from value.digits import hex_digits
from partition.coverage import PartitionSets, compile_partitions
from partition.sets import SetContext


def fnv(text: String, seed: UInt64 = 0xCBF29CE484222325) -> UInt64:
    """FNV-1a over the bytes of `text`; stable across runs, unlike a process hash."""
    var h = seed
    for b in text.as_bytes():
        h = (h ^ UInt64(b)) * 0x100000001B3
    return h


struct Loaded(Movable):
    """A checked spec with its partition sets, ready to run."""

    var path: String
    var hash: String
    """Of the source text; keys the failure store."""
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
    """Raises the diagnostics, one `path:line:col: message` per line."""
    return load_with(source, path, Files())


def load_with(source: String, path: String, files: Files) raises -> Loaded:
    """`load_source` reading the spec's files through `files` (the hash covers each)."""
    var spec = check_source_with(source, path, files)
    var ctx = SetContext()
    var sets = compile_partitions(ctx, spec)
    ref text = spec.ast.source
    # Two offset bases make the hash 128 bits.
    var hash = String(hex_digits(fnv(text), width=16), hex_digits(fnv(text, 0x84222325CBF29CE4), width=16))
    return Loaded(path, hash^, spec^, ctx^, sets^)


def load(path: String) raises -> Loaded:
    return load_source(Path(path).read_text(), path)
