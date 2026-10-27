spec macs

# Formal spec of bitpattern 0.3.0's MAC codec (section 3.8). An address is given as six
# octets and a spelling, and support.py writes it as text.

prelude "macs.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)

record MAC { width: u8, name: string }
record BDDSet { codec: MAC, storage: bitpattern.intset.IntSet }

const bitpattern.codecs.mac: MAC

fn variant.MAC_codec() -> MAC
  ensures table: result.width == 48 and result.name == "mac"
  ensures same_constant: result.width == bitpattern.codecs.mac.width and result.name == bitpattern.codecs.mac.name

# encode accepts exactly 01:23:45:67:89:ab, 01-23-45-67-89-ab and 0123.4567.89ab, in either
# case; mixed separators, bare hex and surrounding whitespace raise ValueError.
fn variant.MAC_encode(octets: list<u8>, form: "colon" | "dash" | "dot" | "mixed" | "bare" | "spaced", upper: bool) -> int
  raises ValueError when len(octets) != 6 or form == "mixed" or form == "bare" or form == "spaced"
  ensures value: result == mac_value(octets)

fn variant.MAC_encode_int(value: int) -> int
  raises TypeError when true

# decode(b) is lowercase and colon-separated, IndexError outside 48 bits.
fn variant.MAC_decode(b: int) -> string
  raises IndexError when b < 0 or b >= 2 ** 48
  ensures text: result == mac_text(b)
  ensures roundtrip: variant.MAC_encode([octet(b, 0), octet(b, 1), octet(b, 2), octet(b, 3), octet(b, 4), octet(b, 5)], "colon", false) == b

fn variant.MAC_min() -> string
  ensures smallest: result == "00:00:00:00:00:00"

fn variant.MAC_max() -> string
  ensures largest: result == "ff:ff:ff:ff:ff:ff"

# multicast / unicast (the I/G bit) and local / universal (the U/L bit) hold 2 ** 47
# addresses each; broadcast is ff:ff:ff:ff:ff:ff, in multicast and local.
fn variant.MAC_set(name: "all" | "multicast" | "unicast" | "local" | "universal" | "broadcast") -> BDDSet
  ensures width: result.storage.width == 48
  ensures size: result.storage.size == mac_size(name)
  ensures members: all(b in mac_sample(): result.storage.has(b) == mac_in(name, b))
  ensures broadcast_is_multicast_and_local: name == "broadcast" implies variant.MAC_set("multicast").storage.has(2 ** 48 - 1) and variant.MAC_set("local").storage.has(2 ** 48 - 1)

# oui(prefix): the 2 ** 24 addresses under a three-octet prefix written with : or -, in
# either case; any other form raises ValueError.
fn variant.MAC_oui(octets: list<u8>, separator: ":" | "-", upper: bool) -> BDDSet
  raises ValueError when len(octets) != 3
  ensures size: result.storage.size == 2 ** 24
  ensures width: result.storage.width == 48
  ensures members: all(low in [0, 1, 2 ** 24 - 1]: result.storage.has((octets[0] << 40) + (octets[1] << 32) + (octets[2] << 24) + low))
  ensures outside: not result.storage.has((octets[0] << 40) + (octets[1] << 32) + (octets[2] << 24) + 2 ** 24) or octets[0] == 255 and octets[1] == 255 and octets[2] == 255
  ensures before: octets[2] > 0 implies not result.storage.has((octets[0] << 40) + (octets[1] << 32) + (octets[2] << 24) - 1)

fn variant.MAC_oui_other_form(form: "dotted" | "short") -> BDDSet
  raises ValueError when true
