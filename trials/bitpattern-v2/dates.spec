spec dates

# Formal spec of bitpattern 0.3.0's Date codec (section 3.9): dates encode as their
# proleptic Gregorian ordinals, date(1, 1, 1) being 1.

prelude "dates.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)

model datetime.date
  observe ordinal: int = datetime.date.toordinal(self)
  build support.date_from_ordinal(n: int)

model datetime.datetime
  observe ordinal: int = datetime.date.toordinal(self)
  build support.datetime_from_ordinal(n: int, seconds: u32)

record Date { width: u8, name: string }
record BDDSet { codec: Date, storage: bitpattern.intset.IntSet }

const bitpattern.codecs.dates: Date

fn variant.Date_codec() -> Date
  ensures table: result.width == 22 and result.name == "dates"
  ensures same_constant: result.width == bitpattern.codecs.dates.width and result.name == bitpattern.codecs.dates.name

fn variant.Date_encode(d: datetime.date) -> int
  ensures ordinal: result == d.ordinal

# dates.encode(d) is d.toordinal(). A datetime refuses to drop its time; anything else that is not a date is a TypeError too.
fn variant.Date_encode_datetime(dt: datetime.datetime) -> int
  raises TypeError when true

fn variant.Date_encode_int(n: int) -> int
  raises TypeError when true

# decode raises IndexError for 0 and for anything past date.max.
fn variant.Date_decode(b: int) -> datetime.date
  requires b >= 0
  raises IndexError when b == 0 or b > 3652059
  ensures ordinal: result.ordinal == b
  relates roundtrip: variant.Date_encode(result) == b

fn variant.Date_min() -> datetime.date
  ensures first_day: result.ordinal == 1

fn variant.Date_max() -> datetime.date
  ensures last_day: result.ordinal == 3652059

fn variant.Date_all() -> BDDSet
  ensures size: result.storage.size == 3652059
  ensures width: result.storage.width == 22
  ensures ends: result.storage.has(1) and result.storage.has(3652059) and not result.storage.has(0) and not result.storage.has(3652060)

# range(start, stop): the dates in [start, stop); dates.range(date(2024, 1, 1), date(2025, 1, 1)).size == 366.
fn variant.Date_range(start: option<datetime.date>, stop: option<datetime.date>) -> BDDSet
  ensures size: result.storage.size == imax(0, (if is_none(stop) then 3652060 else unwrap(stop).ordinal) - (if is_none(start) then 1 else unwrap(start).ordinal))
  ensures edges: is_some(start) and is_some(stop) and unwrap(start).ordinal < unwrap(stop).ordinal implies result.storage.has(unwrap(start).ordinal) and not result.storage.has(unwrap(stop).ordinal)
