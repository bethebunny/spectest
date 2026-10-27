spec uuids

# Formal spec of bitpattern 0.3.0's UUID codec (section 3.10).

prelude "uuids.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)

model uuid.UUID
  observe value: int = builtins.getattr(self, "int")
  observe version: option<int> = builtins.getattr(self, "version")
  build support.uuid_from_int(n: int)
  build uuid.uuid4()

record UUIDCodec { width: u8, name: string }
record BDDSet { codec: UUIDCodec, storage: bitpattern.intset.IntSet }

const bitpattern.codecs.uuid128: UUIDCodec

fn variant.UUID_codec() -> UUIDCodec
  ensures table: result.width == 128 and result.name == "uuid128"
  ensures same_constant: result.width == bitpattern.codecs.uuid128.width and result.name == bitpattern.codecs.uuid128.name

fn variant.UUID_dtype() -> "UINT8" | "UINT16" | "UINT32" | "UINT64"
  ensures rows_of_bytes: result == "UINT8"

# encode(u) is u.int, so the order is Python's UUID order; a string is accepted in any form
# uuid.UUID() parses.
fn variant.UUID_encode(u: uuid.UUID) -> int
  ensures integer: result == u.value

fn variant.UUID_encode_text(u: uuid.UUID, style: "plain" | "hex" | "braces" | "urn") -> int
  ensures integer: result == u.value

fn variant.UUID_encode_garbage(text: string) -> int
  raises ValueError when true

# int and bytes are not UUIDs.
fn variant.UUID_encode_int(n: int) -> int
  raises TypeError when true

fn variant.UUID_decode(b: int) -> uuid.UUID
  raises IndexError when b < 0 or b >= 2 ** 128
  ensures integer: result.value == b
  relates roundtrip: variant.UUID_encode(result) == b

# rfc9562: variant bits 10, size 2 ** 126. version(n): version digit n, 1 <= n <= 8, size 2 ** 122.
fn variant.UUID_rfc9562() -> BDDSet
  ensures size: result.storage.size == 2 ** 126
  ensures width: result.storage.width == 128
  ensures members: all(b in [0, 2 ** 62, 2 ** 63, 3 * 2 ** 62, 2 ** 127, 2 ** 127 + 2 ** 63, 2 ** 128 - 1, member_of(4, 0), wrong_variant(4)]: result.storage.has(b) == rfc9562(b))

fn variant.UUID_version(n: i8) -> BDDSet
  raises ValueError when n < 1 or n > 8
  ensures size: result.storage.size == 2 ** 122
  ensures width: result.storage.width == 128
  ensures member: result.storage.has(member_of(n, 0)) and result.storage.has(member_of(n, 2 ** 62 - 1))
  ensures wrong_variant: not result.storage.has(wrong_variant(n))
  ensures wrong_version: not result.storage.has(wrong_version(n))

fn variant.UUID_in_version(u: uuid.UUID, n: i8) -> bool
  raises ValueError when n < 1 or n > 8
  ensures by_bits: result == (uuid_version(u.value) == n and rfc9562(u.value))
  ensures declared_version: result implies u.version == some(n)

# uuid.uuid4() in uuid128.version(4)
fn variant.UUID_uuid4_in_version4() -> bool
  ensures member: result
