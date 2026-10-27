spec enums

# Formal spec of bitpattern 0.3.0's Members and Flags codecs (section 3.11), over the enums
# of support.py: Color (RED, GREEN, BLUE and CRIMSON, an alias of RED), Level (an IntEnum),
# Single (one member), Empty (none), and the Flags Perm (R=4, W=2, X=1) and Tree (LEAF=4,
# CHAIN=12, LOW=1). Enum members cross as their names (a Flag as its value), and the sets
# as their storage IntSet.

prelude "enums.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)
  observe head(n: int): list<int> = builtins.list(itertools.islice(self, n))

# -- Members -----------------------------------------------------------------------

# width == max(len(enum_cls) - 1, 0).bit_length(); the name is the enum's __name__.
fn variant.Members_codec(kind: "Color" | "Level" | "Single" | "Empty") -> (int, string)
  ensures width: result.0 == members_width(kind)
  ensures name: result.1 == kind

# Each member is encoded as its definition index; an alias encodes to its canonical member's.
fn variant.Members_encode(kind: "Color" | "Level" | "Single", index: u8) -> int
  requires index < member_count(kind)
  ensures definition_index: result == index

fn variant.Members_encode_alias() -> int
  ensures canonical: result == 0

# A value that is not an instance of the enum raises TypeError: the member's raw value, or
# an IntEnum's plain int. A Flag combination that is not a member is a ValueError.
fn variant.Members_encode_raw(kind: "Color" | "Level", index: u8) -> int
  requires index < member_count(kind)
  raises TypeError when true

fn variant.Members_encode_unlisted_combination() -> int
  raises ValueError when true

fn variant.Members_decode(kind: "Color" | "Level" | "Single", i: int) -> string
  requires i >= 0
  raises IndexError when i >= member_count(kind)
  ensures member: result == member_names(kind)[i]

fn variant.Members_dtype(kind: "Color" | "Level" | "Single" | "Empty") -> "UINT8" | "UINT16" | "UINT32" | "UINT64"
  ensures narrowest_unsigned: result == "UINT8"

# all is the indices [0, len); a set holds the indices of its members.
fn variant.Members_all(kind: "Color" | "Level" | "Single" | "Empty") -> bitpattern.intset.IntSet
  ensures indices: result.size == member_count(kind)
  ensures members: result.head(8) == range(0, member_count(kind))
  ensures width: result.width == members_width(kind)

fn variant.Members_set(kind: "Color" | "Level" | "Single", picks: list<u8>) -> bitpattern.intset.IntSet
  ensures indices: result.head(8) == chosen(kind, picks)
  ensures width: result.width == members_width(kind)

# Sets iterate in definition order.
fn variant.Members_iterate(kind: "Color" | "Level" | "Single", picks: list<u8>) -> list<string>
  ensures definition_order: result == map(i in chosen(kind, picks): member_names(kind)[i])

# ~s is the complement within the legal members: ~Members(Color).set([GREEN]) is {RED, BLUE}.
fn variant.Members_invert(kind: "Color" | "Level" | "Single", picks: list<u8>) -> bitpattern.intset.IntSet
  ensures within_legal: result.head(8) == filter(i in range(0, member_count(kind)): not (i in chosen(kind, picks)))

# Sets export the indices, not the values, even for an IntEnum.
fn variant.Members_exported(kind: "Color" | "Level" | "Single", picks: list<u8>) -> (string, list<int>, list<int>)
  requires len(chosen(kind, picks)) > 0
  ensures dtype: result.0 == "uint8"
  ensures indices: result.2 == chosen(kind, picks)

# -- Flags -------------------------------------------------------------------------

# width is the bit length of the largest member value, multi-bit members included.
fn variant.Flags_codec(kind: "Perm" | "Tree") -> (int, string)
  ensures width: result.0 == flags_width(kind)
  ensures name: result.1 == kind

# all: every value that is a union of members, including the empty value; sets iterate in
# order of value.
fn variant.Flags_all(kind: "Perm" | "Tree") -> bitpattern.intset.IntSet
  ensures unions: result.head(16) == flag_all(kind)
  ensures width: result.width == flags_width(kind)

# A combination is encoded as its own integer value; a plain int is not an instance.
fn variant.Flags_encode(kind: "Perm" | "Tree", names: list<"R" | "W" | "X" | "LEAF" | "CHAIN" | "LOW">) -> int
  requires valid_names(kind, names)
  ensures value: result == mask_of(names)

fn variant.Flags_encode_int(kind: "Perm" | "Tree", n: u8) -> int
  raises TypeError when true

fn variant.Flags_decode(kind: "Perm" | "Tree", b: u8) -> int
  requires b in flag_all(kind)
  ensures value: result == b

# having(flags): the members of all with every bit of flags set; lacking(flags): those with
# none of them set; both are all for the empty flag.
fn variant.Flags_having(kind: "Perm" | "Tree", names: list<"R" | "W" | "X" | "LEAF" | "CHAIN" | "LOW">) -> bitpattern.intset.IntSet
  requires valid_names(kind, names)
  ensures with_every_bit: result.head(16) == filter(v in flag_all(kind): (v >> 0) % 2 >= (mask_of(names) >> 0) % 2 and (v >> 1) % 2 >= (mask_of(names) >> 1) % 2 and (v >> 2) % 2 >= (mask_of(names) >> 2) % 2 and (v >> 3) % 2 >= (mask_of(names) >> 3) % 2)
  ensures empty_is_all: len(names) == 0 implies result.head(16) == flag_all(kind)
  ensures write_permission: kind == "Perm" and len(names) == 1 and names[0] == "W" implies result.head(16) == [2, 3, 6, 7]

fn variant.Flags_lacking(kind: "Perm" | "Tree", names: list<"R" | "W" | "X" | "LEAF" | "CHAIN" | "LOW">) -> bitpattern.intset.IntSet
  requires valid_names(kind, names)
  ensures with_none_of_the_bits: result.head(16) == filter(v in flag_all(kind): (v >> 0) % 2 + (mask_of(names) >> 0) % 2 < 2 and (v >> 1) % 2 + (mask_of(names) >> 1) % 2 < 2 and (v >> 2) % 2 + (mask_of(names) >> 2) % 2 < 2 and (v >> 3) % 2 + (mask_of(names) >> 3) % 2 < 2)
  ensures empty_is_all: len(names) == 0 implies result.head(16) == flag_all(kind)
