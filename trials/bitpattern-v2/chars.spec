spec chars

# Formal spec of bitpattern 0.3.0's Char codec (section 3.6). Strings that the host can
# hold are scalar value sequences, so the lone surrogates the informal spec rejects cannot
# be passed in.

prelude "chars.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)
  observe head(n: int): list<int> = builtins.list(itertools.islice(self, n))

record Char { width: u8, name: string }
record BDDSet { codec: Char, storage: bitpattern.intset.IntSet }

const bitpattern.codecs.char: Char

fn variant.Char_new(width: u8, name: string) -> Char
  ensures fields: result.width == width and result.name == name

fn variant.Char_char() -> Char
  ensures table: bitpattern.codecs.char.width == 21 and bitpattern.codecs.char.name == "char"

fn bitpattern.codecs.Char.encode(codec: Char, s: string) -> int
  requires codec.width >= 1
  raises ValueError when len(s) != 1 or (len(s) == 1 and cp(s) >= 2 ** codec.width)
  ensures code_point: result == cp(s)

# Non-strings raise TypeError.
fn variant.Char_encode_int(codec: Char, value: int) -> int
  requires codec.width >= 1
  raises TypeError when true

fn bitpattern.codecs.Char.decode(codec: Char, b: int) -> string
  requires b >= 0 and not is_surrogate(b)
  raises IndexError when b > 1114111
  ensures chr: codepoints(result) == [b]

fn bitpattern.codecs.Char.min(codec: Char) -> string
  requires codec.width >= 1
  ensures nul: codepoints(result) == [0]

fn bitpattern.codecs.Char.max(codec: Char) -> string
  requires codec.width >= 1
  ensures largest: codepoints(result) == [limit(codec.width) - 1 - (if limit(codec.width) - 1 >= 55296 and limit(codec.width) - 1 <= 57343 then limit(codec.width) - 55296 else 0)]

fn bitpattern.codecs.Char.dtype(codec: Char) -> "UINT8" | "UINT16" | "UINT32" | "UINT64"
  requires codec.width >= 1
  ensures narrowest_unsigned: result == unsigned_dtype(codec.width)

# all: every code point from 0 to 0x10FFFF that is not a surrogate and fits the width.
fn bitpattern.codecs.Char.all(codec: Char) -> BDDSet
  requires codec.width >= 1
  ensures size: result.storage.size == char_size(codec.width, 0, limit(codec.width))
  ensures width: result.storage.width == codec.width
  ensures no_surrogates: not result.storage.has(55296) and not result.storage.has(57343) and not result.storage.has(1114112)
  ensures table_char: codec.width == 21 implies result.storage.size == 1112064

fn bitpattern.codecs.Char.none(codec: Char) -> BDDSet
  requires codec.width >= 1
  ensures empty: result.storage.size == 0

fn bitpattern.codecs.Char.set(codec: Char, values: list<string>) -> BDDSet
  requires codec.width >= 1
  raises ValueError when exists(s in values: len(s) != 1 or (len(s) == 1 and cp(s) >= 2 ** codec.width))
  ensures members: all(s in values: result.storage.has(cp(s)))
  ensures size: result.storage.size <= len(values)

# range(start, stop): the code points in [ord(start), ord(stop)) without surrogates; the
# bounds must be encodable, and None leaves an end open.
fn bitpattern.codecs.Char.range(codec: Char, start: option<string>, stop: option<string>) -> BDDSet
  requires codec.width >= 1
  raises ValueError when (is_some(start) and (len(unwrap(start)) != 1 or cp(unwrap(start)) >= 2 ** codec.width)) or (is_some(stop) and (len(unwrap(stop)) != 1 or cp(unwrap(stop)) >= 2 ** codec.width))
  ensures size: result.storage.size == char_size(codec.width, if is_none(start) then 0 else cp(unwrap(start)), if is_none(stop) then limit(codec.width) else cp(unwrap(stop)))
  ensures edges: is_some(start) and is_some(stop) and cp(unwrap(start)) < cp(unwrap(stop)) and not is_surrogate(cp(unwrap(start))) implies result.storage.has(cp(unwrap(start))) and not result.storage.has(cp(unwrap(stop)))
  ensures surrogates_skipped: not result.storage.has(55296) and not result.storage.has(56320) and not result.storage.has(57343)
  ensures empty_when_reversed: is_some(start) and is_some(stop) and cp(unwrap(start)) >= cp(unwrap(stop)) implies result.storage.size == 0

# category(name): the characters of a Unicode general category ("Lu") or major class ("L"),
# restricted to all; names are case-sensitive and an unknown name raises ValueError.
fn bitpattern.codecs.Char.category(codec: Char, name: "Lu" | "Ll" | "Lt" | "Lm" | "Lo" | "Mn" | "Mc" | "Me" | "Nd" | "Nl" | "No" | "Pc" | "Pd" | "Ps" | "Pe" | "Pi" | "Pf" | "Po" | "Sm" | "Sc" | "Sk" | "So" | "Zs" | "Zl" | "Zp" | "Cc" | "Cf" | "Cs" | "Co" | "Cn" | "L" | "M" | "N" | "P" | "S" | "Z" | "C" | "lu" | "Xx" | "l" | "") -> BDDSet
  requires codec.width >= 1
  raises ValueError when name == "lu" or name == "Xx" or name == "l" or name == ""
  ensures width: result.storage.width == codec.width
  ensures within_all: result.storage.size <= char_size(codec.width, 0, limit(codec.width))
  ensures surrogates_are_empty: name == "Cs" implies result.storage.size == 0
  ensures ascii: all(c in range(0, imin(128, limit(codec.width))): result.storage.has(c) == in_category(name, c))
  ensures sm_in_ascii: name == "Sm" and codec.width >= 7 implies result.storage.has(43) and result.storage.has(60) and result.storage.has(61) and result.storage.has(62) and result.storage.has(124) and result.storage.has(126) and not result.storage.has(45)
