from std.testing import assert_equal, TestSuite

from syntax_testkit import expr


def check(source: String, expected: String) raises:
    assert_equal(expr(source), expected)



def test_precedence_and_associativity() raises:
    check('a implies b implies c',
          '(binary implies (name "a") (binary implies (name "b") (name "c")))')
    check('a or b implies c',
          '(binary implies (binary or (name "a") (name "b")) (name "c"))')
    check('a or b and c',
          '(binary or (name "a") (binary and (name "b") (name "c")))')
    check('a and b or c',
          '(binary or (binary and (name "a") (name "b")) (name "c"))')
    check('not a and b',
          '(binary and (unary not (name "a")) (name "b"))')
    check('not a == b',
          '(unary not (binary == (name "a") (name "b")))')
    check('not not a',
          '(unary not (unary not (name "a")))')
    check('x in xs and y',
          '(binary and (binary in (name "x") (name "xs")) (name "y"))')
    check('a | b & c',
          '(binary | (name "a") (binary & (name "b") (name "c")))')
    check('a & b << c',
          '(binary & (name "a") (binary << (name "b") (name "c")))')
    check('a << b + c',
          '(binary << (name "a") (binary + (name "b") (name "c")))')
    check('a >> b >> c',
          '(binary >> (binary >> (name "a") (name "b")) (name "c"))')
    check('a << b << c',
          '(binary << (binary << (name "a") (name "b")) (name "c"))')
    check('a & b - c',
          '(binary & (name "a") (binary - (name "b") (name "c")))')
    check('a - b - c',
          '(binary - (binary - (name "a") (name "b")) (name "c"))')
    check('a + b * c',
          '(binary + (name "a") (binary * (name "b") (name "c")))')
    check('a / b // c % d',
          '(binary % (binary // (binary / (name "a") (name "b")) (name "c")) (name "d"))')
    check('-a * b',
          '(binary * (unary neg (name "a")) (name "b"))')
    check('- -a',
          '(unary neg (unary neg (name "a")))')
    check('-x ** 2',
          '(unary neg (binary ** (name "x") (num "2")))')
    check('2 ** -1',
          '(binary ** (num "2") (unary neg (num "1")))')
    check('a ** b ** c',
          '(binary ** (name "a") (binary ** (name "b") (name "c")))')
    check('a * b ** c',
          '(binary * (name "a") (binary ** (name "b") (name "c")))')
    check('x.y ** 2',
          '(binary ** (attr "y" (name "x")) (num "2"))')
    check('-x.y[0]',
          '(unary neg (index (attr "y" (name "x")) (num "0")))')
    check('f(x).y.0[i:j]',
          '(slice (tuple_index "0" (attr "y" (call (name "f") (typeargs) (arg (name "x"))))) (name "i") (name "j"))')
    check('(a + b) * c',
          '(binary * (binary + (name "a") (name "b")) (name "c"))')
    check('a <= b',
          '(binary <= (name "a") (name "b"))')
    check('a != b',
          '(binary != (name "a") (name "b"))')
    check('a >= b',
          '(binary >= (name "a") (name "b"))')


def test_let_and_if_reach_right() raises:
    check('let x = 1 in x + 1',
          '(let "x" (num "1") (binary + (name "x") (num "1")))')
    check('a implies let y = 1 in y',
          '(binary implies (name "a") (let "y" (num "1") (name "y")))')
    check('a and let y = 1 in y',
          '(binary and (name "a") (let "y" (num "1") (name "y")))')
    check('1 + if a then b else c',
          '(binary + (num "1") (if (name "a") (name "b") (name "c")))')
    check('if a then b else c + 1',
          '(if (name "a") (name "b") (binary + (name "c") (num "1")))')
    check('if a then b else if c then d else e',
          '(if (name "a") (name "b") (if (name "c") (name "d") (name "e")))')
    check('let x = a in b in c',
          '(let "x" (name "a") (binary in (name "b") (name "c")))')
    check('let x = (a in b) in x',
          '(let "x" (binary in (name "a") (name "b")) (name "x"))')
    check('let x = [y in z] in x',
          '(let "x" (list (binary in (name "y") (name "z"))) (name "x"))')


def test_comprehensions() raises:
    check('all(x in xs: x > 0)',
          '(comprehension all "x" (name "xs") (binary > (name "x") (num "0")))')
    check('exists(x in xs: x > 0)',
          '(comprehension exists "x" (name "xs") (binary > (name "x") (num "0")))')
    check('count(x in xs: x > 0)',
          '(comprehension count "x" (name "xs") (binary > (name "x") (num "0")))')
    check('sum(x in xs: x)',
          '(comprehension sum "x" (name "xs") (name "x"))')
    check('max(x in xs: x)',
          '(comprehension max "x" (name "xs") (name "x"))')
    check('map(x in xs: f(x))',
          '(comprehension map "x" (name "xs") (call (name "f") (typeargs) (arg (name "x"))))')
    check('filter(x in xs: x > 0)',
          '(comprehension filter "x" (name "xs") (binary > (name "x") (num "0")))')
    check('all(r in rows: len(r) == len(cols))',
          '(comprehension all "r" (name "rows") (binary == (call (name "len") (typeargs) (arg (name "r"))) (call (name "len") (typeargs) (arg (name "cols")))))')


def test_calls() raises:
    check('f()',
          '(call (name "f") (typeargs))')
    check('f(a, b)',
          '(call (name "f") (typeargs) (arg (name "a")) (arg (name "b")))')
    check('f(a, k=1)',
          '(call (name "f") (typeargs) (arg (name "a")) (arg "k" (num "1")))')
    check('eq(a, b, float="bits", order="ignore")',
          '(call (name "eq") (typeargs) (arg (name "a")) (arg (name "b")) (arg "float" (str "bits")) (arg "order" (str "ignore")))')
    check('wrap<u32>(x)',
          '(call (name "wrap") (typeargs (type "u32")) (arg (name "x")))')
    check('qe<f64>(a, b)',
          '(call (name "qe") (typeargs (type "f64")) (arg (name "a")) (arg (name "b")))')
    check('fits<i8, u8>(x)',
          '(call (name "fits") (typeargs (type "i8") (type "u8")) (arg (name "x")))')
    check('f(g(x))(y)',
          '(call (call (name "f") (typeargs) (arg (call (name "g") (typeargs) (arg (name "x"))))) (typeargs) (arg (name "y")))')
    check('bitpattern.codecs.int8',
          '(attr "int8" (attr "codecs" (name "bitpattern")))')
    check('bitpattern.IntSet.__contains__(s, x)',
          '(call (attr "__contains__" (attr "IntSet" (name "bitpattern"))) (typeargs) (arg (name "s")) (arg (name "x")))')
    check('p.0',
          '(tuple_index "0" (name "p"))')


def test_attributes_and_literals() raises:
    check('p.0.1',
          '(tuple_index "1" (tuple_index "0" (name "p")))')
    check('f64.all',
          '(attr "all" (name "f64"))')
    check('f64.all - nan',
          '(binary - (attr "all" (name "f64")) (name "nan"))')
    check('[1, 2.5, "s", true, false, none]',
          '(list (num "1") (num "2.5") (str "s") (bool true) (bool false) (none))')
    check('{1, 2}',
          '(set (num "1") (num "2"))')
    check('{}',
          '(set)')
    check('[]',
          '(list)')
    check('(1, 2)',
          '(tuple (num "1") (num "2"))')
    check('(1, 2, 3)',
          '(tuple (num "1") (num "2") (num "3"))')
    check('((1, 2), 3)',
          '(tuple (tuple (num "1") (num "2")) (num "3"))')
    check('xs[i]',
          '(index (name "xs") (name "i"))')
    check('xs[a:b]',
          '(slice (name "xs") (name "a") (name "b"))')
    check('xs[a + 1:b - 1][0]',
          '(index (slice (name "xs") (binary + (name "a") (num "1")) (binary - (name "b") (num "1"))) (num "0"))')
    check('0x1p-26 + 1_000',
          '(binary + (num "0x1p-26") (num "1_000"))')
    check('1e-3',
          '(num "1e-3")')
    check('0xff',
          '(num "0xff")')
    check('"a\\"b\\\\c"',
          '(str "a\\"b\\\\c")')
    check('"line\\nbreak\\t\\u{e9}\\x41"',
          '(str "line\\nbreak\\téA")')
    check('""',
          '(str)')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
