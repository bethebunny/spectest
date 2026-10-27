spec ips

# Formal spec of bitpattern 0.3.0's IP codecs (section 3.7). The two codecs are named by
# `kind`; addresses are objects of the ipaddress module.

prelude "ips.prelude"

model Class

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)
  observe head(n: int): list<int> = builtins.list(itertools.islice(self, n))
  build bitpattern.IntSet(items: list<u8>)
  build support.scaled_range(start: u8, stop: u8, shift: i8)

model ipaddress.IPv4Address
  observe value: int = builtins.int(self)
  observe text: string = builtins.str(self)
  build ipaddress.IPv4Address(n: u32)

model ipaddress.IPv6Address
  observe value: int = builtins.int(self)
  observe text: string = builtins.str(self)
  build support.ipv6_from_int(n: int)

record IP { width: u8, name: string, address_type: Class, network_type: Class }
record BDDSet { codec: IP, storage: bitpattern.intset.IntSet }

const bitpattern.codecs.ipv4: IP
const bitpattern.codecs.ipv6: IP

fn variant.IP_codec(kind: "ipv4" | "ipv6") -> IP
  ensures table: result.width == ip_width(kind) and result.name == kind

# encode(v) accepts an address of its own family, a str or an int, and returns int(address).
fn variant.ipv4_encode_address(a: ipaddress.IPv4Address) -> int
  ensures integer: result == a.value

fn variant.ipv6_encode_address(a: ipaddress.IPv6Address) -> int
  ensures integer: result == a.value

fn variant.ipv4_encode_text(a: ipaddress.IPv4Address) -> int
  ensures integer: result == a.value

fn variant.ipv6_encode_text(a: ipaddress.IPv6Address) -> int
  ensures integer: result == a.value

fn variant.ipv4_encode_int(n: int) -> int
  raises ValueError when n < 0 or n >= 2 ** 32
  ensures integer: result == n

fn variant.ipv6_encode_int(n: int) -> int
  raises ValueError when n < 0 or n >= 2 ** 128
  ensures integer: result == n

# The other family's addresses, floats and bytes raise TypeError.
fn variant.ipv4_encode_ipv6_address(a: ipaddress.IPv6Address) -> int
  raises TypeError when true

fn variant.ipv6_encode_ipv4_address(a: ipaddress.IPv4Address) -> int
  raises TypeError when true

fn variant.ip_encode_float(kind: "ipv4" | "ipv6", value: f64) -> int
  raises TypeError when true

fn variant.ip_encode_bytes(kind: "ipv4" | "ipv6", value: bytes) -> int
  raises TypeError when true

# Malformed strings, strings with a /, and interface objects with a prefix raise ValueError.
fn variant.ip_encode_garbage(kind: "ipv4" | "ipv6", text: string) -> int
  raises ValueError when true

fn variant.ipv4_encode_with_prefix(a: ipaddress.IPv4Address, prefix: u8) -> int
  raises ValueError when true

fn variant.ipv6_encode_with_prefix(a: ipaddress.IPv6Address, prefix: u8) -> int
  raises ValueError when true

# decode(b) is an address of the family and raises IndexError outside [0, 2 ** width).
fn variant.ipv4_decode(b: int) -> ipaddress.IPv4Address
  raises IndexError when b < 0 or b >= 2 ** 32
  ensures integer: result.value == b
  relates roundtrip: variant.ipv4_encode_address(result) == b

fn variant.ipv6_decode(b: int) -> ipaddress.IPv6Address
  raises IndexError when b < 0 or b >= 2 ** 128
  ensures integer: result.value == b
  relates roundtrip: variant.ipv6_encode_address(result) == b

fn variant.ipv4_max() -> ipaddress.IPv4Address
  ensures all_ones: result.value == 2 ** 32 - 1 and result.text == "255.255.255.255"

fn variant.ipv4_min() -> ipaddress.IPv4Address
  ensures zero: result.value == 0 and result.text == "0.0.0.0"

fn variant.ipv6_max() -> ipaddress.IPv6Address
  ensures all_ones: result.value == 2 ** 128 - 1

fn variant.ipv6_min() -> ipaddress.IPv6Address
  ensures zero: result.value == 0 and result.text == "::"

# range(start, stop): the addresses in [start, stop), the bounds encoded (an address, a
# string, an int or None).
fn variant.ip_range(kind: "ipv4" | "ipv6", start: option<int>, stop: option<int>) -> BDDSet
  raises ValueError when (is_some(start) and (unwrap(start) < 0 or unwrap(start) >= 2 ** ip_width(kind))) or (is_some(stop) and (unwrap(stop) < 0 or unwrap(stop) >= 2 ** ip_width(kind)))
  ensures width: result.storage.width == ip_width(kind)
  ensures size: result.storage.size == imax(0, (if is_none(stop) then 2 ** ip_width(kind) else unwrap(stop)) - (if is_none(start) then 0 else unwrap(start)))
  ensures edges: is_some(start) and is_some(stop) and unwrap(start) < unwrap(stop) implies result.storage.has(unwrap(start)) and not result.storage.has(unwrap(stop))

# cidr(network): every address of the block; host bits are ignored.
fn variant.ip_cidr(kind: "ipv4" | "ipv6", value: u32, prefix: i16) -> BDDSet
  raises ValueError when prefix < 0 or prefix > ip_width(kind)
  ensures size: result.storage.size == 2 ** (ip_width(kind) - prefix)
  ensures first: result.storage.has(block(value, prefix, ip_width(kind)))
  ensures last: result.storage.has(block(value, prefix, ip_width(kind)) + 2 ** (ip_width(kind) - prefix) - 1)
  ensures contains_value: result.storage.has(value)
  ensures before: block(value, prefix, ip_width(kind)) > 0 implies not result.storage.has(block(value, prefix, ip_width(kind)) - 1)
  ensures after: block(value, prefix, ip_width(kind)) + 2 ** (ip_width(kind) - prefix) < 2 ** ip_width(kind) implies not result.storage.has(block(value, prefix, ip_width(kind)) + 2 ** (ip_width(kind) - prefix))
  ensures whole_space: prefix == 0 implies result.storage.size == 2 ** ip_width(kind)

# A bare address is a single-address block.
fn variant.ip_cidr_bare(kind: "ipv4" | "ipv6", value: u32) -> BDDSet
  ensures single: result.storage.size == 1 and result.storage.has(value)

# networks(source): the fewest CIDR networks that exactly cover source, ascending, as
# (network address, prefix length) pairs.
fn variant.ip_networks(kind: "ipv4" | "ipv6", source: bitpattern.intset.IntSet) -> list<(int, int)>
  requires source.width <= ip_width(kind)
  ensures prefixes: all(n in result: 0 <= n.1 and n.1 <= ip_width(kind))
  ensures aligned: all(n in result: n.0 % 2 ** (ip_width(kind) - n.1) == 0)
  ensures ascending_disjoint: all(i in range(0, imax(len(result) - 1, 0)): result[i].0 + 2 ** (ip_width(kind) - result[i].1) <= result[i + 1].0)
  ensures covers: len(result) <= 512 implies sum(n in result: 2 ** (ip_width(kind) - n.1)) == source.size
  ensures inside: all(n in result: source.has(n.0) and source.has(n.0 + 2 ** (ip_width(kind) - n.1) - 1))
  ensures fewest: all(i in range(0, imax(len(result) - 1, 0)): not (result[i].1 == result[i + 1].1 and result[i + 1].0 == result[i].0 + 2 ** (ip_width(kind) - result[i].1) and result[i].0 % 2 ** (ip_width(kind) - result[i].1 + 1) == 0))
  ensures empty: source.size == 0 implies len(result) == 0
  ensures everything: source.width == ip_width(kind) and source.size == 2 ** ip_width(kind) implies result == [(0, 0)]

# A source of another codec raises TypeError, but only when iteration starts.
fn variant.ip_networks_other_codec(kind: "ipv4" | "ipv6", source: bitpattern.intset.IntSet) -> list<(int, int)>
  requires source.width <= 32
  raises TypeError when true
