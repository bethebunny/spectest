spec binary

# Fixed-width integer packing and UTF-8 text codecs.

error StructError
error DecodeError

fn pack_i32(x: i64) -> bytes
  partition x
    in_range  = i64.range(i32.min, i32.max + 1)
    too_small = i64.range(none, i32.min)
    too_large = i64.range(i32.max + 1, none)
  raises StructError when not fits<i32>(x)
  ensures length: len(result) == 4
  ensures little_endian: le_uint(result) == wrap<u32>(x)
  relates roundtrip: unpack_i32(result) == x

fn unpack_i32(b: bytes) -> i32
  partition b
    four  = len(b) == 4
    other = len(b) != 4
  raises StructError when len(b) != 4
  ensures value: wrap<u32>(result) == le_uint(b)

fn utf8_encode(s: string) -> bytes
  ensures valid: valid_utf8(result)
  ensures length: len(result) == sum(c in codepoints(s):
    if c < 0x80 then 1 else if c < 0x800 then 2 else if c < 0x10000 then 3 else 4)
  relates roundtrip: utf8_decode(result) == s

fn utf8_decode(b: bytes) -> string
  partition b
    valid   = valid_utf8(b)
    invalid = not valid_utf8(b)
  raises DecodeError when not valid_utf8(b)
  relates roundtrip: utf8_encode(result) == b
