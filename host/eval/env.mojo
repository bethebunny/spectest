"""The values a clause sees, and the state of one evaluation."""

from wire.value import Value


@fieldwise_init
struct Failure(Copyable):
    """Why an evaluation has no value."""

    var message: String
    var node: Int
    """The node the failure is attributed to."""
    var skipped: Bool
    """Whether it skips the clause (a planned call raised in the library) rather than
    being an error."""


@fieldwise_init
struct Old(Copyable):
    """What `old(...)` saw before the call: its value, or why it has none."""

    var value: Value
    var failure: Optional[Failure]


struct Env(Movable):
    """The values a clause is evaluated against.

    `params` holds the parameters by position; for a function with a receiver
    `params[0]` is `self`. `self_value` answers `self` where there is no such
    parameter (a model's own clauses and observers); without it `self` reads
    `params[0]`. `olds` maps the node of each `old(...)` call to what it saw before the
    call. `types` instantiates a generic function's type parameters.
    """

    var params: List[Value]
    var result: Optional[Value]
    var self_value: Optional[Value]
    var olds: Dict[Int, Old]
    var types: Dict[String, Int]

    def __init__(out self, var params: List[Value] = []):
        self.params = params^
        self.result = None
        self.self_value = None
        self.olds = {}
        self.types = {}

    def set_result(mut self, var value: Value):
        self.result = value^

    def set_self(mut self, var value: Value):
        self.self_value = value^

    def bind_type(mut self, var name: String, type: Int):
        self.types[name^] = type


@fieldwise_init
struct Local(Copyable):
    var node: Int
    """The LET or COMPREHENSION that binds it."""
    var value: Value


struct Run(Movable):
    """The state of one evaluation: the locals in scope, and the failure that ended it."""

    var locals: List[Local]
    var failure: Optional[Failure]
    """Set by the innermost `value_of` that raised."""

    def __init__(out self):
        self.locals = []
        self.failure = None

    def push(mut self, node: Int, var value: Value):
        self.locals.append(Local(node, value^))

    def pop(mut self):
        _ = self.locals.pop()

    def set_top(mut self, var value: Value):
        self.locals[len(self.locals) - 1].value = value^

    def innermost(self, node: Int) -> Optional[Value]:
        """The value bound by the innermost binder `node`."""
        for local in reversed(self.locals):
            if local.node == node:
                return local.value.copy()
        return None

    def failure_or(self, err: Error, node: Int) -> Failure:
        """The failure recorded, or else `err` attributed to `node`."""
        if case .Some(failure) = self.failure:
            return failure.copy()
        return Failure(String(err), node, skipped=False)

    def skip(mut self, node: Int, var cause: String) -> Error:
        """The error that skips the clause, recorded at `node`."""
        self.failure = Failure(cause.copy(), node, skipped=True)
        return Error(cause^)

    def reraise(mut self, failure: Failure) -> Error:
        """A failure recorded earlier, raised again from the node it came from."""
        self.failure = failure.copy()
        return Error(failure.message)
