"""Partitions of a checked spec compiled to sets, with the checks that their classes are
disjoint and cover the values `requires` admits."""

from std.bit import count_trailing_zeros, pop_count
from std.collections import Set
from std.math import log2

from spec.ast import Ast, Diagnostic
from spec.spec import Spec
from value.digits import hex_digits
from value.fixed import low_mask, signed_of
from value.number_text import float_text

from partition.sets import BitSet, SetContext

from .compile import Elem, SetCompiler, alias_elems, elem_of
from .requires import admitted


@fieldwise_init
struct ClassSets(Copyable):
    """The sets of one partition's classes. A partition over a parameter that isn't
    fixed-width has predicates for classes, and empty sets."""

    var sets: List[BitSet]
    var predicates: Bool


struct PartitionSets(Defaultable, Movable):
    """The compiled classes of every partition, and the warnings found on the way."""

    var partitions: List[List[ClassSets]]
    """Per function, per partition."""
    var warnings: List[Diagnostic]

    def class_count(self, f: Int, p: Int) -> Int:
        return len(self.partitions[f][p].sets)

    def set_of(self, f: Int, p: Int, k: Int) -> BitSet:
        """The set of class `k` of partition `p` of function `f` (empty for a predicate)."""
        return self.partitions[f][p].sets[k]

    def is_predicate(self, f: Int, p: Int, k: Int) -> Bool:
        """Whether the class is on a parameter that isn't fixed-width."""
        return self.partitions[f][p].predicates


def _count_text(n: UInt128) -> String:
    var noun = " value" if n == 1 else " values"
    if n < UInt128(1 << 20):
        var digits = String(n)
        var head = (digits.byte_length() - 1) % 3 + 1  # the digits before the first comma
        var groups: List[String] = [String(digits[byte=0:head])]
        groups += [String(digits[byte=i : i + 3]) for i in range(head, digits.byte_length(), 3)]
        return String(",".join(groups), noun)
    if pop_count(n) == 1:
        return String("2^", Int(count_trailing_zeros(n)), noun)
    var tenths = Int(log2(Float64(n)) * 10.0 + 0.5)
    return String("about 2^", tenths // 10, ".", tenths % 10, noun)


def value_text(elem: Elem, bits: UInt64) raises -> String:
    """A pattern as a value: `0.0 (0x0000000000000000)`, `-3`, `true`."""
    if elem.is_bool():
        return "true" if bits != 0 else "false"
    if elem.is_float():
        return String(float_text(elem.format.id, bits), " (0x", hex_digits(bits, width=elem.width // 4), ")")
    return String(signed_of(bits, elem.width)) if elem.signed else String(bits)


def _example(ctx: SetContext, elem: Elem, s: BitSet) raises -> String:
    """A member of `s`, preferring simple values: 0, 1 and -1."""
    var candidates: List[UInt64] = [0]
    if elem.is_float():
        var one = UInt64(elem.format.bias()) << UInt64(elem.format.fraction_bits)
        candidates += [one, one | elem.format.sign_mask()]
    elif elem.is_int():
        candidates += [1, low_mask(elem.width)]
    else:
        candidates.append(1)
    for c in candidates:
        if ctx.contains(s, c):
            return value_text(elem, c)
    return value_text(elem, ctx.nth(s, 0))


def _uses(ast: Ast, e: Int, names: Set[String]) -> Bool:
    ref n = ast.nodes[e]
    return (n.kind == .NAME and n.text in names) or any([_uses(ast, k, names) for k in n.children])


def compile_partitions(mut ctx: SetContext, spec: Spec) raises -> PartitionSets:
    """The set of every class of every partition over a fixed-width parameter, checked
    to be pairwise disjoint and to cover the values `requires` admits (the whole type
    when it says nothing set-like). Classes over other parameters are marked as
    predicates. Errors are raised together, one `path:line:col: message` per line;
    warnings are returned with the sets."""
    var out = PartitionSets()
    var errors: List[Diagnostic] = []
    var aliases = alias_elems(spec.types, spec.aliases)
    for f in range(len(spec.fns)):
        ref func = spec.fns[f]
        var partitions: List[ClassSets] = []
        for p in range(len(func.partitions)):
            ref part = func.partitions[p]
            var elem = elem_of(spec.types, func.params[part.param].type)
            if elem is None:
                partitions.append(ClassSets([ctx.empty(1) for _ in part.classes], predicates=True))
            else:
                var sets = _class_sets(ctx, spec, f, p, elem.value(), aliases.copy(), errors, out.warnings)
                partitions.append(ClassSets(sets^, predicates=False))
        out.partitions.append(partitions^)
    if errors:
        raise Error("\n".join(errors))
    return out^


def _class_sets(
    mut ctx: SetContext,
    spec: Spec,
    f: Int,
    p: Int,
    elem: Elem,
    var aliases: Dict[String, Elem],
    mut errors: List[Diagnostic],
    mut warnings: List[Diagnostic],
) raises -> List[BitSet]:
    """The sets of one partition's classes (empty where a class failed), checked to be
    disjoint and to cover what `requires` admits."""
    ref ast = spec.ast
    ref part = spec.fns[f].partitions[p]
    var param = spec.fns[f].params[part.param].name
    var label = String("partition ", param, " of ", spec.fns[f].decl_id)
    var compiler = SetCompiler(elem, aliases^, {})
    var failed: Set[String] = {}
    var results = [ctx.empty(elem.width) for _ in part.classes]
    for k, cls in enumerate(part.classes):
        if cls.name in compiler.classes or cls.name in failed:
            errors.append(ast.diagnostic(cls.node, t"{label}: class {cls.name} is defined twice"))
            failed.add(cls.name)
        elif _uses(ast, cls.expr, failed):
            failed.add(cls.name)
        else:
            try:
                results[k] = compiler.compile(ctx, ast, cls.expr)
                compiler.classes[cls.name] = results[k]
            except err:
                errors.append(ast.diagnostic(err.node, t"{label}: class {cls.name}: {err.message}"))
                failed.add(cls.name)
    if failed:
        return results^

    var union = ctx.empty(elem.width)
    for k, cls in enumerate(part.classes):
        if ctx.is_empty(results[k]):
            warnings.append(ast.diagnostic(cls.node, t"{label}: class {cls.name} is empty"))
        for earlier in range(k):
            if not ctx.disjoint(results[earlier], results[k]):
                var common = ctx.intersection(results[earlier], results[k])
                errors.append(
                    ast.diagnostic(
                        cls.node,
                        t"{label}: classes {part.classes[earlier].name} and {cls.name} overlap on"
                        t" {_count_text(ctx.count(common))}, e.g. {param} = {_example(ctx, elem, common)}",
                    )
                )
        union = ctx.union(union, results[k])

    var admits = admitted(ctx, spec, f, part.param)
    var target = admits.or_else(ctx.full(elem.width))
    if not ctx.subset(target, union):
        var missing = ctx.difference(target, union)
        var what = String("every ", elem.name()) if admits is None else String("the values requires admits")
        errors.append(
            ast.diagnostic(
                part.node,
                t"{label} does not cover {what}: {_count_text(ctx.count(missing))} in no class,"
                t" e.g. {param} = {_example(ctx, elem, missing)}",
            )
        )
    if admits is None:
        return results^
    for k, cls in enumerate(part.classes):
        if not ctx.subset(results[k], target):
            var outside = ctx.difference(results[k], target)
            warnings.append(
                ast.diagnostic(
                    cls.node,
                    t"{label}: class {cls.name} has {_count_text(ctx.count(outside))} that"
                    t" requires rejects, e.g. {param} = {_example(ctx, elem, outside)}",
                )
            )
    return results^
