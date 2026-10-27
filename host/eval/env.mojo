"""The values a clause sees, and the state of one evaluation."""

from wire.value import Value


struct Env(Movable):
    """The values a clause is evaluated against.

    `params` holds the parameters by position; for a function with a receiver
    `params[0]` is `self`. `self_value` answers `self` where there is no such
    parameter (a model's own clauses and observers); without it `self` reads
    `params[0]`. `olds` holds the value of each `old(...)` call, by the call's node id,
    taken before the call; one whose evaluation failed holds its failure. `tvars` and
    `tvals` instantiate a generic function's type parameters.
    """

    var params: List[Value]
    var has_result: Bool
    var result: Value
    var has_self: Bool
    var self_value: Value
    var old_nodes: List[Int]
    var old_values: List[Value]
    var old_errors: List[String]
    """The failure message of an old(...) that failed, else an empty string."""
    var old_error_nodes: List[Int]
    var old_skips: List[Bool]
    var tvars: List[String]
    var tvals: List[Int]

    def __init__(out self):
        self.params = List[Value]()
        self.has_result = False
        self.result = Value.none()
        self.has_self = False
        self.self_value = Value.none()
        self.old_nodes = List[Int]()
        self.old_values = List[Value]()
        self.old_errors = List[String]()
        self.old_error_nodes = List[Int]()
        self.old_skips = List[Bool]()
        self.tvars = List[String]()
        self.tvals = List[Int]()

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
        """Instantiate the type parameter `name` with the type `type`."""
        self.tvars.append(name^)
        self.tvals.append(type)

    def old_index(self, node: Int) -> Int:
        for i in range(len(self.old_nodes)):
            if self.old_nodes[i] == node:
                return i
        return -1


struct Run(Movable):
    """The state of one evaluation: the locals in scope, and the failure that ended it."""

    var local_nodes: List[Int]
    var local_values: List[Value]
    var err_node: Int
    """The node a failure is attributed to, or -1 while none has been."""
    var err_message: String
    var skipped: Bool
    """Whether the failure is a skip of the clause rather than an error."""
    var depth: Int

    def __init__(out self):
        self.local_nodes = List[Int]()
        self.local_values = List[Value]()
        self.err_node = -1
        self.err_message = String()
        self.skipped = False
        self.depth = 0

    def push(mut self, node: Int, var value: Value):
        self.local_nodes.append(node)
        self.local_values.append(value^)

    def pop(mut self):
        _ = self.local_nodes.pop()
        _ = self.local_values.pop()

    def truncate(mut self, n: Int):
        while len(self.local_nodes) > n:
            self.pop()

    def set_top(mut self, var value: Value):
        self.local_values[len(self.local_values) - 1] = value^

    def local(self, node: Int) -> Int:
        """The position of the innermost binding of the binder `node`, or -1."""
        var i = len(self.local_nodes) - 1
        while i >= 0:
            if self.local_nodes[i] == node:
                return i
            i -= 1
        return -1

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
