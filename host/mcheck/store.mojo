"""The failure store: one small text file per key, holding a choice sequence."""

from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path

from .choices import Choices, Span

comptime HEADER = "mcheck-choices 1"
comptime PLAIN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"


def file_name(dir: String, key: String, suffix: String) -> String:
    """`dir`/`key` with every byte outside `PLAIN` escaped as `.` and two hex digits."""
    var name = String()
    for b in key.as_bytes():
        var c = chr(Int(b))
        name += c if c in PLAIN else String(".", hex(b, prefix="").ascii_rjust(2, "0"))
    return String(dir, "/", name, suffix)


def store_save(dir: String, key: String, choices: Choices) raises:
    makedirs(dir, exist_ok=True)
    var text = String(HEADER, "\n")
    for value, bound in zip(choices.values, choices.bounds):
        text += String("c ", Int(value), " ", Int(bound), "\n")
    for s in choices.spans:
        text += String("s ", s.start, " ", s.end, " ", s.label, "\n")
    Path(file_name(dir, key, ".choices")).write_text(text)


def store_load(dir: String, key: String) raises -> Optional[Choices]:
    var path = file_name(dir, key, ".choices")
    if not exists(path):
        return None
    var lines = Path(path).read_text().split("\n")
    if len(lines) == 0 or String(lines[0]) != HEADER:
        return None
    var out = Choices()
    for line in lines[1:]:
        var parts = line.split(" ")
        if len(parts) == 3 and parts[0] == "c":
            out.push(UInt64(atol(parts[1])), UInt64(atol(parts[2])))
        elif len(parts) == 4 and parts[0] == "s":
            out.spans.append(Span(atol(parts[1]), atol(parts[2]), atol(parts[3])))
    return out^
