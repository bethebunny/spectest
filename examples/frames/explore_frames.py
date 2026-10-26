"""Questions about spectest itself, asked through the frames spec (run explicitly).

    uv run pytest examples/frames/explore_frames.py

Not collected by a plain ``uv run pytest examples/frames``: the file name does
not match ``test_*.py``. Each conformance here is expected to end badly, and
what matters is how spectest reports it (see README.md, "Weaknesses").

- ``test_dtype_change``: a fillna whose result has object columns. The result
  is not a frame of float columns, so the implementation is at fault. The
  strict observer raises NotAValue, so ``fillna#type`` fails and the clauses
  that read the result skip. (Before NotAValue, ``fillna#type`` passed for any
  object and the observer's refusal made ``fillna.rows`` and both invariants
  SPEC ERRORs, "the spec's or the binding's fault".)
- ``test_select_skips_missing``: a select that leaves out unknown names instead
  of raising ColumnNotFound, as polars' ``df.select`` does for a name that is a
  pattern such as ``*``. ``select#2`` and ``select.columns`` fail, as they
  should, and select.columns' counterexample notes that select#2 required
  ColumnNotFound there. Before ``select.rows`` was guarded, it was a SPEC ERROR
  on the same calls (``index_of`` of a name that is not a column). With the
  guard it passes, because rows are judged only when every name is a column;
  without it, it would now pass too, as a clause that cannot be evaluated where
  a raise was due is a skip ("raise due (select#2)").
"""

from __future__ import annotations

import frames_bindings as fb
import pandas as pd

import spectest


def fillna_to_object(df: pd.DataFrame, value: float) -> pd.DataFrame:
    """Fills the missing cells, then turns every column into an object column."""
    return df.fillna(value).astype(object)


test_dtype_change = spectest.conformance(
    "frames.spec",
    impls={"fillna": fillna_to_object},
    models={"Frame": fb.PANDAS},
    max_examples=20,
)


def select_skips_missing(df: pd.DataFrame, names: list[str]) -> pd.DataFrame:
    """Selects the names that are columns and silently leaves out the others."""
    return df[[n for n in names if n in df.columns]]


test_select_skips_missing = spectest.conformance(
    "frames.spec",
    impls={"select": select_skips_missing},
    models={"Frame": fb.PANDAS},
    max_examples=50,
)
