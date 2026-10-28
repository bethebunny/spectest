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


def choice_lines(choices: Choices) -> String:
    """A `c <value> <bound>` line per choice."""
    var text = String()
    for value, bound in zip(choices.values, choices.bounds):
        text.write("c ", Int(value), " ", Int(bound), "\n")
    return text^


def lines_after(header: StringSlice, path: String) raises -> Optional[List[String]]:
    """The lines of the file at `path` after its first, which is `header`. None when
    there is no file or it starts with another line."""
    if not exists(path):
        return None
    var text = Path(path).read_text()
    var lines = text.split("\n")
    if lines[0] != header:
        return None
    var rest = [String(line) for line in lines[1:]]
    return rest^


def store_save(dir: String, key: String, choices: Choices) raises:
    makedirs(dir, exist_ok=True)
    var text = String(HEADER, "\n", choice_lines(choices))
    for s in choices.spans:
        text.write("s ", s.start, " ", s.end, " ", s.label, "\n")
    Path(file_name(dir, key, ".choices")).write_text(text)


def store_load(dir: String, key: String) raises -> Optional[Choices]:
    var lines = lines_after(HEADER, file_name(dir, key, ".choices"))
    if lines is None:
        return None
    var out = Choices()
    for line in lines.value():
        var parts = line.split(" ")
        if len(parts) == 3 and parts[0] == "c":
            out.push(UInt64(atol(parts[1])), UInt64(atol(parts[2])))
        elif len(parts) == 4 and parts[0] == "s":
            out.spans.append(Span(atol(parts[1]), atol(parts[2]), atol(parts[3])))
    return out^
