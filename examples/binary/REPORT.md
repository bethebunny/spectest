# spectest report: binary

- **Spec:** `binary` (`/home/stef/spectest/examples/binary/binary.spec`)
- **Spec hash:** `f9e87ca0f2e17f9d62860314bbfb0b235d035b2e9f7eefee84a3a0717476341c`
- **Harness:** spectest 0.1.0.dev0, Hypothesis 6.170.9
- **Platform:** CPython 3.13.9, Linux 6.18.54.1-microsoft-standard-WSL2, x86_64
- **Packages:** numpy 2.5.4, gmpy2 2.3.2
- **Items:** 67: 54 passed, 13 expected failures
- **Clause results:** 67: 54 passed, 13 expected failures

## Results

| Item | Clause | Kind | Mode | Verdict | pass | fail | skip | spec error | inconclusive | Time |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `examples/binary/test_binary.py::test_struct::pack_i32#1` | `pack_i32#1` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.10s |
| `examples/binary/test_binary.py::test_struct::pack_i32.length` | `pack_i32.length` | ensures | hypothesis | pass | 209 | 0 | 291 (raised) | 0 | 0 | 0.94s |
| `examples/binary/test_binary.py::test_struct::pack_i32.little_endian` | `pack_i32.little_endian` | ensures | hypothesis | pass | 216 | 0 | 284 (raised) | 0 | 0 | 1.03s |
| `examples/binary/test_binary.py::test_struct::pack_i32.roundtrip` | `pack_i32.roundtrip` | relates | hypothesis | pass | 207 | 0 | 293 (raised) | 0 | 0 | 1.00s |
| `examples/binary/test_binary.py::test_struct::pack_i32#type` | `pack_i32#type` | type | hypothesis | pass | 195 | 0 | 305 (raised) | 0 | 0 | 1.02s |
| `examples/binary/test_binary.py::test_struct::pack_i32#raises` | `pack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.98s |
| `examples/binary/test_binary.py::test_struct::unpack_i32#1` | `unpack_i32#1` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.35s |
| `examples/binary/test_binary.py::test_struct::unpack_i32.value` | `unpack_i32.value` | ensures | hypothesis | pass | 177 | 0 | 323 (raised) | 0 | 0 | 1.25s |
| `examples/binary/test_binary.py::test_struct::unpack_i32#type` | `unpack_i32#type` | type | hypothesis | pass | 186 | 0 | 314 (raised) | 0 | 0 | 1.36s |
| `examples/binary/test_binary.py::test_struct::unpack_i32#raises` | `unpack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.27s |
| `examples/binary/test_binary.py::test_struct::utf8_encode.valid` | `utf8_encode.valid` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.67s |
| `examples/binary/test_binary.py::test_struct::utf8_encode.length` | `utf8_encode.length` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.74s |
| `examples/binary/test_binary.py::test_struct::utf8_encode.roundtrip` | `utf8_encode.roundtrip` | relates | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.94s |
| `examples/binary/test_binary.py::test_struct::utf8_encode#type` | `utf8_encode#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.72s |
| `examples/binary/test_binary.py::test_struct::utf8_encode#raises` | `utf8_encode#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.65s |
| `examples/binary/test_binary.py::test_struct::utf8_decode#1` | `utf8_decode#1` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.91s |
| `examples/binary/test_binary.py::test_struct::utf8_decode.roundtrip` | `utf8_decode.roundtrip` | relates | hypothesis | pass | 214 | 0 | 286 (raised) | 0 | 0 | 1.85s |
| `examples/binary/test_binary.py::test_struct::utf8_decode#type` | `utf8_decode#type` | type | hypothesis | pass | 191 | 0 | 309 (raised) | 0 | 0 | 1.82s |
| `examples/binary/test_binary.py::test_struct::utf8_decode#raises` | `utf8_decode#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.82s |
| `examples/binary/test_binary.py::test_int_bytes::pack_i32#1` | `pack_i32#1` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.90s |
| `examples/binary/test_binary.py::test_int_bytes::pack_i32.length` | `pack_i32.length` | ensures | hypothesis | pass | 216 | 0 | 284 (raised) | 0 | 0 | 0.88s |
| `examples/binary/test_binary.py::test_int_bytes::pack_i32.little_endian` | `pack_i32.little_endian` | ensures | hypothesis | pass | 184 | 0 | 316 (raised) | 0 | 0 | 1.08s |
| `examples/binary/test_binary.py::test_int_bytes::pack_i32.roundtrip` | `pack_i32.roundtrip` | relates | hypothesis | pass | 211 | 0 | 289 (raised) | 0 | 0 | 0.95s |
| `examples/binary/test_binary.py::test_int_bytes::pack_i32#type` | `pack_i32#type` | type | hypothesis | pass | 194 | 0 | 306 (raised) | 0 | 0 | 0.98s |
| `examples/binary/test_binary.py::test_int_bytes::pack_i32#raises` | `pack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.96s |
| `examples/binary/test_binary.py::test_int_bytes::unpack_i32#1` | `unpack_i32#1` | raises | hypothesis | expected fail | 1 | 1 | 0 | 0 | 0 | 0.08s |
| `examples/binary/test_binary.py::test_int_bytes::unpack_i32.value` | `unpack_i32.value` | ensures | hypothesis | expected fail | 10 | 1 | 6 (wrong type) | 0 | 0 | 0.16s |
| `examples/binary/test_binary.py::test_int_bytes::unpack_i32#type` | `unpack_i32#type` | type | hypothesis | expected fail | 2 | 1 | 0 | 0 | 0 | 0.12s |
| `examples/binary/test_binary.py::test_int_bytes::unpack_i32#raises` | `unpack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.34s |
| `examples/binary/test_binary.py::test_numpy::pack_i32#1` | `pack_i32#1` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.99s |
| `examples/binary/test_binary.py::test_numpy::pack_i32.length` | `pack_i32.length` | ensures | hypothesis | pass | 210 | 0 | 290 (raised) | 0 | 0 | 0.92s |
| `examples/binary/test_binary.py::test_numpy::pack_i32.little_endian` | `pack_i32.little_endian` | ensures | hypothesis | pass | 214 | 0 | 286 (raised) | 0 | 0 | 1.06s |
| `examples/binary/test_binary.py::test_numpy::pack_i32.roundtrip` | `pack_i32.roundtrip` | relates | hypothesis | pass | 203 | 0 | 297 (raised) | 0 | 0 | 0.99s |
| `examples/binary/test_binary.py::test_numpy::pack_i32#type` | `pack_i32#type` | type | hypothesis | pass | 232 | 0 | 268 (raised) | 0 | 0 | 0.99s |
| `examples/binary/test_binary.py::test_numpy::pack_i32#raises` | `pack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.93s |
| `examples/binary/test_binary.py::test_numpy::unpack_i32#1` | `unpack_i32#1` | raises | hypothesis | expected fail | 2 | 1 | 0 | 0 | 0 | 0.05s |
| `examples/binary/test_binary.py::test_numpy::unpack_i32.value` | `unpack_i32.value` | ensures | hypothesis | expected fail | 1 | 1 | 10 (raised) | 0 | 0 | 0.49s |
| `examples/binary/test_binary.py::test_numpy::unpack_i32#type` | `unpack_i32#type` | type | hypothesis | pass | 255 | 0 | 245 (raised) | 0 | 0 | 1.29s |
| `examples/binary/test_binary.py::test_numpy::unpack_i32#raises` | `unpack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.17s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32#1` | `pack_i32#1` | raises | hypothesis | expected fail | 1 | 1 | 0 | 0 | 0 | 0.04s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32.length` | `pack_i32.length` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.02s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32.little_endian` | `pack_i32.little_endian` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.93s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32.roundtrip` | `pack_i32.roundtrip` | relates | hypothesis | expected fail | 1 | 1 | 0 | 0 | 0 | 0.04s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32#type` | `pack_i32#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.88s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32#raises` | `pack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.92s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::unpack_i32#1` | `unpack_i32#1` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.30s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::unpack_i32.value` | `unpack_i32.value` | ensures | hypothesis | pass | 179 | 0 | 321 (raised) | 0 | 0 | 1.21s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::unpack_i32#type` | `unpack_i32#type` | type | hypothesis | pass | 167 | 0 | 333 (raised) | 0 | 0 | 1.33s |
| `examples/binary/test_binary.py::test_seeded_wrapping_pack::unpack_i32#raises` | `unpack_i32#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.19s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_encode.valid` | `utf8_encode.valid` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.67s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_encode.length` | `utf8_encode.length` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.79s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_encode.roundtrip` | `utf8_encode.roundtrip` | relates | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.66s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_encode#type` | `utf8_encode#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.69s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_encode#raises` | `utf8_encode#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.66s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_decode#1` | `utf8_decode#1` | raises | hypothesis | expected fail | 2 | 1 | 0 | 0 | 0 | 0.22s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_decode.roundtrip` | `utf8_decode.roundtrip` | relates | hypothesis | expected fail | 2 | 1 | 0 | 0 | 0 | 0.25s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_decode#type` | `utf8_decode#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.87s |
| `examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_decode#raises` | `utf8_decode#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.86s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode.valid` | `utf8_encode.valid` | ensures | hypothesis | expected fail | 2 | 1 | 0 | 0 | 0 | 0.06s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode.length` | `utf8_encode.length` | ensures | hypothesis | expected fail | 1 | 1 | 0 | 0 | 0 | 0.03s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode.roundtrip` | `utf8_encode.roundtrip` | relates | hypothesis | expected fail | 1 | 1 | 0 | 0 | 0 | 0.06s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode#type` | `utf8_encode#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.69s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode#raises` | `utf8_encode#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 0.68s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_decode#1` | `utf8_decode#1` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.53s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_decode.roundtrip` | `utf8_decode.roundtrip` | relates | hypothesis | expected fail | 2 | 1 | 0 | 0 | 0 | 0.03s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_decode#type` | `utf8_decode#type` | type | hypothesis | pass | 227 | 0 | 273 (raised) | 0 | 0 | 1.53s |
| `examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_decode#raises` | `utf8_decode#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.08s |

Skips by cause: raised: the call raised; wrong type: the result was not of its declared type.

## Coverage

Examples each clause judged (pass or fail), per partition class; a class with 0 examples was never exercised by that clause.

### `pack_i32`

| Clause | x: in_range | x: too_small | x: too_large |
| --- | ---: | ---: | ---: |
| `test_struct::pack_i32#1` | 186 | 166 | 148 |
| `test_struct::pack_i32.length` | 209 | **0** | **0** |
| `test_struct::pack_i32.little_endian` | 216 | **0** | **0** |
| `test_struct::pack_i32.roundtrip` | 207 | **0** | **0** |
| `test_struct::pack_i32#type` | 195 | **0** | **0** |
| `test_struct::pack_i32#raises` | 193 | 123 | 184 |
| `test_int_bytes::pack_i32#1` | 208 | 141 | 151 |
| `test_int_bytes::pack_i32.length` | 216 | **0** | **0** |
| `test_int_bytes::pack_i32.little_endian` | 184 | **0** | **0** |
| `test_int_bytes::pack_i32.roundtrip` | 211 | **0** | **0** |
| `test_int_bytes::pack_i32#type` | 194 | **0** | **0** |
| `test_int_bytes::pack_i32#raises` | 203 | 164 | 133 |
| `test_numpy::pack_i32#1` | 207 | 138 | 155 |
| `test_numpy::pack_i32.length` | 210 | **0** | **0** |
| `test_numpy::pack_i32.little_endian` | 214 | **0** | **0** |
| `test_numpy::pack_i32.roundtrip` | 203 | **0** | **0** |
| `test_numpy::pack_i32#type` | 232 | **0** | **0** |
| `test_numpy::pack_i32#raises` | 195 | 158 | 147 |
| `test_seeded_wrapping_pack::pack_i32#1` | 1 | **0** | 1 |
| `test_seeded_wrapping_pack::pack_i32.length` | 200 | 148 | 152 |
| `test_seeded_wrapping_pack::pack_i32.little_endian` | 187 | 169 | 144 |
| `test_seeded_wrapping_pack::pack_i32.roundtrip` | 1 | **0** | 1 |
| `test_seeded_wrapping_pack::pack_i32#type` | 193 | 165 | 142 |
| `test_seeded_wrapping_pack::pack_i32#raises` | 198 | 145 | 157 |

### `unpack_i32`

| Clause | b: four | b: other |
| --- | ---: | ---: |
| `test_struct::unpack_i32#1` | 155 | 345 |
| `test_struct::unpack_i32.value` | 177 | **0** |
| `test_struct::unpack_i32#type` | 186 | **0** |
| `test_struct::unpack_i32#raises` | 168 | 332 |
| `test_int_bytes::unpack_i32#1` | 1 | 1 |
| `test_int_bytes::unpack_i32.value` | 6 | 5 |
| `test_int_bytes::unpack_i32#type` | 1 | 2 |
| `test_int_bytes::unpack_i32#raises` | 146 | 354 |
| `test_numpy::unpack_i32#1` | 1 | 2 |
| `test_numpy::unpack_i32.value` | 1 | 1 |
| `test_numpy::unpack_i32#type` | 186 | 69 |
| `test_numpy::unpack_i32#raises` | 158 | 342 |
| `test_seeded_wrapping_pack::unpack_i32#1` | 170 | 330 |
| `test_seeded_wrapping_pack::unpack_i32.value` | 179 | **0** |
| `test_seeded_wrapping_pack::unpack_i32#type` | 167 | **0** |
| `test_seeded_wrapping_pack::unpack_i32#raises` | 167 | 333 |

### `utf8_decode`

| Clause | b: valid | b: invalid |
| --- | ---: | ---: |
| `test_struct::utf8_decode#1` | 209 | 291 |
| `test_struct::utf8_decode.roundtrip` | 214 | **0** |
| `test_struct::utf8_decode#type` | 191 | **0** |
| `test_struct::utf8_decode#raises` | 218 | 282 |
| `test_seeded_replacing_decode::utf8_decode#1` | 2 | 1 |
| `test_seeded_replacing_decode::utf8_decode.roundtrip` | 2 | 1 |
| `test_seeded_replacing_decode::utf8_decode#type` | 219 | 281 |
| `test_seeded_replacing_decode::utf8_decode#raises` | 218 | 282 |
| `test_seeded_utf16_encode::utf8_decode#1` | 209 | 291 |
| `test_seeded_utf16_encode::utf8_decode.roundtrip` | 3 | **0** |
| `test_seeded_utf16_encode::utf8_decode#type` | 227 | **0** |
| `test_seeded_utf16_encode::utf8_decode#raises` | 242 | 258 |

## Counterexamples

### `test_int_bytes::unpack_i32#1` (expected failure)

```text
unpack_i32#1 (raises) failed as expected (expect_fail)
  raises StructError when len(b) != 4
  in unpack_i32

inputs:
  b = b""
observed:
  result = 0
  StructError was due (len(b) != 4 holds), but the call returned
partitions:
  b: other
explanation:
  raises StructError when len(b) != 4 = true
  errors that must be raised (R) = {StructError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 1 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_int_bytes::unpack_i32#1' --spectest-seed=0
```

### `test_int_bytes::unpack_i32.value` (expected failure)

```text
unpack_i32.value (ensures) failed as expected (expect_fail)
  ensures value: wrap<u32>(result) == le_uint(b)
  in unpack_i32

inputs:
  b = b"\x80"
observed:
  result = -128
  note: unpack_i32#1 required StructError on this input
partitions:
  b: other
explanation:
  result = -128
  wrap<u32>(result) = 4294967168
  b = b"\x80"
  le_uint(b) = 128
verdicts: 10 pass, 1 fail, 6 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_int_bytes::unpack_i32.value' --spectest-seed=0
```

### `test_int_bytes::unpack_i32#type` (expected failure)

```text
unpack_i32#type (type) failed as expected (expect_fail)
  built-in: the result of unpack_i32 reads as i32
  in unpack_i32

inputs:
  b = b"\x00\x00\x00\x00\x01"
observed:
  returned int 4294967296, which is not i32 (outside the i32 range -2147483648..2147483647)
partitions:
  b: other
explanation:
  result = int 4294967296
verdicts: 2 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_int_bytes::unpack_i32#type' --spectest-seed=0
```

### `test_numpy::unpack_i32#1` (expected failure)

```text
unpack_i32#1 (raises) failed as expected (expect_fail)
  raises StructError when len(b) != 4
  in unpack_i32

inputs:
  b = b"\x00\x00\x00\x00\x00\x00\x00\x00"
observed:
  result = 0
  StructError was due (len(b) != 4 holds), but the call returned
partitions:
  b: other
explanation:
  raises StructError when len(b) != 4 = true
  errors that must be raised (R) = {StructError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 2 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_numpy::unpack_i32#1' --spectest-seed=0
```

### `test_numpy::unpack_i32.value` (expected failure)

```text
unpack_i32.value (ensures) failed as expected (expect_fail)
  ensures value: wrap<u32>(result) == le_uint(b)
  in unpack_i32

inputs:
  b = b"\x00\x00\x00\x00\x00\x00\x00\x01"
observed:
  result = 0
  note: unpack_i32#1 required StructError on this input
partitions:
  b: other
explanation:
  result = 0
  wrap<u32>(result) = 0
  b = b"\x00\x00\x00\x00\x00\x00\x00\x01"
  le_uint(b) = 72057594037927936
verdicts: 1 pass, 1 fail, 10 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_numpy::unpack_i32.value' --spectest-seed=0
```

### `test_seeded_wrapping_pack::pack_i32#1` (expected failure)

```text
pack_i32#1 (raises) failed as expected (expect_fail)
  raises StructError when not fits<i32>(x)
  in pack_i32

inputs:
  x = -2147483649
observed:
  result = b"\xff\xff\xff\x7f"
  StructError was due (not fits<i32>(x) holds), but the call returned
partitions:
  x: too_small
explanation:
  raises StructError when not fits<i32>(x) = true
  errors that must be raised (R) = {StructError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 1 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32#1' --spectest-seed=0
```

### `test_seeded_wrapping_pack::pack_i32.roundtrip` (expected failure)

```text
pack_i32.roundtrip (relates) failed as expected (expect_fail)
  relates roundtrip: unpack_i32(result) == x
  in pack_i32

inputs:
  x = -2147483649
observed:
  result = b"\xff\xff\xff\x7f"
  note: pack_i32#1 required StructError on this input
partitions:
  x: too_small
explanation:
  result = b"\xff\xff\xff\x7f"
  unpack_i32(result) = 2147483647
  x = -2147483649
verdicts: 1 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_wrapping_pack::pack_i32.roundtrip' --spectest-seed=0
```

### `test_seeded_replacing_decode::utf8_decode#1` (expected failure)

```text
utf8_decode#1 (raises) failed as expected (expect_fail)
  raises DecodeError when not valid_utf8(b)
  in utf8_decode

inputs:
  b = b"\x80"
observed:
  result = "\u{fffd}"
  DecodeError was due (not valid_utf8(b) holds), but the call returned
partitions:
  b: invalid
explanation:
  raises DecodeError when not valid_utf8(b) = true
  errors that must be raised (R) = {DecodeError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 2 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_decode#1' --spectest-seed=0
```

### `test_seeded_replacing_decode::utf8_decode.roundtrip` (expected failure)

```text
utf8_decode.roundtrip (relates) failed as expected (expect_fail)
  relates roundtrip: utf8_encode(result) == b
  in utf8_decode

inputs:
  b = b"\x80"
observed:
  result = "\u{fffd}"
  note: utf8_decode#1 required DecodeError on this input
partitions:
  b: invalid
explanation:
  result = "\u{fffd}"
  utf8_encode(result) = b"\xef\xbf\xbd"
  b = b"\x80"
verdicts: 2 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_replacing_decode::utf8_decode.roundtrip' --spectest-seed=0
```

### `test_seeded_utf16_encode::utf8_encode.valid` (expected failure)

```text
utf8_encode.valid (ensures) failed as expected (expect_fail)
  ensures valid: valid_utf8(result)
  in utf8_encode

inputs:
  s = "\u{80}"
observed:
  result = b"\x80\x00"
explanation:
  result = b"\x80\x00"
  valid_utf8(result) = false
verdicts: 2 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode.valid' --spectest-seed=0
```

### `test_seeded_utf16_encode::utf8_encode.length` (expected failure)

```text
utf8_encode.length (ensures) failed as expected (expect_fail)
  ensures length: len(result) == sum(c in codepoints(s): if c < 0x80 then 1 else if c < 0x800 then 2 else if c < 0x10000 then 3 else 4)
  in utf8_encode

inputs:
  s = "0"
observed:
  result = b"0\x00"
explanation:
  result = b"0\x00"
  len(result) = 2
  sum(c in codepoints(s): if c < 0x80 then 1 else if c < 0x800 then 2 else if c < 0x10000 then 3 else 4) = 1
verdicts: 1 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode.length' --spectest-seed=0
```

### `test_seeded_utf16_encode::utf8_encode.roundtrip` (expected failure)

```text
utf8_encode.roundtrip (relates) failed as expected (expect_fail)
  relates roundtrip: utf8_decode(result) == s
  in utf8_encode

inputs:
  s = "0"
observed:
  result = b"0\x00"
explanation:
  result = b"0\x00"
  utf8_decode(result) = "0\x00"
  s = "0"
verdicts: 1 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_encode.roundtrip' --spectest-seed=0
```

### `test_seeded_utf16_encode::utf8_decode.roundtrip` (expected failure)

```text
utf8_decode.roundtrip (relates) failed as expected (expect_fail)
  relates roundtrip: utf8_encode(result) == b
  in utf8_decode

inputs:
  b = b"\x00"
observed:
  result = "\x00"
partitions:
  b: valid
explanation:
  result = "\x00"
  utf8_encode(result) = b"\x00\x00"
  b = b"\x00"
verdicts: 2 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/binary/test_binary.py::test_seeded_utf16_encode::utf8_decode.roundtrip' --spectest-seed=0
```
