# Brief: preludes

Specs in more than one file: a user prelude attached with `prelude "x.prelude"`, and
`use "other.spec"`. A diagnostic or a quoted clause from any file names that file and
its own line.

**Owns:** additions to `src/specfile/` (a multi-file tree), `src/specfile/` (resolving
across files), `src/host/load.mojo` (reading the files), and their tests:
`tests/mojo/specfile/test_parser_files*.mojo`, `tests/mojo/specfile/test_checker_preludes.mojo` and
`tests/run/test_preludes.py`. Contract files change only by addition.

**Read first:** `docs/v2/syntax.md` (user prelude files, `def`), the design doc's
"User preludes" paragraph (summarized below), `src/spec/ast.mojo`,
`src/specfile/parser.mojo`, `src/specfile/`, `src/host/load.mojo`, `docs/v2/mojo.md`.

## How user preludes work

- A spec can attach a user prelude: a file of definitions for the helper functions it
  uses, kept next to it and named in the spec: `prelude "bitpattern.prelude"`.
- Its definitions take the single-expression form (`fn name(params) -> T = expr`) and
  are checked with the spec.
- A helper name resolves to the attached user prelude first, then to the system
  prelude.
- A user definition may not reuse a system prelude name, so the built-ins that steer
  the partition-set compiler and the generator keep one meaning.
- Several specs may attach the same user prelude.
- `use "other.spec"` brings in another spec's declarations, as in v1.

## Deliver

1. **One tree, several files.** `Ast` gains a table of files: path, source, the
   byte offset where the file's text starts in `Ast.source`, and its first node. Also
   `file_of(node)`, and `parse_into(mut ast, source, path)` for both spec and prelude
   files. Spans keep byte offsets into the combined source, so `source_text` still
   works. Each span's line and column are its own file's. Every diagnostic and
   verdict location uses `file_of` to name the file.
2. **Checking.** `check` follows `prelude` and `use` declarations, relative to the
   spec's directory, through a loader that reads files. Each file is read once, and
   a cycle of `use` is an error. Resolution order: the spec's own definitions, the
   attached user preludes, then the system prelude. Reusing a system prelude name is
   an error, and so is attaching a missing file. Remove the checker's "not supported
   yet" diagnostic.
3. **Running.** `load(path)` reads attached files. Clauses of used specs' models and
   interfaces apply as in v1.

## Acceptance

`uv run pytest tests/mojo/specfile tests/mojo/specfile tests/run` passes. New tests
cover:

- a spec attaching a prelude whose definitions its clauses and `requires` use;
- two specs sharing one prelude;
- a definition calling another across files;
- diagnostics in a prelude file naming that file and its line;
- a system prelude name reused (an error);
- a missing prelude file;
- a `use` cycle;
- end to end through the runner, a failing clause that calls a prelude definition
  and quotes its own file's text.

## Out of scope

Generic definitions with their own type inference.
