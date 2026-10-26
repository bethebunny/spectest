"""The frames spec's implementations: pandas and polars adapters, and seeded bugs.

The adapters only translate the spec's signatures to each library's calls;
the libraries do the work. The seeded bugs are plausible mistakes, each meant
to break exactly one clause.
"""

from __future__ import annotations

from typing import Any

import pandas as pd
import polars as pl

_OMITTED: Any = object()


# ---------------------------------------------------------------------------
# pandas


def pandas_dropna(df: pd.DataFrame, how: str = _OMITTED) -> pd.DataFrame:
    """df.dropna(how=how); an omitted how is left to pandas' own default."""
    return df.dropna() if how is _OMITTED else df.dropna(how=how)


def pandas_fillna(df: pd.DataFrame, value: float) -> pd.DataFrame:
    return df.fillna(value)


def pandas_select(df: pd.DataFrame, names: list[str]) -> pd.DataFrame:
    """df[names]; pandas raises KeyError for a missing column."""
    return df[names]


# ---------------------------------------------------------------------------
# polars


def polars_dropna(df: pl.DataFrame, how: str = "any") -> pl.DataFrame:
    """how="any": df.drop_nulls(); how="all": drop the rows whose cells are all null."""
    if how == "any":
        return df.drop_nulls()
    return df.filter(pl.any_horizontal(pl.all().is_not_null()))


def polars_fillna(df: pl.DataFrame, value: float) -> pl.DataFrame:
    return df.fill_null(value)


def polars_select(df: pl.DataFrame, names: list[str]) -> pl.DataFrame:
    """df.select(names); polars raises ColumnNotFoundError for a missing column."""
    return df.select(names)


# ---------------------------------------------------------------------------
# Seeded bugs (polars)


def dropna_ignores_how(df: pl.DataFrame, how: str = "any") -> pl.DataFrame:
    """Always drops the rows with any null, as if how were "any"."""
    return df.drop_nulls()


def fillna_fills_nan(df: pl.DataFrame, value: float) -> pl.DataFrame:
    """Fills NaN values as well as nulls: NaN is a value polars keeps, not a missing cell."""
    return df.fill_nan(value).fill_null(value)


def dropna_returns_input(df: pl.DataFrame, how: str = "any") -> pl.DataFrame:
    """Returns the input frame itself when no row is dropped, instead of a new frame.

    The shortcut is "nothing to drop", not "no null": with how="all", a row with
    no cells is dropped although nothing in it is missing.
    """
    out = polars_dropna(df, how)
    return df if out.height == df.height else out
