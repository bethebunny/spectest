# Trial: bitpattern 0.3.0 in spectest v2

The question is whether spectest v2 tests the same library as well as v1 did, from the same
informal spec, and what v2's design costs the writer of the formal spec. v1's report is
[../bitpattern/TRIAL.md](../bitpattern/TRIAL.md).

1. **Informal spec.** The same [INFORMAL_SPEC.md](../bitpattern/INFORMAL_SPEC.md) as v1. It has
   709 lines covering 68 public names and about 200 methods, and was written from bitpattern
   0.3.0's source in about 15 minutes. It was not changed.
2. **Formal spec.** A writer of the same kind as v1's read only INFORMAL_SPEC.md and spectest
   v2's docs, examples and binding API, never bitpattern's code. They wrote eleven `.spec` files
   (1,973 lines) and ten preludes (203 lines) with 314 functions and 848 clauses (102 of them
   `requires`, counted as v1 counts its 590). 203 of the functions are `variant.*` names (G3).
   The binding is [support.py](support.py) (880 lines, 165 functions),
   [test_bitpattern.py](test_bitpattern.py) (403 lines with eleven `spectest.check` objects and
   name maps of 259 entries) and [conftest.py](conftest.py) (19 lines, two converters).
   [TRANSLATION.md](TRANSLATION.md) lists the gaps G1 to G10 that v2 forced on the spec and the
   assumptions A1 to A5. Translating took 51 minutes (v1: 63). The writer spent 47.7 of them
   generating text (about 809k output tokens, most of it reasoning), and its tools ran for about
   4 minutes.
3. **Run.** The first runs exposed spectest gaps and lost test workers (see
   [Crashes](#crashes-and-stepped-slices)). After the fixes, and after the step was dropped from
   the three slice functions, the spec ran once against the installed library. Apart from the
   slices, the spec and binding are as the translator left them. Dropping the steps removed three
   `may_raise` clauses.

## Result

`uv run pytest trials/bitpattern-v2 -n 10 -q -rfEs --tb=short --durations=40 -p no:cacheprovider --spectest-timeout 30`

| | |
| --- | --- |
| Wall clock | **37.9 s** on 10 workers (125 s user CPU and 7 s system, 348% CPU). The longest item is `Char.category#2` at 31.3 s, which is the time of its whole declaration (see [Time](#where-the-time-went)). |
| Items | 1,783: **1,591 passed, 13 failed, 166 skipped, 13 spec errors** |
| Skipped | All 166 are "no example applied", ie. every example of the item was skipped. No item was skipped as inconclusive, and the output reports no call that timed out. |
| Memory | The largest process peaked at 337 MB (344,676 KB, and a MB is 1,024 KB throughout). The machine's used memory went from 1,118 MB to 2,342 MB and back to 1,089 MB. |
| Machine | 12 cores and 15,906 MB under WSL2. The load average was 1.20 just before the run, with no other test processes. |

The counts and the 26 failing and spec error ids are the same as in the run before the Pattern
slice change.

| Check | Spec | Passed | Failed | Skipped | Spec errors |
| --- | --- | ---: | ---: | ---: | ---: |
| `test_bitpattern` | `bitpattern.spec` | 1,096 | 8 | 126 | 0 |
| `test_floats` | `floats.spec` | 90 | 1 | 2 | 0 |
| `test_chars` | `chars.spec` | 44 | 2 | 8 | 1 |
| `test_macs` | `macs.spec` | 34 | 0 | 1 | 4 |
| `test_uuids` | `uuids.spec` | 46 | 0 | 2 | 0 |
| `test_dates` | `dates.spec` | 29 | 0 | 2 | 4 |
| `test_ips` | `ips.spec` | 100 | 0 | 8 | 0 |
| `test_tuples` | `tuples.spec` | 51 | 0 | 4 | 0 |
| `test_enums` | `enums.spec` | 65 | 0 | 3 | 0 |
| `test_datetimes` | `datetimes.spec` | 29 | 0 | 1 | 4 |
| `test_floatfn` | `floatfn.spec` | 7 | 2 | 9 | 0 |

## The 13 failures and 13 spec errors: 8 causes

Line numbers are in bitpattern 0.3.0 as installed, and in spectest at this commit. Each cause
was checked against the source and a small experiment.

| Items | Counterexample | Cause | Whose |
| --- | --- | --- | --- |
| `Int.all#raises`, `Int.none#raises`, `Int.min#raises`, `Int.max#raises`, `Char.all#raises`, `Char.none#raises` (6 failures) | `bitpattern.codecs.Int.all(Int(1, "", signed=False))` raises `TypeError: 'cached_property' object is not callable` | These attributes are `functools.cached_property` (`codecs/codec.py:96`, `codecs/int.py:40`, `codecs/char.py:64`). The spec calls them as functions of the codec, as v2 does for any attribute. The driver reads a `property` through its getter (`driver.py:136`) and calls every other target, and a `cached_property` cannot be called. The TypeError is then judged as the library's. Assumption A2 had guessed these were plain properties. The same cause skips every example of `Int_named.min` and `Int_named.max` (as a "planned call"). | **spectest**: the driver does not read a `cached_property`, and reports its own failed call as an exception of the library |
| `IntSet_range_floats#1`, `#raises` | `IntSet.range(0.0, 1.0)` raises `AttributeError: 'float' object has no attribute 'bit_length'` | The informal spec says non-int bounds raise `TypeError` (**observed**). Without a width, `IntSet.range` first computes `max(stop - 1, 0).bit_length()` (`intset.py:129`), so a float `stop` of 1.0 or more leaks an AttributeError. With a width, the compiled `interval` raises TypeError. | **Library**: an internal error leaks, as in v1's `intset_range_float_stop`. The informal spec generalized from the bounds it tried. |
| The same two items | `IntSet.range(-1.0, 1.0)` raises `ValueError: IntSets can't hold negative numbers, got -1.0`, and `IntSet.range(0.0, 1.0, width=-3)` raises `ValueError: width -3 is out of range` | The clause is `raises TypeError when true`. The informal spec also says a negative `start` and a negative explicit width raise `ValueError`, and the clause leaves no room for either. In a rerun of the declaration, 50 calls with a negative start and 19 with a negative width raised ValueError, beside 20 AttributeErrors (Hypothesis's shrinking calls included). The 41 passing examples raised TypeError. | **Translation**: two stated rules left out of one clause |
| `Int_range_floats#2` | `Int(1, "", signed=False).range(-1.0, inf)` returns the whole set `{0, 1}` | The same claim for codecs. `Int.range` clamps each bound with `max(start, self.min)` and `min(stop, self.max + 1)` before it builds the set (`codecs/int.py:70`), so a float outside `[min, max + 1]` turns into an int. Other float bounds raise TypeError (98 pass, 2 fail). | **Library**: inconsistent checking, as in v1's `int_range_float#1`. The informal spec makes the same overstatement. |
| `FloatFN_set#type`, `FloatFN_range#type`, `FloatFN_codec#type` | `FloatFN_set("all")` returns a set whose codec has the fields `width`, `name`, `exponent` and `format` | `FloatFN` subclasses `Float` and keeps its `format` field, with the default `""`. A dataclass crosses as a record of all its fields (G1), and the spec's `record FloatFN` lists only the three constructor parameters (assumption A2, from `FloatFN(width, name, exponent)` in the informal spec). The message "expected FloatFN, got record (no field format)" means that the declared record has no field `format`. Each type failure also skips the other clauses of its declaration (9 items in `test_floatfn` and 1 in `test_floats`). | **Translation**, on a point the informal spec leaves open. It gives FloatFN's constructor and calls FloatFN a variant of Float, without listing fields. |
| `numpy.from_dlpack.dtype` | An empty `IntSet` of width 15 exports as `uint16`, and the clause expects `uint8` | Two rules of the informal spec disagree for an empty set wider than 8 bits: "the narrowest unsigned type that holds its width" and "the empty set gives an empty `uint8` array". The library picks the type by width alone (`unsigned(self.width)`, `intset.py:192`). The clause gave the empty set priority (83 pass, 17 fail). | **Informal spec**. v1's translator saw the same conflict and judged the dtype only where both rules agree. |
| `MAC_codec.same_constant`, `Char_char.table`, `MAC_encode_int#1`, `#type`, `#raises` (5 spec errors) | `const bitpattern.codecs.mac` reads as a `builtins.module` handle, and `bitpattern.codecs.mac.encode` does not resolve ("has no attribute encode") | `bitpattern.codecs` exports the codecs `mac` and `char` under the names of its submodules `mac.py` and `char.py`. In Python `bitpattern.codecs.mac` is the codec. The driver resolves a name by importing its longest importable prefix (`driver.py:240`), so it gets the submodule. No other codec constant shares a submodule's name. | **spectest**: name resolution prefers a submodule to the package attribute that shadows it. This is new with qualified names and is not among G1 to G10. |
| `Date_range.size`, `.edges`, `#type`, `#raises` and `DT_range#1`, `.size`, `#type`, `#raises` (8 spec errors) | `gen: no values of type datetime.date` (and `datetime.datetime`) | The parameters are `option<datetime.date>` and `option<datetime.datetime>`. The generator draws a model parameter through one of the model's `build` lines. Inside an option or a list it has no case for a model (`host/gen/value.mojo:132`). A probe spec gives the same spec error for `option<M>` and `list<M>` parameters and passes for a plain `M`. `DT_range` passed one example, in which both options were `none`. | **spectest**: the checker accepts the type and the generator cannot draw it. G8 records the same kind of gap for a choice of constants, but not this one. |

## Where the time went

Two items took more than 10 s. With grouping, a declaration runs once on one worker, and its
whole time is charged to the first of its items.

- `Char.category#2` (31.3 s) is all of `Char.category`. A generated `Char` codec is a record
  with any width from 1 to 255 (G8). bitpattern builds its category table by walking all
  1,114,112 code points, and caches it per width (`_category_points`). A rerun of this
  declaration alone drew 53 distinct widths. Their 53 table builds took 88.1 s of the
  declaration's 88.6 s, on a machine that Mojo builds running alongside kept at a load average
  near 10. The slowest single build took 7.1 s, well under the 30 s limit.
- `from_set_minimal.first_member` (13.6 s) is all of `from_set_minimal`. Its adapter runs a
  whole `hypothesis.find` inside each call, and the declaration makes 100 calls. One `find`
  over a small set took 50 to 216 ms on the loaded machine.

Every other item took 3.2 s or less. `Char.category` keeps one worker busy for 31 s, so it sets
the wall clock of the whole run. In the run before the Pattern slice change,
`Pattern_slice.members` took 90.4 s and set it instead.

## Crashes and stepped slices

- The first v2 runs lost xdist workers ("node down: Not properly terminated"). The kernel log
  shows five Python processes killed by the out-of-memory killer between 21:52 on 26 October
  and 07:40 on 27 October, each holding 2.9 to 6.3 GB of anonymous memory (2,996,856 to
  6,618,468 kB).
- `Pattern_slice` caused them. It drew patterns up to 127 bits wide and slices with a step, eg.
  `p[::25]` on a pattern of 2^127 members. bitpattern 0.3.0 builds the slice one position at a
  time for any step other than 1 (`self & IntSet(map(self.__getitem__, positions))`,
  `intset.py:213`). Such a call cannot finish. Its memory grows by about 70 MB/s (the
  diagnosis's measure), and a rerun reached 566 MB after 9.3 s on the loaded machine.
- A plugin bug multiplied the damage. xdist grouping never reached the workers, so every worker
  that held any clause of a declaration ran the whole declaration. In the diagnosis run
  `Pattern_slice` ran on 5 workers and `diagram_cells` on 6. Commit 18b0678 fixed this.
  `test_bitpattern` alone then took 97.2 s on 10 workers, with no crash.
- With the 30 s limit and the grouping fix, the run before the Pattern slice change completed.
  It took 96.7 s wall and 214 s user CPU, with the same counts as this run.
  `Pattern_slice.members` took 90.4 s, and three calls were stopped at the limit (widths 69, 127
  and 63, slices `[-16:3:-15]`, `[::25]` and `[827133965:-22:26]`). Its largest process peaked
  at 2.3 GB (2,423,676 KB).
- **The finding.** bitpattern's author says nothing in bitpattern is meant to support stepped
  slicing, for exactly this reason. bitpattern 0.3.0 accepts a step on `IntSet`, `Pattern` and
  `BDDSet` (`IntSet([1, 2, 3, 4, 5])[::2]` is `IntSet([1, 3, 5], width=3)`), at a cost that
  grows with the size of the set. This is a library finding. The informal spec describes the
  step as the library behaves (`s[a:b:c]` "is the set of members at positions
  `range(size)[a:b:c]`").
- The steps were then removed from `IntSet_slice` and `BDDSet_slice` (ddb5778) and from
  `Pattern_slice` (a3699dc), as TRANSLATION.md's "Changes after translation" records.
  `Pattern_slice` is no longer among the 40 slowest items.

## Interpretation

- **v2 needed spectest fixes before a clean run.** v1 ran unchanged. v2's first runs needed a
  per-call time limit, explicit examples converted to wire values, spec errors kept apart from
  failures, and xdist grouping that reaches the workers. The run then shows three more spectest
  causes (the cached properties, the shadowed modules and options of models). They cost 6
  failures and 13 spec errors, against one spectest cause of seven in v1 (a doc ambiguity). All
  three are in parts new to v2.
- **A fourth spectest bug fails nothing and hides coverage.** The host never judges the
  invariants of a model held in a record result, since `handles_of` (`host/run/util.mojo:53`)
  has no case for records. In a probe spec, `fn f(n: u8) -> Wrapped` with
  `record Wrapped { box: M, tag: string }` skips `M`'s invariant on all 256 examples, and
  `fn g(n: u8) -> M` checks it. In `test_bitpattern` 64 of the 126 skipped items are the four
  `IntSet` invariants of the 16 functions that return a `BDDSet` record. For 8 of those
  functions most calls return normally, so their 32 items are lost coverage. (These counts come
  from the JSON report of the diagnosis run of `test_bitpattern`, which has the same 126 skips.)
- **The findings overlap v1's.** Both float-bound findings came back with
  the same causes. The informal spec's conflict over the dtype of an empty export, which v1 saw
  and stepped around, now fails. The stepped slice is new. None of v1's three translation slips
  recurs. v2 makes a star that expands to no `?` a `may_raise` (A3), does not state the error
  message that held v1's `"08"`, and leaves out custom time zones (G8). v1's `bdd_node#2`
  conflict is still in v2's spec (`BDD_new#1` and `.collapses`), but no example in the run gave
  both children as one node above `bit`.
- **Size and shape.** v2's spec is 1,973 lines of `.spec` and 203 of preludes against v1's
  2,594, with 314 functions and 848 clauses against 236 and 590. The binding shrank from 1,685
  lines to 1,302 (support.py, test_bitpattern.py and conftest.py). The run has 1,783 items
  against 1,080. More functions and clauses account for part of the difference. `#frame` items
  (new in v2) and model invariants account for the rest. `test_bitpattern`'s 1,230 items include
  153 `#frame` items and 249 invariant items.
- **Coverage.** v2 draws real examples from `strategies.from_set` and checks its minimal
  example, which v1 left out of scope. It loses custom Float, IP and DateTime codecs (G8), so
  v1's negative-offset failure has no counterpart. It samples `Float_decode` where v1 decoded
  all 65,536 float16 encodings. Of `test_bitpattern`'s 126 skips, 64 are the record invariants
  above. 47 are `#type` and invariant items of calls that always raise by design, as v1's 45
  were. 11 are hidden by the cached properties. The last 4 are `Int_pattern`'s `width`, `size`,
  `members` and `#type`. All 100 of its calls raised, because a random codec width almost never
  matches a random pattern's width.
- **Run time.** v2 ran 1,783 items in 37.9 s and 125 s of user CPU. v1 ran 1,080 in 95 s and
  844 s, and its longest item was the exhaustive float16 decode at 56 s. v2's two slow
  declarations spend their time inside bitpattern and inside the adapter's nested Hypothesis
  search, and `Char.category` alone sets the wall clock. The run before the Pattern slice change
  took 96.7 s and 214 s of user CPU, most of it in `Pattern_slice`.
- **What v2's gaps cost the translator.** The translation took 51 minutes against v1's 63, and
  nearly all of it was the writer generating text. The gaps shaped what it wrote. G3 (one
  signature per qualified name) made 203 of the 314 functions `variant.*` aliases. The IntSet
  operators with an operand that is not an IntSet take 24 functions, one per operator and kind of
  operand (eg. `IntSet_or_list`, `IntSet_xor_floats` and `IntSet_rsub_list`). v1 covered about
  the same ground with five functions that take the operator as a parameter (`combine`,
  `combine_iterable`, `combine_reflected`, `combine_ints` and `combine_bad`). G1 (a record cannot hold a
  generated object) made every function of a `BDDSet` take `(codec, storage)` and split the spec
  into eleven files, one per `BDDSet` flavour. Most of support.py's 165 functions bridge a gap.
  They rebuild a `BDDSet` from its codec and storage (G1), add keyword arguments (G2), build
  values that a converter cannot pass back (G6), list iterators (G7) or pick a table codec by
  name (G8). The name maps need 259 entries. Two of the run's causes go back to assumption A2.
  Its first half (record fields are the constructor's parameters) was needed because of G1, and
  it broke for FloatFN. Its second half (attributes are plain properties) broke for the cached
  properties. The shadowed modules and the options of models are gaps the translator could not
  have known.
- **What each fix changed.**
  - The per-call time limit (`--spectest-timeout`) turned a worker killed by the OOM killer into
    three inconclusive examples, and the run before the Pattern slice change finished in 96.7 s.
  - Grouping that reaches the workers runs each declaration once. Before it, five workers each
    ran `Pattern_slice`.
  - Converting explicit examples to wire values fixed 28 of the first runs' 29 `test_floats`
    failures. This run has one.
  - Reporting spec errors as pytest errors keeps the 13 spec errors out of the failure count.
  - Dropping the step (a spec change) cut the wall clock from 96.7 s to 37.9 s, user CPU from
    214 s to 125 s and the largest process from 2.3 GB to 337 MB, with the same counts.

## Test output

The spectest summary, the ten slowest items, pytest's short summary and `/usr/bin/time -v`'s
main lines. `-rs` printed 41 `SKIPPED` lines (166 items), all "no example applied".

```
=================================== spectest ===================================
trials/bitpattern-v2/test_bitpattern.py::test_bitpattern (spec bitpattern): 1096 passed, 8 failed, 126 skipped
trials/bitpattern-v2/test_bitpattern.py::test_floats (spec floats): 90 passed, 1 failed, 2 skipped
trials/bitpattern-v2/test_bitpattern.py::test_chars (spec chars): 44 passed, 2 failed, 1 spec error, 8 skipped
  SPEC ERROR variant.Char_char.table: expected Char, got handle <builtins.module #19> (at trials/bitpattern-v2/chars.spec:24:18: bitpattern.codecs.char)
trials/bitpattern-v2/test_bitpattern.py::test_macs (spec macs): 34 passed, 4 spec errors, 1 skipped
  SPEC ERROR variant.MAC_codec.same_constant: expected MAC, got handle <builtins.module #1> (at trials/bitpattern-v2/macs.spec:20:42: bitpattern.codecs.mac)
  SPEC ERROR variant.MAC_encode_int#1: bitpattern.codecs.mac has no attribute encode
  SPEC ERROR variant.MAC_encode_int#type: bitpattern.codecs.mac has no attribute encode
  SPEC ERROR variant.MAC_encode_int#raises: bitpattern.codecs.mac has no attribute encode
trials/bitpattern-v2/test_bitpattern.py::test_uuids (spec uuids): 46 passed, 2 skipped
trials/bitpattern-v2/test_bitpattern.py::test_dates (spec dates): 29 passed, 4 spec errors, 2 skipped
  SPEC ERROR variant.Date_range.size: gen: no values of type datetime.date
  SPEC ERROR variant.Date_range.edges: gen: no values of type datetime.date
  SPEC ERROR variant.Date_range#type: gen: no values of type datetime.date
  SPEC ERROR variant.Date_range#raises: gen: no values of type datetime.date
trials/bitpattern-v2/test_bitpattern.py::test_ips (spec ips): 100 passed, 8 skipped
trials/bitpattern-v2/test_bitpattern.py::test_tuples (spec tuples): 51 passed, 4 skipped
trials/bitpattern-v2/test_bitpattern.py::test_enums (spec enums): 65 passed, 3 skipped
trials/bitpattern-v2/test_bitpattern.py::test_datetimes (spec datetimes): 29 passed, 4 spec errors, 1 skipped
  SPEC ERROR variant.DT_range#1: gen: no values of type datetime.datetime
  SPEC ERROR variant.DT_range.size: gen: no values of type datetime.datetime
  SPEC ERROR variant.DT_range#type: gen: no values of type datetime.datetime
  SPEC ERROR variant.DT_range#raises: gen: no values of type datetime.datetime
trials/bitpattern-v2/test_bitpattern.py::test_floatfn (spec floatfn): 7 passed, 2 failed, 9 skipped
============================= slowest 40 durations =============================
31.34s call     trials/bitpattern-v2/test_bitpattern.py::test_chars::bitpattern.codecs.Char.category#2@trials/bitpattern-v2/test_bitpattern.py::test_chars::bitpattern.codecs.Char.category
13.56s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.from_set_minimal.first_member@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.from_set_minimal
3.17s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.diagram_cells.cube@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.diagram_cells
2.71s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.strategies.from_set.members@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.strategies.from_set
2.48s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.pattern.Pattern.branches.empty@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.pattern.Pattern.branches
1.67s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::numpy.from_dlpack.dtype@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::numpy.from_dlpack
1.49s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.intset.IntSet.__invert__.width@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.intset.IntSet.__invert__
1.46s call     trials/bitpattern-v2/test_bitpattern.py::test_floats::variant.Float_range#1@trials/bitpattern-v2/test_bitpattern.py::test_floats::variant.Float_range
1.30s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.bdd.BDD.__xor__.pointwise@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.bdd.BDD.__xor__
1.17s call     trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.bdd.lshift.shifted@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.bdd.lshift
=========================== short test summary info ============================
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.all#raises@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.all
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.IntSet_range_floats#1@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.IntSet_range_floats
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.IntSet_range_floats#raises@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.IntSet_range_floats
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.none#raises@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.none
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.Int_range_floats#2@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::variant.Int_range_floats
FAILED trials/bitpattern-v2/test_bitpattern.py::test_floatfn::variant.FloatFN_set#type@trials/bitpattern-v2/test_bitpattern.py::test_floatfn::variant.FloatFN_set
FAILED trials/bitpattern-v2/test_bitpattern.py::test_floatfn::variant.FloatFN_range#type@trials/bitpattern-v2/test_bitpattern.py::test_floatfn::variant.FloatFN_range
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::numpy.from_dlpack.dtype@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::numpy.from_dlpack
FAILED trials/bitpattern-v2/test_bitpattern.py::test_chars::bitpattern.codecs.Char.all#raises@trials/bitpattern-v2/test_bitpattern.py::test_chars::bitpattern.codecs.Char.all
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.min#raises@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.min
FAILED trials/bitpattern-v2/test_bitpattern.py::test_floats::variant.FloatFN_codec#type@trials/bitpattern-v2/test_bitpattern.py::test_floats::variant.FloatFN_codec
FAILED trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.max#raises@trials/bitpattern-v2/test_bitpattern.py::test_bitpattern::bitpattern.codecs.Int.max
FAILED trials/bitpattern-v2/test_bitpattern.py::test_chars::bitpattern.codecs.Char.none#raises@trials/bitpattern-v2/test_bitpattern.py::test_chars::bitpattern.codecs.Char.none
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_codec.same_constant@trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_codec
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range.size@trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range.edges@trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range#type@trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range#raises@trials/bitpattern-v2/test_bitpattern.py::test_dates::variant.Date_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range#1@trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range.size@trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range#type@trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range#raises@trials/bitpattern-v2/test_bitpattern.py::test_datetimes::variant.DT_range
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_chars::variant.Char_char.table@trials/bitpattern-v2/test_bitpattern.py::test_chars::variant.Char_char
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_encode_int#1@trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_encode_int
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_encode_int#type@trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_encode_int
SPEC ERROR trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_encode_int#raises@trials/bitpattern-v2/test_bitpattern.py::test_macs::variant.MAC_encode_int
13 failed, 1591 passed, 166 skipped, 13 errors in 36.56s
Command exited with non-zero status 1
	Command being timed: "uv run pytest trials/bitpattern-v2 -n 10 -q -rfEs --tb=short --durations=40 -p no:cacheprovider --spectest-timeout 30"
	User time (seconds): 124.94
	System time (seconds): 7.09
	Percent of CPU this job got: 348%
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:37.85
	Maximum resident set size (kbytes): 344676
	Exit status: 1
```

The spec error lines printed absolute paths, shown here from the repository root. The previous
run's output and the diagnosis files were kept outside the repository.
