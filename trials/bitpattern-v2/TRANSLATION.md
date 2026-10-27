# bitpattern 0.3.0 in v2: translation notes

Source: `trials/bitpattern/INFORMAL_SPEC.md` only. The spec is split in eleven files because a v2 spec
file can declare one `BDDSet` record (see G1): `bitpattern.spec` (IntSet, Pattern, BDD, the Int
codec and its sets, strategies, DLPack), and one file each for floats, floatfn, chars, macs, uuids,
dates, datetimes, ips, tuples and enums. `test_bitpattern.py` holds one `spectest.check` per file
and the name maps; `support.py` the callables the maps point at; `conftest.py` two converters.

Tags: **[new]** caused by v2's design (qualified names, no binding layer, build lines, operators
host-only); **[tool]** a limit of the v2 host, driver or plugin; **[lang]** a gap in the language
(v1 has it too); **[inf]** the informal spec is silent, ambiguous or "observed" only.

## How v2 forced the spec's shape

- **G1 [new] Dataclass values are records, and a record cannot hold a generated object.** Codecs
  and `BDDSet` are frozen dataclasses, so they cross as `Record`s; a record containing a handle
  (`BDDSet.storage`) is never drawn, and a model needs a `Handle`, which a build cannot get from a
  dataclass. So every function of a `BDDSet` takes `(codec, storage)` and `support.py` rebuilds the
  set (`bddset_*`), widening the storage to the codec width. Record names are unqualified, so one
  spec file holds one `BDDSet` flavour, hence the file split. Codec methods take the codec as a
  plain first parameter, not `self`, since a receiver must be a model.
- **G2 [new, tool] Calls are positional.** The host never sends keyword arguments, so every
  keyword-only parameter (`width`, `rng`, `low_bit`, `stream`, ...) is bridged by a `support.py`
  function that adds the keyword, mapped over the library name with `modules=`.
- **G3 [new] One signature per qualified name.** The argument shapes of dynamically typed calls
  (a float, a list, a string where an int is expected) and the constructors (the class name is
  the model's, so `fn bitpattern.IntSet` collides with `model`) are declared as `variant.X` names
  and mapped back to the library callable: 203 of the 314 functions, and a map of about 260 entries.
  The same trick selects a codec by name (`kind`).
- **G4 [new] Operators are host-only.** Expressions cannot apply a library operator, so `a | b` is the call
  `bitpattern.intset.IntSet.__or__`. A direct dunder call differs from the operator when the
  operands do not fit (`NotImplemented`, reflected operands, `len` limits), so those cases call
  `operator.le`, `builtins.len` and so on, or the reflected dunder.
- **G5 [new] Model names must be the class's `module.qualname`.** A handle's class is compared with
  the model's qualified name, so models are named by the defining module: `bitpattern.intset.IntSet`,
  `bitpattern.pattern.Pattern`, `bitpattern.bdd.BDD`, not the public `bitpattern.IntSet`. See A1.
- **G6 [new] Enums and records cannot be qualified.** `enum` and `record` names are one word, so a
  library enum (`DType`, an enum member) fails the exact-name check on read; `conftest.py` converts
  enum members to their name and a `Flag` to its value. Converters are one way: a converted class
  can only be read, never passed back, so dates, UUIDs, addresses and enum members are models built
  by `build` lines or `support.py`, and `Members`/`Flags` are exercised over enums defined there.
- **G7 [tool] Iterators and ndarrays are opaque.** `members`, `blocks`, `paths`, `networks`, the
  slice objects and `numpy.from_dlpack` cross as lists (first 513 items) or as `(dtype, shape,
  items)` through `support.py`; `from_set` as drawn examples.
- **G8 [tool] A choice of constants (`int8 | uint16`) type-checks but the generator draws nothing for
  it**, so a generated codec is a record (Int, Char) and the table codecs are named by `kind`.
- **G9 [lang] `raises ... when` cannot call spec functions.** Conditions needing a library answer
  (membership, rank, a diagram's count) go through observers whose reading expressions call
  `support.py` (`has`, `rank`, `total`, `branch_list`).
- **G10 [tool] Observers are all read for the frame check**, so no zero-argument observer may be
  expensive: members are read through `head(n)` / `last(n)`, guarded by `size`.

## Assumptions

- **A1** Home modules (G5) are inferred from section 7 (`intset.written`, `pattern.dotted`,
  `dlpack.unsigned`) and the section 0 table. If a class's `__module__` differs, every result of that
  model fails `#type`; this is the first thing to check in the run.
- **A2** Dataclass fields are the constructor parameters of section 3: `Int(width, name, signed)`,
  `Float(width, name, exponent, format)`, `FloatFN(width, name, exponent)`, `IP(width, name,
  address_type, network_type)`, `DateTime(width, name, tz)`, `Tuple` with `fields`, `BDDSet(codec,
  storage)`. Operators are the Python dunders; attributes (`size`, `min`, `all`, `branches`, the named
  sets) are properties or slots, not `cached_property`, which the driver cannot call.
- **A3** Statements marked **observed** are asserted as written (branch order and determinism,
  `exactly_these` and `IntSet` treating a negative width as 0, `IntSet.range` raising for a negative
  width). A star that expands to no `?` (`1111*`) and `lshift` by a negative amount are `may_raise`.
- **A4** `IntSet.range` with an explicit width: only the size is asserted (the clipped range), not the
  width. `freed_between` with `low_bit >= high_bit` is the empty range. Sets are drawn from `u8`/`u16`
  items and widths up to 200 (`requires`), so deep diagrams do not meet the recursion limit.
- **A5** `repr` and `str` clauses are exact for up to ten members (IntSet, BDDSet) or three branches
  (Pattern), and only for Patterns whose size is not a power of two when it is printed (the informal
  spec does not say if `count_repr` formats it).

## Not formalized, or only approximated

- IntSet: int-like items (`bool`, numpy ints, `__index__`) and non-int `range` bounds other than
  floats cannot be generated **[tool]**. `choice` uniformity is statistical **[lang]**. Associativity
  and distributivity need three operands, so two-operand absorption/idempotence stand in **[lang]**.
  `isinstance(s, abc.Set)` needs a class argument (G8). A member too long for the decimal limit
  printed in hex (**observed**) is not stated. "Operations return new sets" is only the frame check.
  Complexity promises (section 7) are not stated; `perf` is never evaluated.
- Pattern: `*` is checked for validity, width and size, but the expanded bits are not (no string
  join in expressions) **[lang]**; whitespace stripping (**observed**) not stated; `str`/`repr` of
  more than three branches and `eval(repr(p)) == p` not stated (no join, no eval) **[lang]**.
- Public surface: the three identities `bitpattern.IntSet is bitpattern.intset.IntSet` etc. cannot
  be stated since the model and a constant would share one name **[new]**; `BDDSet`, `Codec` and
  `OrderedCodec` identities and `__version__` are.
- BDD: `tensor` (a capsule) not stated; `blocks`/`members`/`paths` see only the first 513 items
  (G7); `lshift` by a negative amount is `may_raise`: the lowest tested bit is not observable **[inf]**;
  `collect()` and `stats()` are diagnostic (non-negative ints, the key names).
- Codecs: custom Float, IP and DateTime codecs (G8); `Fraction`/`Decimal`/numpy inputs to `Float.encode`
  **[tool]**; rounding of the two 8-bit formats (the prelude rounds only to f16, bf16, f32, f64), so
  their `encode` is checked by round trip and the special values **[tool]**; `Float` iteration order
  of a range (`[0] == 0.0`); codec equality across classes; pickling of codecs and sets; the default
  `OrderedCodec` min/max/range as a generic law (the concrete codecs' values are stated instead).
- Char: lone surrogates cannot be passed (host strings are scalar values), so the surrogate
  `ValueError`s and the "decode does not reject surrogates" observation are out **[tool]**;
  `category` is stated for ASCII only, the rest being Python's `unicodedata` **[lang]**.
- IP: `networks` and `cidr` over strings and ints, `range` over ints only (not strings or address
  objects), `"10.1.2.3" in ipv4 set` and `cidr(network object)` not stated. MAC: `range`, and
  `oui == range`. DateTime: fixed-offset and named zones (names, sizes, `min`), daylight saving and
  folds, a `tzinfo` with a `None` offset. UUID: the 32-quartet patterns.
- Members/Flags: the `Members`/`Flags` codec fields (only width and name are read), a `Flag` boundary
  that makes `decode` raise, and `having(W) == pattern("?1?")` as set equality (stated on members).
- Tuple: two `Int` fields only; `Tuple(*fields)` and `product(*sets)` are variadic **[lang]**, mixed
  field codecs need another `BDDSet` record (G1) so the `ipv4 x uint16` example is out;
  `source <= product(project(source, 0), project(source, 1))` not stated.
- BDDSet: `iter`/`reversed` and `len`'s `OverflowError` (G1: stated through `getitem`/`size`);
  DLPack of 128-bit rows, float dtypes and the capsule version labels; `from_set` of a BDDSet;
  "every member can be generated" is statistical.

## Checks made

The helper definitions of the preludes (decimal text, dotted bits, slice positions, the Pattern syntax
rules, float layout, decoding and rounding, the named sets, ASCII categories, MAC text, flag unions)
were run against independent Python references; the spec's own test items have not been run.
