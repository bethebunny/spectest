"""The failure store of stateful runs: a failing step sequence as the choices that
generate it plus the edits that shortened it.

A file holds `c <value> <bound>` per choice, `d <sid>` per deleted step and
`a <sid> <index> <value>` per integer argument that was lowered. The steps are
numbered in the order the choices generate them."""

from std.os import makedirs
from std.pathlib import Path

from mcheck.choices import Choices
from mcheck.store import choice_lines, file_name, lines_after

comptime HEADER = "stateful-steps 1"


@fieldwise_init
struct ArgEdit(Copyable):
    """An integer argument of a step that shrinking lowered."""

    var sid: Int
    var index: Int
    var value: Int


struct Stored(Movable):
    var choices: Choices
    var deleted: List[Int]
    """The steps shrinking deleted."""
    var edits: List[ArgEdit]

    def __init__(out self):
        self.choices = Choices()
        self.deleted = []
        self.edits = []


def save_stored(dir: String, key: String, stored: Stored) raises:
    makedirs(dir, exist_ok=True)
    var text = String(HEADER, "\n", choice_lines(stored.choices))
    for sid in stored.deleted:
        text += String("d ", sid, "\n")
    for edit in stored.edits:
        text += String("a ", edit.sid, " ", edit.index, " ", edit.value, "\n")
    Path(file_name(dir, key, ".steps")).write_text(text)


def load_stored(dir: String, key: String) raises -> Optional[Stored]:
    var lines = lines_after(HEADER, file_name(dir, key, ".steps"))
    if lines is None:
        return None
    var out = Stored()
    for line in lines.value():
        var parts = line.split(" ")
        match String(parts[0]), len(parts):
            case "c", 3:
                out.choices.push(UInt64(atol(parts[1])), UInt64(atol(parts[2])))
            case "d", 2:
                out.deleted.append(atol(parts[1]))
            case "a", 4:
                out.edits.append(ArgEdit(atol(parts[1]), atol(parts[2]), atol(parts[3])))
            case _:
                pass
    return out^
