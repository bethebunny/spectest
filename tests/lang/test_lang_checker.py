import pytest

from spectest import ast
from spectest.lang import Resolution, Spec, check, parse
from spectest.lang.errors import SpecCheckError
from spectest.types import (
    BOOL,
    BYTES,
    INT,
    QERR,
    REAL,
    STRING,
    UNIT,
    EnumT,
    FixedIntT,
    FloatT,
    FnT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    RecordT,
    SetT,
    TupleT,
    TypeVarT,
)

F64 = FloatT("f64")
F32 = FloatT("f32")
I32 = FixedIntT(32, True)
I64 = FixedIntT(64, True)
U8 = FixedIntT(8, False)
U64 = FixedIntT(64, False)


def ok(body: str) -> Spec:
    return check(parse("spec t\n" + body, "t.spec"))


def errors(body: str) -> list[str]:
    with pytest.raises(SpecCheckError) as info:
        ok(body)
    return [d.message for d in info.value.diagnostics]


def fails(body: str, *fragments: str) -> list[str]:
    msgs = errors(body)
    for fragment in fragments:
        assert any(fragment in m for m in msgs), f"{fragment!r} not in {msgs}"
    return msgs


def clause(spec: Spec, cid: str) -> ast.Expr:
    expr = spec.clause_ids[cid].expr
    assert expr is not None
    return expr


def ty_of(body: str, expr: str, params: str = "") -> object:
    """Type of expr in an ensures clause of fn f(params) -> unit."""
    spec = ok(f"fn f({params})\n  ensures e: same({expr}, {expr})\n")
    call = clause(spec, "f.e")
    assert isinstance(call, ast.Call)
    return call.args[0].ty


def ensures_ty(params: str, expr: str, returns: str = "") -> object:
    arrow = f" -> {returns}" if returns else ""
    spec = ok(f"fn f({params}){arrow}\n  ensures e: let v = {expr} in true\n")
    let = clause(spec, "f.e")
    assert isinstance(let, ast.Let)
    return let.value.ty


def nodes(expr: ast.Node, kind: type) -> list:
    return [n for n in ast.walk(expr) if isinstance(n, kind)]


class TestArithmeticTyping:
    @pytest.mark.parametrize(
        ("params", "expr", "ty"),
        [
            ("a: i32, b: u8", "a + b", INT),
            ("a: i32", "a * 2 - 1", INT),
            ("a: i32", "a // 2", INT),
            ("a: i32", "a % 3", INT),
            ("a: i32", "a / 2", REAL),
            ("a: int, b: int", "a / b", REAL),
            ("x: f64", "x + 1", REAL),
            ("x: f64, y: f32", "x * y", REAL),
            ("x: f64", "-x", F64),
            ("x: f32", "- -x", F32),
            ("a: i8", "-a", INT),
            ("a: int", "-a", INT),
            ("x: f64", "real(x) - 1", REAL),
            ("", "1", INT),
            ("", "1.5", REAL),
            ("", "0x1p-26", REAL),
            ("", "-0x1p-26", REAL),
            ("xs: list<int>, ys: list<int>", "xs + ys", ListT(INT)),
            ("xs: list<u8>", "xs + [1]", ListT(INT)),
            ("s: string", 's + "x"', STRING),
            ("b: bytes", "b + b", BYTES),
            ('m: "a" | "b"', 'm + "c"', STRING),
            ("xs: list<int>", "xs + []", ListT(INT)),
        ],
    )
    def test_types(self, params: str, expr: str, ty: object):
        assert ensures_ty(params, expr) == ty

    def test_floor_division_needs_integers(self):
        fails("fn f(x: f64)\n  ensures x // 2 == 0\n", "// takes integers")
        fails("fn f(x: real)\n  ensures true\n", "real is clause-only")

    def test_mixed_operands(self):
        fails("fn f(s: string)\n  ensures s + 1 == s\n", "cannot apply + to string and int")
        fails(
            "fn f(xs: list<int>, ys: list<string>)\n  ensures len(xs + ys) == 0\n",
            "cannot concatenate list<int> and list<string>",
        )
        fails("fn f(b: bool)\n  ensures -b\n", "unary - needs a number")


class TestEqualityRule:
    def test_canonical_types_compare(self):
        spec = ok(
            "fn f(a: i32, b: u64, s: string, xs: list<option<u8>>, t: (int, string)) -> u64\n"
            '  ensures a == b and s != "x" and xs == [some(1), none] and t == (1, s)\n'
            "  ensures result == a\n"
            '  ensures a in [1, 2] and s in [s] and "a" in s\n'
        )
        assert spec.fns["f"].clauses[0].expr.ty == BOOL

    def test_float_equality_is_rejected_with_the_alternatives(self):
        (msg,) = fails("fn f(x: f64) -> f64\n  ensures result == x\n")
        for alt in ("same(a, b)", "ieee_eq(a, b)", "real(a) == real(b)", "eq(a, b"):
            assert alt in msg
        assert "f64" in msg

    @pytest.mark.parametrize(
        "expr",
        ["x != 1", "x == 0.5", "[x] == [x]", "some(x) == none", "(x, 1) == (x, 1)", "x in [x]"],
    )
    def test_floats_anywhere_in_the_operands(self, expr: str):
        fails(f"fn f(x: f64)\n  ensures {expr}\n", "floats have no implicit equality")

    def test_models_compare_through_observers(self):
        fails(
            "model M\n  observe n: int\nfn f(a: M, b: M)\n  ensures a == b\n",
            "handles",
            "eq(a, b, ...)",
        )
        ok("model M\n  observe n: int\nfn f(a: M, b: M)\n  ensures a.n == b.n\n")

    def test_type_parameters_need_eq(self):
        fails("fn f<T>(x: T, y: T)\n  ensures x == y\n", "declare it as T: Eq")
        ok("fn f<T: Eq>(x: T, y: T)\n  ensures x == y\n")
        ok("fn f<T: Ord>(x: T, y: T)\n  ensures x != y\n")

    def test_real_comparison_is_canonical(self):
        ok("fn f(x: f64, y: f64)\n  ensures is_finite(x) implies real(x) == real(y)\n")

    def test_incompatible_operands(self):
        fails("fn f(s: string, n: int)\n  ensures s == n\n", "cannot compare string with int")

    def test_unknown_types_cannot_decide(self):
        fails("fn f()\n  ensures [] == []\n", "cannot tell the type")
        ok("fn f(xs: list<int>)\n  ensures xs == [] or xs != []\n")

    def test_literal_union_compares_with_its_members(self):
        ok('fn f(how: "any" | "all")\n  ensures how == "any" or how != "all"\n')
        fails(
            'fn f(how: "any" | "all")\n  ensures how == "anyy"\n',
            '"anyy" is not one of "any" | "all"',
        )

    def test_none_unifies_with_any_option(self):
        ok("fn f(o: option<list<f64>>, p: option<u8>)\n  ensures is_none(o) and p != none\n")

    def test_in_on_maps_and_strings(self):
        ok('fn f(m: map<string, f64>, s: string)\n  ensures s in m and "ab" in s\n')
        fails("fn f(s: string)\n  ensures 1 in s\n", "looks for a substring")
        fails("fn f(n: int)\n  ensures 1 in n\n", "in needs a list, map or string")


class TestOrdering:
    def test_numbers_and_ordered_types(self):
        ok(
            "fn f(x: f64, n: u8, s: string, b: bytes, xs: list<int>, t: (int, string), "
            "flag: bool)\n"
            '  ensures -1 <= x and x < n and s < "z" and b >= b and xs <= [1] and '
            't > (0, "") and flag >= false\n'
        )

    def test_unordered_types(self):
        fails("fn f<T: Eq>(a: T, b: T)\n  ensures a < b\n", "declare it as T: Ord")
        fails("fn f(a: option<int>, b: option<int>)\n  ensures a < b\n", "no total order")
        fails("fn f(s: string)\n  ensures s < 1\n", "cannot compare string with int")
        fails("fn f(xs: list<f64>)\n  ensures xs < xs\n", "no total order")


class TestExpressions:
    def test_if_and_let(self):
        assert ensures_ty("c: bool, o: option<f64>, x: f64", "if c then some(x) else o") == OptionT(
            F64
        )
        assert ensures_ty("c: bool, a: u8, b: i64", "if c then a else b") == INT
        assert ensures_ty("c: bool, a: int", "if c then a else 0.5") == REAL
        fails(
            "fn f(c: bool, x: f64)\n  ensures if c then x else 0\n",
            "branches of if have different types: f64 and int",
        )
        fails(
            "fn f(c: int)\n  ensures if c then true else false\n", "condition of if must be a bool"
        )

    def test_let_scoping(self):
        spec = ok("fn f(x: int)\n  ensures e: let x = [x] in len(x) == 1\n")
        let = clause(spec, "f.e")
        inner = [n for n in nodes(let.body, ast.Name) if n.id == "x"]
        assert inner[0].ty == ListT(INT)
        assert spec.resolution[inner[0]] == Resolution("local", "x", let)
        fails("fn f()\n  ensures (let y = 1 in y == 1) and y == 1\n", "unknown name y")

    def test_comprehensions(self):
        assert ensures_ty("xs: list<u8>", "count(x in xs: x > 1)") == INT
        assert ensures_ty("xs: list<u8>", "sum(x in xs: x)") == INT
        assert ensures_ty("xs: list<f32>", "sum(x in xs: x)") == REAL
        assert ensures_ty("xs: list<u8>", "map(x in xs: [x])") == ListT(ListT(U8))
        assert ensures_ty("xs: list<u8>", "filter(x in xs: x > 1)") == ListT(U8)
        assert ensures_ty("s: string", "map(c in s: c)") == ListT(STRING)
        assert ensures_ty("b: bytes", "map(c in b: c)") == ListT(INT)
        assert ensures_ty("m: map<string, f64>", "map(k in m: k)") == ListT(STRING)
        assert ensures_ty("", "map(i in range(0, 3): i * 2)") == ListT(INT)
        fails("fn f(xs: list<int>)\n  ensures all(x in xs: x)\n", "body of all(...) must be a bool")
        fails("fn f(n: int)\n  ensures all(x in n: true)\n", "ranges over a list")
        fails("fn f(xs: list<string>)\n  ensures sum(x in xs: x) == 0\n", "adds numbers")

    def test_comprehension_variable_is_local(self):
        spec = ok("fn f(xs: list<int>)\n  ensures e: all(x in xs: x > 0)\n")
        comp = clause(spec, "f.e")
        (x,) = [n for n in nodes(comp, ast.Name) if n.id == "x"]
        assert spec.resolution[x] == Resolution("local", "x", comp)
        assert x.ty == INT

    def test_indexing_and_slicing(self):
        assert ensures_ty("xs: list<u8>", "xs[0]") == U8
        assert ensures_ty("s: string", "s[1]") == STRING
        assert ensures_ty("b: bytes", "b[1]") == INT
        assert ensures_ty("m: map<string, f64>", 'm["k"]') == F64
        assert ensures_ty("xs: list<u8>", "xs[1:len(xs)]") == ListT(U8)
        assert ensures_ty("s: string", "s[0:1]") == STRING
        assert ensures_ty("b: bytes", "b[0:1]") == BYTES
        assert ensures_ty("t: (int, string)", "t.1") == STRING
        fails("fn f(xs: list<int>)\n  ensures xs[0.5] == 0\n", "an index must be an integer")
        fails("fn f(t: (int, int))\n  ensures t[0] == 0\n", "selected with .0")
        fails("fn f(t: (int, int))\n  ensures t.2 == 0\n", "out of range")
        fails("fn f(n: int)\n  ensures n.0 == 0\n", "needs a tuple")
        fails("fn f(n: int)\n  ensures n[0] == 0\n", "cannot index a int")
        fails("fn f(m: map<f64, int>, x: f64)\n  ensures m[x] == 0\n", "map lookup")

    def test_list_literals(self):
        assert ensures_ty("a: u8", "[a, a]") == ListT(U8)
        assert ensures_ty("a: u8", "[a, 300]") == ListT(INT)
        assert ensures_ty("", "[[1], []]") == ListT(ListT(INT))
        fails('fn f()\n  ensures len([1, "a"]) == 2\n', "elements of a list have one type")

    def test_tuples(self):
        assert ensures_ty("x: f64", "(x, 1)") == TupleT((F64, INT))

    def test_logic_operands_are_bool(self):
        fails("fn f(n: int)\n  ensures n and true\n", "left operand of and must be a bool")
        fails("fn f(n: int)\n  ensures not n\n", "operand of not must be a bool")
        fails("fn f(n: int)\n  ensures n + 1\n", "the ensures clause must be a bool")

    def test_bitwise_operators_are_set_only(self):
        fails("fn f(a: bool, b: bool)\n  ensures a | b\n", "for booleans write or")
        fails("fn f(a: int, b: int)\n  ensures (a & b) == 0\n", "needs a set on both sides")

    def test_every_expression_gets_a_type(self):
        spec = ok(
            "model M\n  observe n: u8\n  observe at(i: int): f64\n"
            "fn f(m: M, xs: list<f64>) -> M\n"
            "  ensures a: let k = m.n in all(i in range(0, k): is_finite(m.at(i))) and "
            'eq(result, m, float="bits") and len(map(x in xs: real(x))) == k\n'
        )
        for node in ast.walk(spec.file):
            if isinstance(node, ast.Expr):
                assert node.ty is not None, node


RESOLUTION_SRC = (
    "error Boom\n"
    "enum Color { Red, Green }\n"
    "record Pt { x: int, y: f64 }\n"
    "model Frame\n"
    "  observe columns: list<string>\n"
    "  observe cell(i: u64, name: string): option<f64>\n"
    "  invariant uniq: distinct(columns) and len(columns) >= 0\n"
    '  invariant cells: all(i in range(0, 3): is_none(cell(i, "a")) or true)\n'
    "fn g(x: f64) -> f64\n"
    "fn f(x: f64, df: Frame, p: Pt, c: Color) -> f64\n"
    "  partition x\n"
    "    nan  = f64.nan\n"
    "    small = f64.range(-1, 1) & f64.finite - nan\n"
    "    rest = f64.all - nan - small\n"
    "  raises Boom when c == Red\n"
    "  ensures a: p.x == 1 and c != Color.Green and i32.max > 0 and same(f64.max, x)\n"
    '  ensures b: is_none(df.cell(0, "a")) and len(df.columns) == 0\n'
    "  ensures m: is_finite(x) implies real(result) <= mp.cos(x) + 1\n"
    "  ensures q: qe(result, cr.cos(x)) <= 1\n"
    "  ensures o: old(df.columns) == df.columns\n"
    "  relates r: same(g(-x), result)\n"
    "interface Q<T: Eq>\n"
    "  observe items: list<T>\n"
    "  invariant ok: len(items) >= 0 and len(self.items) >= 0\n"
    "  new empty() -> Q\n"
    "    ensures e: len(result.items) == 0\n"
    "  method push(self, x: T)\n"
    "    ensures p: self.items == old(self.items) + [x]\n"
)


@pytest.fixture(scope="module")
def spec() -> Spec:
    return ok(RESOLUTION_SRC)


class TestResolution:
    def res(self, spec: Spec, cid: str) -> list[tuple[str, str, Resolution]]:
        out = []
        for n in ast.walk(clause(spec, cid)):
            if n in spec.resolution:
                label = getattr(n, "id", None) or getattr(n, "attr", None) or type(n).__name__
                out.append((type(n).__name__, label, spec.resolution[n]))
        return out

    def test_params_fields_types_and_enums(self, spec: Spec):
        got = {(k, label): r for k, label, r in self.res(spec, "f.a")}
        assert got[("Attribute", "x")] == Resolution("record_field", "x", "Pt")
        assert got[("Name", "p")] == Resolution("param", "p", 2)
        assert got[("Name", "c")] == Resolution("param", "c", 3)
        assert got[("Attribute", "Green")] == Resolution("enum_member", "Green", "Color")
        assert got[("Attribute", "max")] in (
            Resolution("type_const", "max", FixedIntT(32, True)),
            Resolution("type_const", "max", F64),
        )
        consts = [r for k, label, r in self.res(spec, "f.a") if r.kind == "type_const"]
        assert set(consts) == {
            Resolution("type_const", "max", FixedIntT(32, True)),
            Resolution("type_const", "max", F64),
        }
        attrs = {n.attr: n.ty for n in nodes(clause(spec, "f.a"), ast.Attribute)}
        assert attrs["Green"] == EnumT("Color", ("Red", "Green"))

    def test_bare_enum_member_and_error(self, spec: Spec):
        raises = spec.fns["f"].clauses[0]
        assert spec.resolution[raises] == Resolution("error", "Boom")
        (red,) = [n for n in nodes(raises.expr, ast.Name) if n.id == "Red"]
        assert spec.resolution[red] == Resolution("enum_member", "Red", "Color")

    def test_observers_and_prelude(self, spec: Spec):
        got = self.res(spec, "f.b")
        kinds = {(k, label): r for k, label, r in got}
        assert kinds[("Call", "Call")] in (
            Resolution("prelude", "is_none"),
            Resolution("observer", "cell", "Frame"),
            Resolution("prelude", "len"),
        )
        calls = [r for k, label, r in got if k == "Call"]
        assert Resolution("observer", "cell", "Frame") in calls
        assert kinds[("Attribute", "columns")] == Resolution("observer", "columns", "Frame")
        assert kinds[("Attribute", "cell")] == Resolution("observer", "cell", "Frame")
        expr = clause(spec, "f.b")
        (cell,) = [
            n
            for n in nodes(expr, ast.Call)
            if isinstance(n.func, ast.Attribute) and n.func.attr == "cell"
        ]
        assert cell.ty == OptionT(F64)
        assert cell.func.ty == FnT((U64, STRING), OptionT(F64), ("i", "name"))

    def test_mp_and_result(self, spec: Spec):
        got = self.res(spec, "f.m")
        rs = [r for _, _, r in got]
        assert Resolution("prelude", "mp.cos") in rs
        assert Resolution("result", "result") in rs
        (mp,) = [
            n for n in nodes(clause(spec, "f.m"), ast.Call) if spec.resolution[n].name == "mp.cos"
        ]
        assert mp.ty == REAL
        assert spec.resolution[mp.func] == Resolution("prelude", "mp.cos")

    def test_qe_and_cr(self, spec: Spec):
        expr = clause(spec, "f.q")
        assert isinstance(expr, ast.Binary) and expr.ty == BOOL
        qe = expr.left
        assert isinstance(qe, ast.Call) and qe.ty == QERR
        assert spec.resolution[qe] == Resolution("prelude", "qe")
        cr = qe.args[1]
        assert isinstance(cr, ast.Call) and cr.ty == F64
        assert spec.resolution[cr] == spec.resolution[cr.func] == Resolution("prelude", "cr.cos")

    def test_old(self, spec: Spec):
        expr = clause(spec, "f.o")
        (old,) = [n for n in nodes(expr, ast.Call) if isinstance(n.func, ast.Name)]
        assert spec.resolution[old] == Resolution("old", "old")
        assert old.ty == ListT(STRING)

    def test_spec_fn_calls_in_relates(self, spec: Spec):
        expr = clause(spec, "f.r")
        (g,) = [n for n in nodes(expr, ast.Call) if getattr(n.func, "id", "") == "g"]
        assert spec.resolution[g] == Resolution("spec_fn", "g", spec.fns["g"])
        assert g.ty == F64
        assert g.args[0].ty == F64

    def test_partition_classes(self, spec: Spec):
        part = spec.fns["f"].partitions[0]
        nan, small, rest = part.classes
        assert all(c.expr.ty == SetT(F64) for c in part.classes)
        assert spec.resolution[nan.expr] == Resolution("type_const", "nan", F64)
        refs = [n for n in nodes(rest.expr, ast.Name) if n.id in ("nan", "small")]
        assert [spec.resolution[n] for n in refs] == [
            Resolution("class", "nan", nan), Resolution("class", "small", small),
        ]  # fmt: skip
        (rng,) = nodes(small.expr, ast.Call)
        assert spec.resolution[rng] == Resolution("set_ctor", "range", F64)
        assert spec.owner[part] is spec.fns["f"]
        assert spec.owner[nan] is spec.fns["f"]

    def test_invariant_fields(self, spec: Spec):
        got = self.res(spec, "Frame.uniq")
        assert ("Name", "columns", Resolution("field", "columns", "Frame")) in got
        cells = self.res(spec, "Frame.cells")
        assert ("Call", "Call", Resolution("field", "cell", "Frame")) in cells

    def test_interface_self_and_fields(self, spec: Spec):
        inv = self.res(spec, "Q.ok")
        assert ("Name", "items", Resolution("field", "items", "Q")) in inv
        assert ("Name", "self", Resolution("self", "self", "Q")) in inv
        push = self.res(spec, "Q.push.p")
        assert ("Name", "self", Resolution("self", "self", "Q")) in push
        assert ("Attribute", "items", Resolution("observer", "items", "Q")) in push
        e = self.res(spec, "Q.empty.e")
        assert ("Name", "result", Resolution("result", "result")) in e

    def test_every_name_call_and_attribute_is_resolved(self, spec: Spec):
        bases = {
            id(n.value)
            for n in ast.walk(spec.file)
            if isinstance(n, ast.Attribute)
            and spec.resolution.get(n, Resolution("", "")).kind
            in ("type_const", "set_ctor", "enum_member", "prelude")
        }
        for node in ast.walk(spec.file):
            if isinstance(node, (ast.Name, ast.Call, ast.Attribute)):
                assert node in spec.resolution or id(node) in bases, (node, node.span)


class TestDeclarationsAndSignatures:
    def test_spec_tables(self):
        spec = ok(
            "error E\nenum Color { Red }\nrecord R { a: int, b: list<f64> }\n"
            "type Row = list<option<f64>>\n"
            "model M<T>\n  observe items: list<T>\n  observe at(i: int): T\n"
            "interface Q<T: Ord>\n  observe items: list<T>\n  new empty() -> Q\n"
            "  new of(xs: list<T>) -> Q<T>\n  method pop(self) -> T\n  method clear(self)\n"
            "fn f<K: Eq>(m: M<K>, r: R, row: Row) -> option<K>\n"
            "fn g()\n"
        )
        assert spec.name == "t" and spec.path == "t.spec"
        assert spec.errors == {"E"}
        assert spec.enums == {"Color": EnumT("Color", ("Red",))}
        assert spec.records["R"] == RecordT("R", (("a", INT), ("b", ListT(F64))))
        assert spec.aliases == {"Row": ListT(OptionT(F64))}
        assert set(spec.models) == {"M"} and set(spec.interfaces) == {"Q"}
        assert set(spec.fns) == {"f", "g"}
        m, q = spec.models["M"], spec.interfaces["Q"]
        t = TypeVarT("T")
        t_ord = TypeVarT("T", "Ord")
        assert spec.tparams[m] == {"T": t}
        assert spec.signature[m.observers[0]] == FnT((), ListT(t), ())
        assert spec.signature[m.observers[1]] == FnT((INT,), t, ("i",))
        qt = ModelT("Q", (t_ord,), True)
        assert spec.signature[q.ctors[0]] == FnT((), qt, ())
        assert spec.signature[q.ctors[1]] == FnT((ListT(t_ord),), qt, ("xs",))
        assert spec.signature[q.methods[0]] == FnT((), t_ord, ())
        assert spec.signature[q.methods[1]] == FnT((), UNIT, ())
        k = TypeVarT("K", "Eq")
        assert spec.signature[spec.fns["f"]] == FnT(
            (ModelT("M", (k,)), spec.records["R"], ListT(OptionT(F64))),
            OptionT(k),
            ("m", "r", "row"),
        )
        assert spec.signature[spec.fns["g"]] == FnT((), UNIT, ())
        assert spec.tparams[spec.fns["f"]] == {"K": k}
        assert spec.decl_ids[q.methods[0]] == "Q.pop"
        assert spec.owner[q.methods[0]] is q
        assert spec.model_type("Q") == qt
        assert [o.name for o in spec.fields("M")] == ["items"]
        assert spec.resolve_type("list<(i64, Row)>") == ListT(TupleT((I64, ListT(OptionT(F64)))))
        assert spec.resolve_type("M<T>", {"T": t}) == ModelT("M", (t,))

    def test_hash(self):
        a = ok("fn f()\n")
        b = ok("fn f()\n")
        c = ok("fn g()\n")
        assert a.hash == b.hash != c.hash
        assert len(a.hash) == 64

    @pytest.mark.parametrize(
        ("body", "message"),
        [
            ("fn f(x: float)\n", "unknown type float (did you mean f64?)"),
            ("fn f(x: Nope)\n", "unknown type Nope"),
            ("fn f(x: list)\n", "list takes 1 type argument"),
            ("fn f(x: map<int>)\n", "map takes 2 type arguments"),
            ("fn f(x: f64<int>)\n", "f64 takes no type arguments"),
            ("model M<T>\nfn f(x: M)\n", "M takes 1 type argument(s): M<T>"),
            ("interface Q<T: Eq>\nfn f(q: Q<f64>)\n", "f64 does not satisfy T: Eq of Q"),
            ("model M<T: Ord>\nfn f<U: Eq>(m: M<U>)\n", "U does not satisfy T: Ord"),
            ("fn f<T: Num>(x: T)\n", "unknown bound Num"),
            ("fn f<T, T>(x: T)\n", "type parameter T is declared twice"),
            ("fn f(x: int, x: int)\n", "parameter x is declared twice"),
            ("fn f(result: int)\n", "result is reserved"),
            ("fn f()\nfn f()\n", "f is already declared at line 2"),
            ("fn f(x: int)\n  ensures x > 0\nfn f(x: int)\n  ensures x > 0\n", "already declared"),
            ("error f64\n", "f64 is a built-in type"),
            ("model old\n", "old is reserved"),
            ("type A = B\ntype B = A\n", "defined in terms of itself"),
            ("record R { r: R }\n", "record R contains itself"),
            ("record R { a: int, a: int }\n", "two fields named a"),
            ("enum E { A, A }\n", "lists a member twice"),
            ("fn f(x: set<f64>)\n", "set is not a type"),
            ("fn f(x: list<real>)\n", "real is clause-only"),
            ("interface Q\n  new e() -> int\n", "a constructor returns its interface"),
            ("interface Q\n  observe a: int\n  method a(self)\n", "already has a member named a"),
            ("fn f(x: (int, Nope))\n", "unknown type Nope"),
        ],
    )
    def test_declaration_errors(self, body: str, message: str):
        fails(body, message)

    @pytest.mark.parametrize(
        ("body", "message"),
        [
            ('fn f(how: "any" | "all" = "anyy")\n', '"anyy" is not one of'),
            ("fn f(n: u8 = 300)\n", "300 is not a u8 value"),
            ("fn f(n: i8 = -129)\n", "-129 is not a i8 value"),
            ("fn f(x: f64 = 0.1)\n", "not exactly representable as f64"),
            ("fn f(x: f16 = 0x1p-25)\n", "not exactly representable as f16"),
            ('fn f(n: int = "a")\n', "the default of n must be a int"),
            ("fn f(n: int = m)\n", "unknown name m"),
        ],
    )
    def test_default_errors(self, body: str, message: str):
        fails(body, message)

    def test_good_defaults(self):
        ok(
            'fn f(how: "any" | "all" = "any", n: u8 = 255, k: i8 = -128, x: f64 = 0.5, '
            "y: f16 = 0x1p-24, z: f64 = -0x1p-1074, w: i32 = i32.max, o: option<u8> = none, "
            "xs: list<u8> = [1, 2])\n"
        )


class TestClauseIds:
    def test_ids(self):
        spec = ok(
            "error E\n"
            "model M\n  observe n: int\n  invariant pos: n >= 0\n  invariant n < 10\n"
            "fn f(x: int) -> int\n  requires x > 0\n  ensures big: result > x\n"
            "  raises E when x > 9\n  impl_defined order\n"
            "interface Q\n  observe n: int\n  invariant n >= 0\n"
            "  new make() -> Q\n    ensures z: result.n == 0\n"
            "  method inc(self)\n    modifies self\n    ensures up: self.n == old(self.n) + 1\n"
        )
        assert list(spec.clause_ids) == [
            "M.pos", "M#2", "f#1", "f.big", "f#3", "f#4", "Q#1", "Q.make.z", "Q.inc#1",
            "Q.inc.up",
        ]  # fmt: skip
        for cid, c in spec.clause_ids.items():
            assert c.id == cid

    def test_labels_are_unique_per_declaration(self):
        fails(
            "fn f(x: int)\n  ensures a: x > 0\n  ensures a: x > 1\n",
            "clause label a is already used in f (line 3)",
        )
        ok("fn f(x: int)\n  ensures a: x > 0\nfn g(x: int)\n  ensures a: x > 0\n")

    def test_labels_and_names_share_nothing(self):
        ok("fn f(x: int)\n  ensures len: x > 0\n  ensures x: len([x]) == 1\n")

    def test_type_clause_labels_cannot_take_a_member_id(self):
        iface = (
            "interface Q\n  observe n: int\n  invariant {label}: n >= 0\n"
            "  new make() -> Q\n  method inc(self)\n    modifies self\n"
        )
        for label, kind in (("make", "constructor"), ("inc", "method"), ("n", "observer")):
            fails(
                iface.format(label=label),
                f"clause label {label} gives the ID Q.{label}, which already names the "
                f"{kind} Q.{label}: rename the label (e.g. invariant {label}_holds:)",
            )
        fails(
            "model M\n  observe n: int\n  invariant n: n >= 0\n",
            "clause label n gives the ID M.n, which already names the observer M.n",
        )
        spec = ok(iface.format(label="positive"))
        assert list(spec.clause_ids) == ["Q.positive", "Q.inc#1"]
        ok("interface Q\n  observe n: int\n  new make() -> Q\n    ensures make: result.n == 0\n")


class TestClauseRules:
    def test_result_is_not_available_before_the_call(self):
        fails("fn f(x: int) -> int\n  requires result > 0\n", "result is not available in requires")
        fails(
            "error E\nfn f(x: int) -> int\n  raises E when result > 0\n",
            "result is not available in raises",
        )
        fails(
            "error E\nfn f(x: int) -> int\n  may_raise E when result > 0\n",
            "result is not available in may_raise",
        )

    def test_no_result_for_unit(self):
        fails("fn f(x: int)\n  ensures result == 1\n", "f returns nothing")
        fails(
            "interface Q\n  observe n: int\n  method m(self)\n    ensures result == 1\n",
            "Q.m returns nothing",
        )

    def test_old_needs_ensures_and_state(self):
        fails(
            "fn f(x: int) -> int\n  ensures result == old(x)\n",
            "old(...) needs state that the call can change, but f has no handle parameter",
        )
        fails(
            "model M\n  observe n: int\nfn f(m: M)\n  requires old(m.n) == 0\n",
            "old(...) is only allowed in ensures",
        )
        fails(
            "model M\n  observe n: int\nfn f(m: M) -> int\n  relates old(m.n) == result\n",
            "old(...) is only allowed in ensures",
        )
        fails(
            "model M\n  observe n: int\nfn f(m: M)\n  ensures old(old(m.n)) == 0\n",
            "cannot be nested",
        )
        fails(
            "model M\n  observe n: int\nfn f(m: M) -> int\n  ensures old(result) == 0\n",
            "result does not exist before the call",
        )
        fails(
            "model M\n  observe n: int\nfn f(m: M)\n  ensures old(m.n, 1) == 0\n",
            "old takes one expression",
        )
        ok("model M\n  observe n: int\nfn f(m: M) -> int\n  ensures result == old(m.n)\n")
        ok("model M\n  observe n: int\nfn f(ms: list<M>)\n  ensures len(old(ms)) == len(ms)\n")

    def test_old_in_interfaces(self):
        ok("interface Q\n  observe n: int\n  method m(self)\n    ensures self.n >= old(self.n)\n")
        fails(
            "interface Q\n  observe n: int\n  new e() -> Q\n    ensures old(1) == 1\n",
            "Q.e has no handle parameter or self",
        )
        fails(
            "interface Q\n  observe n: int\n  invariant old(n) == n\n",
            "old(...) is only allowed in ensures",
        )

    def test_spec_function_calls_only_in_relates(self):
        base = "fn g(x: int) -> int\n"
        ok(base + "fn f(x: int) -> int\n  relates g(x) == result\n")
        for kind in ("ensures", "requires"):
            fails(
                base + f"fn f(x: int) -> int\n  {kind} g(x) == 1\n",
                "calls the spec function g",
                "only allowed in relates",
            )
        fails(
            base + "fn f(xs: list<int>)\n  partition xs\n    a = g(1) == 1\n",
            "only allowed in relates",
        )
        fails(
            "model M\n  observe n: int\n  invariant g(n) == 1\n" + base, "only allowed in relates"
        )
        fails("fn len(x: int) -> int\n  ensures len([x]) == 1\n", "shadows the prelude function")

    def test_relates_arguments(self):
        base = 'fn g(x: i32, s: string = "a") -> i32\n'
        ok(base + 'fn f(x: i32) -> i32\n  relates g(x + 1) == result and g(x * 2, s="b") >= 0\n')
        ok(base + "fn f(x: i8) -> i32\n  relates g(-x) == result and g(x / 2) == 0\n")
        fails(
            base + 'fn f(x: i32) -> i32\n  relates g("a") == result\n',
            "argument x of g is a i32, but this is string",
        )
        fails(base + "fn f(x: i32) -> i32\n  relates g() == result\n", "g needs argument x")
        fails(
            base + 'fn f(x: i32) -> i32\n  relates g(1, "a", 2) == result\n',
            "g takes 2 argument(s)",
        )
        fails(
            base + 'fn f(x: i32) -> i32\n  relates g(1, t="a") == result\n',
            "g has no parameter named t",
        )
        fails(base + "fn f(x: i32) -> i32\n  relates g(1, x=2) == result\n", "given twice")

    def test_relates_float_arguments(self):
        base = "fn g(x: f32) -> f32\n"
        ok(base + "fn f(x: f32) -> f32\n  relates same(g(-x), result) and is_nan(g(0.5))\n")
        fails(
            base + "fn f(x: f32) -> f32\n  relates same(g(x), 1)\n",
            "same compares two values of one type",
        )

    def test_generic_spec_function_calls(self):
        base = "fn sort<T: Ord>(xs: list<T>) -> list<T>\n"
        spec = ok(base + "fn f<U: Ord>(xs: list<U>) -> list<U>\n  relates r: sort(xs) == result\n")
        (call,) = [n for n in nodes(clause(spec, "f.r"), ast.Call)]
        assert call.ty == ListT(TypeVarT("U", "Ord"))
        ok(base + "fn f(xs: list<i64>) -> list<i64>\n  relates sort(xs + [1]) == result\n")
        fails(
            base + "fn f(xs: list<f64>)\n  relates len(sort(xs)) == 0\n",
            "f64 does not satisfy T: Ord",
        )
        fails(
            base + "fn f<U: Eq>(xs: list<U>)\n  relates len(sort(xs)) == 0\n",
            "U does not satisfy T: Ord",
        )

    def test_invariants_see_fields_only(self):
        ok("model M\n  observe xs: list<int>\n  observe n: u64\n  invariant n == len(xs)\n")
        fails(
            "model M\n  observe n: int\n  invariant result == 1\n",
            "an invariant describes an object's state",
        )
        fails(
            "model M\n  observe n: int\n  observe at(i: int): int\n  invariant at == 1\n",
            "at takes arguments",
        )
        fails("model M\n  observe n: int\n  invariant m == 1\n", "unknown name m")
        fails("model M\n  observe n: int\n  invariant n\n", "an invariant must be a bool")
        fails("model M\n  observe n: int\n  invariant at(1) == 1\n", "unknown function at")

    def test_fields_are_not_bare_names_in_methods(self):
        fails(
            "interface Q\n  observe items: list<int>\n  method m(self)\n"
            "    ensures len(items) == 0\n",
            "did you mean self.items?",
        )
        fails(
            "model M\n  observe rows: list<int>\nfn f(df: M)\n  ensures len(rows) == 0\n",
            "did you mean df.rows?",
        )

    def test_self(self):
        fails("fn f()\n  ensures self == self\n", "self is only available in methods")
        fails(
            "interface Q\n  observe n: int\n  new e() -> Q\n    ensures self.n == 0\n",
            "a constructor has no self",
        )

    def test_modifies(self):
        model = "model M\n  observe n: int\n"
        ok(model + "fn f(m: M, k: M)\n  modifies m, k\n")
        ok("interface Q\n  observe n: int\n  method m(self)\n    modifies self\n")
        fails(
            model + "fn f(m: M, x: int)\n  modifies x\n",
            "modifies names handle parameters (models or interfaces) or self; x is a int",
        )
        fails(model + "fn f(m: M)\n  modifies q\n", "f has no parameter q")
        fails(model + "fn f(m: M)\n  modifies self\n", "self is only available in methods")
        fails(model + "fn f(m: M)\n  modifies m, m\n", "lists m twice")

    def test_errors_must_be_declared(self):
        fails("fn f(x: int)\n  raises Oops when x > 0\n", "unknown error Oops")
        fails("fn f(x: int)\n  may_raise Oops\n", "declare it with 'error Oops'")
        ok("error Oops\nfn f(x: int)\n  raises Oops when x > 0\n  may_raise Oops\n")

    def test_clause_placement(self):
        fails("fn f(x: int)\n  invariant x > 0\n", "invariant belongs to a model or interface")
        fails(
            "model M\n  observe n: int\n  requires n > 0\n",
            "requires belongs to a function, constructor or method, not to model M",
        )
        fails("interface Q\n  observe n: int\n  ensures n > 0\n", "not to interface Q")
        ok("model M\n  observe n: int\n  unspecified order\n  perf whatever\n")

    def test_freedoms_cannot_be_observed(self):
        frame = "model F\n  observe n: int\n  observe layout: int\n"
        fails(
            frame + "fn f(df: F) -> F\n  ensures not shares_memory(result, df)\n"
            "  unspecified shares_memory\n",
            "observes shares_memory, which f declares unspecified",
        )
        fails(
            frame + "fn f(df: F) -> F\n  ensures result.layout == 0\n  impl_defined layout\n",
            "observes layout",
        )
        fails(
            frame + "fn f(df: F)\n  unspecified a\n  impl_defined a\n",
            "a is already declared a freedom of f",
        )
        ok(frame + "fn f(df: F) -> F\n  ensures fresh(result)\n  unspecified shares_memory\n")

    def test_duplicate_declarations_report_once(self):
        msgs = errors("fn f(x: int)\n  ensures a: x > 0\nfn f(x: int)\n  ensures a: y > 0\n")
        assert msgs == ["f is already declared at line 2"]

    def test_all_errors_are_reported_together(self):
        msgs = errors(
            "fn f(x: f64) -> int\n  requires result > 0\n  ensures x == x\n  ensures nope\n"
        )
        assert len(msgs) == 3


class TestPartitions:
    def test_fixed_width_classes_are_sets(self):
        spec = ok(
            "fn f(x: i64, y: u8, b: bool, z: f32)\n"
            "  partition x\n"
            "    lo = i64.range(none, i32.min)\n"
            "    mid = i64.range(i32.min, i32.max + 1)\n"
            "    hi = i64.all - lo - mid\n"
            "  partition y\n"
            "    small = {0, 1, 2}\n"
            "    big = u8.all - small\n"
            "  partition b\n"
            "    t = {true}\n"
            "    f = bool.all - t\n"
            "  partition z\n"
            "    special = f32.nan | f32.inf | {0, f32.max, -f32.max}\n"
            '    pat = f32.pattern("0 11111111 0*")\n'
            "    other = f32.all - special - pat\n"
        )
        fn = spec.fns["f"]
        types = [[c.expr.ty for c in p.classes] for p in fn.partitions]
        assert types == [
            [SetT(I64)] * 3, [SetT(U8)] * 2, [SetT(BOOL)] * 2, [SetT(F32)] * 3,
        ]  # fmt: skip
        lo = fn.partitions[0].classes[0].expr
        assert isinstance(lo, ast.Call) and isinstance(lo.args[0], ast.NoneLit)
        assert lo.args[0].ty == OptionT(lo.args[0].ty.elem)

    def test_predicate_classes(self):
        spec = ok(
            "model M\n  observe n: int\n"
            "fn f(xs: list<int>, s: string, m: M)\n"
            "  partition xs\n"
            "    empty = len(xs) == 0\n"
            "    one = len(xs) == 1\n"
            "    more = not empty and not one\n"
            "  partition m\n"
            "    zero = m.n == 0\n"
            "    other = m.n != 0\n"
        )
        part = spec.fns["f"].partitions[0]
        more = part.classes[2].expr
        refs = [n for n in nodes(more, ast.Name)]
        assert [spec.resolution[n].kind for n in refs] == ["class", "class"]
        assert all(c.expr.ty == BOOL for c in part.classes)

    @pytest.mark.parametrize(
        ("body", "message"),
        [
            (
                "fn f(x: f64)\n  partition x\n    nan = is_nan(x)\n",
                "classes of the fixed-width parameter x are sets of values, so x cannot appear",
            ),
            ("fn f(x: f64)\n  partition x\n    a = x > 0\n", "x cannot appear in them"),
            (
                "fn f(x: i64)\n  partition x\n    a = i32.all\n",
                "class a of the i64 parameter x must be a set of i64 values",
            ),
            (
                "fn f(x: f64)\n  partition x\n    a = f32.nan | f64.nan\n",
                "cannot combine a set of f32 with a set of f64",
            ),
            ("fn f(x: f64)\n  partition x\n    a = 1\n", "must be a set of f64 values"),
            ("fn f(x: f64)\n  partition x\n    a = b\n    b = f64.nan\n", "unknown name b"),
            (
                "fn f(x: f64)\n  partition x\n    a = f64.nan\n    a = f64.inf\n",
                "already has a class named a",
            ),
            (
                "fn f(x: f64)\n  partition x\n    a = f64.all\n  partition x\n    b = f64.all\n",
                "x is already partitioned at line 3",
            ),
            ("fn f(x: f64)\n  partition y\n    a = f64.all\n", "f has no parameter y"),
            (
                "fn f(x: f64)\n  partition x\n    x = f64.all\n",
                "class x has the name of a parameter",
            ),
            ('fn f(x: f64)\n  partition x\n    a = {"s"}\n', "a member of a set of f64"),
            ("fn f(x: u8)\n  partition x\n    a = {0.5}\n", "a member of a set of u8"),
            ("fn f(x: f64)\n  partition x\n    a = f64.range(0)\n", "takes two bounds"),
            (
                'fn f(x: f64)\n  partition x\n    a = f64.range("a", none)\n',
                "a bound of f64.range must be a number or none",
            ),
            ("fn f(x: f64)\n  partition x\n    a = f64.pattern(1)\n", "takes one string literal"),
            ("fn f(x: f64)\n  partition x\n    a = f64.bogus\n", "f64 has no constant bogus"),
            ("fn f(x: f64)\n  partition x\n    a = f64.range\n", "f64.range is called"),
            ("fn f(x: i8)\n  partition x\n    a = i8.nan\n", "i8 has no constant nan"),
            ("fn f(x: bool)\n  partition x\n    a = bool.range(0, 1)\n", "bool has no range"),
            (
                "fn f(xs: list<int>, n: int)\n  partition xs\n    a = len(xs) == n\n",
                "a class of partition xs may only refer to xs, not to n",
            ),
            (
                "fn f(xs: list<int>)\n  partition xs\n    a = len(xs)\n",
                "class a (a predicate over xs) must be a bool",
            ),
            (
                "fn f(xs: list<int>)\n  partition xs\n    a = f64.nan\n",
                "f64.nan is a partition set",
            ),
            ("fn f(xs: list<int>)\n  partition xs\n    a = {1}\n", "{...} is a partition set"),
            (
                "interface Q\n  observe n: int\n  method m(self)\n    partition self\n      a = true\n",
                "self cannot be partitioned",
            ),
            (
                "fn f(x: f64) -> f64\n  partition x\n    a = f64.range(0, result)\n",
                "a partition class describes an input",
            ),
        ],
    )
    def test_partition_errors(self, body: str, message: str):
        fails(body, message)

    def test_sets_outside_partitions(self):
        fails(
            "fn f(x: f64)\n  requires x in f64.nan\n",
            "f64.nan is a partition set",
            "test the value with is_nan(x)",
        )
        fails(
            "fn f(x: f64)\n  ensures f64.range(0, 1) == f64.range(0, 1)\n",
            "f64.range(...) is a partition set",
        )


class TestPreludeTyping:
    @pytest.mark.parametrize(
        ("params", "expr", "ty"),
        [
            ("x: f16", "is_subnormal(x)", BOOL),
            ("x: bf16", "bits(x)", INT),
            ("x: f32", "next_up(x)", F32),
            ("x: f64", "next_down(x)", F64),
            ("x: f64", "ulp<f32>(real(x))", REAL),
            ("x: f64, y: f64", "qe(x, y)", QERR),
            ("x: f16", "qe<f16>(x, 0.5)", QERR),
            ("x: f16", "qe<f16>(1, real(x))", QERR),
            ("x: f64, y: f64", "steps(qe(x, y))", INT),
            ("x: f64, y: f64", "nans(qe(x, y)) + 1", INT),
            ("x: f64, y: f64", "qe(x, y) + qe(y, x)", QERR),
            ("x: bf16", "cr.exp(x)", FloatT("bf16")),
            ("x: f32", "cr.sqrt(cr.log(x))", F32),
            ("x: f64", "round<f32>(mp.exp(x))", F32),
            ("n: i64", "wrap<u8>(n * 3)", U8),
            ("n: i64", "fits<i32>(n)", BOOL),
            ("x: f64", "fits<f32>(x)", BOOL),
            ("r: f64", "fits<u8>(real(r) / 2)", BOOL),
            ("b: bytes", "le_uint(b)", INT),
            ("m: map<string, u8>", "keys(m)", ListT(STRING)),
            ("m: map<string, u8>", "values(m)", ListT(U8)),
            ("xs: list<string>", "sorted(xs)", ListT(STRING)),
            ("xs: list<string>", 'index_of(xs, "a")', INT),
            ("xs: list<u8>", "is_subsequence(xs, [1])", BOOL),
            ("x: u8", "some(x)", OptionT(U8)),
            ("o: option<list<u8>>", "unwrap(o)", ListT(U8)),
            ("b: bytes", "valid_utf8(b)", BOOL),
            ("xs: list<f64>", 'eq(xs, xs, float="nan_any", order="ignore")', BOOL),
            ("x: f64, y: f64", "ieee_eq(x, y)", BOOL),
            ("x: u8", "mp.atan(x)", REAL),
            ("x: f64, y: f64", "same(x, y)", BOOL),
        ],
    )
    def test_types(self, params: str, expr: str, ty: object):
        assert ensures_ty(params, expr) == ty

    @pytest.mark.parametrize(
        ("params", "expr", "message"),
        [
            ("n: int", "is_nan(n)", "is_nan takes a float, but argument 1 is int"),
            ("n: int", "bits(n)", "bits takes a float"),
            ("x: f64", "wrap<f64>(1)", "the type argument must be a fixed-width integer type"),
            ("x: f64", "round<i32>(x)", "the type argument must be a float type"),
            ("x: f64", "wrap(x)", "wrap needs a type argument"),
            ("x: f64", "wrap<i8>(x)", "wrap takes an integer, but argument 1 is f64"),
            ("x: f64", "wrap<i8, i16>(1)", "wrap takes 1 type argument(s)"),
            ("x: f64", "qe(x)", "qe takes 2 arguments"),
            ("x: f64", "qe(x, 1)", "qe compares two floats of one format, but argument 2 is int"),
            ("x: f64", "qe(x, mp.cos(x))", "round a real first"),
            ("x: f64, y: f32", "qe(x, y)", "but got f64 and f32"),
            ("x: f64", "qe<f32>(x, 1)", "qe<f32> compares f32 values, but argument 1 is f64"),
            ("x: f64", 'qe<f64>(x, "a")', "qe<f64> takes f64 values or numbers"),
            ("x: f64", "qe<i32>(x, x)", "the type argument must be a float type"),
            ("x: f64", "qe<f64, f64>(x, x)", "qe takes 1 type argument(s)"),
            ("x: f64", "steps(x)", "steps takes a qerr"),
            ("n: int", "nans(n)", "nans takes a qerr"),
            ("n: int", "cr.cos(n)", "cr.cos rounds in the format of its argument"),
            ("n: int", "cr.cos(n)", "for a real use mp.cos"),
            ("x: f64", "cr.cos(x, x)", "cr.cos takes 1 argument"),
            ("n: int", "len(n)", "len takes a list, string, bytes or map"),
            ("xs: list<f64>", "sorted(xs)", "sorted needs ordered elements"),
            ("xs: list<f64>", "is_sorted(xs)", "map them to real(x) first"),
            ("xs: list<f64>", "distinct(xs)", "distinct compares elements with =="),
            ("xs: list<f64>", "is_permutation(xs, xs)", "no canonical equality"),
            ("xs: list<int>, ys: list<string>", "is_permutation(xs, ys)", "two lists of one"),
            ("xs: list<string>", "index_of(xs, 1)", "index_of looks for a string"),
            ("x: f64", "eq([x], [x])", 'float="bits"'),
            ("x: f64", 'eq(x, x, float="exact")', 'float= must be one of "bits"'),
            ("x: f64", 'eq(x, x, float="bits", order="any")', "order= must be one of"),
            ("x: f64", 'eq(x, x, floats="bits")', "eq has no argument named floats"),
            ("x: f64", "same(x, 1)", "same compares two values of one type"),
            ("n: int", "fresh(n)", "fresh takes a model or interface handle"),
            ("x: f64", "range(0, x)", "range takes an integer"),
            ("s: string", "mp.cos(s)", "mp.cos takes a number"),
            ("n: int", "unwrap(n)", "unwrap takes an option"),
            ("n: int", "le_uint(n)", "le_uint takes bytes"),
            ("n: int", "len(n, n)", "len takes 1 argument"),
        ],
    )
    def test_errors(self, params: str, expr: str, message: str):
        fails(f"fn f({params})\n  ensures let v = {expr} in true\n", message)

    def test_eq_needs_float_mode_through_models(self):
        frame = "model F\n  observe rows: list<list<option<f64>>>\n"
        fails(frame + "fn f(a: F, b: F)\n  ensures eq(a, b)\n", "which contain floats")
        ok(frame + 'fn f(a: F, b: F)\n  ensures eq(a, b, float="bits")\n')
        ok("model G\n  observe n: int\nfn f(a: G, b: G)\n  ensures eq(a, b)\n")

    def test_identity_functions(self):
        ok(
            "model M\n  observe n: int\nfn f(a: M) -> M\n"
            "  ensures fresh(result) and not same_object(a, result) and "
            "not shares_memory(a, result)\n"
        )

    def test_unknown_functions_and_names(self):
        fails(
            "fn f(x: f64)\n  ensures cos(x) == 1\n",
            "unknown function cos (did you mean mp.cos or cr.cos?)",
        )
        fails("fn f(x: f64)\n  ensures mp.cosh(x) == 1\n", "unknown function mp.cosh: mp holds")
        fails("fn f(x: f64)\n  ensures cr.cosh(x) == 1\n", "unknown function cr.cosh: cr holds")
        fails("fn f(x: f64)\n  ensures mp.cos == 1\n", "mp.cos is a function: call it")
        fails("fn f(x: f64)\n  ensures same(cr.cos, x)\n", "cr.cos is a function: call it")
        fails("fn f(x: f64)\n  ensures cr\n", "cr is the namespace of the correctly rounded")
        fails("fn f(cr: f64)\n", "cr is reserved")
        fails("fn f(x: f64)\n  ensures x(1)\n", "x is a value, not a function")
        fails("fn f(x: f64)\n  ensures len\n", "len is a function")
        fails("fn f(x: f64)\n  ensures f64\n", "f64 is a type, not a value")
        fails("fn f(x: f64)\n  ensures nope\n", "unknown name nope")
        fails("fn f(x: f64)\n  ensures old\n", "old is called as old(e)")
        fails("fn f(x: f64)\n  ensures let result = 1 in true\n", "result is reserved")
        fails("fn f(x: f64)\n  ensures x.foo\n", "f64 has no field foo")
        fails("fn f(t: (int, int))\n  ensures t.a == 1\n", "tuple fields are numbered")
        fails(
            "model M\n  observe n: int\nfn f(m: M)\n  ensures m.q == 1\n",
            "M has no observer q (its observers: n)",
        )
        fails(
            "model M\n  observe n: int\nfn f(m: M)\n  ensures m.n(1) == 1\n",
            "n is a field of M and takes no arguments",
        )
        fails(
            "model M\n  observe at(i: int): int\nfn f(m: M)\n  ensures m.at == 1\n",
            "at takes arguments: at(i)",
        )
        fails(
            'model M\n  observe at(i: int): int\nfn f(m: M)\n  ensures m.at("a") == 1\n',
            "argument i of M.at is a int, but this is string",
        )
        fails("record R { a: int }\nfn f(r: R)\n  ensures r.b == 1\n", "record R has no field b")
        fails("enum E { A }\nfn f(e: E)\n  ensures e == E.B\n", "enum E has no member B")
        fails(
            "enum E { A }\nenum G { A }\nfn f(e: E)\n  ensures e == A\n",
            "A is a member of several enums",
        )

    def test_type_constants(self):
        assert ensures_ty("", "i32.max") == INT
        assert ensures_ty("", "u64.min") == INT
        assert ensures_ty("", "f64.max") == F64
        assert ensures_ty("", "-f16.min") == FloatT("f16")


class TestUnitAndLiterals:
    def test_literal_union_param(self):
        spec = ok('fn f(how: "any" | "all" = "any")\n  ensures how == "all" or true\n')
        assert spec.signature[spec.fns["f"]].params == (LiteralT(("any", "all")),)

    def test_maps_and_records(self):
        spec = ok(
            "record P { k: string, v: u8 }\nfn f(m: map<string, P>) -> u8\n"
            "  ensures e: all(k in keys(m): m[k].v <= 255) and result >= 0\n"
        )
        assert spec.signature[spec.fns["f"]].params == (MapT(STRING, spec.records["P"]),)
