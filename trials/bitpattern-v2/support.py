"""Callables the spec reaches by name, through the `modules` map of test_bitpattern.py.

bitpattern's keyword-only parameters cannot be passed by v2, which calls by position,
and its iterators and ndarrays cannot cross to the host, so the functions here put the
keyword in, or turn the object into a list. Each one is a single call of the library
function the spec names; none computes an answer. Importing this module imports
bitpattern, so it is only imported when a run resolves one of these names.
"""

from __future__ import annotations

import itertools
import operator
import pickle
import random

import bitpattern
import bitpattern.bdd as bdd
import bitpattern.codecs
import numpy

# Iterators are cut here; the spec's clauses read at most this many items.
LIMIT = 513


# -- IntSet -------------------------------------------------------------------------


def intset_width(items, width):
    """IntSet(items, width=width)."""
    return bitpattern.IntSet(items, width=width)


def intset_range(start, stop, width=None):
    """IntSet.range(start, stop, width=width)."""
    return bitpattern.IntSet.range(start, stop, width=width)


def scaled_range(start, stop, shift):
    """A set far too large to list: IntSet.range(start << shift, stop << shift)."""
    return bitpattern.IntSet.range(start << shift, stop << shift)


def choice(s, rng):
    """s.choice(rng=rng)."""
    return s.choice(rng=rng)


def choice_seeded(s, seed):
    """The members chosen by two rngs seeded alike."""
    return (s.choice(rng=random.Random(seed)), s.choice(rng=random.Random(seed)))


def getslice(s, start, stop, step):
    """s[start:stop:step]; a slice object cannot cross from the host."""
    return s[slice(start, stop, step)]


def exported(s):
    """numpy.from_dlpack(s) as (dtype name, shape, items), an ndarray being opaque."""
    array = numpy.from_dlpack(s)
    return (str(array.dtype), list(array.shape), array.reshape(-1).tolist())


def dlpack(s, stream, max_version, dl_device, copy):
    """s.__dlpack__(stream=..., max_version=..., dl_device=..., copy=...), without the capsule."""
    s.__dlpack__(stream=stream, max_version=max_version, dl_device=dl_device, copy=copy)


# -- Pattern ------------------------------------------------------------------------


def pattern_tokens(tokens):
    """Pattern(text) for the text the tokens spell."""
    return bitpattern.Pattern("".join(tokens))


def pattern_from_cells(cells):
    """Pattern(text) for the cells (0, 1 or ?, most significant first), in quartets."""
    text = "".join(cells)
    first = len(text) % 4 or 4
    quartets = [text[:first]] + [text[i : i + 4] for i in range(first, len(text), 4)]
    return bitpattern.Pattern(".".join(quartets))


# -- bitpattern.bdd -----------------------------------------------------------------


def diagram(cells):
    """bdd.diagram(bits) for the cells, a list of 0, 1 and ?."""
    return bdd.diagram("".join(cells))


def bdd_count(node, width):
    return bdd.count(node, width=width)


def bdd_rank(node, value, width):
    return bdd.rank(node, value, width=width)


def bdd_nth(node, n, width):
    return bdd.nth(node, n, width=width)


def bdd_members(node, width):
    return list(itertools.islice(bdd.members(node, width=width), LIMIT))


def bdd_blocks(node, width):
    return list(itertools.islice(bdd.blocks(node, width=width), LIMIT))


def bdd_paths(node, width):
    return list(itertools.islice(bdd.paths(node, width=width), LIMIT))


def exactly_these(values, width):
    return bdd.exactly_these(values, width=width)


def interval(start, stop, width):
    return bdd.interval(start, stop, width=width)


def narrowed(node, width):
    return bdd.narrowed(node, width=width)


def freed_between(node, low_bit, high_bit):
    return bdd.freed_between(node, low_bit=low_bit, high_bit=high_bit)


def pickle_roundtrip(node):
    return pickle.loads(pickle.dumps(node))


# -- bitpattern.codecs: the BDDSet of a codec ---------------------------------------
#
# A BDDSet crosses as a record (codec, storage) and a record cannot be built from an
# object the host generates, so the spec passes the codec record and the storage IntSet,
# and each function here rebuilds the set (widening the storage to the codec's width)
# and makes the one call the spec names.


def _set(codec, storage):
    return bitpattern.codecs.BDDSet(codec, storage.widened(codec.width))


def codec_pattern(codec, tokens):
    """codec.pattern(text) for the text the tokens spell."""
    return codec.pattern("".join(tokens))


def bddset_size(codec, storage):
    return _set(codec, storage).size


def bddset_contains(codec, storage, v):
    return v in _set(codec, storage)


def bddset_contains_other(codec, storage, v):
    """v in s for a v that is not an int."""
    return v in _set(codec, storage)


def bddset_getitem(codec, storage, i):
    return _set(codec, storage)[i]


def bddset_slice(codec, storage, start, stop, step):
    return _set(codec, storage)[slice(start, stop, step)]


def bddset_index(codec, storage, v, start, stop):
    return _set(codec, storage).index(v, start, stop)


def bddset_count(codec, storage, v):
    return _set(codec, storage).count(v)


def bddset_invert(codec, storage):
    return ~_set(codec, storage)


def bddset_or(codec, a, b):
    return _set(codec, a) | _set(codec, b)


def bddset_and(codec, a, b):
    return _set(codec, a) & _set(codec, b)


def bddset_sub(codec, a, b):
    return _set(codec, a) - _set(codec, b)


def bddset_xor(codec, a, b):
    return _set(codec, a) ^ _set(codec, b)


def bddset_le(codec, a, b):
    return operator.le(_set(codec, a), _set(codec, b))


def bddset_lt(codec, a, b):
    return operator.lt(_set(codec, a), _set(codec, b))


def bddset_ge(codec, a, b):
    return operator.ge(_set(codec, a), _set(codec, b))


def bddset_gt(codec, a, b):
    return operator.gt(_set(codec, a), _set(codec, b))


def bddset_eq(codec, a, b):
    return _set(codec, a) == _set(codec, b)


def bddset_isdisjoint(codec, a, b):
    return _set(codec, a).isdisjoint(_set(codec, b))


def bddset_or_other_codec(codec, a, other_codec, b):
    return operator.or_(_set(codec, a), _set(other_codec, b))


def bddset_or_foreign(codec, a, other):
    """s | other for an operand that is not a BDDSet."""
    return operator.or_(_set(codec, a), other)


def bddset_le_foreign(codec, a, other):
    return operator.le(_set(codec, a), other)


def bddset_isdisjoint_foreign(codec, a, other):
    return _set(codec, a).isdisjoint(other)


def bddset_eq_foreign(codec, a, other):
    return operator.eq(_set(codec, a), other)


def bddset_choice(codec, storage, rng):
    return _set(codec, storage).choice(rng=rng)


def bddset_repr(codec, storage):
    return repr(_set(codec, storage))


def bddset_exported(codec, storage):
    array = numpy.from_dlpack(_set(codec, storage))
    return (str(array.dtype), list(array.shape), array.reshape(-1).tolist())


# -- bitpattern.strategies ----------------------------------------------------------


def strategy_examples(source):
    """Twenty values drawn from from_set(source), none when the strategy has none."""
    from bitpattern.strategies import from_set
    from hypothesis import HealthCheck, given, settings

    drawn = []

    @settings(
        max_examples=20,
        database=None,
        derandomize=True,
        deadline=None,
        suppress_health_check=list(HealthCheck),
    )
    @given(from_set(source))
    def collect(x):
        drawn.append(x)

    if source.size == 0:
        return []
    collect()
    return drawn


def strategy_minimal(source):
    """The simplest example of from_set(source)."""
    from bitpattern.strategies import from_set
    from hypothesis import find, settings

    return find(from_set(source), lambda x: True, settings=settings(database=None))


# -- bitpattern.codecs: the float codecs, picked by name ---------------------------------


def _codec(kind):
    return getattr(bitpattern.codecs, kind)


def float_codec(kind):
    return _codec(kind)


def float_codec_fn():
    return bitpattern.codecs.float8_e4m3fn


def float_dtype(kind):
    return _codec(kind).dtype()


def float_max(kind):
    return _codec(kind).max


def float_min(kind):
    return _codec(kind).min


def float_fn_max():
    return bitpattern.codecs.float8_e4m3fn.max


def float_encode(kind, value):
    return _codec(kind).encode(value)


def float_decode(kind, b):
    return _codec(kind).decode(b)


def float_fn_encode(value):
    return bitpattern.codecs.float8_e4m3fn.encode(value)


def float_fn_decode(b):
    return bitpattern.codecs.float8_e4m3fn.decode(b)


def float_set(kind, name):
    codec = _codec(kind)
    return codec.all if name == "all" else getattr(codec, name)


def float_partition(kind):
    """The partition laws are clauses over the named sets; there is nothing to call."""
    return 0


def float_range(kind, start, stop):
    return _codec(kind).range(start, stop)


def float_getitem(kind, i):
    return _codec(kind).all[i]


def char_codec():
    return bitpattern.codecs.char


# -- bitpattern.codecs: MAC, UUID, Date ---------------------------------------------


def _hex_octets(octets, upper):
    texts = ["%02x" % o for o in octets]
    return [t.upper() for t in texts] if upper else texts


def _mac_text(octets, form, upper):
    parts = _hex_octets(octets, upper)
    if form == "colon":
        return ":".join(parts)
    if form == "dash":
        return "-".join(parts)
    if form == "dot":
        flat = "".join(parts)
        return ".".join(flat[i : i + 4] for i in range(0, len(flat), 4))
    if form == "mixed":
        return "".join(p + (":" if i % 2 == 0 else "-") for i, p in enumerate(parts))[:-1]
    if form == "bare":
        return "".join(parts)
    return " " + ":".join(parts) + "\n"


def mac_codec():
    return bitpattern.codecs.mac


def mac_encode(octets, form, upper):
    return bitpattern.codecs.mac.encode(_mac_text(octets, form, upper))


def mac_decode(b):
    return bitpattern.codecs.mac.decode(b)


def mac_min():
    return bitpattern.codecs.mac.min


def mac_max():
    return bitpattern.codecs.mac.max


def mac_set(name):
    codec = bitpattern.codecs.mac
    return codec.all if name == "all" else getattr(codec, name)


def mac_oui(octets, separator, upper):
    return bitpattern.codecs.mac.oui(separator.join(_hex_octets(octets, upper)))


def mac_oui_other_form(form):
    return bitpattern.codecs.mac.oui("001a.2b" if form == "dotted" else "00:1a")


def uuid_codec():
    return bitpattern.codecs.uuid128


def uuid_dtype():
    return bitpattern.codecs.uuid128.dtype()


def uuid_from_int(n):
    """A UUID for any integer: n modulo 2 ** 128."""
    import uuid

    return uuid.UUID(int=n % 2**128)


def uuid_encode_text(u, style):
    text = {
        "plain": str(u),
        "hex": u.hex,
        "braces": "{" + str(u) + "}",
        "urn": "urn:uuid:" + str(u),
    }[style]
    return bitpattern.codecs.uuid128.encode(text)


def uuid_rfc9562():
    return bitpattern.codecs.uuid128.rfc9562


def uuid_version(n):
    return bitpattern.codecs.uuid128.version(n)


def uuid_in_version(u, n):
    return u in bitpattern.codecs.uuid128.version(n)


def uuid4_in_version4():
    import uuid

    return uuid.uuid4() in bitpattern.codecs.uuid128.version(4)


def date_from_ordinal(n):
    """A date for any integer: ordinal 1 + n modulo the number of dates."""
    import datetime

    return datetime.date.fromordinal(1 + n % 3652059)


def datetime_from_ordinal(n, seconds):
    import datetime

    day = datetime.date.fromordinal(1 + n % 3652059)
    return datetime.datetime.combine(day, datetime.time()) + datetime.timedelta(seconds=seconds % 86400)


def date_codec():
    return bitpattern.codecs.dates


def date_min():
    return bitpattern.codecs.dates.min


def date_max():
    return bitpattern.codecs.dates.max


def date_all():
    return bitpattern.codecs.dates.all


# -- bitpattern.codecs: the IP codecs ------------------------------------------------


def _ip(kind):
    return getattr(bitpattern.codecs, kind)


def ip_codec(kind):
    return _ip(kind)


def ipv6_from_int(n):
    """An IPv6 address for any integer: n modulo 2 ** 128."""
    import ipaddress

    return ipaddress.IPv6Address(n % 2**128)


def ipv4_encode(v):
    return bitpattern.codecs.ipv4.encode(v)


def ipv6_encode(v):
    return bitpattern.codecs.ipv6.encode(v)


def ipv4_encode_text(a):
    return bitpattern.codecs.ipv4.encode(str(a))


def ipv6_encode_text(a):
    return bitpattern.codecs.ipv6.encode(str(a))


def ipv4_encode_with_prefix(a, prefix):
    import ipaddress

    return bitpattern.codecs.ipv4.encode(ipaddress.IPv4Interface(f"{a}/{prefix % 33}"))


def ipv6_encode_with_prefix(a, prefix):
    import ipaddress

    return bitpattern.codecs.ipv6.encode(ipaddress.IPv6Interface(f"{a}/{prefix % 129}"))


def ip_encode_float(kind, value):
    return _ip(kind).encode(value)


def ip_encode_bytes(kind, value):
    return _ip(kind).encode(value)


def ip_encode_garbage(kind, text):
    return _ip(kind).encode(text)


def ip_range(kind, start, stop):
    return _ip(kind).range(start, stop)


def ip_cidr(kind, value, prefix):
    import ipaddress

    address = (ipaddress.IPv4Address if kind == "ipv4" else ipaddress.IPv6Address)(value)
    return _ip(kind).cidr(f"{address}/{prefix}")


def ip_cidr_bare(kind, value):
    import ipaddress

    address = (ipaddress.IPv4Address if kind == "ipv4" else ipaddress.IPv6Address)(value)
    return _ip(kind).cidr(str(address))


def _networks(codec, source):
    s = bitpattern.codecs.BDDSet(codec, source.widened(codec.width))
    networks = itertools.islice(codec.networks(s), LIMIT)
    return [(int(n.network_address), n.prefixlen) for n in networks]


def ip_networks(kind, source):
    return _networks(_ip(kind), source)


def ip_networks_other_codec(kind, source):
    """A source of the other family: ipv4 asked for the networks of an ipv6 set, and the reverse."""
    codec, other = (_ip(kind), bitpattern.codecs.ipv6 if kind == "ipv4" else bitpattern.codecs.ipv4)
    s = bitpattern.codecs.BDDSet(other, source.widened(other.width))
    return [(int(n.network_address), n.prefixlen) for n in itertools.islice(codec.networks(s), LIMIT)]


def ipv4_min():
    return bitpattern.codecs.ipv4.min


def ipv4_max():
    return bitpattern.codecs.ipv4.max


def ipv6_min():
    return bitpattern.codecs.ipv6.min


def ipv6_max():
    return bitpattern.codecs.ipv6.max


# -- bitpattern.codecs: Tuple, product, project --------------------------------------


def tuple_new(a, b):
    return bitpattern.codecs.Tuple(a, b)


def tuple_empty():
    return bitpattern.codecs.Tuple()


def tuple_encode(a, b, x, y):
    return bitpattern.codecs.Tuple(a, b).encode((x, y))


def tuple_encode_list(a, b, x, y):
    return bitpattern.codecs.Tuple(a, b).encode([x, y])


def tuple_encode_length(a, b, x):
    return bitpattern.codecs.Tuple(a, b).encode((x,))


def tuple_decode(a, b, bits):
    return bitpattern.codecs.Tuple(a, b).decode(bits)


def tuple_product(ca, a, cb, b):
    return bitpattern.codecs.product(_set(ca, a), _set(cb, b))


def tuple_product_nothing():
    return bitpattern.codecs.product()


def tuple_mul(ca, a, cb, b):
    return _set(ca, a) * _set(cb, b)


def tuple_mul_foreign(ca, a, other):
    return _set(ca, a) * other


def tuple_project(ca, a, cb, b, index):
    projected = bitpattern.codecs.project(tuple_product(ca, a, cb, b), index)
    return (projected.storage, projected.codec.name)


def tuple_project_non_tuple(ca, a, index):
    projected = bitpattern.codecs.project(_set(ca, a), index)
    return (projected.storage, projected.codec.name)


# -- bitpattern.codecs: Members and Flags, over enums defined here --------------------
#
# bitpattern does not provide enums, so the spec's enums are these.

import enum  # noqa: E402


class Color(enum.Enum):
    RED = "r"
    GREEN = "g"
    BLUE = "b"
    CRIMSON = "r"  # an alias of RED


class Level(enum.IntEnum):
    LOW = 1
    MID = 2
    HIGH = 3


class Single(enum.Enum):
    ONLY = 1


class Empty(enum.Enum):
    pass


class Perm(enum.Flag):
    R = 4
    W = 2
    X = 1


class Tree(enum.Flag):
    LEAF = 4
    CHAIN = 12
    LOW = 1


_ENUMS = {"Color": Color, "Level": Level, "Single": Single, "Empty": Empty, "Perm": Perm, "Tree": Tree}


def _member(kind, index):
    return list(_ENUMS[kind].__members__.values())[index]


def _members(kind, picks):
    members = [_member(kind, p % len(_ENUMS[kind])) for p in picks]
    return bitpattern.codecs.Members(_ENUMS[kind]).set(members)


def _flags(kind, names):
    flags = _ENUMS[kind](0)
    for name in names:
        flags |= _ENUMS[kind][name]
    return flags


def members_codec(kind):
    codec = bitpattern.codecs.Members(_ENUMS[kind])
    return (codec.width, codec.name)


def members_encode(kind, index):
    return bitpattern.codecs.Members(_ENUMS[kind]).encode(_member(kind, index))


def members_encode_alias():
    return bitpattern.codecs.Members(Color).encode(Color.CRIMSON)


def members_encode_raw(kind, index):
    return bitpattern.codecs.Members(_ENUMS[kind]).encode(_member(kind, index).value)


def members_encode_unlisted_combination():
    return bitpattern.codecs.Members(Tree).encode(Tree.LEAF | Tree.LOW)


def members_decode(kind, i):
    return bitpattern.codecs.Members(_ENUMS[kind]).decode(i)


def members_dtype(kind):
    return bitpattern.codecs.Members(_ENUMS[kind]).dtype()


def members_all(kind):
    return bitpattern.codecs.Members(_ENUMS[kind]).all.storage


def members_set(kind, picks):
    return _members(kind, picks).storage


def members_iterate(kind, picks):
    return list(_members(kind, picks))


def members_invert(kind, picks):
    return (~_members(kind, picks)).storage


def members_exported(kind, picks):
    array = numpy.from_dlpack(_members(kind, picks))
    return (str(array.dtype), list(array.shape), array.reshape(-1).tolist())


def flags_codec(kind):
    codec = bitpattern.codecs.Flags(_ENUMS[kind])
    return (codec.width, codec.name)


def flags_all(kind):
    return bitpattern.codecs.Flags(_ENUMS[kind]).all.storage


def flags_encode(kind, names):
    return bitpattern.codecs.Flags(_ENUMS[kind]).encode(_flags(kind, names))


def flags_encode_int(kind, n):
    return bitpattern.codecs.Flags(_ENUMS[kind]).encode(n)


def flags_decode(kind, b):
    return bitpattern.codecs.Flags(_ENUMS[kind]).decode(b)


def flags_having(kind, names):
    return bitpattern.codecs.Flags(_ENUMS[kind]).having(_flags(kind, names)).storage


def flags_lacking(kind, names):
    return bitpattern.codecs.Flags(_ENUMS[kind]).lacking(_flags(kind, names)).storage


# -- bitpattern.codecs: DateTime ------------------------------------------------------


def is_aware(dt):
    return dt.utcoffset() is not None


def offset_seconds(dt):
    offset = dt.utcoffset()
    return 0 if offset is None else int(offset.total_seconds())


def naive_datetime(day, micros):
    """A naive datetime for any integers: a date, and a time of day in microseconds."""
    import datetime

    date = datetime.date.fromordinal(1 + day % 3652059)
    return datetime.datetime.combine(date, datetime.time()) + datetime.timedelta(
        microseconds=micros % (86400 * 10**6)
    )


def aware_datetime(day, micros, offset_minutes):
    """An aware datetime in a fixed zone of up to 23 hours 59 minutes from UTC."""
    import datetime

    zone = datetime.timezone(datetime.timedelta(minutes=offset_minutes % 2879 - 1439))
    return naive_datetime(day, micros).replace(tzinfo=zone)


def _datetimes(kind):
    return bitpattern.codecs.datetimes if kind == "utc" else bitpattern.codecs.naive_datetimes


def dt_codec(kind):
    return _datetimes(kind)


def dt_utc_equals():
    import datetime

    return bitpattern.codecs.DateTime(datetime.timezone.utc) == bitpattern.codecs.datetimes


def dt_encode(kind, dt):
    return _datetimes(kind).encode(dt)


def dt_decode(kind, b):
    return _datetimes(kind).decode(b)


def dt_all(kind):
    return _datetimes(kind).all


def dt_range(kind, start, stop):
    return _datetimes(kind).range(start, stop)
