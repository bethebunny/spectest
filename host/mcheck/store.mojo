"""The failure store: one small text file per key, holding a choice sequence."""

from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path

from .choices import Choices, Span

comptime HEADER = "mcheck-choices 1"


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
    return dir + "/" + name + ".choices"


def store_save(dir: String, key: String, choices: Choices) raises:
    makedirs(dir, exist_ok=True)
    var text = String(HEADER, "\n")
    for i in range(len(choices.values)):
        text += String("c ", Int(choices.values[i]), " ", Int(choices.bounds[i]), "\n")
    for s in choices.spans:
        text += String("s ", s.start, " ", s.end, " ", s.label, "\n")
    Path(_file_name(dir, key)).write_text(text)


def store_load(dir: String, key: String) raises -> Optional[Choices]:
    var path = _file_name(dir, key)
    if not exists(path):
        return None
    var lines = Path(path).read_text().split("\n")
    if len(lines) == 0 or String(lines[0]) != HEADER:
        return None
    var out = Choices()
    for line in lines[1:]:
        var parts = line.split(" ")
        if len(parts) == 3 and String(parts[0]) == "c":
            out.push(UInt64(atol(parts[1])), UInt64(atol(parts[2])))
        elif len(parts) == 4 and String(parts[0]) == "s":
            out.spans.append(Span(atol(parts[1]), atol(parts[2]), atol(parts[3])))
    return out^
