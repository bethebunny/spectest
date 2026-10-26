"""frames conformance: pandas and polars behind one Frame model, and seeded bugs.

The conformances run as pytest items, one per clause. The plain test functions
at the end check the findings of examples/frames/FINDINGS.md, the seeded bugs'
counterexamples and the library behaviour the bindings rely on, using pandas
and polars directly, without spectest.
"""

from __future__ import annotations

import math
import struct

import frames_bindings as fb
import frames_impls as fi
import numpy as np
import pandas as pd
import polars as pl
import pytest

import spectest

spec = spectest.load("frames.spec")

# Names that a library could read as patterns rather than as names: "*" (every column) and
# a "^...$" regex, neither of them a column, so ColumnNotFound is due. The generator almost
# never draws them, so they are explicit examples, judged on every select item before the
# search. A Frame is given by its fields; nrows is computed from the rows. (A column that is
# itself named "*" would fail select.rows too, hiding that item's own finding, so that case
# is left to test_polars_select_reads_names_as_patterns.)
PATTERN_NAMES = {
    "select": [
        {"df": {"columns": ["b", "bc"], "rows": [[2.0, 3.0]]}, "names": ["*"]},
        {"df": {"columns": ["b", "bc"], "rows": [[2.0, 3.0]]}, "names": ["^b.*$"]},
    ]
}

test_pandas = spectest.conformance(
    spec,
    impls={"dropna": fi.pandas_dropna, "fillna": fi.pandas_fillna, "select": fi.pandas_select},
    models={"Frame": fb.PANDAS},
    errors={KeyError: "ColumnNotFound"},
    examples=PATTERN_NAMES,
)

test_polars = spectest.conformance(
    spec,
    impls={"dropna": fi.polars_dropna, "fillna": fi.polars_fillna, "select": fi.polars_select},
    models={"Frame": fb.POLARS},
    errors={pl.exceptions.ColumnNotFoundError: "ColumnNotFound"},
    examples=PATTERN_NAMES,
    expect_fail={
        # FINDINGS.md, "polars select of no columns drops every row": df.select([]) returns a
        # 0 x 0 frame, losing the row count that select.rows keeps (polars can hold rows
        # without columns: df.drop of the last column keeps them).
        "select.rows",
        # FINDINGS.md, "polars select reads names as patterns", on the explicit examples:
        # names ["*"] and ["^b.*$"] are not columns, yet select returns the columns they
        # match instead of raising ColumnNotFound (select#2), so the result's columns are
        # not the names (select.columns, with the note that select#2 was due).
        "select.columns",
        "select#2",
    },
)

test_seeded_bugs = spectest.conformance(
    spec,
    impls={"dropna": fi.dropna_ignores_how, "fillna": fi.fillna_fills_nan},
    models={"Frame": fb.POLARS},
    expect_fail={
        # dropna treats how="all" as "any": a row with a value and a null is dropped.
        "dropna.rows",
        # fillna overwrites NaN values, which polars keeps as values (some(NaN)), not nulls.
        "fillna.rows",
    },
)

test_seeded_fresh = spectest.conformance(
    spec,
    impls={"dropna": fi.dropna_returns_input},
    models={"Frame": fb.POLARS},
    expect_fail={
        # dropna returns its input object when no row is dropped: the result is not fresh.
        "dropna.fresh",
    },
)


# ---------------------------------------------------------------------------
# The findings, checked without spectest


def bits(x: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def polars_cells(df: pl.DataFrame) -> list[list[int | None]]:
    """Rows of cell bits (None for null), read straight from polars."""
    return [[None if c is None else bits(c) for c in row] for row in df.rows()]


def test_polars_select_of_no_columns_drops_every_row() -> None:
    # The minimized counterexample of test_polars::select.rows: one row, no columns.
    df = pl.DataFrame(height=1)
    assert df.shape == (1, 0)
    assert df.select([]).shape == (0, 0)
    # The same with a column (the counterexample of an earlier run).
    one = pl.DataFrame({"": pl.Series("", [None], dtype=pl.Float64)})
    assert one.select([]).shape == (0, 0)
    # polars can hold the expected result: dropping the column keeps the row.
    assert one.drop("").shape == (1, 0)
    assert one.drop("").rows() == [()]
    # pandas keeps the row, as the spec's model does: one empty row per input row.
    assert pd.DataFrame({"": [math.nan]})[[]].shape == (1, 0)
    assert pd.DataFrame(index=pd.RangeIndex(1))[[]].shape == (1, 0)


def test_polars_frames_without_columns_keep_their_rows_elsewhere() -> None:
    # What the binding relies on to build such frames, and what the other clauses saw.
    df = pl.DataFrame(height=3)
    assert df.shape == (3, 0) and df.rows() == [(), (), ()]
    assert df.drop_nulls().shape == (3, 0)
    assert fi.polars_dropna(df, "all").shape == (0, 0)
    assert df.fill_null(0.0).shape == (3, 0)
    assert df.select([]).shape == (0, 0)


def test_polars_select_reads_names_as_patterns() -> None:
    # test_polars' explicit examples (FINDINGS.md): df.select takes expressions, and a
    # string is a column expression in which "*" is every column and "^...$" a regex.
    star = pl.DataFrame({"*": [1.0], "b": [2.0]})
    assert star.select(["*"]).columns == ["*", "b"]  # select.columns wants ["*"]
    plain = pl.DataFrame({"b": [2.0], "bc": [3.0]})
    assert plain.select(["*"]).columns == ["b", "bc"]  # select#2 wants ColumnNotFound
    assert plain.select(["^b.*$"]).columns == ["b", "bc"]  # likewise
    # pandas reads the same names literally.
    with pytest.raises(KeyError):
        pd.DataFrame({"b": [2.0]})[["*"]]
    assert pd.DataFrame({"*": [1.0], "b": [2.0]})[["*"]].columns.tolist() == ["*"]


def test_pandas_dropna_on_rows_without_columns() -> None:
    # all() over no cells is true and exists() false: how="any" keeps every row and
    # how="all" drops every row, as dropna.rows says.
    df = pd.DataFrame(index=pd.RangeIndex(3))
    assert df.dropna().shape == (3, 0)
    assert df.dropna(how="all").shape == (0, 0)


def test_pandas_reads_nan_as_missing_and_polars_keeps_it() -> None:
    pdf = pd.DataFrame({"a": [math.nan, 1.0]})
    assert pdf.dropna()["a"].tolist() == [1.0]
    assert pdf.fillna(0.0)["a"].tolist() == [0.0, 1.0]
    df = pl.DataFrame({"a": pl.Series("a", [math.nan, None, 1.0], dtype=pl.Float64)})
    assert polars_cells(df.drop_nulls()) == [[bits(math.nan)], [bits(1.0)]]
    assert polars_cells(df.fill_null(0.0)) == [[bits(math.nan)], [bits(0.0)], [bits(1.0)]]


def test_polars_frame_from_a_list_of_series_renames_an_empty_name() -> None:
    # Why frames_bindings.polars_frame builds from a dict: a list of Series renames "".
    s = pl.Series("", [1.0], dtype=pl.Float64)
    assert pl.DataFrame([s]).columns == ["column_0"]
    assert pl.DataFrame({"": s}).columns == [""]


def test_sharing_is_unspecified_because_pandas_shares() -> None:
    # unspecified shares_memory: pandas (copy-on-write) shares the input's data when select
    # or dropna keeps a column whole, and copies when dropna drops rows.
    df = pd.DataFrame({"a": [1.0, 3.0], "b": [2.0, math.nan]})
    assert np.shares_memory(df["a"].to_numpy(), df[["a"]]["a"].to_numpy())
    assert np.shares_memory(df["a"].to_numpy(), df.dropna(how="all")["a"].to_numpy())
    assert not np.shares_memory(df["a"].to_numpy(), df.dropna()["a"].to_numpy())
    assert df.dropna(how="all") is not df


# ---------------------------------------------------------------------------
# The seeded bugs' counterexamples, checked without spectest


def frame(columns: list[str], row: list[float | None]) -> pl.DataFrame:
    """A one-row polars frame of Float64 columns."""
    return pl.DataFrame(
        {name: pl.Series(name, [cell], dtype=pl.Float64) for name, cell in zip(columns, row)}
    )


def test_seeded_dropna_ignores_how() -> None:
    # test_seeded_bugs::dropna.rows, as spectest minimizes it: one row without cells, which
    # how="all" drops (no cell has a value) and the bug keeps (no cell is null).
    no_cells = pl.DataFrame(height=1)
    assert fi.dropna_ignores_how(no_cells, "all").height == 1
    assert fi.polars_dropna(no_cells, "all").height == 0
    # A row with a value and a null is kept by how="all", but the bug drops it. Shrinking
    # used to stop at three such columns: a column goes only with its cell in every row.
    df = frame(["", "0", "00"], [None, None, 0.0])
    assert fi.dropna_ignores_how(df, "all").height == 0
    assert polars_cells(fi.polars_dropna(df, "all")) == [[None, None, bits(0.0)]]
    two = frame(["", "0"], [None, 0.0])
    assert (fi.dropna_ignores_how(two, "all").height, fi.polars_dropna(two, "all").height) == (0, 1)


def test_seeded_fillna_overwrites_nan() -> None:
    # test_seeded_bugs::fillna.rows, as spectest minimizes it: one NaN cell, replaced too.
    one = frame([""], [math.nan])
    assert polars_cells(fi.fillna_fills_nan(one, 0.0)) == [[bits(0.0)]]
    assert polars_cells(fi.polars_fillna(one, 0.0)) == [[bits(math.nan)]]
    # Shrinking used to stop at four columns, as here.
    df = frame(["", "0", "1", "00"], [None, None, 0.0, math.nan])
    assert polars_cells(fi.fillna_fills_nan(df, 0.0)) == [[bits(0.0)] * 4]
    assert polars_cells(fi.polars_fillna(df, 0.0)) == [[bits(0.0)] * 3 + [bits(math.nan)]]


def test_seeded_dropna_returns_its_input() -> None:
    # test_seeded_fresh::dropna.fresh: nothing to drop from the empty frame, so it comes back.
    df = pl.DataFrame()
    assert fi.dropna_returns_input(df) is df
    assert fi.polars_dropna(df) is not df
    assert fi.dropna_returns_input(pl.DataFrame({"a": [None, 1.0]})).height == 1
    # With how="all", a row without cells is dropped although nothing in it is missing, so
    # a "no null" shortcut would also have broken dropna.rows (spectest's first counterexample).
    empty_row = pl.DataFrame(height=1)
    assert sum(s.null_count() for s in empty_row.get_columns()) == 0
    assert fi.dropna_returns_input(empty_row, "all").height == 0
