# bitpattern.spec: what the translation leaves out

`bitpattern.spec` formalizes INFORMAL_SPEC.md as 236 spec functions, each bound in
`test_bitpattern.py` to an adapter that builds its inputs from plain values (a set from a list
of ints and a width, a pattern from its quartets, a diagram from a list of bit characters),
makes one call into bitpattern and returns what the spec observes. This file lists what could
not be formalized or only approximately, and why: a gap in the language, a limit of the
binding, or an ambiguity in the informal specification.

## Language gaps

| Informal requirement | What the spec does | Why |
| --- | --- | --- |
| Laws at any width, such as `(a \| ~a).size == 2**a.width` | Checked at small widths only: complements up to 10 bits, IntSet results up to 16 bits | No exponentiation. Powers of two are written out as tables, and the IntSet model lists every member. |
| Sizes "of any magnitude" | Checked through `IntSet.range` (ints up to about 2**128) and the codec tables | The same reason. |
| Associativity, distributivity, De Morgan, `IntSet(list(a), width=a.width) == a` | Implied by the per-operator definitions (membership and width), not built as compositions. Only commutativity, inclusion-exclusion, `~~a == a` and `a <= b iff a - b is empty` are checked as relations. | No user-defined functions, and models have no `==`, so every law is restated over observed members. |
| Named codec sets as sets (`finite`, `nan`, `float16.range() == all - nan`, `oui == range(...)`) | Checked by size and by membership of individual encodings | Partition sets are not values in clauses. |
| reprs with arbitrary numbers (`IntSet([...], width=W)`, `BDDSet(...)`, `<Pattern: K branches, ...>`) | Prefix, suffix, elision and joining rules, the documented examples exactly, and an `eval(repr(s))` round trip | There is no int-to-decimal function. `count_repr` is checked by parsing its digits. |
| `strategies.from_set`: every member can be generated, values are `source[i]`, the minimal example is `source[0]` | Only that it returns a Hypothesis `SearchStrategy` | The result is a strategy. Drawing from it needs a nested Hypothesis run inside an implementation call. |
| `choice` is uniform | Membership and reproducibility only | Not expressible per example. |
| O(width) and O(\|a\| * \|b\|) performance | Not formalized | `perf` clauses are not judged. |
| DLPack: the export is a fresh copy, float8 dtypes are labelled version 1.1, `tensor(...)` | Not formalized | It needs the capsule's C struct. Only the capsule's name is read (`dltensor` or `dltensor_versioned`, the DLPack standard's names). |
| `repr` of a member past Python's decimal limit (`IntSet([2**20000])`) | Not formalized | 2**20000 is beyond the generated values and the tables. |
| DST rules of `DateTime` with zone names (`America/New_York`: non-existent and repeated local times, `fold`) | Not formalized. Only fixed-offset zones and the naive codec are covered. | The spec would need the time-zone database. |
| `datetimes.range(...)` size example | Not formalized (`dates.range` is) | Only for brevity. It follows from the encoding, which is checked. |
| float8 rounding | Computed with spacings derived from `ulp<f16>`, and checked through a relation with `float8_decode` | The language has no `round<f8>` or floor of a real. A floor is counted, which is valid below 2**16. Larger values only need the overflow rule. |

## Binding limits

- Inputs are built from small, generated plain values. Sets have at most 8 items (u8), or up to 100
  for a sixteenth of the lists. Patterns have quartets of up to 4 characters, so an over-long quartet
  (`"11111"`) only comes from an explicit example. Flags use two fixed classes (`Perm`: R=4, W=2,
  X=1, and `Tree`: LEAF=4, CHAIN=12, LOW=1). Members use generated enums `E` with members
  `M0 ... M(n-1)`. Tuple fields are 8- and 16-bit ints.
- Exceptions map by class: `FrozenInstanceError` first, then `TypeError`, `ValueError`,
  `IndexError`, `OverflowError`, `AttributeError`, `BufferError`, `NotImplementedError`.
  `AddressValueError` counts as `ValueError`.
- Observers use the most basic operations: `list(s)`, `s.size`, `s.width`,
  `type(s).__name__`, and for a BDDSet `repr(s.codec)`, `s.codec.width`, `s.storage.width` and
  `e in s.storage`. A fault in those shows up as a spec error, not as a failure.
- Some adapters turn an outcome into a value: a `ValueError` from `p.bits` / `p.free` becomes
  `None` plus its message, `codec.pattern` and BDDSet operators return the message they raised,
  and `pattern_repr_eval` returns `None` for a repr that is not `Pattern(...)`.
- `codec_assign` assigns on `copy.copy` of the codec, so a codec that fails to refuse is not
  changed for other items.
- The binding reads the field names the constructors show: `Int(...).signed` and `Float(...).exponent`.

## Ambiguities, and the reading taken

- `s[a:b:0]`: "positions `range(size)[a:b:c]`" is read as raising `ValueError` like `range`.
- `IntSet | BDDSet` (an IntSet on the left of a BDDSet operator): section 1 converts any iterable
  of ints, while section 3.3 says IntSets raise `TypeError` "on either side". This case is left
  out. A BDDSet on the left is judged.
- The TypeError message "<codec> sets only combine with each other" is read as naming the left
  operand's codec.
- Empty IntSet export: "narrowest type for the width" against "the empty set gives an empty
  uint8 array". The dtype is judged only where both agree (width <= 8).
- Pattern repr, "joined text at most 200 characters": widths are kept to 8 bits, where every 1 to
  8 branch repr is under 200 characters under either reading.
- Whitespace stripped by `Pattern`: which characters count is not said. The spec judges only that
  any character outside `0 1 ? * .` and Python whitespace raises, and that all-whitespace text raises.
- Float encode of ints beyond 2**53: rounding the int directly and going through `float()` can
  differ, so ints are kept within ±2**53.
- `IntSet.bdd`'s highest tested bit below the width is unspecified, so the bdd functions use
  `may_raise ValueError` when their width is below the set's width.
- `char.category("Cn")` is taken as valid (a Unicode general category).
- `DateTime` with a negative fixed offset: "every microsecond representable in tz" is read as
  every instant whose local time fits `datetime` and whose encoding is not negative. So such a
  zone keeps the full size, and its encodings run past the naive maximum. Only the +01:00
  example is given.
- The float codecs' names are not given, so they are not judged.
- Interface objects "carrying a prefix" are tested with prefixes /8 and /64 only, not /32 or /128.
- MAC hex digits "either case" is read as any mix of cases within one address.
- Several statements marked **observed** are judged as written: width widening, negative widths,
  `numpy` items, attribute assignment, slices keeping type and width, seeded `choice`, branch
  order, `eval(repr(p))`, pickling, the observed exceptions for non-int bounds, and the float
  rounding examples.
