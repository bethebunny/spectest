"""Helpers for the partitions tests.

`build_spec` fills only what partitions read from a parsed spec: functions (and an
interface's constructors and methods), parameter types, partitions, type aliases and
clauses. It accepts specs the checker rejects, which the partition error tests need.
"""

import check.types as ty
import syntax.ast as sx
from check.spec import Clause, Fn, Param, Partition, PartitionClass, Spec
from partitions.compile import compile_set_aliased
from sets import BitSet, SetContext
from syntax.ast import Ast
from syntax.parser import parse_spec


def _resolved(
    mut types: ty.Types,
    ast: Ast,
    aliases: Dict[String, Int],
    tparams: List[String],
    node: Int,
) -> Int:
    if node == 0:
        return ty.ANY_TYPE
    ref n = ast.nodes[node]
    var args = [_resolved(types, ast, aliases, tparams, k) for k in n.children]
    if n.kind == .TUPLE_TYPE:
        return types.tuple_of(args)
    if n.kind != .TYPE:
        return ty.ANY_TYPE
    if len(args) == 0:
        var scalar = types.scalar(n.text)
        if scalar is not None:
            return scalar.value()
        var alias = aliases.get(n.text)
        if alias is not None:
            return alias.value()
        return types.typevar(n.text, "") if n.text in tparams else ty.ANY_TYPE
    if n.text == "list" and len(args) == 1:
        return types.list_of(args[0])
    if n.text == "set" and len(args) == 1:
        return types.set_of(args[0])
    if n.text == "option" and len(args) == 1:
        return types.option_of(args[0])
    if n.text == "map" and len(args) == 2:
        return types.map_of(args[0], args[1])
    return ty.ANY_TYPE


def _clause_expr(it: sx.Node) -> Int:
    if it.op in [sx.Op.REQUIRES, sx.Op.ENSURES, sx.Op.RELATES, sx.Op.INVARIANT, sx.Op.AGGREGATE]:
        return it.children[0]
    if it.op in [sx.Op.RAISES, sx.Op.MAY_RAISE] and len(it.children) > 1:
        return it.children[1]
    return 0


def _add_fn(
    ast: Ast,
    mut types: ty.Types,
    aliases: Dict[String, Int],
    outer: List[String],
    node: Int,
    decl_id: String,
    mut fns: List[Fn],
    mut clauses: List[Clause],
):
    ref n = ast.nodes[node]
    var own = [ast.nodes[t].text for t in ast.nodes[n.children[0]].children]
    var tparams = outer.copy() + own.copy()
    var params = List[Param]()
    for pn in ast.nodes[n.children[1]].children:
        ref kids = ast.nodes[pn].children
        var type_id = _resolved(types, ast, aliases, tparams, kids[0] if kids else 0)
        params.append(Param(ast.nodes[pn].text, type_id, 0, pn))
    var partitions = List[Partition]()
    var clause_ids = List[Int]()
    for item in n.children[3:]:
        ref it = ast.nodes[item]
        if it.kind == .PARTITION:
            var position = -1
            for j, param in enumerate(params):
                if param.name == it.text:
                    position = j
            var classes = [
                PartitionClass(ast.nodes[c].text, c, ast.nodes[c].children[0])
                for c in it.children
            ]
            partitions.append(Partition(position, item, classes^))
        elif it.kind == .CLAUSE:
            clause_ids.append(len(clauses))
            clauses.append(
                Clause(
                    String(decl_id, "#", len(clause_ids)),
                    it.op,
                    it.text,
                    item,
                    _clause_expr(it),
                    String(),
                    List[String](),
                    len(fns),
                    -1,
                )
            )
    fns.append(
        Fn(
            n.text, decl_id, decl_id, n.kind, node, -1, own^, List[String](),
            params^, False, ty.ANY_TYPE, partitions^, clause_ids^,
        )
    )


def build_spec(source: String, path: String = "t.spec") raises -> Spec:
    var ast = parse_spec(source, path)
    var types = ty.Types()
    var aliases = Dict[String, Int]()
    var fns = List[Fn]()
    var clauses = List[Clause]()
    var no_tparams = List[String]()
    for d in ast.nodes[ast.root()].children:
        if ast.nodes[d].kind == .ALIAS:
            aliases[ast.nodes[d].text] = _resolved(
                types, ast, aliases, no_tparams, ast.nodes[d].children[0]
            )
    for d in ast.nodes[ast.root()].children:
        ref dn = ast.nodes[d]
        if dn.kind == .FN:
            _add_fn(ast, types, aliases, no_tparams, d, dn.text, fns, clauses)
        elif dn.kind == .INTERFACE:
            var tparams = [ast.nodes[t].text for t in ast.nodes[dn.children[0]].children]
            for m in dn.children[1:]:
                if ast.nodes[m].kind in [sx.NodeKind.CTOR, sx.NodeKind.METHOD]:
                    var decl_id = String(dn.text, ".", ast.nodes[m].text)
                    _add_fn(ast, types, aliases, tparams, m, decl_id, fns, clauses)
    var spec = Spec(ast.nodes[ast.root()].text, ast^, types^)
    spec.fns = fns^
    spec.clauses = clauses^
    spec.aliases = aliases^
    return spec^


def parse_set_expr(source: String, line_offset: Int = 0) raises -> Ast:
    """The tree of an expression, parsed as the first clause of a function, so its node
    is `set_expr_node(ast)`. Its span starts at line 3, column 11 (plus `line_offset`
    blank lines before the function)."""
    var blank_lines = "\n" * line_offset
    return parse_spec(
        String("spec t\n", blank_lines, "fn f()\n  ensures ", source, "\n"), "t.spec"
    )


def set_expr_node(ast: Ast) -> Int:
    return ast.child(ast.child(ast.child(ast.root(), 0), 3), 0)


def compile_set(
    mut ctx: SetContext,
    ast: Ast,
    types: ty.Types,
    elem_type: Int,
    node: Int,
    classes: Dict[String, BitSet],
) raises -> BitSet:
    return compile_set_aliased(ctx, ast, types, elem_type, node, classes, {})
