from fractions import Fraction

import pytest

from spectest import ast
from spectest.lang.errors import SpecSyntaxError
from spectest.lang.parser import parse, parse_expr, parse_type


def show(e: ast.Node) -> str:
    """A compact s-expression of an expression tree."""
    if isinstance(e, ast.Num):
        return e.text
    if isinstance(e, ast.Str):
        return repr(e.value)
    if isinstance(e, ast.BoolLit):
        return "true" if e.value else "false"
    if isinstance(e, ast.NoneLit):
        return "none"
    if isinstance(e, ast.Name):
        return e.id
    if isinstance(e, ast.Unary):
        return f"({e.op} {show(e.operand)})"
    if isinstance(e, ast.Binary):
        return f"({e.op} {show(e.left)} {show(e.right)})"
    if isinstance(e, ast.If):
        return f"(if {show(e.cond)} {show(e.then)} {show(e.else_)})"
    if isinstance(e, ast.Let):
        return f"(let {e.name} {show(e.value)} {show(e.body)})"
    if isinstance(e, ast.Comprehension):
        return f"({e.kind} {e.var} {show(e.iterable)} {show(e.body)})"
    if isinstance(e, ast.Call):
        parts = [show(e.func)]
        if e.type_args:
            parts[0] += "<" + ",".join(show(t) for t in e.type_args) + ">"
        parts += [show(a) for a in e.args] + [f"{k}={show(v)}" for k, v in e.kwargs]
        return "(call " + " ".join(parts) + ")"
    if isinstance(e, ast.Attribute):
        return f"{show(e.value)}.{e.attr}"
    if isinstance(e, ast.TupleIndex):
        return f"{show(e.value)}.{e.index}"
    if isinstance(e, ast.Index):
        return f"{show(e.value)}[{show(e.index)}]"
    if isinstance(e, ast.Slice):
        return f"{show(e.value)}[{show(e.start)}:{show(e.stop)}]"
    if isinstance(e, ast.ListLit):
        return "[" + " ".join(show(x) for x in e.elems) + "]"
    if isinstance(e, ast.SetLit):
        return "{" + " ".join(show(x) for x in e.elems) + "}"
    if isinstance(e, ast.TupleLit):
        return "(tuple " + " ".join(show(x) for x in e.elems) + ")"
    if isinstance(e, ast.TypeExpr):
        return e.name + ("<" + ",".join(show(a) for a in e.args) + ">" if e.args else "")
    if isinstance(e, ast.TupleTypeExpr):
        return "(" + ",".join(show(a) for a in e.elems) + ")"
    if isinstance(e, ast.LiteralTypeExpr):
        return "|".join(repr(v) for v in e.values)
    raise TypeError(e)


def p(source: str) -> str:
    return show(parse_expr(source))


def syntax_error(source: str) -> str:
    with pytest.raises(SpecSyntaxError) as info:
        parse(source, "t.spec")
    return str(info.value)


def expr_error(source: str) -> str:
    with pytest.raises(SpecSyntaxError) as info:
        parse_expr(source)
    return str(info.value)


class TestPrecedence:
    @pytest.mark.parametrize(
        ("source", "tree"),
        [
            ("a implies b implies c", "(implies a (implies b c))"),
            ("a or b implies c", "(implies (or a b) c)"),
            ("a or b and c", "(or a (and b c))"),
            ("not a and b", "(and (not a) b)"),
            ("not a == b", "(not (== a b))"),
            ("not not a", "(not (not a))"),
            ("a == b or c < d", "(or (== a b) (< c d))"),
            ("x in xs and y", "(and (in x xs) y)"),
            ("a | b & c", "(| a (& b c))"),
            ("a & b - c", "(& a (- b c))"),
            ("a + b * c", "(+ a (* b c))"),
            ("a - b - c", "(- (- a b) c)"),
            ("a / b // c % d", "(% (// (/ a b) c) d)"),
            ("-a * b", "(* (- a) b)"),
            ("- -a", "(- (- a))"),
            ("-x.y[0]", "(- x.y[0])"),
            ("f(x).y.0[i:j]", "(call f x).y.0[i:j]"),
            ("a <= b", "(<= a b)"),
            ("(a + b) * c", "(* (+ a b) c)"),
        ],
    )
    def test_trees(self, source: str, tree: str):
        assert p(source) == tree

    def test_comparisons_do_not_chain(self):
        assert "comparisons do not chain" in expr_error("a < b < c")
        assert "comparisons do not chain" in expr_error("a == b != c")


class TestLetAndIf:
    def test_let_body_extends_right(self):
        assert p("let y = f(x) in y > 0 and z") == "(let y (call f x) (and (> y 0) z))"

    def test_in_ends_the_let_value(self):
        assert p("let ys = xs + [x] in x in ys") == "(let ys (+ xs [x]) (in x ys))"

    def test_in_inside_brackets_in_a_let_value(self):
        assert p("let b = (x in xs) in b") == "(let b (in x xs) b)"
        assert p("let b = f(x in xs) in b") == "(let b (call f (in x xs)) b)"

    def test_nested_let(self):
        assert p("let a = let b = 1 in b in a") == "(let a (let b 1 b) a)"

    def test_let_after_implies(self):
        assert p("a implies let y = g(x) in b and y") == (
            "(implies a (let y (call g x) (and b y)))"
        )

    def test_if_then_else(self):
        assert p("if a then b else c or d") == "(if a b (or c d))"
        assert p("if x in xs then 1 else 2") == "(if (in x xs) 1 2)"
        assert p("(if a then b else c) + 1") == "(+ (if a b c) 1)"
        assert p("1 + if a then b else c") == "(+ 1 (if a b c))"

    def test_if_needs_else(self):
        assert "'else'" in expr_error("if a then b")


class TestAtoms:
    def test_literals(self):
        e = parse_expr('[1, 2.5, "s", true, false, none]')
        assert isinstance(e, ast.ListLit)
        num, real = e.elems[0], e.elems[1]
        assert isinstance(num, ast.Num) and num.value == 1 and num.text == "1"
        assert isinstance(real, ast.Num) and real.value == Fraction(5, 2)
        assert show(e) == "[1 2.5 's' true false none]"

    def test_hex_float_and_negation(self):
        e = parse_expr("-0x1p-26")
        assert isinstance(e, ast.Unary) and e.op == "-"
        assert isinstance(e.operand, ast.Num) and e.operand.value == Fraction(1, 2**26)

    def test_tuples_lists_sets(self):
        assert p("(a, b)") == "(tuple a b)"
        assert p("(a)") == "a"
        assert p("[]") == "[]"
        assert p("{1, -1}") == "{1 (- 1)}"
        assert p("{}") == "{}"

    def test_comprehensions(self):
        for kind in ("all", "exists", "count", "sum", "max", "map", "filter"):
            assert p(f"{kind}(x in xs: f(x))") == f"({kind} x xs (call f x))"
        assert p("all(r in rows: len(r) == len(cols))") == (
            "(all r rows (== (call len r) (call len cols)))"
        )

    def test_comprehension_names_are_plain_names_otherwise(self):
        assert p("count") == "count"
        assert p("sum(a, b)") == "(call sum a b)"
        assert p("max(a, b)") == "(call max a b)"
        assert p("i32.max + f64.max") == "(+ i32.max f64.max)"

    def test_comprehensions_over_sets(self):
        assert p("sum(v in f16.all: qe(f(v), cr.cos(v))) == 0") == (
            "(== (sum v f16.all (call qe (call f v) (call cr.cos v))) 0)"
        )
        assert p("max(v in f32.range(-1, 1) - f32.zero: g(v))") == (
            "(max v (- (call f32.range (- 1) 1) f32.zero) (call g v))"
        )

    def test_generic_prelude_calls(self):
        assert p("wrap<u32>(x)") == "(call wrap<u32> x)"
        assert p("round<f64>(mp.sqrt(x))") == "(call round<f64> (call mp.sqrt x))"
        assert p("not fits<i32>(x)") == "(not (call fits<i32> x))"
        assert p("ulp<f32>(r)") == "(call ulp<f32> r)"
        assert p("qe<f16>(x, 0.5) <= 1") == "(<= (call qe<f16> x 0.5) 1)"
        assert p("qe(x, y) < 1") == "(< (call qe x y) 1)"

    def test_other_names_before_less_than_compare(self):
        assert p("a < b") == "(< a b)"

    def test_generic_call_needs_arguments(self):
        assert "'(' and the arguments of wrap" in expr_error("wrap<u32> + 1")

    def test_keyword_arguments(self):
        assert p('eq(a, b, float="bits", order="ignore")') == (
            "(call eq a b float='bits' order='ignore')"
        )
        assert "positional arguments must come before" in expr_error("f(a=1, b)")
        assert "given twice" in expr_error("f(a=1, a=2)")

    def test_attributes_may_be_keywords(self):
        assert p("f64.all") == "f64.all"
        assert p("f64.range(none, 0)") == "(call f64.range none 0)"

    def test_tuple_index(self):
        assert p("p.0") == "p.0"
        assert p("p.0.1") == "p.0.1"
        assert "decimal index" in expr_error("p.0x1")

    def test_slices_take_both_bounds(self):
        assert p("xs[a:b]") == "xs[a:b]"
        assert "an expression" in expr_error("xs[:b]")

    def test_reserved_words_are_not_names(self):
        assert "expected an expression" in expr_error("then")


class TestTypes:
    @pytest.mark.parametrize(
        ("source", "tree"),
        [
            ("f64", "f64"),
            ("list<T>", "list<T>"),
            ("option<list<f64>>", "option<list<f64>>"),
            ("map<string, (int, bool)>", "map<string,(int,bool)>"),
            ("(K, V)", "(K,V)"),
            ('"any" | "all"', "'any'|'all'"),
            ("MutableList<T>", "MutableList<T>"),
            ("Deque", "Deque"),
        ],
    )
    def test_type_syntax(self, source: str, tree: str):
        assert show(parse_type(source)) == tree

    def test_one_element_tuple_type_is_an_error(self):
        with pytest.raises(SpecSyntaxError, match="at least two elements"):
            parse_type("(int)")

    def test_greater_equal_after_a_type_argument(self):
        f = parse("spec s\nfn f(x: option<u8>= none)\n")
        param = f.decls[0].params[0]
        assert show(param.type) == "option<u8>"
        assert isinstance(param.default, ast.NoneLit)


SPEC = """\
spec demo

use "other.spec"
error E1
enum Color { Red, Green }
record Pt { x: int, y: int }
type Row = list<option<f64>>

model Frame<T: Eq>
  observe columns: list<string>
  observe cell(i: u64, name: string): option<T>
  invariant unique: distinct(columns)
  unspecified layout

fn f<T: Ord, U>(x: f64, mode: "a" | "b" = "a") -> list<T>
  partition x
    nan = f64.nan
    rest = f64.all - nan
  requires mode == "a"
  ensures ok: is_finite(x) implies
    len(result) >= 0   # trailing comment
  raises E1 when x < 0
  may_raise E1
  may_raise lbl: E1 when is_nan(x)
  modifies a, b
  relates r: f(x) == result
  impl_defined payload
  perf p99 < 5us

interface Q<T>
  observe items: list<T>
  invariant len(items) >= 0
  new empty() -> Q
    ensures len(result.items) == 0
  method push(self, x: T)
    modifies self
  method pop(self) -> T

fn g()
"""


class TestDeclarations:
    def test_file_structure(self):
        f = parse(SPEC, "demo.spec")
        assert f.name == "demo" and f.path == "demo.spec" and f.source == SPEC
        kinds = [type(d).__name__ for d in f.decls]
        assert kinds == [
            "UseDecl", "ErrorDecl", "EnumDecl", "RecordDecl", "AliasDecl",
            "ModelDecl", "FnDecl", "InterfaceDecl", "FnDecl",
        ]  # fmt: skip
        use, err, enum, rec, alias = f.decls[:5]
        assert use.path == "other.spec"
        assert err.name == "E1"
        assert enum.members == ["Red", "Green"]
        assert [(p.name, show(p.type)) for p in rec.fields] == [("x", "int"), ("y", "int")]
        assert show(alias.type) == "list<option<f64>>"

    def test_model(self):
        m = parse(SPEC).decls[5]
        assert isinstance(m, ast.ModelDecl)
        assert [(t.name, t.bound) for t in m.tparams] == [("T", "Eq")]
        assert [o.name for o in m.observers] == ["columns", "cell"]
        assert [p.name for p in m.observers[1].params] == ["i", "name"]
        assert show(m.observers[1].type) == "option<T>"
        assert [(c.kind, c.label) for c in m.clauses] == [
            ("invariant", "unique"), ("unspecified", None),
        ]  # fmt: skip
        assert m.clauses[1].freedom == "layout"

    def test_function(self):
        fn = parse(SPEC).decls[6]
        assert isinstance(fn, ast.FnDecl)
        assert [(t.name, t.bound) for t in fn.tparams] == [("T", "Ord"), ("U", None)]
        assert [p.name for p in fn.params] == ["x", "mode"]
        assert show(fn.params[1].type) == "'a'|'b'"
        assert isinstance(fn.params[1].default, ast.Str)
        assert show(fn.returns) == "list<T>"
        (part,) = fn.partitions
        assert part.param == "x"
        assert [(c.name, show(c.expr)) for c in part.classes] == [
            ("nan", "f64.nan"), ("rest", "(- f64.all nan)"),
        ]  # fmt: skip
        got = [(c.kind, c.label, c.error, c.names, c.freedom) for c in fn.clauses]
        assert got == [
            ("requires", None, None, [], None),
            ("ensures", "ok", None, [], None),
            ("raises", None, "E1", [], None),
            ("may_raise", None, "E1", [], None),
            ("may_raise", "lbl", "E1", [], None),
            ("modifies", None, None, ["a", "b"], None),
            ("relates", "r", None, [], None),
            ("impl_defined", None, None, [], "payload"),
            ("perf", None, None, [], None),
        ]
        assert fn.clauses[3].expr is None
        assert show(fn.clauses[2].expr) == "(< x 0)"

    def test_clause_text_is_verbatim_and_normalized(self):
        fn = parse(SPEC).decls[6]
        texts = [c.text for c in fn.clauses]
        assert texts == [
            'requires mode == "a"',
            "ensures ok: is_finite(x) implies len(result) >= 0",
            "raises E1 when x < 0",
            "may_raise E1",
            "may_raise lbl: E1 when is_nan(x)",
            "modifies a, b",
            "relates r: f(x) == result",
            "impl_defined payload",
            "perf p99 < 5us",
        ]

    def test_clause_text_keeps_spacing_inside_strings_and_lines(self):
        f = parse('spec s\nfn f(s: string)\n  ensures s  ==   "a  b"\n')
        assert f.decls[0].clauses[0].text == 'ensures s == "a  b"'

    def test_interface(self):
        i = parse(SPEC).decls[7]
        assert isinstance(i, ast.InterfaceDecl)
        assert [o.name for o in i.observers] == ["items"]
        assert [c.name for c in i.ctors] == ["empty"]
        assert show(i.ctors[0].returns) == "Q"
        assert [m.name for m in i.methods] == ["push", "pop"]
        assert [p.name for p in i.methods[0].params] == ["x"]
        assert i.methods[0].returns is None
        assert show(i.methods[1].returns) == "T"
        assert [c.kind for c in i.methods[0].clauses] == ["modifies"]
        assert i.methods[0].clauses[0].names == ["self"]
        assert [c.kind for c in i.clauses] == ["invariant"]

    def test_fn_without_return_or_body(self):
        g = parse(SPEC).decls[8]
        assert g.returns is None and g.params == [] and g.clauses == []

    def test_spans(self):
        f = parse(SPEC)
        fn = f.decls[6]
        assert (fn.span.line, fn.span.col) == (15, 1)
        assert (fn.span.end_line, fn.span.end_col) == (28, 17)
        ensures = fn.clauses[1]
        assert (ensures.span.line, ensures.span.col) == (20, 3)
        assert (ensures.span.end_line, ensures.span.end_col) == (21, 21)
        cls = fn.partitions[0].classes[1]
        assert (cls.span.line, cls.span.col, cls.span.end_col) == (18, 5, 25)
        minus = cls.expr
        assert (minus.span.line, minus.span.col, minus.span.end_col) == (18, 12, 25)
        assert (f.decls[0].span.line, f.decls[0].span.col, f.decls[0].span.end_col) == (3, 1, 17)

    def test_every_node_has_a_span(self):
        f = parse(SPEC)
        for node in ast.walk(f):
            assert node.span.line > 0, node

    def test_paren_spans_cover_the_parentheses(self):
        e = parse_expr("(a + b) * c")
        assert (e.span.col, e.span.end_col) == (1, 12)
        assert isinstance(e, ast.Binary)
        assert (e.left.span.col, e.left.span.end_col) == (2, 7)

    def test_model_without_block(self):
        f = parse("spec s\nmodel M\nfn f()\n")
        assert f.decls[0].observers == [] and f.decls[0].clauses == []


class TestSyntaxErrors:
    @pytest.mark.parametrize(
        ("source", "message"),
        [
            ("fn f()\n", "expected 'spec <name>'"),
            ("spec s\nensures true\n", "must be indented under a declaration"),
            ("spec s\nfoo bar\n", "expected a declaration"),
            ("spec s\nfn f()\n  bogus x\n", "expected a clause"),
            ("spec s\nfn f(x int)\n", "expected ':' and the type of x"),
            ("spec s\nmodel M\n  fn f()\n", "expected 'observe' or a clause"),
            ("spec s\ninterface I\n  method m(x: int)\n", "expected 'self'"),
            ("spec s\ninterface I\n  new e()\n", "expected '->' and the interface name"),
            ("spec s\nfn f()\n  raises E\n", "expected 'when'"),
            ("spec s\nfn f()\n  partition x\n", "expected an indented list of classes"),
            ("spec s\nfn f()\n  partition x\n    a f64.nan\n", "expected '='"),
            ("spec s\nfn f()\n  ensures a b\n", "expected end of line, found 'b'"),
            ("spec s\nfn f()\n  ensures\n", "expected an expression, found end of line"),
            ("spec s\nuse other\n", "a file name in quotes"),
            ("spec s\nfn f(let: int)\n", "reserved word"),
            ("spec s\nenum E { A, }\n", "expected an enum member"),
            ("spec s\nfn f()\n  ensures let x = 1 x\n", "expected 'in'"),
        ],
    )
    def test_messages(self, source: str, message: str):
        assert message in syntax_error(source)

    def test_location_and_excerpt(self):
        text = syntax_error("spec s\nfn f()\n  ensures a b\n")
        assert text.startswith("t.spec:3:13: error: expected end of line, found 'b'")
        assert "   |             ^" in text


LAYOUT = """\
# leading comment

spec layout   # the name

interface Q<T: Eq>
  # comment inside the interface

  observe items: list<T>

  method put(self, x: T, n: u8)

    partition n   # a nested partition
      small = u8.range(0, 16)

      # between classes
      big = u8.all
        - small

    partition x
      first = len(self.items) == 0
    requires n <
             10
    ensures items: self.items ==
        old(self.items) +
      [x]

  method get(self) -> T
    ensures true
fn after(a: (int,
             int)) -> int
  ensures result == a.0 + a.1
"""


class TestLayoutRoundTrip:
    def test_structure(self):
        f = parse(LAYOUT)
        iface, after = f.decls
        assert [m.name for m in iface.methods] == ["put", "get"]
        put = iface.methods[0]
        assert [p.param for p in put.partitions] == ["n", "x"]
        assert [(c.name, show(c.expr)) for c in put.partitions[0].classes] == [
            ("small", "(call u8.range 0 16)"), ("big", "(- u8.all small)"),
        ]  # fmt: skip
        assert [c.text for c in put.clauses] == [
            "requires n < 10",
            "ensures items: self.items == old(self.items) + [x]",
        ]
        assert [c.text for c in iface.methods[1].clauses] == ["ensures true"]
        assert show(after.params[0].type) == "(int,int)"
        assert after.clauses[0].text == "ensures result == a.0 + a.1"

    def test_clause_text_reparses_to_the_same_tree(self):
        from pathlib import Path

        root = Path(__file__).resolve().parents[2]
        sources = [LAYOUT, SPEC] + [p.read_text() for p in sorted(root.glob("examples/*/*.spec"))]
        count = 0
        for source in sources:
            for node in ast.walk(parse(source)):
                if not isinstance(node, ast.Clause) or node.expr is None:
                    continue
                again = parse("spec r\nfn f()\n  " + node.text + "\n").decls[0].clauses[0]
                assert again.text == node.text
                assert show(again.expr) == show(node.expr), node.text
                assert (again.kind, again.label, again.error) == (node.kind, node.label, node.error)
                count += 1
        assert count > 60

    def test_numbers_round_trip_through_the_parser(self):
        for text in ("0", "255", "0xff", "1.5", "1e-3", "0x1p-26", "0x1.8p3", "0x1p-1074"):
            e = parse_expr(text)
            assert isinstance(e, ast.Num) and e.text == text
            assert parse_expr(e.text).value == e.value
