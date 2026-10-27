"""Helpers for tests: a `Spec` built by hand from `parse_spec` output.

It fills what partitions read: functions (and an interface's constructors and methods),
parameter types from the TYPE nodes, partitions with their node ids, type aliases and
clauses. Everything else of a `Spec` stays empty.
"""

import check.types as ty
import syntax.ast as sx
from check.spec import Clause, Fn, Param, Partition, PartitionClass, Spec
from syntax.ast import Ast
from syntax.parser import parse_spec


def _resolve(
    mut types: ty.Types,
    ast: Ast,
    aliases: Dict[String, Int],
    tparams: List[String],
    node: Int,
) -> Int:
    if node == 0:
        return ty.ANY_TYPE
    ref n = ast.nodes[node]
    if n.kind == sx.TUPLE_TYPE:
        var elems = List[Int]()
        for k in n.kids:
            elems.append(_resolve(types, ast, aliases, tparams, k))
        return types.tuple_of(elems)
    if n.kind != sx.TYPE:
        return ty.ANY_TYPE
    if len(n.kids) == 0:
        var scalar = types.scalar(n.text)
        if scalar:
            return scalar.value()
        var alias = aliases.get(n.text)
        if alias:
            return alias.value()
        for t in tparams:
            if t == n.text:
                return types.typevar(n.text, "")
        return ty.ANY_TYPE
    var args = List[Int]()
    for k in n.kids:
        args.append(_resolve(types, ast, aliases, tparams, k))
    if n.text == "list" and len(args) == 1:
        return types.list_of(args[0])
    if n.text == "set" and len(args) == 1:
        return types.set_of(args[0])
    if n.text == "option" and len(args) == 1:
        return types.option_of(args[0])
    if n.text == "map" and len(args) == 2:
        return types.map_of(args[0], args[1])
    return ty.ANY_TYPE


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
    var tparams = outer.copy()
    var own = List[String]()
    for t in ast.nodes[n.kids[0]].kids:
        tparams.append(ast.nodes[t].text)
        own.append(ast.nodes[t].text)
    var params = List[Param]()
    for pn in ast.nodes[n.kids[1]].kids:
        var type_node = ast.nodes[pn].kids[0] if len(ast.nodes[pn].kids) > 0 else 0
        params.append(
            Param(
                ast.nodes[pn].text,
                _resolve(types, ast, aliases, tparams, type_node),
                0,
                pn,
            )
        )
    var partitions = List[Partition]()
    var clause_ids = List[Int]()
    var fn_pos = len(fns)
    for i in range(3, len(n.kids)):
        var item = n.kids[i]
        ref it = ast.nodes[item]
        if it.kind == sx.PARTITION:
            var position = -1
            for j in range(len(params)):
                if params[j].name == it.text:
                    position = j
            var classes = List[PartitionClass]()
            for c in it.kids:
                classes.append(
                    PartitionClass(ast.nodes[c].text, c, ast.nodes[c].kids[0])
                )
            partitions.append(Partition(position, item, classes^))
        elif it.kind == sx.CLAUSE:
            var expr = 0
            if (
                it.op == sx.REQUIRES
                or it.op == sx.ENSURES
                or it.op == sx.RELATES
                or it.op == sx.INVARIANT
                or it.op == sx.AGGREGATE
            ):
                expr = it.kids[0]
            elif it.op == sx.RAISES or it.op == sx.MAY_RAISE:
                if len(it.kids) > 1:
                    expr = it.kids[1]
            clause_ids.append(len(clauses))
            clauses.append(
                Clause(
                    String(decl_id, "#", len(clause_ids)),
                    it.op,
                    it.text,
                    item,
                    expr,
                    String(),
                    List[String](),
                    fn_pos,
                    -1,
                )
            )
    fns.append(
        Fn(
            n.text,
            decl_id,
            decl_id,
            n.kind,
            node,
            -1,
            own^,
            List[String](),
            params^,
            False,
            ty.ANY_TYPE,
            partitions^,
            clause_ids^,
        )
    )


def build_spec(source: String, path: String = "t.spec") raises -> Spec:
    """Parse `source` (a whole spec file) and fill a `Spec` from it by hand."""
    var ast = parse_spec(source, path)
    var types = ty.Types()
    var aliases = Dict[String, Int]()
    var fns = List[Fn]()
    var clauses = List[Clause]()
    var none = List[String]()
    for d in ast.nodes[ast.root].kids:
        ref dn = ast.nodes[d]
        if dn.kind == sx.ALIAS:
            aliases[dn.text] = _resolve(types, ast, aliases, none, ast.nodes[d].kids[0])
    for d in ast.nodes[ast.root].kids:
        ref dn = ast.nodes[d]
        if dn.kind == sx.FN:
            _add_fn(ast, types, aliases, none, d, dn.text, fns, clauses)
        elif dn.kind == sx.INTERFACE:
            var tparams = List[String]()
            for t in ast.nodes[dn.kids[0]].kids:
                tparams.append(ast.nodes[t].text)
            for i in range(1, len(dn.kids)):
                var m = dn.kids[i]
                if ast.nodes[m].kind == sx.CTOR or ast.nodes[m].kind == sx.METHOD:
                    _add_fn(
                        ast,
                        types,
                        aliases,
                        tparams,
                        m,
                        String(dn.text, ".", ast.nodes[m].text),
                        fns,
                        clauses,
                    )
    var spec = Spec(ast.nodes[ast.root].text, ast^, types^)
    spec.fns = fns^
    spec.clauses = clauses^
    spec.aliases = aliases^
    return spec^
