"""Partitions of a checked spec compiled to sets, with the checks that their classes are
disjoint and cover the values `requires` admits."""

from std.collections import Dict
from std.math import log2

import check.types as ty
import syntax.ast as sx
from bigint import BigUInt
from check.spec import Partition, Spec
from numeric.floats import is_nan
from numeric.formats import format_by_id
from numeric.text import float_text
from sets import BitSet, SetContext
from syntax.ast import Ast, Diagnostic

from .compile import Elem, SetCompiler, alias_elems, elem_of
from .requires import admitted


struct PartitionSets(Movable):
    """The compiled classes of every partition, and the warnings found on the way."""

    var starts: List[List[Int]]
    """Per function, per partition: index of its first class in `sets`."""
    var counts: List[List[Int]]
    var sets: List[BitSet]
    var predicates: List[Bool]
    var warnings: List[Diagnostic]

    def __init__(out self):
        self.starts = List[List[Int]]()
        self.counts = List[List[Int]]()
        self.sets = List[BitSet]()
        self.predicates = List[Bool]()
        self.warnings = List[Diagnostic]()

    def class_count(self, f: Int, p: Int) -> Int:
        return self.counts[f][p]

    def set_of(self, f: Int, p: Int, k: Int) -> BitSet:
        """The set of class `k` of partition `p` of function `f` (a placeholder when
        the class is a predicate)."""
        return self.sets[self.starts[f][p] + k]

    def is_predicate(self, f: Int, p: Int, k: Int) -> Bool:
        """Whether the class is a predicate on a parameter that isn't fixed-width."""
        return self.predicates[self.starts[f][p] + k]


def _count_text(n: BigUInt) -> String:
    var small = n.uint128_or_none().value()
    var noun = " value" if small == 1 else " values"
    if small < UInt128(1 << 20):
        var digits = String(Int(small))
        var out = String()
        var len = digits.byte_length()
        for i in range(len):
            if i > 0 and (len - i) % 3 == 0:
                out += ","
            out += digits[byte=i : i + 1]
        return out + noun
    if small & (small - 1) == 0:
        var k = 0
        while (small >> UInt128(k)) > 1:
            k += 1
        return String("2^", k, noun)
    var tenths = Int(log2(Float64(small)) * 10.0 + 0.5)
    return String("about 2^", tenths // 10, ".", tenths % 10, noun)


def _hex(bits: UInt64, digits: Int) -> String:
    var out = String()
    for i in range(digits):
        var nibble = Int((bits >> UInt64(4 * (digits - 1 - i))) & 15)
        out += String(nibble) if nibble < 10 else chr(ord("a") + nibble - 10)
    return out


def value_text(elem: Elem, bits: UInt64) raises -> String:
    """A pattern as a value: `0.0 (0x0000000000000000)`, `-3`, `true`."""
    if elem.kind == ty.BOOL:
        return "true" if bits != 0 else "false"
    if elem.is_float():
        return float_text(elem.format_id, bits) + " (0x" + _hex(bits, elem.width // 4) + ")"
    if elem.signed:
        var shift = UInt64(64 - elem.width)
        var extended = Int64(bits << shift) >> Int64(shift)
        return String(Int(extended))
    return String(bits)


def _example(mut ctx: SetContext, elem: Elem, s: BitSet) raises -> String:
    """A member of `s`, preferring simple values: 0, 1 and -1."""
    var candidates = List[UInt64]()
    candidates.append(0)
    if elem.is_float():
        var f = elem.format()
        var one = UInt64(f.bias()) << UInt64(f.fraction_bits)
        candidates.append(one)
        candidates.append(one | f.sign_mask())
    elif elem.is_int():
        candidates.append(1)
        candidates.append(UInt64.MAX if elem.width == 64 else (UInt64(1) << UInt64(elem.width)) - 1)
    else:
        candidates.append(1)
    for c in candidates:
        if ctx.contains(s, c):
            return value_text(elem, c)
    return value_text(elem, ctx.nth(s, BigUInt(0)))


def _uses(ast: Ast, e: Int, names: Dict[String, Bool]) -> Bool:
    ref n = ast.nodes[e]
    if n.kind == sx.NAME and n.text in names:
        return True
    for k in n.kids:
        if _uses(ast, k, names):
            return True
    return False


def compile_partitions(mut ctx: SetContext, spec: Spec) raises -> PartitionSets:
    """The set of every class of every partition over a fixed-width parameter, checked
    to be pairwise disjoint and to cover the values `requires` admits (the whole type
    when it says nothing set-like). Classes over other parameters are marked as
    predicates. Errors are raised together, one `path:line:col: message` per line;
    warnings are returned with the sets."""
    var out = PartitionSets()
    var errors = List[String]()
    var aliases = alias_elems(spec.types, spec.aliases)
    for f in range(len(spec.fns)):
        ref func = spec.fns[f]
        var starts = List[Int]()
        var counts = List[Int]()
        for p in range(len(func.partitions)):
            ref part = func.partitions[p]
            starts.append(len(out.sets))
            counts.append(len(part.classes))
            var elem = elem_of(spec.types, func.params[part.param].type)
            if not elem:
                for _ in range(len(part.classes)):
                    out.sets.append(ctx.empty(1))
                    out.predicates.append(True)
                continue
            var found = _check_partition(
                ctx, spec, f, p, elem.value(), aliases.copy(), out.sets, out.warnings
            )
            for _ in range(len(part.classes)):
                out.predicates.append(False)
            for e in found:
                errors.append(e)
        out.starts.append(starts^)
        out.counts.append(counts^)
    if len(errors) > 0:
        var message = String()
        for i in range(len(errors)):
            message += ("\n" if i > 0 else "") + errors[i]
        raise Error(message)
    return out^


def _diag(ast: Ast, node: Int, message: String) -> String:
    return String(ast.path, ":", ast.nodes[node].span, ": ", message)


def _check_partition(
    mut ctx: SetContext,
    spec: Spec,
    f: Int,
    p: Int,
    elem: Elem,
    var aliases: Dict[String, Elem],
    mut sets: List[BitSet],
    mut warnings: List[Diagnostic],
) raises -> List[String]:
    """Compiles one partition, appending its classes' sets (empty ones where a class
    failed), and returns its errors."""
    ref ast = spec.ast
    ref func = spec.fns[f]
    ref part = func.partitions[p]
    var pname = func.params[part.param].name
    var label = String("partition ", pname, " of ", func.decl_id)
    var errors = List[String]()
    var comp = SetCompiler(elem, aliases^, Dict[String, BitSet]())
    var failed = Dict[String, Bool]()
    var compiled = List[Int]()  # positions of the classes that compiled
    var results = List[BitSet]()
    for k in range(len(part.classes)):
        ref cls = part.classes[k]
        if cls.name in comp.classes or cls.name in failed:
            errors.append(
                _diag(ast, cls.node, String(label, ": class ", cls.name, " is defined twice"))
            )
            failed[cls.name] = True
            results.append(ctx.empty(elem.width))
            continue
        if _uses(ast, cls.expr, failed):
            failed[cls.name] = True
            results.append(ctx.empty(elem.width))
            continue
        try:
            var s = comp.compile(ctx, ast, cls.expr)
            comp.classes[cls.name] = s
            compiled.append(k)
            results.append(s)
        except:
            errors.append(
                comp.diagnostic(ast, String(label, ": class ", cls.name, ": "))
            )
            failed[cls.name] = True
            results.append(ctx.empty(elem.width))
    for s in results:
        sets.append(s)
    if len(errors) > 0:
        return errors^

    var union = ctx.empty(elem.width)
    for i in range(len(compiled)):
        ref cls = part.classes[compiled[i]]
        var s = results[compiled[i]]
        if ctx.is_empty(s):
            warnings.append(
                Diagnostic(
                    ast.path,
                    ast.nodes[cls.node].span,
                    String(label, ": class ", cls.name, " is empty"),
                )
            )
        for j in range(i):
            var other = part.classes[compiled[j]].name
            var common = ctx.intersection(results[compiled[j]], s)
            if not ctx.is_empty(common):
                errors.append(
                    _diag(
                        ast,
                        cls.node,
                        String(
                            label, ": classes ", other, " and ", cls.name,
                            " overlap on ", _count_text(ctx.count(common)),
                            ", e.g. ", pname, " = ", _example(ctx, elem, common),
                        ),
                    )
                )
        union = ctx.union(union, s)

    var target = admitted(ctx, spec, f, part.param)
    if not target:
        var missing = ctx.difference(ctx.full(elem.width), union)
        if not ctx.is_empty(missing):
            errors.append(
                _diag(
                    ast,
                    part.node,
                    String(
                        label, " does not cover every ", elem.name(), ": ",
                        _count_text(ctx.count(missing)), " in no class, e.g. ",
                        pname, " = ", _example(ctx, elem, missing),
                    ),
                )
            )
        return errors^
    var missing = ctx.difference(target.value(), union)
    if not ctx.is_empty(missing):
        errors.append(
            _diag(
                ast,
                part.node,
                String(
                    label, " does not cover the values requires admits: ",
                    _count_text(ctx.count(missing)), " in no class, e.g. ", pname,
                    " = ", _example(ctx, elem, missing),
                ),
            )
        )
    for i in range(len(compiled)):
        ref cls = part.classes[compiled[i]]
        var s = results[compiled[i]]
        var outside = ctx.difference(s, target.value())
        if not ctx.is_empty(s) and not ctx.is_empty(outside):
            warnings.append(
                Diagnostic(
                    ast.path,
                    ast.nodes[cls.node].span,
                    String(
                        label, ": class ", cls.name, " has ",
                        _count_text(ctx.count(outside)),
                        " that requires rejects, e.g. ", pname, " = ",
                        _example(ctx, elem, outside),
                    ),
                )
            )
    return errors^
