# Brief: gen

The spectest side of input generation: values of spec types drawn from mcheck's
`Source`, steered by partition classes, with models built through their `build`
calls. mcheck stays free of spectest types; this package is where they meet.

**Owns:** `src/host/draw/`, `tests/mojo/host/draw/`.

**Read first:** `docs/language.md` (Declarations: partitions, generating model values,
sizes, shrinking), `src/mcheck/` (Source, Many, spans, Property, search),
`src/partition/` (`nth`, `count`, named sets), `src/spec/types.mojo`,
`src/spec/spec.mojo` (`Fn`, `Param`, `Model`, `Build`), `src/value/value.mojo`,
`src/value/float_formats.mojo`, `docs/v2/mojo.md`. v1 is the reference for
distributions and sizes: `spectest/generate.py`.

## Deliver

1. `draw_value(mut src: Source, mut types: Types, t: Int, sizes: Sizes, depth: Int)
   raises -> Value` for every type a parameter can have: bool; int (biased toward
   small values and edges); fixed-width integers and floats as bit patterns (with
   v1's emphasis on special values: zeros, infinities, NaNs, subnormals, extremes);
   string (code points, including some outside the BMP, never surrogates); bytes;
   `list`, `map` (distinct keys), tuple, option, literal unions, enums, records.
   `Sizes` carries v1's bounds: lists of at most 8 (4 when nested), strings of 12,
   bytes of 16. One top-level value in 16 is long (17 to 100 flat elements, strings
   of 25 to 100, bytes of 33 to 100), and a long list repeats up to 17 drawn values.
   `long_share = 0` turns long values off. Spans mark each value and element, so
   mcheck's shrinker deletes elements and simplifies values.
2. **Partitions.** `draw_in_classes(mut src, mut ctx, classes: List[BitSet], elem:
   Int) raises -> Value` draws a class, then a member through `nth` with a uniform
   index, so −0 is as likely as a normal float. `draw_predicate_class` is left to wave
   2b, when the evaluator exists: for a non-fixed-width parameter, draw a class index
   (or, as often as any one class, none) and let the caller filter.
3. **Small domains.** `domain_size(types, t) -> Optional[UInt64]` for types with at most
   2\*\*16 values (`bool`, `u8`, `i16`, `f16`, `bf16`, tuples of these within the
   bound), and `value_at(types, t, index) -> Value`, so a property can run exhaustively
   with `mcheck.enumerate_all`.
4. **Models.** `trait Builder` with `def build(mut self, model: Int, build: Int, args:
   List[Value]) raises -> Value`, which the runner implements by calling the driver.
   `draw_model(mut src, spec, model, mut builder, sizes)` picks one of the model's
   `build`s, draws its arguments by their declared types, and calls the builder. A
   build argument of model type is drawn recursively, with depth bounded. A build
   whose call raises makes the example invalid (`src.reject()`), never failed.
5. `draw_args(mut src, spec: Spec, fn: Int, ..., mut builder) raises -> List[Value]`:
   one value per parameter, in order, defaults included as v1 draws them, each
   parameter in its own span.

## Acceptance

`uv run pytest tests/mojo/host/draw` passes, covering:

- every type draws values of its kind within its bounds, over a few thousand draws
  each, with the long-value share near 1/16;
- floats reach each special class within a few hundred draws, and integer edges
  appear;
- strings never hold surrogates; map keys are distinct; records have their fields in
  order;
- class steering: with classes {nan}, {zero} and {normal} of f64, each is drawn about
  equally often;
- exhaustive enumeration visits every value of `u8`, `f16` and `(bool, u8)` exactly
  once;
- models: with a test `Builder` that records calls, a model with two builds uses both,
  arguments have their declared types, and a raising build rejects the example;
- shrinking through mcheck: a property failing for lists containing an element >= 10
  shrinks to `[10]`, and one failing for f64 values above 1.0 shrinks to a value
  just above 1.0;
- speed: drawing 10,000 values of `list<(i32, string)>` takes under 50 ms (print it).

Hand-build the `Spec`s you need: the checker is written at the same time.

## Out of scope

Predicate classes (wave 2b), stateful step sequences, the runner.
