# Brief: checker

Turns a parsed spec into a `Spec`: every name resolved, every expression typed, every
clause given its id, and every static rule of the language enforced.

**Owns:** `host/check/` except `types.mojo` and `spec.mojo`, which are contracts (add
only), and `tests/host/check/` (add to `test_contracts.mojo` only). The typing rules
of prelude functions are this package's: the prelude package evaluates them.

**Read first:** `docs/language.md` (all of it), `docs/v2/syntax.md`,
`host/check/types.mojo`, `host/check/spec.mojo`, `host/prelude/names.mojo`,
`host/syntax/` (`parse_spec`, the tree), `docs/v2/mojo.md`. v1 is the reference for
every rule it already has: `src/spectest/lang/checker.py`, `signatures.py` and their
tests in `tests/lang/`.

## Deliver

1. `check(var ast: Ast) raises -> Spec`, and `check_source(source, path) raises ->
   Spec`, which parses first. Collect every error. If there are any, raise one `Error`
   whose message is the diagnostics, one `path:line:col: message` per line, in source
   order. Use v1's message texts where the rule is v1's. Warnings go to
   `Spec.warnings`.
2. Everything v1's checker does on one file: declarations, aliases, enums, records,
   models, interfaces, functions, observers, type parameters and bounds, types of
   every expression, the equality and order rules, what each clause kind may
   reference, `old`, comprehensions, `let`, clause ids and labels, freedoms, and the
   typing of every prelude function in `prelude/names.mojo`. `use` and `prelude`
   declarations get a diagnostic, "not supported yet": only one file is checked for
   now.
3. v2's rules:
   - **Qualified names.** Functions, models, interfaces and constants are named by
     their qualified names. A qualified `fn` whose first parameter is `self` is a
     method of the model its prefix names: `fn bitpattern.IntSet.__or__(self, other:
     bitpattern.IntSet)` belongs to model `bitpattern.IntSet`, and `self` has its type.
     A missing model is an error. `Fn.target` is the qualified callable the driver
     resolves. An interface's constructor or method `m` has target `<interface>.m`.
   - **Calls in clauses.** A call whose callee spells a declared function's qualified
     name is a planned call (`R_SPEC_FN`). A method is called with its receiver first:
     `bitpattern.IntSet.__contains__(s, x)`. Planned calls are allowed in `ensures`,
     `relates`, `invariant` and `aggregate`. `requires` may call only prelude functions
     and definitions. A function whose `modifies` lists anything can't be called in a
     clause.
   - **Operators belong to the host.** Operators apply only to the types the language
     gives them. A model or interface value has none, so `x in s` on a handle is a
     type error.
   - **Errors.** `raises` and `may_raise` name qualified exception classes. A one-part
     name means `builtins.<name>` (`ValueError` is `builtins.ValueError`), and
     `Clause.error` holds the qualified form. An `error` declaration is accepted but
     not required.
   - **Constants.** `const q.name: T` adds to `Spec.consts`. The attribute chain
     `q.name` in an expression resolves to it (`R_CONST`). A choice type
     `a.b | a.c` needs every alternative declared with one type.
   - **Builds and observers.** `build` parameters are typed. An observer with
     `= expr` has its expression typed with `self` in scope, and that type must be
     the declared one.
   - **Definitions.** A `def` is typed: its body must have its declared result type.
     Definitions may call prelude functions and other definitions but not
     themselves, directly or through others; report the cycle. They resolve as
     `R_DEF`, and `requires` may call them.
   - **New operators and parts.** `a ** b` and `a << b`, `a >> b` take integers and
     give `int`. `**` with a negative literal exponent is an error. `&` and `|` also
     work on integers, as bitwise and and or. `e.steps` and `e.nans` read a qerr's
     parts (`R_QERR_PART`), and so do v1's `steps(e)` and `nans(e)`.
     `bit_length(int) -> int` and `from_codepoints(list<int>) -> string` join the
     prelude.
4. **Partitions.** Record each `Partition` and its classes (node ids). Type class
   expressions as v1 does: set expressions over a fixed-width parameter, predicates
   otherwise. Compiling the sets and checking that they are disjoint and cover the
   domain is the partitions package's job.

## Acceptance

`uv run pytest tests/host/check` passes, covering:

- v1's checker, diagnostics and signature tests (`tests/lang/test_lang_checker.py`,
  `test_lang_diagnostics.py`, `test_lang_signatures.py`), ported where the rule
  carries over, with the same messages;
- every existing spec checks without errors: `examples/*/*.spec` and
  `trials/bitpattern/bitpattern.spec`. If one doesn't because a v2 rule differs from
  v1's, report it rather than loosen the rule;
- a v2 sample, `tests/host/check/data/v2.spec`, using every v2 form above, checks;
  and an error case for each v2 rule, with its message and position;
- resolutions and types of a sample of nodes, read back from the `Spec`;
- speed: checking `bitpattern.spec` takes under 50 ms (print it).

## Out of scope

Compiling partition sets (partitions package), evaluation, generation, more than one
file.
