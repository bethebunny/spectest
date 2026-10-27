spec datetimes

# Formal spec of bitpattern 0.3.0's DateTime codec (section 3.9), for the aware UTC codec
# `datetimes` and the naive `naive_datetimes`. A datetime encodes as the microseconds since
# 0001-01-01 00:00: the UTC instant for an aware codec, the wall time for the naive one.

prelude "datetimes.prelude"

model Class

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)

model datetime.date
  observe ordinal: int = datetime.date.toordinal(self)
  build support.date_from_ordinal(n: int)

model datetime.datetime
  observe ordinal: int = datetime.date.toordinal(self)
  observe hour: int = builtins.getattr(self, "hour")
  observe minute: int = builtins.getattr(self, "minute")
  observe second: int = builtins.getattr(self, "second")
  observe microsecond: int = builtins.getattr(self, "microsecond")
  observe aware: bool = support.is_aware(self)
  observe offset_seconds: int = support.offset_seconds(self)
  build support.naive_datetime(day: int, micros: int)
  build support.aware_datetime(day: int, micros: int, offset_minutes: i16)

record DateTime { width: u8, name: string, tz: option<Class> }
record BDDSet { codec: DateTime, storage: bitpattern.intset.IntSet }

const bitpattern.codecs.datetimes: DateTime
const bitpattern.codecs.naive_datetimes: DateTime

# The width is 59; the name is "naive_datetimes" without a zone and "datetimes[UTC]" for UTC.
fn variant.DT_codec(kind: "utc" | "naive") -> DateTime
  ensures width: result.width == 59
  ensures name: result.name == (if kind == "utc" then "datetimes[UTC]" else "naive_datetimes")
  ensures zone: (kind == "naive") == is_none(result.tz)

# DateTime(timezone.utc) == datetimes.
fn variant.DT_utc_equals() -> bool
  ensures equal: result

# An aware codec raises ValueError for a naive datetime and the naive codec for an aware one;
# aware input from any zone is identified by instant; an instant that cannot be represented
# raises ValueError.
fn variant.DT_encode(kind: "utc" | "naive", dt: datetime.datetime) -> int
  raises ValueError when (kind == "utc" and not dt.aware) or (kind == "naive" and dt.aware) or (kind == "utc" and (utc_us(dt) < 0 or utc_us(dt) >= end_us()))
  ensures utc_instant: kind == "utc" implies result == utc_us(dt)
  ensures wall_time: kind == "naive" implies result == wall_us(dt)
  ensures in_universe: 0 <= result and result < 2 ** 59

# A plain date is not a datetime.
fn variant.DT_encode_date(kind: "utc" | "naive", d: datetime.date) -> int
  raises TypeError when true

fn variant.DT_decode(kind: "utc" | "naive", b: int) -> datetime.datetime
  requires b >= 0
  raises IndexError when b >= end_us()
  ensures aware: result.aware == (kind == "utc")
  ensures instant: (kind == "utc" and utc_us(result) == b) or (kind == "naive" and wall_us(result) == b)
  relates roundtrip: variant.DT_encode(kind, result) == b

# all is every microsecond representable in tz.
fn variant.DT_all(kind: "utc" | "naive") -> BDDSet
  ensures size: result.storage.size == 315537897600000000
  ensures width: result.storage.width == 59
  ensures ends: result.storage.has(0) and result.storage.has(end_us() - 1) and not result.storage.has(end_us())

# range(start, stop): the datetimes in [start, stop), the bounds encoded.
fn variant.DT_range(kind: "utc" | "naive", start: option<datetime.datetime>, stop: option<datetime.datetime>) -> BDDSet
  raises ValueError when (is_some(start) and ((kind == "utc" and not unwrap(start).aware) or (kind == "naive" and unwrap(start).aware) or (kind == "utc" and (utc_us(unwrap(start)) < 0 or utc_us(unwrap(start)) >= end_us())))) or (is_some(stop) and ((kind == "utc" and not unwrap(stop).aware) or (kind == "naive" and unwrap(stop).aware) or (kind == "utc" and (utc_us(unwrap(stop)) < 0 or utc_us(unwrap(stop)) >= end_us()))))
  ensures size: result.storage.size == imax(0, (if is_none(stop) then end_us() else (if kind == "utc" then utc_us(unwrap(stop)) else wall_us(unwrap(stop)))) - (if is_none(start) then 0 else (if kind == "utc" then utc_us(unwrap(start)) else wall_us(unwrap(start)))))
