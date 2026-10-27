"""Code under test for the runner's end-to-end tests: correct implementations and
seeded bugs."""

from __future__ import annotations

import math

# -- Plain functions ---------------------------------------------------------


def clamp(x, lo, hi):
    return max(lo, min(x, hi))


def clamp_no_lower_bound(x, lo, hi):
    return min(x, hi)


def clamp_identity_bug(x, lo, hi):
    """Right except that it clamps one step inside the bounds."""
    r = max(lo, min(x, hi))
    return r - 1 if r == hi and hi > lo else r


def isqrt(x):
    if x < 0:
        raise ValueError("negative")
    return math.isqrt(x)


def isqrt_never_raises(x):
    return math.isqrt(abs(x))


def isqrt_raises_too_much(x):
    if x <= 0:
        raise ValueError("not positive")
    return math.isqrt(x)


def isqrt_wrong_error(x):
    if x < 0:
        raise KeyError("negative")
    return math.isqrt(x)


def recip_or_zero(x):
    if x == 0:
        raise ZeroDivisionError("zero")
    return 1000 // x


def to_text(x):
    return str(x)


def too_big_for_u8(x):
    return x + 250


def small_u8(x):
    return x % 256


def half(x):
    if x % 2:
        raise ValueError("odd")
    return x // 2


def negate(x):
    return -x


def negate_asymmetric(x):
    return -x if x != 7 else 8


def ident(x):
    return x


def ident_plus_one_from_five(x):
    return x + (1 if x >= 5 else 0)


def rare_bug(x):
    """Wrong for one input in 997."""
    return x + 1 if x % 997 == 5 else x


def tag(x):
    return "small" if x < 10 else "large"


def bad_tag(x):
    return "small" if x < 10 else "medium"


def first_or_none(xs):
    return xs[0] if xs else None


def mapping_get(m, k):
    return m.get(k)


def pair_swap(p):
    return (p[1], p[0])


# -- Floats ------------------------------------------------------------------


def f16_id(x):
    return x


def f16_subnormal_to_zero(x):
    return 0.0 if x != 0 and abs(x) < 2**-14 else x


def f32_id(x):
    return x


def cos_shifted(x):
    """cos(x) = sin(x + pi/2): the shifted argument is rounded, so the result drifts."""
    return math.sin(x + math.pi / 2)


# -- Models ------------------------------------------------------------------


class Box:
    def __init__(self, items):
        self.items = list(items)

    @property
    def size(self):
        return len(self.items)

    def get(self, i):
        return self.items[i] if 0 <= i < len(self.items) else None


class Counter:
    def __init__(self, value=0):
        self.value = value


def make_box(items):
    return Box(items)


def make_counter(value):
    return Counter(value)


def append(b, x):
    b.items.append(x)


def append_to_both(a, b, x):
    a.items.append(x)
    b.items.append(x)


def append_without_listing(b, x):
    b.items.append(x)


def bump(c):
    c.value += 1


def bump_twice(c):
    c.value += 2


def new_counter(start):
    return Counter(start)


def new_counter_off_by_one(start):
    return Counter(start + 1)


def count_up(c, n):
    c.value += n


def sum_box(b):
    return sum(b.items)


def concat(a, b):
    return Box(a.items + b.items)


def concat_in_place(a, b):
    a.items.extend(b.items)
    return a


def not_a_box(items):
    return 12


# -- Strings -----------------------------------------------------------------


def shout(s):
    return s.upper()


# -- Counting calls ------------------------------------------------------------

CALLS = []


def counted(x):
    CALLS.append(x)
    return x


def repeat(s, n=3):
    return s * n


def repeat_bug(s, n=3):
    return s * n + ("!" if n == 4 else "")


def ident_generic(x):
    return x


def ident_generic_bug(x):
    return x if x != 3 else 4


# -- Constants, identity and reading expressions ---------------------------------

LIMIT = 100


def clip_to_limit(x):
    return min(x, LIMIT)


def same_box(b):
    return b


def new_box(items):
    return Box(items)


def pick_first(a, b):
    return a


# -- Inputs the library cannot build, and clauses that cannot be evaluated ---------


def make_small_box(items):
    if len(items) > 3:
        raise ValueError("too many items")
    return Box(items)


def size_of_small(b):
    return b.size


def div_by(x):
    return 100 // x if x else 0


class BadBox:
    """A box whose size lies once it holds more than two items."""

    def __init__(self, n):
        self.items = [0] * n

    @property
    def size(self):
        return len(self.items) + (1 if len(self.items) > 2 else 0)


def new_bad_box(n):
    return BadBox(n)
