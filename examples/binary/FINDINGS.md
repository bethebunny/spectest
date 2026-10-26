# binary findings

This file records what spectest found when it ran binary.spec against five targets:

- Python's struct module and the str/bytes UTF-8 codecs
- int.to_bytes and int.from_bytes
- numpy 2.x
- three seeded bugs
- one off-by-one bug, as an exploration

Each finding gives the clause, the counterexample, an independent check, and why it violates the spec. The plain test functions at the end of examples/binary/test_binary.py check every counterexample with plain Python, without spectest. The spec changed once: `utf8_encode.length` first bounded the length (`len(s) <= len(result) <= 4 * len(s)`), and now states the exact UTF-8 length through the prelude's `codepoints` (section 4).

Environment: Python 3.13.9, numpy 2.5.4, Hypothesis 6.170.9, x86-64 Linux. Unless stated otherwise, the counterexamples come from seed 0 with max_examples=500 (the REPORT.md run).

## 1. int.from_bytes reads any length (test_int_bytes: unpack_i32#1, unpack_i32.value, unpack_i32#type)

**What happens.** The adapter is `int.from_bytes(b, "little", signed=True)`. It has no fixed width: it reads a byte string of any length as one integer, and it never raises. binary.spec's `unpack_i32` has `raises StructError when len(b) != 4`. This is a mismatch between the adapter and the spec, not a CPython bug: int.from_bytes is documented to accept any length.

**One cause, three failing clauses:**
- `unpack_i32#1` (`raises StructError when len(b) != 4`): b = b"" returns 0 instead of raising.
- `unpack_i32.value` (`wrap<u32>(result) == le_uint(b)`): b = b"\x80" returns -128. wrap<u32>(-128) is 4294967168, but le_uint(b) is 128.
  - The language judges an `ensures` whenever the call returns normally. So a call that should have raised, and returned instead, is also held to the value clause. The counterexample says so: `note: unpack_i32#1 required StructError on this input`.
- `unpack_i32#type`: b = b"\x00\x00\x00\x00\x01" returns 4294967296 (2^32), which is not an i32.

**What passes.**
- On 4-byte input the adapter agrees with `struct.unpack("<i", b)`. This was checked on boundary values and 2,000 random buffers.
- The pack side, `x.to_bytes(4, "little", signed=True)`, raises OverflowError ("int too big to convert") out of range. Mapped to StructError, every pack_i32 clause passes.

**Independent check.** These plain tests confirm each counterexample and that struct raises for every length but 4:
- `test_int_from_bytes_reads_any_length`
- `test_struct_rejects_every_length_but_four`
- `test_int_to_bytes_raises_overflow_error_out_of_range`

**Decision.** The three clauses are in test_int_bytes's expect_fail. An adapter that fits the spec checks `len(b) == 4` first.

## 2. numpy.frombuffer reads the first of several i32s (test_numpy: unpack_i32#1, unpack_i32.value)

**What numpy 2.5.4 does.**

| Input | Behaviour | Mapped to |
| --- | --- | --- |
| pack, x outside i32 (including the i64 extremes) | `numpy.array([x], dtype="<i4")` raises OverflowError: "Python integer 2147483648 out of bounds for int32" | StructError |
| pack, x in range | the same 4 bytes as struct.pack("<i", x) | |
| unpack, len(b) = 0 | `frombuffer` gives an empty array, so `[0]` raises IndexError: "index 0 is out of bounds for axis 0 with size 0" | StructError |
| unpack, len(b) = 1-3, 5-7, 9-11, 13-15 | ValueError: "buffer size must be a multiple of element size" | StructError |
| unpack, len(b) = 4 | the i32 as numpy.int32, equal to struct.unpack | |
| unpack, len(b) = 8, 12, 16 | returns the first element, struct.unpack("<i", b[:4])[0], without raising | |

The errors mapping is {OverflowError, ValueError, IndexError} → StructError. All three mean "not an i32" or "not 4 bytes" here. With that mapping, the only violations are the lengths that are multiples of 4 above 4:

- `unpack_i32#1`: b = 8 zero bytes returns 0.
  - 12 and 16 zero bytes fail the same way. Earlier runs reported 16 (see the harness notes).
- `unpack_i32.value`: b = `bytes(7) + b"\x01"` returns 0, but le_uint(b) is 2^56.
  - Any 8-, 12- or 16-byte buffer whose bytes after the first four are not all zero fails. Earlier runs reported b"\xf0\x90\x80\x80\xf0\x90\x80\x80", which returns -2139057936: wrap<u32>(result) is 2155909360, but le_uint(b) is 9259560196496199920.
- `unpack_i32#type` passes, because the result is always a numpy.int32.

**Independent check.**
- `test_numpy_array_raises_overflow_error_out_of_range`
- `test_numpy_frombuffer_by_length` covers every length from 0 to 16.
- `test_numpy_unpack_counterexamples`

**Decision.** This is how the adapter really behaves: frombuffer reads an array, and `[0]` picks its first element. Both clauses are in test_numpy's expect_fail. An adapter that fits the spec checks `len(b) == 4`.

## 3. struct and the codecs pass every clause (test_struct)

All 19 items pass at 500 examples. A deeper run with 5,000 examples per item (seed 11, about 6 minutes) found no failure in test_struct, and none in test_int_bytes or test_numpy beyond findings 1 and 2.

**The oracle was the implementation.** spectest's `valid_utf8` was implemented as `b.decode("utf-8", errors="strict")` (src/spectest/prelude/collections.py). For `utf8_decode#1` and `utf8_encode.valid`, the spec's oracle and the implementation under test were therefore the same CPython code, and a bug in CPython's decoder would have passed. `valid_utf8` now follows Table 3-7 byte by byte without a codec, and tests/prelude/test_prelude_collections.py checks it against CPython's strict decoder on every byte string of up to 3 bytes and on about 1.7 million longer ones.

`test_python_utf8_decoder_accepts_exactly_table_3_7` checks CPython's decoder against Unicode Table 3-7 ("Well-Formed UTF-8 Byte Sequences"), written out separately in the test. It covers about 700,000 inputs:
- every byte string of length 2 or less
- every 3-byte string with a lead byte of 0xC0 or more and an edge-value third byte
- 4-byte strings with a lead byte of 0xE0 or more and edge-value trailing bytes
- 20,000 random strings of up to 16 bytes

The two agree on every input. Every accepted string also re-encodes to itself, which is the one-to-one correspondence both roundtrip clauses rely on. `test_table_3_7_is_written_out_correctly` checks the table itself.

## 4. Seeded bugs (one conformance each; all in expect_fail)

Each seeded bug has its own conformance with a correct partner. A `relates` clause calls the same conformance's other implementations, so two bugs in one conformance would show up in each other's roundtrip items.

**Wrapping pack** (test_seeded_wrapping_pack): `(x & 0xFFFFFFFF).to_bytes(4, "little")`.
- `pack_i32#1`: x = -2147483649 (i32.min - 1, the boundary) gives b"\xff\xff\xff\x7f" instead of StructError. Seeds 0 to 5 all minimize to -2147483649.
- `pack_i32.roundtrip`: for the same x, unpack gives 2147483647.
- `length` and `little_endian` pass: by construction the result is 4 bytes and le_uint(result) is wrap<u32>(x).
- Checked by `test_wrapping_pack_counterexamples`. It also checks the other boundary: 2147483648 packs to b"\x00\x00\x00\x80", which unpacks to -2147483648.

**Replacing decode** (test_seeded_replacing_decode): `b.decode("utf-8", errors="replace")`.
- `utf8_decode#1`: b = b"\x80" returns "�" instead of DecodeError.
- `utf8_decode.roundtrip`: for the same b, "�" encodes to b"\xef\xbf\xbd", which is not b"\x80".
- On valid input it equals strict decoding, so utf8_encode's items pass. Their roundtrip calls this decoder.
- Checked by `test_replacing_decode_counterexamples`.

**UTF-16-LE encode** (test_seeded_utf16_encode): `s.encode("utf-16-le")`. These clauses catch it:
- `utf8_encode.valid`: s = "\u{80}" (U+0080) gives b"\x80\x00", which is not UTF-8.
  - ASCII strings encode to valid UTF-8 (a NUL after each character), so this clause needs a non-ASCII character.
- `utf8_encode.roundtrip`: s = "0" gives b"0\x00", which decodes to "0\x00".
  - It catches any non-empty ASCII string. For a non-ASCII string the planned decode raises and the clause skips; there were 5 skips before the failure.
- `utf8_encode.length`: s = "0" gives b"0\x00", 2 bytes where UTF-8 takes 1.
  - The clause states the exact UTF-8 length, 1 to 4 bytes per code point by `codepoints(s)`. It catches any string with an ASCII character or one from U+0800 to U+FFFF; for U+0080 to U+07FF and above U+FFFF, UTF-16 and UTF-8 take the same number of bytes.
  - Before the prelude had `codepoints`, the clause could only bound the length, `len(s) <= len(result) <= 4 * len(s)`, and UTF-16's 2 or 4 bytes per scalar value stayed inside the bounds, so this bug passed it.
- `utf8_decode.roundtrip`: b = b"\x00" decodes to "\x00", which the buggy encoder re-encodes as b"\x00\x00". This is the encoder's bug, reported under the decoder's item.
- Checked by `test_utf16_encode_counterexamples`.

## 5. Coverage

Figures are from REPORT.md (500 examples per item, seed 0), the deep run (5,000 per item, seed 11), and explore_binary.py (2,000 seeded draws through `spectest.generate.args_strategy`). The utf8_decode and unpack_i32 figures were measured again after predicate partitions began to steer generation (a seed 0 run at 500 examples per item, and explore_binary.py), with the earlier figures beside them.

**pack_i32: all three classes are hit, about a third each.**
- test_struct's `pack_i32#1` drew 186 in_range, 166 too_small and 148 too_large.
- Every item that ran its full search drew 123 to 232 per class. In the deep run it was 1,579 to 1,818 per class out of 5,000.

**Boundaries.**
- Uniform draws rarely hit i32.min - 1 or i32.max + 1: 0.1% of 2,000 draws.
- Each run still draws them early: within the first 16 draws for seeds 0 to 9, because the first member of `too_large` is i32.max + 1.
- An off-by-one pack that accepts exactly 2^31 (explore_binary.py, `test_explore_off_by_one_pack`) was caught by `pack_i32#1` on all of seeds 0 to 19. It was found within 2 to 14 examples and always reported as x = 2147483648.

**utf8_decode: the valid class is reached, with real multi-byte text.**
- `valid` gets 191 to 242 of 500 examples per item (38 to 48%; 179 to 205 in REPORT.md, before predicate partitions steered generation).
- Of 2,000 explore draws (before steering, in parentheses):

| Draws | Share |
| --- | ---: |
| valid | 43.8% (37.4%) |
| valid with a multi-byte sequence | 22.9% (29.0%) |
| valid with a 4-byte sequence | 13.9% (19.2%) |
| valid, ASCII only | 11.5% (8.3%) |
| empty | 9.3% (0.1%) |

**unpack_i32: the four class gets a fair share.**
- `four` (`len(b) == 4`) is a predicate class, and predicate partitions now steer generation: a class, or no class as often as any one class, is drawn first, and a length test fixes the length drawn. `four` gets 146 to 186 of 500 per item (29 to 37%), and test_struct's `unpack_i32.value` is judged on 176 four-byte inputs.
- Before, the partition only tagged coverage: `four` got 31 to 56 of 500 per item (6 to 11%), test_struct's `unpack_i32.value` was judged on only 35 four-byte inputs (the other 465 examples were skips), and the deep run had 409 to 422 of 5,000.
- In explore, 34.2% of draws have length 4 (7.2% before). Lengths 8, 12 and 16 make up 16.0%, and 4.5% of the draws are long (33 to 100 bytes; Sizes.long_share).

---

Notes on the harness (filed in docs/ISSUES.md as "binary:" entries):
- **Counterexamples were not minimal** (fixed). numpy's `unpack_i32#1` reported 16 zero bytes where 8 suffice, and `unpack_i32.value` a spliced invalid-UTF-8 sequence where `bytes(4) + b"\x01" + bytes(3)` would do. A deterministic pass after Hypothesis's shrinking now gives 8 zero bytes and `bytes(7) + b"\x01"`.
- **Coverage counts skipped examples.** test_struct's `pack_i32.length` lists about 150 too_small and 150 too_large examples, all of them skips.
- **Report rows don't name the conformance.** The coverage tables and counterexample headings label entries by clause ID only, so with six conformances `pack_i32#1` appears four times.
- **Store replays change the report.** A rerun replays each stored counterexample, so the report's counts and coverage for that item come from one example.