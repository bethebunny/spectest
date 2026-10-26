# binary

binary.spec covers fixed-width integer packing (`pack_i32`, `unpack_i32`) and the UTF-8 text codecs (`utf8_encode`, `utf8_decode`). The case shows:

- **An i64 parameter with set partitions over open ranges** (`i64.range(none, i32.min)`, `i64.range(i32.max + 1, none)`). Inputs are drawn class first, so out-of-range integers are as common as in-range ones.
- **`raises` clauses** (StructError, DecodeError) mapped from Python exceptions through `errors=`.
- **Round-trip `relates` clauses between two functions.** In `pack_i32.roundtrip: unpack_i32(result) == x`, the second call is a planned call to the bound implementation.
- **bytes and string parameters**, with predicate partitions (`len(b) == 4`, `valid_utf8(b)`) that tag coverage.

## Files

| File | What it is |
| --- | --- |
| `binary.spec` | The requirement. |
| `binary_impls.py` | The struct, int.to_bytes/int.from_bytes and numpy adapters, the three seeded bugs, and an off-by-one pack for the exploration. |
| `test_binary.py` | Six conformances and 12 plain checks of the findings, which run without spectest. |
| `explore_binary.py` | Measures how generation reaches each partition class, and whether a bug at a single boundary input is found. Run it explicitly. |
| `REPORT.md` | Written by the plugin's `--spectest-report` option. |
| `FINDINGS.md` | The findings, with their independent checks. |

## Conformances

| Conformance | Binds | Expected failures |
| --- | --- | --- |
| `test_struct` | `struct.pack("<i")` / `struct.unpack("<i")`, `str.encode` / `bytes.decode` | none |
| `test_int_bytes` | `x.to_bytes(4, "little", signed=True)` / `int.from_bytes(b, "little", signed=True)` | `unpack_i32#1`, `unpack_i32.value`, `unpack_i32#type`: from_bytes reads any length (FINDINGS 1) |
| `test_numpy` | `numpy.array([x], dtype="<i4").tobytes()` / `numpy.frombuffer(b, dtype="<i4")[0]` | `unpack_i32#1`, `unpack_i32.value`: 8, 12 and 16 bytes return the first element (FINDINGS 2) |
| `test_seeded_wrapping_pack` | pack wraps out-of-range x; struct unpack | `pack_i32#1`, `pack_i32.roundtrip` |
| `test_seeded_replacing_decode` | decode with `errors="replace"`; correct encode | `utf8_decode#1`, `utf8_decode.roundtrip` |
| `test_seeded_utf16_encode` | encode as UTF-16-LE; correct decode | `utf8_encode.valid`, `utf8_encode.length`, `utf8_encode.roundtrip`, `utf8_decode.roundtrip` |

Each seeded bug gets its own conformance. Planned calls in a `relates` clause go to the same conformance's implementations, so a bug bound next to another bug would show up in the other function's roundtrip items.

## How to run

```
uv run pytest examples/binary
uv run pytest examples/binary --spectest-report=examples/binary/REPORT.md
uv run pytest examples/binary/explore_binary.py -s
```

## What to expect

**`uv run pytest examples/binary`** gives 66 passed and 13 xfailed in about 35 to 65 seconds:
- 54 spectest items pass and 13 are expected failures (strict xfail), from 67 items in six conformances, at max_examples=500.
- All 12 plain checks pass.

**`explore_binary.py`** gives 13 passed and 2 failed, and prints share tables:
- The two failures are the off-by-one pack's `pack_i32#1` and `pack_i32.roundtrip`, both at x = 2147483648. They are an answer (spectest does find a bug at a single boundary input), not a bug.

**Counterexamples are stored** under `.spectest/counterexamples/<first 16 hex digits of the spec hash>/` (today `f9e87ca0f2e17f9d`):
- A rerun replays each stored counterexample instead of searching, so expected failures then read "1 fail", with coverage from that one example.
- REPORT.md was written from a cleared store. To regenerate it the same way, delete that directory first.