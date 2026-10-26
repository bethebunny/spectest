# v2 syntax

v2's grammar is v1's (`docs/language.md`, Grammar) with the additions below, so every
v1 spec still parses. Where the design doc only sketched a form, the choice made here
is marked *provisional*: it is what the parser accepts until the language doc settles
it.

## Qualified names

```
QNAME = NAME { "." NAME } ;
```

A spec function, model, interface, error, constant or build target is named by its
qualified name: `fn bitpattern.IntSet.range(...)`, `model bitpattern.IntSet`,
`raises bitpattern.PatternError when ...`. A one-part name is still a QNAME, so v1's
`fn cos(...)` and `raises IndexError when ...` parse unchanged. Inside expressions a
qualified name is an attribute chain, `ATTR(ATTR(NAME bitpattern) codecs) int8`; the
checker resolves it.

## Declarations

```
decl      = "use" STRING | "prelude" STRING | "error" QNAME | const | enum | record
          | alias | model | interface | fn | def ;
const     = "const" QNAME ":" type ;                               (provisional)
model     = "model" QNAME [ tparams ] [ INDENT { observe | build | clause } DEDENT ] ;
build     = "build" QNAME params ;
interface = "interface" QNAME [ tparams ] [ INDENT { observe | ctor | method | clause } DEDENT ] ;
fn        = "fn" QNAME [ tparams ] params [ "->" type ] [ INDENT body DEDENT ] ;
def       = "fn" NAME [ tparams ] params "->" type "=" expr ;
observe   = "observe" NAME [ params ] ":" type [ "=" expr ] ;
params    = "(" [ param { "," param } ] ")" ;
param     = "self" | NAME ":" type [ "=" expr ] ;
clause    = ( "requires" | "ensures" | "relates" | "invariant" | "aggregate" ) [ NAME ":" ] expr
          | "raises" [ NAME ":" ] QNAME "when" expr
          | "may_raise" [ NAME ":" ] QNAME [ "when" expr ]
          | "modifies" NAME { "," NAME } | ( "unspecified" | "impl_defined" ) NAME
          | "perf" LINE ;
```

- `prelude "bitpattern.prelude"` attaches a user prelude, a file of definitions kept
  next to the spec.
- `const` declares a library constant and its type, so clauses and types can name it:
  `const bitpattern.codecs.int8: bitpattern.Codec`. *(provisional)*
- `build` lists a call that makes values of the model; the generator picks one and
  generates its arguments.
- An observer may give the expression that reads it: `observe members: list<int> =
  builtins.list(self)`.
- `self` as a parameter takes no type: in a method it is the receiver, and in a
  qualified `fn` such as `fn bitpattern.IntSet.__or__(self, other: bitpattern.IntSet)`
  it is the receiver, of the model the name's prefix names.
- A `def` is a single-expression definition: `fn` with a one-part name, a return type,
  `=` and an expression on the same logical line. The `=` after the return type is
  what tells it from a spec function. *(The design doc puts definitions in user
  preludes; the parser accepts them in spec files too, and the checker decides where
  they are allowed.)*

## User prelude files

```
prelude_file = { "use" STRING | def } ;
```

A user prelude has no `spec` header: just definitions, and `use` of other preludes.
*(provisional)*

## Types

```
type   = QNAME [ "<" type { "," type } ">" ] | "(" type "," type { "," type } ")" | choice ;
choice = alt "|" alt { "|" alt } | STRING ;
alt    = STRING | QNAME ;
```

A choice of library constants, `bitpattern.codecs.int8 | bitpattern.codecs.uint16`,
joins v1's string-literal unions. An alternative that is a QNAME takes no type
arguments.

## Expressions

Two additions to v1's operators:

- `**` on integers, right-associative and binding tighter than unary minus on its
  left: `-x ** 2` is `-(x ** 2)`, and `2 ** -1` is an error the checker reports.
  `unary = "-" unary | let | if | power ; power = post [ "**" unary ] ;`
- `<<` and `>>` on integers, between `&` and `+ -`:
  `inter = shift { "&" shift } ; shift = sum { ( "<<" | ">>" ) sum } ;`
  *(provisional: the design doc lists `&` and `>>` on ints as possible)*

Calls to library functions in clauses need no new syntax: `bitpattern.IntSet.__contains__(s, x)`
is a call whose callee is an attribute chain.

## Choices the parser makes where the language doc is silent

- A `def` may continue on deeper-indented lines after `=`, like any clause.
- Generic calls keep v1's rule: only `wrap`, `fits`, `round`, `ulp` and `qe` followed
  by `<` start type arguments, so a qualified `mp.round<f64>(x)` is a comparison.
- A `perf` clause keeps its text, continuation lines joined by a space.
- Names are ASCII, as in v1.
