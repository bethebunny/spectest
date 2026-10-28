# Brief: plugin

The pytest front end for v2 specs. It collects specs, turns each clause into an item,
runs each declaration once through the host, and reports with v1's rendering. v1's
conformance objects keep working beside it.

**Owns:**
- `spectest/specs.py` (the `spectest.check` API);
- the v2 parts of `spectest/pytest_plugin.py`: v1's plugin, extended. v1's
  behavior must not change, and every v1 test must still pass;
- the `check` entry of `_EXPORTS` in `spectest/__init__.py`;
- module mapping in `spectest/driver/driver.py`;
- `tests/specs/` (the plugin's tests).

**Read first:** `docs/v2/host-api.md` (the host API you call), `docs/v2/protocol.md`,
`spectest/pytest_plugin.py` and `spectest/runtime/report.py` (v1's plugin and
rendering, reused), `tests/plugin/` (v1's plugin tests, the model for yours), the
root `conftest.py` (worker counts and profiles), and `spectest/driver/`.

## Deliver

1. **`spectest.check(path, **options)`** returns an object that the plugin collects
   from a test module, as it collects v1's conformance objects:

   ```python
   libm = spectest.check(
       "libm.spec",                       # relative to the test module
       modules={"math": "examples.libm.buggy"},  # run the spec against another module
       expect_fail={"math.cos.accurate"}, # clauses that must fail (seeded bugs)
       instantiations={"sort": [{"T": "i64"}, {"T": "string"}]},
       examples={"math.cos": [{"x": 0.5}]},
       max_examples=None, seed=None,
   )
   ```

   A `.spec` file named on the command line (`pytest examples/x/x.spec`) is collected
   directly, with default options.
2. **Module mapping.** `Driver(module_map={"math": "examples.libm.buggy"})` resolves
   `math.cos` as `examples.libm.buggy.cos`, replacing the longest mapped prefix.
   `--spectest-module NAME=REPLACEMENT` (repeatable) adds mappings for the session.
3. **Items.** One per host item (`docs/v2/host-api.md`) and per instantiation. Node ids
   end with the clause name, instantiation included (`sort[T=i64].ordered`), using
   v1's `clause_name`. A generic declaration without instantiations is one item that
   errors with a message saying what to add.
4. **Runs.** Call `_host.run` once per declaration and instantiation per process, and
   let its items read their own clause's result. Group a declaration's items for
   pytest-xdist (`xdist_group`, and `--dist loadgroup` when running under xdist), so
   one worker runs them together.
5. **Options.** Reuse v1's `--spectest-*` options: seed, max examples, exhaustive
   limit, store and no store, report and JSON, and clause selection. Use the root
   conftest's strength (`--ci` is full). `--spectest-report` writes v1's Markdown
   report from the `ClauseResult`s.
6. **Outcomes.** As v1: pass, fail (with v1's failure rendering), error for spec
   errors, skip when nothing was judged, and xfail and xpass under `expect_fail`.
   A spec that doesn't load fails collection with the diagnostics.

## Acceptance

`uv run pytest tests/specs` passes. Tests use pytester (as `tests/plugin/` does) and a
fake `_host` module that implements `docs/v2/host-api.md` with canned results,
installed by a fixture. They cover:

- collection from a test module and from a `.spec` argument;
- node ids, and instantiation items;
- one run per declaration shared by its items;
- every outcome;
- `expect_fail`;
- module mapping, both in the driver and through the option;
- clause selection;
- the Markdown report;
- a spec error at collection.

One more test runs against the real `spectest._host` when it has `run`, and skips
otherwise: the runner is being built at the same time. The whole dev suite
(`uv run pytest`) still passes, and v1 is unchanged.

## Out of scope

The host itself; interfaces (wave 3b).
