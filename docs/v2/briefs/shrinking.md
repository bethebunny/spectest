# Brief: shrinking

Counterexamples that reach the minimal input in the cases where they now stop short.
The builders of gen, runner and stateful each found one.

**Owns:** `host/mcheck/shrink.mojo`, list drawing in `host/gen/value.mojo`, spec-error
shrinking in `host/run/` (`runner.mojo` and its helpers), and the tests:
`tests/host/mcheck/test_shrink*.mojo`, `tests/host/gen/test_shrink*.mojo` and
`tests/run/test_shrinking.py`.

**Read first:** `host/mcheck/` (choices, spans, the shrink passes, `smaller`),
`host/gen/value.mojo` (`_draw_list`, the long-list path), `host/run/runner.mojo`
(how a failure is shrunk and how spec errors are reported), `docs/language.md`
(Shrinking), `docs/v2/mojo.md`. Hypothesis's shrinker is the model for the new passes.

## The cases

1. **Choices that must move together.** A property failing when `x == hi` and
   `lo < x`, with all three drawn, stops with large values: lowering any one choice
   alone breaks the failure. Add passes that:
   - lower every choice holding the same value together (Hypothesis's duplicated-block
     minimization);
   - lower two nearby choices by the same amount.
   Each pass searches its step size as the minimize pass does.
2. **Long lists.** A long list (17 to 100 elements, drawn one time in 16) has its
   length drawn as an exact count. Deleting an element's span then no longer replays,
   so a long counterexample keeps all its elements: the stateful tests saw 81. Draw a
   long list's elements as a sequence that deletion can shorten. Keep its length
   bounds and its palette of repeated values. Let switching the long flag off be
   tried, as deleting choices does.
3. **Spec errors.** A spec error is reported once per message with its first input,
   unshrunk. Shrink it as a failure is shrunk, keeping a candidate only when it raises
   a spec error with the same message up to the values in it, as v1 does
   (`docs/language.md`, Shrinking).

## Acceptance

`uv run pytest tests/host/mcheck tests/host/gen tests/run` passes, with new tests
showing:

- `x == hi and lo < x` over ints in [0, 1000] shrinking to `lo = 0, x = hi = 1`;
- a property failing for lists of at least 20 elements shrinking to exactly 20, and
  one failing for a list containing 7 shrinking to `[7]` even when first found long;
- the stateful Leaky case from `tests/run/test_stateful.py` ending with a short list
  argument;
- a spec error reported with a shrunk input, and two different spec error messages
  each kept and shrunk on their own;
- the existing shrink results unchanged (`[100]`, 1000, 501 and -501, `[10]`, the f64
  just above 1.0).

Shrinking must not slow down passing runs; print the time of a passing 1,000-example
search before and after.

## Out of scope

Changes to generation's distributions other than how long lists are drawn.
