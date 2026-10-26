spec frames

# A dataframe of float columns, observed without assuming an index or a library.
# A missing cell is `none`; a NaN that the library keeps as a value is `some(NaN)`.

error ColumnNotFound

model Frame
  observe columns: list<string>
  observe rows: list<list<option<f64>>>
  observe nrows: u64
  invariant unique_columns: distinct(columns)
  invariant rectangular: all(r in rows: len(r) == len(columns))
  invariant row_count: nrows == len(rows)

fn dropna(df: Frame, how: "any" | "all" = "any") -> Frame
  ensures columns: result.columns == df.columns
  ensures rows: eq(result.rows,
                   filter(r in df.rows: if how == "any" then all(c in r: is_some(c))
                                        else exists(c in r: is_some(c))),
                   float="bits")
  ensures fresh: fresh(result)
  unspecified shares_memory

fn fillna(df: Frame, value: f64) -> Frame
  requires not is_nan(value)
  ensures columns: result.columns == df.columns
  ensures rows: eq(result.rows,
                   map(r in df.rows: map(c in r: if is_none(c) then some(value) else c)),
                   float="bits")
  ensures fresh: fresh(result)
  unspecified shares_memory

fn select(df: Frame, names: list<string>) -> Frame
  requires distinct(names)
  raises ColumnNotFound when exists(n in names: not (n in df.columns))
  ensures columns: result.columns == names
  ensures rows: all(n in names: n in df.columns) implies
                eq(result.rows,
                   map(r in df.rows: map(n in names: r[index_of(df.columns, n)])),
                   float="bits")
  unspecified shares_memory
