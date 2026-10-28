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


struct Stored(Movable):
    var choices: Choices
    var deleted: List[Int]
    var arg_sid: List[Int]
    var arg_index: List[Int]
    var arg_value: List[Int]

    def __init__(out self):
        self.choices = Choices()
        self.deleted = []
        self.arg_sid = []
        self.arg_index = []
        self.arg_value = []


def save_stored(dir: String, key: String, stored: Stored) raises:
    makedirs(dir, exist_ok=True)
    var text = String(HEADER, "\n", choice_lines(stored.choices))
    for sid in stored.deleted:
        text += String("d ", sid, "\n")
    for sid, index, value in zip(stored.arg_sid, stored.arg_index, stored.arg_value):
        text += String("a ", sid, " ", index, " ", value, "\n")
    Path(file_name(dir, key, ".steps")).write_text(text)


def load_stored(dir: String, key: String) raises -> Optional[Stored]:
    var lines = lines_after(HEADER, file_name(dir, key, ".steps"))
    if lines is None:
        return None
    var out = Stored()
    for line in lines.value():
        var parts = line.split(" ")
        if len(parts) == 3 and String(parts[0]) == "c":
            out.choices.push(UInt64(atol(parts[1])), UInt64(atol(parts[2])))
        elif len(parts) == 2 and String(parts[0]) == "d":
            out.deleted.append(atol(parts[1]))
        elif len(parts) == 4 and String(parts[0]) == "a":
            out.arg_sid.append(atol(parts[1]))
            out.arg_index.append(atol(parts[2]))
            out.arg_value.append(atol(parts[3]))
    return out^
