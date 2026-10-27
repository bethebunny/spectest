"""Callables the spec reaches by name, through the `modules` map of test_bitpattern.py.

bitpattern's keyword-only parameters cannot be passed by v2, which calls by position,
and its iterators and ndarrays cannot cross to the host, so the functions here put the
keyword in, or turn the object into a list. Each one is a single call of the library
function the spec names; none computes an answer. Importing this module imports
bitpattern, so it is only imported when a run resolves one of these names.
"""

from __future__ import annotations

import itertools
import pickle
import random

import bitpattern
import bitpattern.bdd as bdd
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
