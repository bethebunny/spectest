# deque findings

This is what spectest found when it ran deque.spec against Python's `collections.deque` and five hand-written deques with seeded bugs. Each seeded bug below gives:
- the clause it fails;
- the minimized step log;
- an independent check;
- why the behaviour breaks the spec.

The plain test functions at the end of examples/deque/test_deque.py replay every counterexample on the buggy class and on `collections.deque`, without spectest. deque.spec was changed in two places (section 3).

Environment: Python 3.13.9, pytest 9.1.1, Hypothesis 6.170.9, x86-64 Linux (WSL2).

## 1. collections.deque conforms (no finding)

`test_collections_deque` binds both constructors and runs 300 examples per instantiation. It passes every clause of deque.spec for T = i64 and T = string. An earlier version of the example also had `test_collections_deque_bounded`, which bound only `bounded` and ran 600 examples so that bounded deques would fill up; the search no longer needs it (section 2).

Deep runs with `--spectest-max-examples=2000` at seeds 1, 2 and 3 (6 items) also pass. Nothing about the real deque is in expect_fail.

Selected tallies at seed 0 (REPORT.md), as pass / skip. A skip on `pop.value` or `popleft.value` means the call raised. That only happens on an empty deque, where `pop#1` / `popleft#1` judged the IndexError.

| Clause | i64 | string |
| --- | ---: | ---: |
| `Deque.pop#1` (raises IndexError when empty) | 1473 / 0 | 1401 / 0 |
| `Deque.pop.value` | 365 / 1108 | 550 / 851 |
| `Deque.popleft.value` | 697 / 909 | 500 / 1040 |
| `Deque.appendleft.items` | 1019 / 0 | 1387 / 0 |
| `Deque.rotate.items` | 1515 / 0 | 1855 / 0 |
| `Deque.within_bound` (the invariant, after every call) | 8319 / 0 | 8650 / 0 |

## 2. What the collections.deque search exercised

Interface items record partition coverage, but deque.spec has no partitions, and most of its edge cases depend on the deque's state as well as on the arguments, so the report cannot show which of them a search reached.

`explore_deque.py` measures it. It repeats the collections.deque search over `ProbedDeque`, a subclass of collections.deque whose methods count the case they meet and then call the deque's own method. It uses the plugin's seed, options and item IDs. All 76 clause tallies of the repeated run equal the plugin's (compared with `--spectest-json`), so the counts below come from the conformance run itself.

Calls per edge case at seed 0. "Before" is the both-constructor conformance at its 200 examples, before the stateful search changes (docs/ISSUES.md, "stateful searches rarely reach deep states"); "now" is the conformance at its 300 examples:

| Edge case | i64 before | i64 now | string before | string now |
| --- | ---: | ---: | ---: | ---: |
| new bounded(0) | 108 | 98 | 90 | 107 |
| new bounded(1) | 9 | 38 | 61 | 58 |
| new bounded(n >= 2) | 902 | 171 | 738 | 221 |
| new empty() | 1081 | 319 | 584 | 235 |
| append on a full bounded(0) | 362 | 443 | 437 | 591 |
| append on a full bounded(1) | 0 | 30 | 3 | 173 |
| append on a full bounded(n >= 2) | 0 | 107 | 0 | 119 |
| appendleft on a full bounded(0) | 43 | 107 | 34 | 242 |
| appendleft on a full bounded(1) | 0 | 107 | 5 | 72 |
| appendleft on a full bounded(n >= 2) | 1 | 78 | 0 | 93 |
| pop on an empty deque | 376 | 1108 | 635 | 851 |
| popleft on an empty deque | 507 | 909 | 266 | 1040 |
| rotate on an empty deque | 443 | 1039 | 546 | 1178 |
| rotate with n < 0 (non-empty deque) | 104 | 262 | 145 | 293 |
| rotate with n < -len | 98 | 147 | 124 | 177 |
| rotate with -len <= n < 0 | 6 | 115 | 21 | 116 |
| rotate with n > len | 166 | 103 | 165 | 235 |
| rotate by a nonzero multiple of len | 205 | 282 | 255 | 385 |
| rotate on a full bounded deque | 0 | 154 | 0 | 210 |

**Why the search now fills bounded deques.** Before, every constructor was a rule as likely as any method, so the 30 steps of an example were spread over about ten deques (2,100 constructions in 200 examples, T = i64), most method calls met an empty deque, and `bounded(n)` rarely drew a small n. Appendleft on a full bounded(1) or bounded(n >= 2) deque and rotate on a full bounded deque never ran with both constructors, which is why the example had a second, bounded-only conformance at 600 examples. Now:
- a step sequence holds at most two deques (`max_handles`, default 2): constructors run only while fewer are live, so there were 626 constructions in 300 examples;
- a method runs on the deque used last at least half the time, so one deque gets most of the steps;
- an argument declared as an integer is drawn from -4 to 4 (0 to 4 when unsigned) three times in four: `bounded(n)` drew n = 1 for 38 of 307 bounded deques (before 9 of 1,019), and small negative rotations are common.

At 300 examples every edge case ran at each of seeds 0 to 11, for both T (24 items); the rarest count was 5 (appendleft on a full bounded(1), seed 8, T = string). At 200 examples, seed 0 with T = i64 never appended to a full bounded(1) deque. So the conformance runs 300 examples, still fewer than the 200 + 600 of the two conformances it replaces.

## 3. Spec changes

The first two changes only strengthen the spec, and the third renames a label. Before changing anything, I showed for each hole that a plainly wrong deque passed every clause of the original spec (300 examples per instantiation, both T, in a scratch run).

### 3.1 rotate on an empty deque was unconstrained

The original clause:

```
ensures items: let xs = old(self.items) in
  len(xs) == 0 or
  self.items == xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)]
```

The guard is there so that `% len(xs)` never divides by zero, but it also makes the clause true for every result when the deque was empty. No other clause covers that case. A `ListDeque` whose rotate on an empty deque re-inserts the last item ever appended passed the whole original spec. collections.deque leaves an empty deque empty.

The new clause states the intended result:

```
ensures items: let xs = old(self.items) in
  self.items == (if len(xs) == 0 then xs
                 else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)])
```

### 3.2 No clause kept maxlen fixed

No method clause said that `maxlen` stays the same. Worse, `append.items` and `appendleft.items` read the post-state `self.maxlen`, so a method could drop or change the bound and still pass.

`RebuildingDeque` (deque_impls.py) wraps a collections.deque. Its `rotate` rebuilds the wrapped deque as `collections.deque(items)` and forgets `maxlen`. It passed every clause of the original spec: after a rotate the deque is unbounded, and later appends are judged against `maxlen = none`.

The fix adds `ensures maxlen: self.maxlen == old(self.maxlen)` to each of the five methods, and a header comment ("The bound is fixed when the deque is made: no method changes maxlen."). Seeded bug (e) is that deque, and it now fails `Deque.rotate.maxlen`. collections.deque passes, since its maxlen is read-only.

These five new clause IDs broke `tests/lang/test_lang_examples.py::test_clause_ids`, which pinned the old 19 IDs. It now derives deque's IDs from the spec text.

### 3.3 The invariant's ID named the constructor

The invariant was labelled `bounded`, which gave it the ID `Deque.bounded`, the constructor's own ID, so `Deque.bounded.items` read like part of the invariant. The checker now rejects a label that names a member, and the invariant is `within_bound` (`Deque.within_bound`).

### Not changed

- The spec cannot say that a raising pop leaves the deque unchanged. That is a language gap (section 6), not a spec bug.

## 4. Seeded bugs (test_seeded_*; all in expect_fail)

Each bug has its own conformance with both constructors and 100 examples per instantiation. Each item xfails, so no clause outside its expect_fail list failed, no spec error occurred, and every listed clause failed: interface items enforce expect_fail per clause, so a listed clause that never failed would make the item a strict unexpected pass. REPORT.md has a counterexample for every listed clause.

**(a) `WrongEndDeque`: appendleft on a full deque drops the new item. Fails `Deque.appendleft.items`.**
- T = i64:
  ```
  1. d1 = Deque.bounded(n=1)
  2. d1.append(x=1)
  3. d1.appendleft(x=0)
  ```
  Explanation: `ys = [0, 1]`, `self.items = [1]`, and the clause demands `ys[0:1] = [0]`.
- T = string: the same steps with `append(x="0")` and `appendleft(x="")`, giving `["0"]` where `[""]` is required.
- Why it is a violation: appendleft on a full bounded deque must drop the rightmost item. The class copies append's trimming (`del items[0]`), so it drops the item it just added.
- Check: `test_seeded_appendleft_drops_the_new_item`. collections.deque gives `[0]` (and `[0, 1]` for maxlen 2 after appending 1 and 2 and appendleft(0), where the bug gives `[1, 2]`).

**(b) `BackwardRotateDeque`: rotate(n) rotates left. Fails `Deque.rotate.items`.**
- T = i64:
  ```
  1. d1 = Deque.empty()
  2. d1.append(x=0)
  3. d1.append(x=0)
  4. d1.append(x=1)
  5. d1.rotate(n=1)
  ```
  The deque holds `[0, 1, 0]`; the clause demands `xs[2:3] + xs[0:2] = [1, 0, 0]`.
- T = string: step 1 is `d1 = Deque.bounded(n=3)`, and from `["0", "", ""]` rotate(1) gives `["", "", "0"]` where `["", "0", ""]` is required. The bound plays no part in the bug, but n cannot be lowered: with fewer than three items, rotating one step left equals rotating one step right. Shrinking does not switch to `empty()`.
- Check: `test_seeded_rotate_goes_left`; collections.deque gives `[1, 0, 0]`.

**(c) `PopleftNoneDeque`: popleft on an empty deque returns None. Fails `Deque.popleft#1` and `Deque.popleft#type`.**
- Log:
  ```
  1. d1 = Deque.bounded(n=0)
  2. d1.popleft() returned NoneType None
  ```
- `popleft#1` fails because IndexError was due (`len(self.items) == 0` holds) but the call returned.
- `popleft#type` fails because None is not an i64 (or a string).
- Check: `test_seeded_popleft_returns_none_on_an_empty_deque`; collections.deque raises IndexError.

**(d) `SlotDeque`: pop on an empty deque raises KeyError. Fails `Deque.pop#1` and `Deque.pop#raises`.**
- Log:
  ```
  1. d1 = Deque.bounded(n=0)
  2. d1.pop() raised KeyError: -1 (no spec error maps it)
  ```
- The class keeps items in a dict of numbered slots, and pop does `slots.pop(hi - 1)` without the empty check that popleft has.
- `pop#1` fails because IndexError was due. `errors` maps only IndexError, and KeyError is not an IndexError subclass, so `pop#raises` fails too: nothing admits the exception.
- Check: `test_seeded_pop_raises_keyerror_on_an_empty_deque`, which asserts `KeyError(-1)`, collections.deque's IndexError, and `not issubclass(KeyError, IndexError)`.

**(e) `RebuildingDeque`: rotate loses the bound. Fails `Deque.rotate.maxlen`.**
- Log:
  ```
  1. d1 = Deque.bounded(n=0)
  2. d1.rotate(n=0)
  ```
  Explanation: `self.maxlen = none`, `old(self.maxlen) = some(0)`.
- Check: `test_seeded_rotate_loses_the_bound`. After bounded(1), append(1), rotate(1), append(2), the bug holds `[1, 2]` and collections.deque holds `[2]`.

`test_list_deque_baseline_matches_collections_deque` checks that `ListDeque`, which (a) to (c) override, agrees with collections.deque on mixed appends and rotations by -128 to 127 for maxlen none and 0 to 3.

## 5. Seed sensitivity

Bugs (a) and (b) need a full bounded deque or one of three or more items (section 2). Each figure counts items, one per (seed, T), at seeds 0-5, with both constructors bound; the counterexample store was cleared before each run, so nothing was replayed. "Before" is the search before the stateful changes of section 2.

| Bug | Examples | Found before | Found now |
| --- | --- | --- | --- |
| (a) | 100 | 6 of 12 (missed at seeds 1, 3 and 5) | 12 of 12 |
| (a) | 200 | 8 of 12 | 12 of 12 |
| (b) | 100 | 11 of 12 (missed at seed 1, T = i64) | 12 of 12 |
| (c), (d) | 100 | 8 of 8 each (seeds 0-3) | 12 of 12 each |
| (e) | 100 | 12 of 12 | 12 of 12 |

Before, another `--spectest-seed` could make test_seeded_appendleft_wrong_end or test_seeded_rotate_backwards a strict unexpected pass. Now each seeded conformance keeps its 100 examples and finds its bug at every seed tried; once found, a failing step log is stored under `.spectest/` and replayed first on later runs (the counterexample then says so).

Shrinking is minimal now. Before, bug (a), T = string, 300 examples, seed 4 gave a 14-step log: `bounded(n=12)`, twelve appends, then `appendleft`; making n smaller alone, or deleting one append alone, stopped the failure. That run now gives `bounded(n=1)`, `append(x="")`, `appendleft(x="0")`. After Hypothesis shrinks a sequence, spectest deletes steps and lowers a constructor's integer argument, also together with deleting one step on the deque it made; that 14-step program itself minimizes to `bounded(n=1)`, `append(x="0")`, `appendleft(x="")` (tests/runtime/test_runtime_stateful.py). Over seeds 0-5 (100 examples, and 300 at seed 4), step deletion alone left `bounded(n=2)` and four steps in 2 of the 12 logs; with the lowering all 12 have three steps.

## 6. Notes on the harness

Filed in docs/ISSUES.md, prefixed "deque:".

- **Results table.** For interface items, the Markdown Results table never names the clause: 38 rows per item all read `...::Deque[T=i64]`. "Items: 524" counts clause results for 14 spectest items. Counterexample headings do not name the conformance.
- **Strict expect_fail.** It was not enforced per clause for interfaces: an expected clause that never failed was silent in pytest (XFAIL) when another expected clause failed, while the Markdown header counted it as "1 unexpected pass". Resolved: the item is a strict unexpected pass, and the XPASS message names the clauses that never failed.
- **Shallow searches.** Stateful searches reached few deep states, which caused the seed sensitivity of section 5. Resolved: at most `max_handles` live deques, methods mostly on the deque used last, small integer arguments, and `steps=` and `max_handles=` options (sections 2 and 5).
- **Coverage and store.** Interface items recorded no coverage and never used the counterexample store. Resolved: they count partition classes of constructor and method parameters (deque.spec has none), and store and replay failing step logs.
- **Shrinking.** It could not shrink a constructor argument together with the steps that depend on it. Resolved (section 5).
- **Speed.** `eval.snapshot_olds` re-walked each clause's AST on every call: 11 s of a 94 s profile. Resolved: old(...) calls are found once per clause, and a step reuses the previous step's observations as its pre-state. The WrongEndDeque T = i64 item takes 3.6 s instead of 32.4 s, and the whole example about 53 s instead of 133 s.
- **Clause IDs.** The invariant `Deque.bounded` and the constructor `Deque.bounded` shared an ID string. Resolved: the checker rejects such a label, and the invariant is now `Deque.within_bound`.
- **Counts.** Verdict counts in an interface clause's counterexample included its muted reruns, e.g. "106 pass, 169 fail" for `Deque.popleft#1`. Resolved: each clause counts verdicts up to its first failure; that clause now reads "1 fail".
- **Language.** No clause can constrain the state after a call that raises. A pop that raises IndexError and also appends an item passes every clause (checked at 300 examples). In v1 this is by design: the state a raise leaves in a handle the call may modify is implementation-defined, while every other live handle must stay unchanged. A later version may add subclauses under `raises` for it.
