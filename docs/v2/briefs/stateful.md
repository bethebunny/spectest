# Brief: stateful

Runs interfaces: generated sequences of constructor and method calls on live
objects, each call judged like a function call, and the interface's invariants
checked after every call.

**Owns:** `host/run/stateful*.mojo` (new modules in the runner's package; change
existing runner modules only where an interface needs a hook, and say so in the commit
message), `tests/run/test_stateful*.py` and the Python modules those tests drive.

**Read first:** `docs/language.md` (Declarations: interfaces; Verdicts),
`docs/v2/host-api.md`, `host/run/` (the runner: `run`, the host over the driver, how a
call is judged, results), `host/check/spec.mojo` (`Model.ctors`, `Model.methods`,
`Fn.target`), `host/gen/`, `host/mcheck/`, `docs/v2/mojo.md`. v1 is the reference for
every rule: `src/spectest/runtime/stateful.py`, `examples/deque/` and
`tests/runtime/` (its stateful tests).

## Deliver

1. **Targets.** A constructor named `__init__` calls the interface's class itself
   (`collections.deque(...)`). Any other constructor `m` calls `<interface>.m`, a
   classmethod or staticmethod. A method `m` calls `<interface>.m` with the receiver
   first. (Provisional, recorded in `docs/v2/syntax.md` by this package.)
2. **Runs.** `run(spec, decl)` with an interface's name runs step sequences in one
   mcheck search, keeping v1's rules:
   - at most `steps` calls (30) and `max_handles` live objects (2);
   - constructors run only while fewer objects are live;
   - a method runs on the object used last at least half the time;
   - integer arguments are drawn from -4 to 4 (0 to 4 unsigned) three times in four;
   - every call is judged like a function call: `ensures`, `raises`, `may_raise`,
     `relates`, `modifies` and the frame rule, `#type` and `#raises`;
   - the invariants are checked on every live object after every call.
   Options `steps` and `max_handles` join the host API's options.
3. **Results.** One `ClauseResult` per clause of every constructor and method, and
   per invariant, with ids as v1 prints them (`collections.deque.pop#1`, with the
   instantiation after the interface's name). A failing sequence is the
   counterexample, as v1's step log: `d1 = collections.deque()`,
   `d1.append(x=5)`, ... Then comes the failing call's observation and explanation.
4. **Shrinking and replay.** Shrink by deleting steps, and lower a constructor's
   integer argument together with the calls that filled its object, as v1 does.
   Failing sequences go to the store and are replayed first.

## Acceptance

`uv run pytest tests/run/test_stateful*.py` passes, with a v2 spec of a deque-like
interface over a small Python class written for the tests, modeled on
`examples/deque/deque.spec`. It covers:

- a correct class passing;
- seeded bugs (a wrong `pop` end, a bounded append that doesn't evict, a `rotate` off
  by one), each failing the right clause with a short step log;
- invariants checked after every call;
- `modifies` and the frame rule on methods;
- the handle cap;
- store replay;
- `collections.deque` itself against the spec, which passes.

The runner's existing tests (`tests/run`, `tests/host/run`) still pass.

## Out of scope

Concurrency and linearizability.
