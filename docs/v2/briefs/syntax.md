# Brief: syntax

The lexer and parser for v2 spec files and user preludes, producing the flat syntax
tree of `src/spec/ast.mojo`, and a text dump of the tree for tests.

**Owns:** `src/specfile/` (`ast.mojo` is a contract: add node kinds or ops only at the
end), `tests/mojo/specfile/`.

**Read first:** `docs/language.md` (Declarations, Clauses, Expressions, Grammar),
`docs/v2/syntax.md`, `src/spec/ast.mojo` (the tree and every node's children),
`docs/v2/mojo.md`. v1's `spectest/lang/lexer.py` and `parser.py` are the
reference: port their behavior, including the layout rule (INDENT, DEDENT, a deeper
line continuing a clause), `perf` lines, comments, string escapes, numbers, and their
error messages.

## Deliver

1. `parse_spec(source: String, path: String) raises -> Ast` and
   `parse_prelude(source, path) raises -> Ast`. On a syntax error, raise an `Error`
   whose message is the `Diagnostic` text, `path:line:col: message`, for the first
   error.
2. Every node gets a span. A clause's span covers its continuation lines, so
   `Ast.source_text` quotes the clause as written.
3. `dump(ast, id) -> String`: one line, `(kind op "text" child child ...)`, leaving
   out `op` when it is `NO_OP` and `"text"` when empty; `_` for EMPTY; strings quoted
   with `\"` and `\\` escaped. Example: `(binary + (name "x") (num "1"))`.

## Acceptance

`uv run pytest tests/mojo/specfile` passes, covering:

- a dump test for each construct of both grammars: every declaration, member and
  clause kind, every operator at its precedence and associativity (`implies` right,
  `**` right, `-x ** 2`), `let` and `if` reaching right, comprehensions, calls with
  keyword and type arguments, attribute chains, tuple fields, indexing and slices,
  list, set and tuple literals, every type form;
- v2's additions: qualified names in each declaration, `build`, observers with `=`,
  `self` parameters, `const`, `prelude`, single-expression `def`s (and a `def` without
  `=` being a spec function), choice types of constants, `**`, `<<`, `>>`;
- a prelude file;
- syntax errors with their messages and positions, ported from v1's lexer and
  parser tests where they apply;
- every existing spec parses: `examples/*/*.spec` and
  `trials/bitpattern/bitpattern.spec`;
- a sample in v2 syntax, `tests/mojo/specfile/data/sample.spec`, written to use every
  v2 form, parses and dumps as expected;
- speed: parsing `bitpattern.spec` (2,594 lines) takes under 50 ms, v2's target for
  loading a spec. Print the time; assert under 200 ms so the test stays robust.

## Out of scope

Name resolution, types and every static rule (the checker, wave 2).
