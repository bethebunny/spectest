# Brief: mcheck

The input engine: generation, search, shrinking, enumeration and replay, in the
spirit of Hypothesis's design. It is part of spectest for now, but its API names no
spectest type, so it can later be a property-testing library for Mojo.

**Owns:** `src/mcheck/`, `tests/mojo/mcheck/`.

**Read first:** the design doc's mcheck section (summarized here), `docs/v2/mojo.md`.
Hypothesis's own design is the model: every example is drawn from a recorded sequence
of choices, and replay and shrinking work on that sequence, never on values.

## Deliver

1. **Randomness:** a deterministic generator (splitmix64 to seed, xoshiro256\*\* to
   draw). The same seed and generator code give the same examples on every machine.
2. **Choices and Source.** `Choices` records each choice (its value and its bound)
   and spans (start, end, an integer label) marking structure. `Source` is what
   generators draw from, generating from the generator or replaying a `Choices`
   (running past the end makes the example invalid):
   - `draw_bits(n)`, `draw_below(n)` (uniform in [0, n)), `draw_int(lo, hi)`
     (inclusive, Int64, with about 1 in 8 draws taking an edge: `lo`, `hi`, 0, 1 or
     -1 when in range), `draw_bool(p)`, `draw_choice(n)` (an index);
   - every choice shrinks toward 0 in its encoding, and `draw_int` encodes so that
     smaller magnitudes near 0 (or near `lo` when 0 is out of range) are smaller;
   - `start_span(label)` and `stop_span()`;
   - `Many(min, max, average)`, a loop helper for collections (`while many.more(src)`)
     whose elements shrinking can delete;
   - `reject()` marks the example invalid; a budget of choices per example.
3. **Properties.** `trait Property` with `def run(mut self, mut src: Source) raises ->
   Outcome`. One run judges one example against several properties: the `Outcome`
   lists, by integer property id, each property that passed, failed or skipped, or
   says the example was invalid.
4. **Search.** `search[P: Property](mut prop: P, settings) raises -> SearchResult`.
   It replays stored failures first, then generates until `max_examples` valid
   examples. It keeps each property's first failure, then shrinks each failing
   property on its own, and returns per property: the shrunk `Choices`, pass, fail
   and skip counts; plus examples run, invalid examples, and time taken.
5. **Shrinking.** `shrink[P](mut prop, choices, property_id, budget) -> Choices`.
   Passes over the sequence: delete spans (larger first), delete single choices,
   zero choices, minimize each choice by binary search toward 0, and lower one choice
   while raising another. A candidate is kept only when replaying it is valid and
   fails the same property. Order: shorter first, then lexicographically smaller.
6. **Enumeration.** `enumerate_all[P](mut prop, n, settings)` runs the property once
   for each index in [0, n), drawn as the example's first `draw_below(n)`, or on a
   uniform sample of indices when `n` is over `settings.max_exhaustive`. Same result
   shape; a failure is the smallest failing index, not shrunk.
7. **Store.** Saves and loads `Choices` by string key under a directory, one small
   file per key. `search` replays every stored sequence for its keys first. The
   caller composes keys.
8. `Settings`: seed, max_examples, max_shrink_steps, max_choices, max_exhaustive,
   store directory (optional).

## Acceptance

`uv run pytest tests/mojo/mcheck` passes, covering:

- determinism: the same seed gives the same examples, and another seed doesn't;
- an int in [0, 10000] failing at x >= 1000 shrinks to exactly 1000;
- a list of ints in [0, 1000] failing when its sum >= 100 shrinks to `[100]`;
- a list failing when its length >= 3 shrinks to `[0, 0, 0]`;
- two properties in one search, one failing above 500 and one below -500 on an int
  in [-10000, 10000], shrink to 501 and -501;
- a property that never fails reports no failure and the right counts;
- a generator that rejects most examples reports the invalid count and stops at a
  cap rather than running forever;
- enumeration over 65,536 indices, failing when the index mod 1000 is 7, reports 7 and
  the number of failures;
- the store: a failure saved by one search is replayed first by a search with another
  seed;
- speed: 10,000 trivial examples run in under 50 ms (print it; assert under 500 ms).
  The engine's share of v2's 50 µs budget per example should be about a microsecond.

## Out of scope

Anything about spec types, partitions or values: that is the spectest side (gen,
wave 2), which turns spec types into calls on `Source`. Stateful step sequences come
later.
