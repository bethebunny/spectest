"""The failure store of stateful runs: a failing step sequence as the choices that
generate it plus the edits that shortened it.

A file holds `c <value> <bound>` per choice, `d <sid>` per deleted step and
`a <sid> <index> <value>` per integer argument that was lowered. The steps are
numbered in the order the choices generate them."""

from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path

from mcheck.choices import Choices

comptime HEADER = "stateful-steps 1"


struct Stored(Movable):
    var choices: Choices
    var deleted: List[Int]
    var arg_sid: List[Int]
    var arg_index: List[Int]
    var arg_value: List[Int]

    def __init__(out self):
        self.choices = Choices()
        self.deleted = List[Int]()
        self.arg_sid = List[Int]()
        self.arg_index = List[Int]()
        self.arg_value = List[Int]()


def _file_name(dir: String, key: String) -> String:
    var name = String()
    for b in key.as_bytes():
        var c = Int(b)
        var plain = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
            or c == ord("_")
        )
        if plain:
            name += chr(c)
        else:
            var hex = "0123456789abcdef"
            name += "." + hex[byte = c // 16 : c // 16 + 1] + hex[byte = c % 16 : c % 16 + 1]
    return dir + "/" + name + ".steps"


def save_stored(dir: String, key: String, stored: Stored) raises:
    makedirs(dir, exist_ok=True)
    var text = String(HEADER, "\n")
    for i in range(len(stored.choices.values)):
        text += String("c ", Int(stored.choices.values[i]), " ", Int(stored.choices.bounds[i]), "\n")
    for sid in stored.deleted:
        text += String("d ", sid, "\n")
    for i in range(len(stored.arg_sid)):
        text += String("a ", stored.arg_sid[i], " ", stored.arg_index[i], " ", stored.arg_value[i], "\n")
    Path(_file_name(dir, key)).write_text(text)


def load_stored(dir: String, key: String) raises -> Optional[Stored]:
    var path = _file_name(dir, key)
    if not exists(path):
        return None
    var lines = Path(path).read_text().split("\n")
    if len(lines) == 0 or String(lines[0]) != HEADER:
        return None
    var out = Stored()
    for line in lines[1:]:
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
