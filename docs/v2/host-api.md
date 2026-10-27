# The host's Python API

What the pytest plugin calls in `spectest._host`, and what comes back. The runner
package implements it in Mojo (`host/bridge/module.mojo` and `host/run/`). The
plugin package uses it, and tests the plugin against a fake with the same API.

## Functions

| Function | Returns | Does |
| --- | --- | --- |
| `load(path, driver)` | `int`, a spec handle | Parses and checks the spec and compiles its partitions. A spec error raises `spectest.SpecError` (a `ValueError`) whose message is the diagnostics, one `path:line:col: message` per line. `driver` is a `spectest.driver.Driver`, kept for the spec's runs. |
| `items(spec)` | `list[dict]` | The items the spec has, in source order (below). |
| `run(spec, decl, options)` | `dict` | Runs one declaration, a function or an aggregate clause's function, in one search that judges all of its clauses, and returns the results (below). |
| `unload(spec)` | `None` | Frees the spec. |

## Items

One dict per clause that a run judges, and per built-in clause:

```python
{
    "decl": "math.cos",            # the declaration a run covers, the `decl` of `run`
    "clause_id": "math.cos.accurate",  # or "math.cos#2", "math.cos#type", "math.cos#raises"
    "kind": "ensures",             # requires is not an item; "type" and "raises" for built-ins
    "text": "ensures accurate: qe(result, cr.cos(x)) <= 1",
    "line": 12,
    "file": "/path/to/libm.spec",  # the file the clause is written in (a used spec's own)
    "tparams": ["T"],              # type parameters the run needs instantiated, else []
}
```

`requires` clauses and freedoms (`may_raise`, `unspecified`, `impl_defined`, `perf`) are
not items. An aggregate clause is an item of its function, judged in the same `run`.
Besides the written clauses a function has `<decl>#type` and `<decl>#raises`, a
`<decl>#frame` item (kind `"frame"`) when it takes a model and has no `modifies`, and
one `<decl>:<invariant id>` item (kind `"invariant"`) per invariant of each model it
returns or modifies. A `modifies` clause is an item of kind `"modifies"`.

## Options

```python
{
    "seed": 0,                 # base seed; each declaration's seed derives from it and its name
    "max_examples": 100,       # valid examples per search
    "exhaustive_limit": 65536, # run every input when the domain is at most this large
    "store": ".spectest/store",  # failure store directory, or None
    "instantiation": {"T": "i64"},  # type arguments for a generic declaration
    "examples": [{"x": 1.0}],  # explicit inputs, judged before the search (wire objects)
    "strength": "dev",         # "dev" or "full": the shrink budget, 5000 or 20000 steps
    "aggregate_samples": 10000,  # members an aggregate clause visits of a set above exhaustive_limit
    "steps": 30,               # interfaces: calls per step sequence, at most
    "max_handles": 2,          # interfaces: objects live at once
}
```

## Results

```python
{
    "decl": "math.cos",
    "mode": "search",          # "search", "exhaustive" or "replay"
    "examples": 100,           # valid examples judged
    "invalid": 3,              # examples rejected (requires false, a build that raised)
    "seconds": 0.012,
    "clauses": [ClauseResult, ...],
}
```

Each `ClauseResult` is a dict that v1's `spectest.runtime.report.ClauseResult.from_dict`
reads, so v1's rendering prints it:

```python
{
    "item_id": "",             # filled in by the plugin
    "clause_id": "math.cos.accurate",
    "clause_text": "ensures accurate: ...",
    "kind": "ensures",
    "decl": "math.cos",
    "instantiation": {},
    "mode": "hypothesis",      # v1's names: "hypothesis" for a search, "exhaustive"
    "counts": {"pass": 97, "fail": 1, "skip": 2, "spec_error": 0, "inconclusive": 0},
    "coverage": {"x: nan": 12, ...},
    "counterexample": {        # the shrunk failing example, or None
        "inputs": {"x": "0.5"},
        "observation": "result = 0.8775825618903728",
        "partitions": {"x": "moderate"},
        "explanation": [["qe(result, cr.cos(x))", "2"]],
        "seed": 1234,
        "reproduce": "...",
    },
    "failing_inputs": 1,
    "spec_errors": [],         # one line per distinct spec error
    "failing_examples": [],
    "aggregate": None,
    "replayed": False,
    "skips": {"requires": 2},  # by cause, keys of v1's SKIP_CAUSES
    "duration": 0.004,
}
```

## Interfaces

`run(spec, "collections.deque", options)` with an interface's name runs step
sequences: constructors and methods called on live objects, in one search that judges
every clause of every constructor and method (their ids are the checker's, such as
`collections.deque.pop#1`), the built-in `#type`, `#raises` and `#frame` clauses, and
each invariant (`collections.deque.within_bound`, kind `"invariant"`) after every call
on every live object. `items(spec)` lists the same clauses with `decl` set to the
interface's name and `tparams` the interface's type parameters. Results have mode
`"stateful"`; a counterexample's `observation` starts with the step log:

```
steps:
1. p1 = stateimpls.PopWrongEnd.bounded(n=2)
2. p1.append(x=0)
3. p1.append(x=1)
4. p1.pop() -> 0
result = 0
```

A failing sequence is stored under the failure store, as the choices that generate it
and the edits that shortened it, and is replayed first on the next run (`mode`
`"replay"`, `replayed` true on the clause).
