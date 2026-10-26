from std.testing import assert_equal, TestSuite

from syntax.testkit import decls, type_


def test_types() raises:
    assert_equal(type_('f64'),
                 '(type "f64")')
    assert_equal(type_('list<T>'),
                 '(type "list" (type "T"))')
    assert_equal(type_('option<list<f64>>'),
                 '(type "option" (type "list" (type "f64")))')
    assert_equal(type_('map<string, (int, bool)>'),
                 '(type "map" (type "string") (tuple_type (type "int") (type "bool")))')
    assert_equal(type_('(K, V)'),
                 '(tuple_type (type "K") (type "V"))')
    assert_equal(type_('"any" | "all"'),
                 '(choice_type (str "any") (str "all"))')
    assert_equal(type_('"a"'),
                 '(choice_type (str "a"))')
    assert_equal(type_('MutableList<T>'),
                 '(type "MutableList" (type "T"))')
    assert_equal(type_('bitpattern.Codec'),
                 '(type "bitpattern.Codec")')
    assert_equal(type_('bitpattern.Set<bitpattern.Item>'),
                 '(type "bitpattern.Set" (type "bitpattern.Item"))')
    assert_equal(type_('pkg.a | pkg.b'),
                 '(choice_type (qname "pkg.a") (qname "pkg.b"))')
    assert_equal(type_('"a" | pkg.b'),
                 '(choice_type (str "a") (qname "pkg.b"))')
    assert_equal(type_('list<list<int>>'),
                 '(type "list" (type "list" (type "int")))')
    assert_equal(type_('list<list<list<int>>>'),
                 '(type "list" (type "list" (type "list" (type "int"))))')
    assert_equal(type_('(int, (int, int))'),
                 '(tuple_type (type "int") (tuple_type (type "int") (type "int")))')


def test_use() raises:
    assert_equal(decls('use "other.spec"'),
                 '(use "other.spec")')


def test_prelude() raises:
    assert_equal(decls('prelude "bitpattern.prelude"'),
                 '(prelude "bitpattern.prelude")')


def test_error() raises:
    assert_equal(decls('error ValueError'),
                 '(error "ValueError")')


def test_error_qualified() raises:
    assert_equal(decls('error bitpattern.PatternError'),
                 '(error "bitpattern.PatternError")')


def test_const() raises:
    assert_equal(decls('const bitpattern.codecs.int8: bitpattern.Codec'),
                 '(const "bitpattern.codecs.int8" (type "bitpattern.Codec"))')


def test_const_one_part() raises:
    assert_equal(decls('const pi: f64'),
                 '(const "pi" (type "f64"))')


def test_enum() raises:
    assert_equal(decls('enum Color { Red, Green }'),
                 '(enum "Color" (name "Red") (name "Green"))')


def test_enum_lines() raises:
    assert_equal(decls('enum Color {\n  Red,\n  Green\n}'),
                 '(enum "Color" (name "Red") (name "Green"))')


def test_record() raises:
    assert_equal(decls('record P { x: int, y: int = 0 }'),
                 '(record "P" (param "x" (type "int") _) (param "y" (type "int") (num "0")))')


def test_alias() raises:
    assert_equal(decls('type Row = list<option<f64>>'),
                 '(alias "Row" (type "list" (type "option" (type "f64"))))')


def test_alias_continued() raises:
    assert_equal(decls('type Row =\n  list<f64>'),
                 '(alias "Row" (type "list" (type "f64")))')


def test_model_bare() raises:
    assert_equal(decls('model M'),
                 '(model "M" (tparams))')


def test_model_qualified() raises:
    assert_equal(decls('model bitpattern.IntSet'),
                 '(model "bitpattern.IntSet" (tparams))')


def test_model_tparams() raises:
    assert_equal(decls('model M<T, U: Ord>'),
                 '(model "M" (tparams (tparam "T") (tparam "U" (qname "Ord"))))')


def test_model_members() raises:
    assert_equal(decls('model bitpattern.IntSet\n  observe width: int\n  observe cell(i: int, name: string): option<T>\n  observe members: list<int> = builtins.list(self)\n  build bitpattern.IntSet(items: list<int>, width: int = 8)\n  build bitpattern.IntSet.range(lo: int, hi: int)\n  invariant ascending: is_sorted(members)\n  unspecified layout'),
                 '(model "bitpattern.IntSet" (tparams) (observe "width" _ (type "int") _) (observe "cell" (params (param "i" (type "int") _) (param "name" (type "string") _)) (type "option" (type "T")) _) (observe "members" _ (type "list" (type "int")) (call (attr "list" (name "builtins")) (typeargs) (arg (name "self")))) (build "bitpattern.IntSet" (params (param "items" (type "list" (type "int")) _) (param "width" (type "int") (num "8")))) (build "bitpattern.IntSet.range" (params (param "lo" (type "int") _) (param "hi" (type "int") _))) (clause invariant "ascending" (call (name "is_sorted") (typeargs) (arg (name "members")))) (clause unspecified (name "layout")))')


def test_model_comment_inside() raises:
    assert_equal(decls('model M\n  # about\n  observe a: int\n\n  invariant true'),
                 '(model "M" (tparams) (observe "a" _ (type "int") _) (clause invariant (bool true)))')


def test_fn_bare() raises:
    assert_equal(decls('fn f()'),
                 '(fn "f" (tparams) (params) _)')


def test_fn_typed() raises:
    assert_equal(decls('fn f(x: int, y: list<int> = []) -> bool'),
                 '(fn "f" (tparams) (params (param "x" (type "int") _) (param "y" (type "list" (type "int")) (list))) (type "bool"))')


def test_fn_qualified_with_self() raises:
    assert_equal(decls('fn bitpattern.IntSet.__or__(self, other: bitpattern.IntSet) -> bitpattern.IntSet'),
                 '(fn "bitpattern.IntSet.__or__" (tparams) (params (param "self" _ _) (param "other" (type "bitpattern.IntSet") _)) (type "bitpattern.IntSet"))')


def test_fn_tparams() raises:
    assert_equal(decls('fn first<T: Ord, U>(xs: list<T>) -> T'),
                 '(fn "first" (tparams (tparam "T" (qname "Ord")) (tparam "U")) (params (param "xs" (type "list" (type "T")) _)) (type "T"))')


def test_fn_clauses() raises:
    assert_equal(decls('fn f(x: int) -> int\n  requires x > 0\n  ensures r: result > x\n  relates q: x == x\n  invariant i: true\n  aggregate g: sum(y in ys: y) > 0\n  raises ValueError when x < 0\n  raises e: bitpattern.PatternError when x > 9\n  may_raise OverflowError\n  may_raise m: OverflowError when x > 99\n  modifies a, b\n  unspecified rounding\n  impl_defined payload'),
                 '(fn "f" (tparams) (params (param "x" (type "int") _)) (type "int") (clause requires (binary > (name "x") (num "0"))) (clause ensures "r" (binary > (name "result") (name "x"))) (clause relates "q" (binary == (name "x") (name "x"))) (clause invariant "i" (bool true)) (clause aggregate "g" (binary > (comprehension sum "y" (name "ys") (name "y")) (num "0"))) (clause raises (qname "ValueError") (binary < (name "x") (num "0"))) (clause raises "e" (qname "bitpattern.PatternError") (binary > (name "x") (num "9"))) (clause may_raise (qname "OverflowError") _) (clause may_raise "m" (qname "OverflowError") (binary > (name "x") (num "99"))) (clause modifies (name "a") (name "b")) (clause unspecified (name "rounding")) (clause impl_defined (name "payload")))')


def test_fn_perf() raises:
    assert_equal(decls('fn f()\n  perf O(n) time\n  ensures true'),
                 '(fn "f" (tparams) (params) _ (clause perf (str "O(n) time")) (clause ensures (bool true)))')


def test_fn_perf_continued() raises:
    assert_equal(decls('fn f()\n  perf O(n) time\n    and O(1) space\n  ensures true'),
                 '(fn "f" (tparams) (params) _ (clause perf (str "O(n) time and O(1) space")) (clause ensures (bool true)))')


def test_fn_perf_empty() raises:
    assert_equal(decls('fn f()\n  perf\n  ensures true'),
                 '(fn "f" (tparams) (params) _ (clause perf (str)) (clause ensures (bool true)))')


def test_fn_partition() raises:
    assert_equal(decls('fn f(x: int) -> int\n  partition x\n    small = range(0, 4)\n    rest = int - small\n  ensures true'),
                 '(fn "f" (tparams) (params (param "x" (type "int") _)) (type "int") (partition "x" (class "small" (call (name "range") (typeargs) (arg (num "0")) (arg (num "4")))) (class "rest" (binary - (name "int") (name "small")))) (clause ensures (bool true)))')


def test_clause_continued() raises:
    assert_equal(decls('fn f(x: int)\n  ensures x > 0 and\n    x < 9 and\n      x != 5\n  ensures true'),
                 '(fn "f" (tparams) (params (param "x" (type "int") _)) _ (clause ensures (binary and (binary and (binary > (name "x") (num "0")) (binary < (name "x") (num "9"))) (binary != (name "x") (num "5")))) (clause ensures (bool true)))')


def test_def() raises:
    assert_equal(decls('fn double(x: int) -> int = x * 2'),
                 '(def "double" (tparams) (params (param "x" (type "int") _)) (type "int") (binary * (name "x") (num "2")))')


def test_def_tparams() raises:
    assert_equal(decls('fn id<T>(x: T) -> T = x'),
                 '(def "id" (tparams (tparam "T")) (params (param "x" (type "T") _)) (type "T") (name "x"))')


def test_def_continued() raises:
    assert_equal(decls('fn clamp(x: int, lo: int, hi: int) -> int =\n  if x < lo then lo else if x > hi then hi else x'),
                 '(def "clamp" (tparams) (params (param "x" (type "int") _) (param "lo" (type "int") _) (param "hi" (type "int") _)) (type "int") (if (binary < (name "x") (name "lo")) (name "lo") (if (binary > (name "x") (name "hi")) (name "hi") (name "x"))))')


def test_def_without_is_a_spec_function() raises:
    assert_equal(decls('fn double(x: int) -> int'),
                 '(fn "double" (tparams) (params (param "x" (type "int") _)) (type "int"))')


def test_def_with_nested_generics() raises:
    assert_equal(decls('fn f(x: int) -> list<list<int>> = []'),
                 '(def "f" (tparams) (params (param "x" (type "int") _)) (type "list" (type "list" (type "int"))) (list))')


def test_interface_bare() raises:
    assert_equal(decls('interface Q'),
                 '(interface "Q" (tparams))')


def test_interface_members() raises:
    assert_equal(decls('interface bitpattern.Stack<T>\n  observe items: list<T>\n  new empty() -> bitpattern.Stack<T>\n  new of(xs: list<T>) -> bitpattern.Stack<T>\n    requires len(xs) > 0\n  method push(self, x: T)\n    ensures true\n  method pop(self) -> T\n    raises IndexError when false\n  invariant bounded: len(items) <= 10'),
                 '(interface "bitpattern.Stack" (tparams (tparam "T")) (observe "items" _ (type "list" (type "T")) _) (ctor "empty" (tparams) (params) (type "bitpattern.Stack" (type "T"))) (ctor "of" (tparams) (params (param "xs" (type "list" (type "T")) _)) (type "bitpattern.Stack" (type "T")) (clause requires (binary > (call (name "len") (typeargs) (arg (name "xs"))) (num "0")))) (method "push" (tparams) (params (param "self" _ _) (param "x" (type "T") _)) _ (clause ensures (bool true))) (method "pop" (tparams) (params (param "self" _ _)) (type "T") (clause raises (qname "IndexError") (bool false))) (clause invariant "bounded" (binary <= (call (name "len") (typeargs) (arg (name "items"))) (num "10"))))')


def test_two_decls() raises:
    assert_equal(decls('error A\nerror B'),
                 '(error "A")\n(error "B")')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
