"""Bindings of the Frame model to pandas and polars.

A Frame's fields are its columns (names), its rows (cells of option<f64>) and
its row count. Each library gets a concretizer, which builds a frame of float64
columns from field values, and observers, which read a frame back.

The two libraries disagree about missing values, and the bindings keep that
difference visible instead of hiding it:

- pandas has no separate null for float64 columns: a missing cell is NaN. The
  concretizer writes none (and a NaN value) as NaN, and the observers read
  every NaN as none. The binding is therefore lossy: a generated some(NaN)
  reads back as none, and counterexamples show the frame as built next to the
  generated one.
- polars keeps null and NaN apart: none becomes null, some(NaN) stays a NaN
  value, and the observers read null as none and NaN as some(NaN). A frame
  with rows but no columns is built with ``pl.DataFrame(height=n)``; a polars
  without that parameter cannot hold one, and the concretizer raises
  Unrepresentable (the example is skipped).

The observers are strict: a column whose dtype is not float64 is not a Frame
column, so reading one raises NotAValue instead of converting its values to
floats, and ``accepts`` refuses anything but a DataFrame of the library. On a
frame an implementation returned, spectest charges either to the
implementation (``<fn>#type`` fails). spectest also reads every concretized
frame back and reports a binding error when it differs from the generated
fields (bit for bit; the lossy pandas binding is exempt), so a binding that
builds the wrong frame is reported instead of silently testing another input.
"""

from __future__ import annotations

import inspect
import math
from typing import Any

import pandas as pd
import polars as pl

import spectest

# ---------------------------------------------------------------------------
# pandas


def pandas_frame(fields: dict[str, Any]) -> pd.DataFrame:
    """A float64 DataFrame; none and NaN cells are NaN, and the index counts the rows."""
    columns: list[str] = fields["columns"]
    rows: list[list[float | None]] = fields["rows"]
    data = {
        name: pd.Series(
            [math.nan if r[j] is None else r[j] for r in rows], dtype="float64", name=name
        )
        for j, name in enumerate(columns)
    }
    return pd.DataFrame(data, index=pd.RangeIndex(fields["nrows"]), columns=pd.Index(columns))


def _pandas_column(df: pd.DataFrame, j: int) -> list[Any]:
    col = df.iloc[:, j]
    if col.dtype != "float64":
        raise spectest.NotAValue(f"column {df.columns[j]!r} has dtype {col.dtype}, not float64")
    return [None if math.isnan(x) else x for x in col.tolist()]


def pandas_columns(df: pd.DataFrame) -> list[Any]:
    return list(df.columns)


def pandas_rows(df: pd.DataFrame) -> list[list[Any]]:
    cols = [_pandas_column(df, j) for j in range(df.shape[1])]
    return [[c[i] for c in cols] for i in range(df.shape[0])]


def pandas_nrows(df: pd.DataFrame) -> int:
    return df.shape[0]


PANDAS = spectest.ModelBinding(
    observers={"columns": pandas_columns, "rows": pandas_rows, "nrows": pandas_nrows},
    concretize=pandas_frame,
    accepts=lambda obj: isinstance(obj, pd.DataFrame),
    lossy=True,
)


# ---------------------------------------------------------------------------
# polars

POLARS_HAS_HEIGHT = "height" in inspect.signature(pl.DataFrame).parameters


def polars_frame(fields: dict[str, Any]) -> pl.DataFrame:
    """A DataFrame of Float64 columns: none is null and some(NaN) a NaN value."""
    columns: list[str] = fields["columns"]
    rows: list[list[float | None]] = fields["rows"]
    if not columns:
        if POLARS_HAS_HEIGHT:
            return pl.DataFrame(height=fields["nrows"])
        if fields["nrows"] > 0:
            raise spectest.Unrepresentable(
                f"polars {pl.__version__} has no frame with {fields['nrows']} row(s) and no columns"
            )
    # A dict, not a list of Series: pl.DataFrame([Series("")]) renames the column "column_0".
    return pl.DataFrame(
        {
            name: pl.Series(name, [r[j] for r in rows], dtype=pl.Float64)
            for j, name in enumerate(columns)
        }
    )


def _polars_column(df: pl.DataFrame, j: int) -> list[Any]:
    col = df.to_series(j)
    if col.dtype != pl.Float64:
        raise spectest.NotAValue(f"column {col.name!r} has dtype {col.dtype}, not Float64")
    return col.to_list()


def polars_columns(df: pl.DataFrame) -> list[Any]:
    return list(df.columns)


def polars_rows(df: pl.DataFrame) -> list[list[Any]]:
    cols = [_polars_column(df, j) for j in range(df.width)]
    return [[c[i] for c in cols] for i in range(df.height)]


def polars_nrows(df: pl.DataFrame) -> int:
    return df.height


POLARS = spectest.ModelBinding(
    observers={"columns": polars_columns, "rows": polars_rows, "nrows": polars_nrows},
    concretize=polars_frame,
    accepts=lambda obj: isinstance(obj, pl.DataFrame),
)
