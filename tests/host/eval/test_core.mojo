from std.testing import assert_equal, assert_true, TestSuite

from eval.testkit import *
from wire.value import Value


def v(expr: String) raises -> String:
    return value_text("", expr, none_args())


def err(expr: String) raises -> String:
    return error_of("", expr, none_args())


def has(message: String, fragment: String) raises:
    assert_true(fragment in message, "'" + fragment + "' not in '" + message + "'")


def test_literals() raises:
    assert_equal(v("1"), "1")
    assert_equal(v("0xff"), "255")
    assert_equal(v("1_000"), "1000")
    assert_equal(v("123456789012345678901234567890"), "123456789012345678901234567890")
    assert_equal(v("1.5"), "1.5")
    assert_equal(v("0x1p-1"), "0.5")
    assert_equal(v("true"), "true")
    assert_equal(v("false"), "false")
    assert_equal(v('"hi"'), '"hi"')
    assert_equal(v("none"), "none")
    assert_equal(v("[1, 2, 3]"), "[1, 2, 3]")
    assert_equal(v("(1, true)"), "(1, true)")
    assert_equal(v("[]"), "[]")


def test_literal_unions_compare_with_strings() raises:
    var spec = spec_of(fragment('how: "any" | "all", hows: list<"any" | "all">', 'how == "any" and "any" in hows and hows == ["any", "all"] and how in ["any"] and "n" in how + "any"'))
    var host = Mock()
    var member = Value.enum("", "any")
    var hows = Value.list(two(Value.enum("", "any"), Value.enum("", "all")))
    assert_true(evaluate(spec, expr_node(spec), Env(two(member^, hows^)), host).as_bool())
    # A string works as well as a member.
    var hows2 = Value.list(two(Value.string("any"), Value.string("all")))
    assert_true(evaluate(spec, expr_node(spec), Env(two(Value.string("any"), hows2^)), host).as_bool())
    var other = Value.enum("", "all")
    var hows3 = Value.list(two(Value.enum("", "any"), Value.enum("", "all")))
    assert_true(not evaluate(spec, expr_node(spec), Env(two(other^, hows3^)), host).as_bool())


def test_set_literal_and_constructors_have_no_value() raises:
    var spec = spec_of("fn f(x: u8)\n  partition x\n    a = {1, 2}\n    b = u8.all - a\n  ensures e: true\n")
    var host = Mock()
    var node = spec.fns[0].partitions[0].classes[0].expr
    try:
        _ = evaluate(spec, node, Env(), host)
        assert_true(False, "expected an error")
    except e:
        has(String(e), "partition set")


def test_params_result_and_self() raises:
    assert_equal(value_text("a: int, b: int", "b", two(Value.int(1), Value.int(2))), "2")
    var spec = spec_of(fragment("a: int", "result + a", "int"))
    var host = Mock()
    var env = Env(one(Value.int(2)))
    env.set_result(Value.int(40))
    assert_equal(format_value(evaluate(spec, expr_node(spec), env, host)), "42")


def test_result_without_a_value_is_an_error() raises:
    var spec = spec_of(fragment("a: int", "result", "int"))
    var host = Mock()
    try:
        _ = evaluate(spec, expr_node(spec), Env(one(Value.int(2))), host)
        assert_true(False, "expected an error")
    except e:
        has(String(e), "no value for the result")


def test_let_shadowing_and_nesting() raises:
    assert_equal(v("let x = 1 in let y = x + 1 in x + y"), "3")
    assert_equal(v("let x = 1 in (let x = 5 in x) + x"), "6")
    assert_equal(v("let x = 2 in sum(x in [10, 20]: x) + x"), "32")
    assert_equal(v("(let x = 1 in x) + (let x = 2 in x)"), "3")


def test_enum_members_and_records() raises:
    var decls = "enum Color { Red, Green }\nrecord P { x: int, y: string }\n"
    var spec = spec_of(decls + fragment("c: Color, p: P", "c == Red and p.x == 3 and p.y == \"a\" and Color.Green != c", ""))
    var host = Mock()
    var rec = Value.record("P", ["x", "y"], two(Value.int(3), Value.string("a")))
    var args = two(Value.enum("Color", "Red"), rec^)
    assert_true(evaluate(spec, expr_node(spec), Env(args^), host).as_bool())


def test_boolean_operators() raises:
    assert_equal(v("true and false"), "false")
    assert_equal(v("true or false"), "true")
    assert_equal(v("false implies false"), "true")
    assert_equal(v("true implies false"), "false")
    assert_equal(v("not true"), "false")
    assert_equal(v("not (1 < 2) or 3 == 3"), "true")


def test_short_circuit_guards_errors() raises:
    assert_equal(v("false and 1 // 0 == 1"), "false")
    assert_equal(v("true or 1 // 0 == 1"), "true")
    assert_equal(v("false implies 1 // 0 == 1"), "true")
    assert_equal(v("if true then 1 else 1 // 0"), "1")
    assert_equal(v("if false then 1 // 0 else 2"), "2")
    assert_equal(v("let xs = [1, 2] in 5 < len(xs) implies xs[5] == 0"), "true")
    assert_equal(v("let xs = [1, 2] in 0 < len(xs) and xs[0] == 1"), "true")
    has(err("true and 1 // 0 == 1"), "division by zero")
    has(err("false or 1 // 0 == 1"), "division by zero")
    has(err("true implies 1 // 0 == 1"), "division by zero")


def test_quantifiers_short_circuit_left_to_right() raises:
    assert_equal(v("all(x in [1, 0, 2]: x != 0 implies 10 // x > 0)"), "true")
    assert_equal(v("exists(x in [1, 2, 0]: x == 1 or 10 // x > 0)"), "true")
    has(err("all(x in [0]: 10 // x > 0)"), "division by zero")
    assert_equal(v("all(x in [1, 2]: x > 5 implies 1 // 0 == 0)"), "true")
    assert_equal(v("all(x in [3, 1]: x > 2)"), "false")


def test_comparisons() raises:
    assert_equal(v("1 < 2"), "true")
    assert_equal(v("2 <= 2"), "true")
    assert_equal(v("3 > 4"), "false")
    assert_equal(v("3 >= 3"), "true")
    assert_equal(v("1 < 1.5"), "true")
    assert_equal(v("0.5 < 1"), "true")
    assert_equal(v('"a" < "b"'), "true")
    assert_equal(v('"ab" < "a"'), "false")
    assert_equal(v("[1, 2] < [1, 3]"), "true")
    assert_equal(v("[1] < [1, 0]"), "true")
    assert_equal(v("(1, 2) < (1, 2)"), "false")
    assert_equal(v("false < true"), "true")
    assert_equal(value_text("a: bytes, b: bytes", "a < b", two(bytes_of("a"), bytes_of("b"))), "true")
    assert_equal(value_text("a: bytes, b: bytes", "a < b", two(bytes_of("ab"), bytes_of("a"))), "false")
    # By code point, not UTF-16 code unit.
    assert_equal(v('"\\u{10000}" > "\\u{e000}"'), "true")


def test_equality_is_structural() raises:
    assert_equal(v("[1, 2] == [1, 2]"), "true")
    assert_equal(v("[1, 2] != [2, 1]"), "true")
    assert_equal(v("(1, [2]) == (1, [2])"), "true")
    assert_equal(v("some(1) == some(1)"), "true")
    assert_equal(value_text("a: option<int>", "a == none", one(Value.none())), "true")
    assert_equal(value_text("a: option<int>", "a == some(1)", one(Value.some(Value.int(1)))), "true")
    assert_equal(v('"a" == "a"'), "true")
    assert_equal(v("1 == 1.0"), "true")
    assert_equal(v("0.5 == 1 / 2"), "true")
    assert_equal(v("[1, 0.5] == [1.0, 0.5]"), "true")
    assert_equal(v("true == (1 == 1)"), "true")


def test_map_equality_ignores_order() raises:
    var m1 = Value.map(two(Value.int(1), Value.int(2)), two(Value.string("a"), Value.string("b")))
    var m2 = Value.map(two(Value.int(2), Value.int(1)), two(Value.string("b"), Value.string("a")))
    var args = two(m1^, m2^)
    assert_equal(value_text("a: map<int, string>, b: map<int, string>", "a == b", args^), "true")


def test_membership() raises:
    assert_equal(v("2 in [1, 2, 3]"), "true")
    assert_equal(v("4 in [1, 2, 3]"), "false")
    assert_equal(v("2 in [1.0, 2.0]"), "true")
    assert_equal(v('"ell" in "hello"'), "true")
    assert_equal(v('"xyz" in "hello"'), "false")
    assert_equal(v('"" in "hello"'), "true")
    var m = Value.map(two(Value.string("k"), Value.string("j")), two(Value.int(1), Value.int(2)))
    assert_equal(value_text("m: map<string, int>", '"k" in m', one(m.copy())), "true")
    assert_equal(value_text("m: map<string, int>", '"z" in m', one(m.copy())), "false")


def test_concatenation() raises:
    assert_equal(v("[1] + [2, 3]"), "[1, 2, 3]")
    assert_equal(v("[] + []"), "[]")
    assert_equal(v('"ab" + "cd"'), '"abcd"')
    assert_equal(value_text("a: bytes, b: bytes", "a + b", two(bytes_of("a"), bytes_of("b"))), 'b"ab"')
    assert_equal(v("[1] + [2.5]"), "[1, 2.5]")


def test_index() raises:
    assert_equal(v("[10, 20, 30][1]"), "20")
    assert_equal(v('"héllo"[1]'), '"é"')
    assert_equal(value_text("b: bytes", "b[2]", one(bytes_of("abc"))), "99")
    assert_equal(v("[10, 20][1 - 1]"), "10")
    has(err("[1, 2][2]"), "index 2 is out of range for a list of length 2")
    has(err("[1, 2][-1]"), "index -1 is out of range")
    has(err('"ab"[5]'), "out of range for a string of length 2")
    has(error_of("b: bytes", "b[2]", one(bytes_of("ab"))), "out of range for bytes of length 2")
    has(err("[1][99999999999999999999]"), "out of range")


def test_map_lookup() raises:
    var m = Value.map(two(Value.int(1), Value.int(5)), two(Value.string("a"), Value.string("b")))
    assert_equal(value_text("m: map<int, string>", "m[5]", one(m.copy())), '"b"')
    has(error_of("m: map<int, string>", "m[7]", one(m.copy())), "key 7 is not in the map")
    # A bool is not an int.
    var mb = Value.map(one(Value.bool(True)), one(Value.int(1)))
    has(error_of("m: map<bool, int>", "m[true] + m[false]", one(mb^)), "key false is not in the map")


def test_slices() raises:
    assert_equal(v("[1, 2, 3, 4][1:3]"), "[2, 3]")
    assert_equal(v("[1, 2][0:0]"), "[]")
    assert_equal(v('"héllo"[1:3]'), '"él"')
    assert_equal(value_text("b: bytes", "b[1:3]", one(bytes_of("abcd"))), 'b"bc"')
    assert_equal(v("[1, 2, 3][3:3]"), "[]")
    has(err("[1, 2][1:3]"), "out of range")
    has(err("[1, 2][2:1]"), "out of range")
    has(err("[1, 2][-1:1]"), "out of range")


def test_tuple_index() raises:
    assert_equal(v("(5, true).0"), "5")
    assert_equal(v("(5, true).1"), "true")


def test_if_and_let_as_operands() raises:
    assert_equal(v("(if 1 < 2 then 10 else 20) + 1"), "11")
    assert_equal(v("1 + (let x = 2 in x * 3)"), "7")
    assert_equal(v("if 1 < 2 then 1 else 2.5"), "1")
    assert_equal(v("if 2 < 1 then 1 else 2.5"), "2.5")


def test_comprehensions() raises:
    assert_equal(v("all(x in [1, 2, 3]: x > 0)"), "true")
    assert_equal(v("exists(x in [1, 2, 3]: x > 2)"), "true")
    assert_equal(v("exists(x in [1, 2, 3]: x > 3)"), "false")
    assert_equal(v("count(x in [1, 2, 3, 4]: x % 2 == 0)"), "2")
    assert_equal(v("sum(x in [1, 2, 3]: x * x)"), "14")
    assert_equal(v("max(x in [1, 5, 3]: x)"), "5")
    assert_equal(v("map(x in [1, 2, 3]: x * 2)"), "[2, 4, 6]")
    assert_equal(v("filter(x in [1, 2, 3, 4]: x > 2)"), "[3, 4]")
    assert_equal(v("sum(x in [1.5, 2.5]: x)"), "4")
    assert_equal(v("sum(x in [1, 2]: x / 2)"), "1.5")


def test_comprehension_over_strings_bytes_maps_and_ranges() raises:
    assert_equal(v('map(c in "aé": c)'), '["a", "é"]')
    assert_equal(value_text("b: bytes", "sum(x in b: x)", one(Value.bytes([1, 2]))), "3")
    assert_equal(v("sum(i in range(0, 5): i)"), "10")
    assert_equal(v("count(i in range(2, 2): true)"), "0")
    assert_equal(v("all(i in range(0, 3): all(j in range(i, 3): j >= i))"), "true")
    var m = Value.map(two(Value.int(1), Value.int(2)), two(Value.int(5), Value.int(6)))
    assert_equal(value_text("m: map<int, int>", "sum(k in m: k)", one(m^)), "3")


def test_empty_comprehensions() raises:
    assert_equal(value_text("xs: list<int>", "all(x in xs: x > 0)", one(ints())), "true")
    assert_equal(value_text("xs: list<int>", "exists(x in xs: x > 0)", one(ints())), "false")
    assert_equal(value_text("xs: list<int>", "sum(x in xs: x)", one(ints())), "0")
    has(error_of("xs: list<int>", "max(x in xs: x)", one(ints())), "max(...) of no elements")


def test_errors_name_the_expression_and_location() raises:
    var m = err("1 + 2 // 0")
    has(m, "division by zero")
    has(m, "t.spec:")
    has(m, "(at ")
    has(m, "2 // 0")


def test_comprehension_body_must_be_bool() raises:
    var spec = spec_of(fragment("xs: list<int>", "all(x in xs: x > 0)"))
    var host = Mock()
    var body = spec.ast.kid(expr_node(spec), 1)
    # The body evaluated outside its comprehension has no value for x.
    try:
        _ = evaluate(spec, body, Env(one(ints(1))), host)
        assert_true(False, "expected an error")
    except e:
        has(String(e), "no value for the local x")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
