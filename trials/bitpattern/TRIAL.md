# Trial: a blind spec of bitpattern 0.3.0

The question: can spectest test a real library from a spec written by someone who never saw its code?

1. **Informal spec.** One writer read the installed bitpattern 0.3.0 source and wrote
   [INFORMAL_SPEC.md](INFORMAL_SPEC.md): 709 lines covering 68 public names and about 200
   methods. Behaviour the writer found by experiment rather than in documentation is marked
   **observed**. Writing it took about 15 minutes.
2. **Formal spec.** A second writer read only INFORMAL_SPEC.md and spectest's own docs,
   examples and binding API, never bitpattern's code. They wrote
   [bitpattern.spec](bitpattern.spec) (2,594 lines: 236 functions and 590 clauses),
   [test_bitpattern.py](test_bitpattern.py) (the binding, 1,685 lines) and
   [TRANSLATION.md](TRANSLATION.md) (what could not be expressed, and the readings they
   chose). They checked only that the spec parses and the tests collect, and added no
   expected failures. Translating took about 63 minutes.
3. **Run.** The formal spec was run against the installed library once, unchanged.

## Result

`uv run pytest trials/bitpattern -n 10 -q -rfE --tb=short`

| | |
| --- | --- |
| Wall clock | **95 s** on 10 workers (844 s user CPU). The longest item is `f16_decode.decoded`, which checks all 65,536 float16 encodings and takes 56 s alone. |
| Items | 1,080: **1,026 passed, 9 failed, 45 skipped, 0 spec errors** |
| Skipped | All 45 are `#type` and invariant items of functions whose every call raises, so they have nothing to judge |

| Conformance | Passed | Failed | Skipped |
| --- | --- | --- | --- |
| `test_intset` | 265 | 2 | 18 |
| `test_pattern` | 62 | 1 | 0 |
| `test_codecs` | 531 | 4 | 24 |
| `test_bdd` | 126 | 2 | 3 |
| `test_export` | 42 | 0 | 0 |

## The 9 failures: 7 causes

| Item | Counterexample | Cause | Whose |
| --- | --- | --- | --- |
| `intset_range_float_stop#1`, `#raises` | `IntSet.range(0, 1.0)` raises `AttributeError: 'float' object has no attribute 'bit_length'` | The informal spec says non-int bounds raise `TypeError` (observed). That holds for the other float bounds tried, but a float `stop` without a width reaches `.bit_length()` first. | **Library**: an internal error leaks. The informal spec generalized from the bounds it tried. |
| `int_range_float#1` | `int8.range(-128.00000000000003)` returns all of `int8` | Same claim for codecs. A float bound outside the range is clamped before its type is checked, so it is accepted. Other float bounds raise `TypeError`. | **Library**: inconsistent checking. Same overstatement in the informal spec. |
| `bdd_node#2` | `BDD(0, x, x)`, where `x` tests bit 7, returns `x` | The informal spec states two rules that conflict here: `ValueError` when a child tests a bit `>= bit`, and `BDD(b, x, x) is x`. The library reduces before it validates. | **Informal spec** contradicts itself. The library's leniency is arguable. |
| `pattern.syntax` | `Pattern("1*111")` is accepted as `1111` | "A `*` expands to however many `?` bring the quartet to 4" allows zero `?`. The translator's explicit example took the stricter reading. | **Translation** of an ambiguous rule |
| `codec_pattern_message.message` | expected `"pattern is 1 bits, not 08"` | The spec formats the width as two digits by hand, because the language has no int-to-string. | **Translation** slip, caused by a language gap |
| `datetime_codec.size`, `datetime_decode#2` | A `UTC-00:01` codec has 60,000,000 fewer members | The informal spec says instants that would overflow `datetime` at *either* end are left out, but gives only a `+01:00` example. The translator decided that negative offsets lose nothing. | **Translation** reasoning error |
| `bdd_nth#4` | `bdd.nth(IntSet([1]).bdd, 0, width=0)` raises `ValueError` | Both an `IndexError` (`raises`) and a `ValueError` (`may_raise`) apply here. The runtime fails the `raises` clause, because R is non-empty and `ValueError` is not in R. | **spectest's language doc** is ambiguous. Its `raises` row says the call must raise a member of R. Its `may_raise` row and soundness rule 6 say a declared freedom passes. |

## Interpretation

- **The pipeline worked without changes to spectest.** A 2,600-line spec, written blind, ran first
  time against a library with a compiled core. Nothing was tuned, there were no spec errors and no
  binding failures, and it covered nearly the whole public surface. On valid input, the library
  matched its informal spec everywhere tested.
- **The failures are informative and quick to diagnose.** Each counterexample's evaluated
  subexpressions show the cause directly: the `"08"`, the size off by exactly one offset, the
  error sets R and M. Three causes are genuine gaps between bitpattern and its own description,
  all in error handling at the edges (float bounds, out-of-order nodes). Three are translation
  mistakes. One is a semantic question about spectest itself, which none of its five use cases
  had raised.
- **Expressiveness is the main cost.** The formal spec is about 3.7 times the informal spec's
  length, and the 63 minutes of translation dwarf the 95 s run. TRANSLATION.md traces most of the
  bulk to four gaps:
  - no exponentiation, so powers of two are written out as tables;
  - no int-to-string conversion;
  - no user-defined helper functions, so laws are restated over members;
  - no `==` on models.

  The `"08"` failure comes directly from the second gap. Bit-width conditions like
  `bdd_nth#4`'s are hard to read. A few prelude additions (`2**k`, `str(n)`, `bit_length`,
  spec-level helpers) would shrink the spec and remove a class of translation slips.
- **What it cannot reach.** Hypothesis strategies (`from_set`), DLPack capsule contents,
  uniformity of `choice` and DST behaviour stayed out of scope. These are limits of
  per-example clauses and of the binding.

## Test output

```
bringing up nodes...
bringing up nodes...

..................................................s......s..s........... [  6%]
.......s.........s...F....ss.F..s...ss......s....s....................s. [ 13%]
.............s...s.......s.......s.........s............................ [ 20%]
.................................................s..................s... [ 26%]
...s..F..s................................s...................s..s...... [ 33%]
..................................................................F..... [ 40%]
.....................................s.................................. [ 46%]
.........................................................s.............. [ 53%]
.............s...........F..............................s............... [ 60%]
...........s...................s.........s.............................. [ 66%]
..............s...F.............s.......................s............F.. [ 73%]
.........s...............................s.......................s...... [ 80%]
...............ss......s..........s.....s.............................F. [ 86%]
...........F................................s........................... [ 93%]
.......................................................................s [100%]
=================================== FAILURES ===================================
_______________ spectest test_intset::intset_range_float_stop#1 ________________
[gw2] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
intset_range_float_stop#1 (raises) failed
  raises TypeError when true
  in intset_range_float_stop

inputs:
  start = 0
  stop = 1.0 (0x3ff0000000000000)
observed:
  raised AttributeError: 'float' object has no attribute 'bit_length' (maps to AttributeError)
  TypeError was due (true holds), but the call raised AttributeError: 'float' object has no attribute 'bit_length' (maps to AttributeError)
explanation:
  raises TypeError when true = true
  errors that must be raised (R) = {TypeError}
  errors that may be raised (M) = {}
  raised = AttributeError: 'float' object has no attribute 'bit_length' (maps to AttributeError)
verdicts: 5 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_intset::intset_range_float_stop#1' --spectest-seed=0
_____________ spectest test_intset::intset_range_float_stop#raises _____________
[gw2] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
intset_range_float_stop#raises (raises) failed
  built-in: intset_range_float_stop raises only what a raises or may_raise admits
  in intset_range_float_stop

inputs:
  start = 0
  stop = 1.0 (0x3ff0000000000000)
observed:
  raised AttributeError: 'float' object has no attribute 'bit_length' (maps to AttributeError)
  no raises or may_raise admits AttributeError here
explanation:
  raises TypeError when true = true
  errors that must be raised (R) = {TypeError}
  errors that may be raised (M) = {}
verdicts: 4 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_intset::intset_range_float_stop#raises' --spectest-seed=0
____________________ spectest test_pattern::pattern.syntax _____________________
[gw0] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
pattern.syntax (raises) failed
  raises syntax: ValueError when not (len(quartets) >= 1 and all(j in range(0, len(quartets)): count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4)))
  in pattern

inputs:
  quartets = [["1", "*", "1", "1", "1"]]
observed:
  result = IntSet { kind: "Pattern", width: 4, size: 1, members: [15] }
  ValueError was due (not (len(quartets) >= 1 and all(j in range(0, len(quartets)): count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))) holds), but the call returned
  (an explicit example of the conformance (examples=))
partitions:
  quartets: invalid
explanation:
  raises ValueError when not (len(quartets) >= 1 and all(j in range(0, len(quartets)): count(c in quartets[j]: c == "*") <= 1 and len(quartets[j]) >= 1 and len(quartets[j]) <= 4 and (j == 0 or "*" in quartets[j] or len(quartets[j]) == 4))) = true
  errors that must be raised (R) = {ValueError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 11 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_pattern::pattern.syntax' --spectest-seed=0
___________________ spectest test_codecs::int_range_float#1 ____________________
[gw8] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
int_range_float#1 (raises) failed
  raises TypeError when true
  in int_range_float

inputs:
  c = "int8"
  bound = -128.00000000000003 (0xc060000000000001)
observed:
  result = CodecSet { codec: "int8", codec_width: 8, width: 8, size: 256 }
  TypeError was due (true holds), but the call returned
explanation:
  raises TypeError when true = true
  errors that must be raised (R) = {TypeError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 13 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_codecs::int_range_float#1' --spectest-seed=0
_____________ spectest test_codecs::codec_pattern_message.message ______________
[gw4] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
codec_pattern_message.message (ensures) failed
  ensures message: let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] in let n = sum(q in quartets: if "*" in q then 4 else len(q)) in let w = (if c in ["uint8", "int8", "float8_e5m2", "float8_e4m3fn"] then 8 else if c in ["uint16", "int16", "float16", "bfloat16"] then 16 else if c == "char" then 21 else 32) in result == "pattern is " + (if n < 10 then digits[n] else digits[n // 10] + digits[n % 10]) + " bits, not " + digits[w // 10] + digits[w % 10]
  in codec_pattern_message

inputs:
  c = "uint8"
  quartets = [["0"]]
observed:
  result = "pattern is 1 bits, not 8"
partitions:
  quartets: valid
explanation:
  digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
  n = 1
  w = 8
  result = "pattern is 1 bits, not 8"
  "pattern is " + (if n < 10 then digits[n] else digits[n // 10] + digits[n % 10]) + " bits, not " + digits[w // 10] + digits[w % 10] = "pattern is 1 bits, not 08"
verdicts: 1 fail, 8 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_codecs::codec_pattern_message.message' --spectest-seed=0
__________________ spectest test_codecs::datetime_codec.size ___________________
[gw8] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
datetime_codec.size (ensures) failed
  ensures size: result.2 == 315537897600000000 - (if is_none(zone) or unwrap(zone) <= 0 then 0 else unwrap(zone) * 60000000)
  in datetime_codec

inputs:
  zone = some(-1)
observed:
  result = ("datetimes[UTC-00:01]", 59, 315537897540000000, false)
explanation:
  result.2 = 315537897540000000
  315537897600000000 - (if is_none(zone) or unwrap(zone) <= 0 then 0 else unwrap(zone) * 60000000) = 315537897600000000
verdicts: 8 pass, 1 fail, 2 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_codecs::datetime_codec.size' --spectest-seed=0
___________________ spectest test_codecs::datetime_decode#2 ____________________
[gw8] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
datetime_decode#2 (raises) failed
  raises IndexError when b + (if is_some(zone) then unwrap(zone) * 60000000 else 0) > 315537897599999999
  in datetime_decode

inputs:
  zone = some(-1)
  b = 315537897600000000
observed:
  raised IndexError: datetimes[UTC-00:01] has no value encoded as 315537897600000000 (maps to IndexError)
  the call raised IndexError although b + (if is_some(zone) then unwrap(zone) * 60000000 else 0) > 315537897599999999 is false
partitions:
  b: beyond
explanation:
  raises IndexError when b + (if is_some(zone) then unwrap(zone) * 60000000 else 0) > 315537897599999999 = false
  errors that must be raised (R) = {}
  errors that may be raised (M) = {}
  raised = IndexError: datetimes[UTC-00:01] has no value encoded as 315537897600000000 (maps to IndexError)
verdicts: 22 pass, 1 fail, 17 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_codecs::datetime_decode#2' --spectest-seed=0
________________________ spectest test_bdd::bdd_node#2 _________________________
[gw5] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
bdd_node#2 (raises) failed
  raises ValueError when bit < 0 or max(v in [-1] + map(i in filter(i in range(0, len(left)): left[i] != "?"): len(left) - 1 - i): v) >= bit or max(v in [-1] + map(i in filter(i in range(0, len(right)): right[i] != "?"): len(right) - 1 - i): v) >= bit
  in bdd_node

inputs:
  bit = 0
  left = ["1", "0", "0", "0", "1", "0", "0", "1"]
  right = ["1", "0", "0", "0", "1", "0", "0", "1"]
  value = 0
observed:
  result = false
  ValueError was due (bit < 0 or max(v in [-1] + map(i in filter(i in range(0, len(left)): left[i] != "?"): len(left) - 1 - i): v) >= bit or max(v in [-1] + map(i in filter(i in range(0, len(right)): right[i] != "?"): len(right) - 1 - i): v) >= bit holds), but the call returned
partitions:
  bit: valid
explanation:
  raises ValueError when bit < 0 or max(v in [-1] + map(i in filter(i in range(0, len(left)): left[i] != "?"): len(left) - 1 - i): v) >= bit or max(v in [-1] + map(i in filter(i in range(0, len(right)): right[i] != "?"): len(right) - 1 - i): v) >= bit = true
  errors that must be raised (R) = {ValueError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 28 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_bdd::bdd_node#2' --spectest-seed=0
_________________________ spectest test_bdd::bdd_nth#4 _________________________
[gw9] linux -- Python 3.13.9 /home/stef/spectest/.venv/bin/python
bdd_nth#4 (raises) failed
  raises IndexError when q >= 0 and ( let w = max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) in let pow = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536] in let c = (if q >= w then count(x in range(0, 256): x in iterable) * pow[q - w] else count(x in range(0, pow[q]): x in iterable)) in n >= c or n < -c)
  in bdd_nth

inputs:
  iterable = [1]
  width = 0
  n = 0
  q = 0
observed:
  raised ValueError: node tests bit 0, outside width 0 (maps to ValueError)
  IndexError was due (q >= 0 and ( let w = max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) in let pow = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536] in let c = (if q >= w then count(x in range(0, 256): x in iterable) * pow[q - w] else count(x in range(0, pow[q]): x in iterable)) in n >= c or n < -c) holds), but the call raised ValueError: node tests bit 0, outside width 0 (maps to ValueError)
partitions:
  q: narrow
explanation:
  raises ValueError when q < 0 = false
  raises IndexError when q >= 0 and ( let w = max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) in let pow = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536] in let c = (if q >= w then count(x in range(0, 256): x in iterable) * pow[q - w] else count(x in range(0, pow[q]): x in iterable)) in n >= c or n < -c) = true
  may_raise ValueError when q < max(v in [width, count(p in [1, 2, 4, 8, 16, 32, 64, 128]: exists(x in iterable: x >= p))]: v) = true
  errors that must be raised (R) = {IndexError}
  errors that may be raised (M) = {ValueError}
  raised = ValueError: node tests bit 0, outside width 0 (maps to ValueError)
verdicts: 18 pass, 1 fail, 20 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'trials/bitpattern/test_bitpattern.py::test_bdd::bdd_nth#4' --spectest-seed=0
=================================== spectest ===================================
trials/bitpattern/test_bitpattern.py::test_intset (spec bitpattern): 265 passed, 2 failed, 18 skipped
trials/bitpattern/test_bitpattern.py::test_pattern (spec bitpattern): 62 passed, 1 failed
trials/bitpattern/test_bitpattern.py::test_codecs (spec bitpattern): 531 passed, 4 failed, 24 skipped
trials/bitpattern/test_bitpattern.py::test_bdd (spec bitpattern): 126 passed, 2 failed, 3 skipped
trials/bitpattern/test_bitpattern.py::test_export (spec bitpattern): 42 passed
report written to <scratch>/REPORT.md
report written to <scratch>/report.json
=========================== short test summary info ============================
FAILED trials/bitpattern/test_bitpattern.py::test_intset::intset_range_float_stop#1
FAILED trials/bitpattern/test_bitpattern.py::test_intset::intset_range_float_stop#raises
FAILED trials/bitpattern/test_bitpattern.py::test_pattern::pattern.syntax - p...
FAILED trials/bitpattern/test_bitpattern.py::test_codecs::int_range_float#1
FAILED trials/bitpattern/test_bitpattern.py::test_codecs::codec_pattern_message.message
FAILED trials/bitpattern/test_bitpattern.py::test_codecs::datetime_codec.size
FAILED trials/bitpattern/test_bitpattern.py::test_codecs::datetime_decode#2
FAILED trials/bitpattern/test_bitpattern.py::test_bdd::bdd_node#2 - bdd_node#...
FAILED trials/bitpattern/test_bitpattern.py::test_bdd::bdd_nth#4 - bdd_nth#4 ...
9 failed, 1026 passed, 45 skipped in 94.88s (0:01:34)
Command exited with non-zero status 1
WALL 95.36 s  USER 844.29 s  SYS 34.21 s  MAXRSS 149152 KB
```

The last line is from `/usr/bin/time`. `<scratch>` is a scratch directory. The Markdown and JSON reports written there were not committed.
