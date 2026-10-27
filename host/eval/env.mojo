"""The values a clause sees, and the state of one evaluation."""

from wire.value import Value


@fieldwise_init
struct Old(Copyable, Movable):
    """What `old(...)` saw before the call: its value, or its failure."""

    var value: Value
    var error: String
    """The failure message, or an empty string when the evaluation succeeded."""
    var error_node: Int
    var skipped: Bool


struct Env(Movable):
    """The values a clause is evaluated against.

    `params` holds the parameters by position; for a function with a receiver
    `params[0]` is `self`. `self_value` answers `self` where there is no such
    parameter (a model's own clauses and observers); without it `self` reads
    `params[0]`. `olds` maps the node of each `old(...)` call to what it saw before the
    call. `types` instantiates a generic function's type parameters.
    """

    var params: List[Value]
    var has_result: Bool
    var result: Value
    var has_self: Bool
    var self_value: Value
    var olds: Dict[Int, Old]
    var types: Dict[String, Int]

    def __init__(out self):
        self.params = []
        self.has_result = False
        self.result = Value.none()
        self.has_self = False
        self.self_value = Value.none()
        self.olds = {}
        self.types = {}

    def __init__(out self, var params: List[Value]):
        self = Self()
        self.params = params^

    def set_result(mut self, var value: Value):
        self.has_result = True
        self.result = value^

    def set_self(mut self, var value: Value):
        self.has_self = True
        self.self_value = value^

    def bind_type(mut self, var name: String, type: Int):
        self.types[name^] = type


@fieldwise_init
struct Local(Copyable, Movable):
    var node: Int
    var value: Value


struct Run(Movable):
    """The state of one evaluation: the locals in scope, and the failure that ended it."""

    var locals: List[Local]
    var err_node: Int
    """The node a failure is attributed to, or -1 while none has been."""
    var err_message: String
    var skipped: Bool
    """Whether the failure is a skip of the clause rather than an error."""

    def __init__(out self):
        self.locals = []
        self.err_node = -1
        self.err_message = String()
        self.skipped = False

    def push(mut self, node: Int, var value: Value):
        self.locals.append(Local(node, value^))

    def pop(mut self):
        _ = self.locals.pop()

    def truncate(mut self, n: Int):
        while len(self.locals) > n:
            self.pop()

    def set_top(mut self, var value: Value):
        self.locals[len(self.locals) - 1].value = value^

    def innermost(self, node: Int) -> Optional[Value]:
        """The value bound by the innermost binder `node`."""
        for i in reversed(range(len(self.locals))):
            if self.locals[i].node == node:
                return self.locals[i].value.copy()
        return None

    def fail(mut self, node: Int, var message: String) -> Error:
        if self.err_node < 0:
            self.err_node = node
            self.err_message = message.copy()
        return Error(message^)

    def skip(mut self, node: Int, var cause: String) -> Error:
        self.skipped = True
        return self.fail(node, cause^)

    def reraise(mut self, node: Int, var message: String, skipped: Bool) -> Error:
        """Raise a failure recorded earlier, keeping the node it came from."""
        self.err_node = node
        self.err_message = message.copy()
        self.skipped = skipped
        return Error(message^)
