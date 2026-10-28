"""What the runner asks of the driver (docs/v2/protocol.md)."""

from value.value import Value


trait Driver:
    """The driver's side of a run: names, calls, constants, observers and handles.
    Tests mock it."""

    def resolve(mut self, name: String) raises -> Int:
        """The target id of a qualified name. Raises for a name that doesn't resolve."""
        ...

    def call(mut self, target: Int, args: List[Value]) raises -> Value:
        """Calls a target. An exception the call raised comes back as an ERROR Value."""
        ...

    def get(mut self, target: Int) raises -> Value:
        ...

    def observe(
        mut self, obj: Value, name: String, args: Optional[List[Value]]
    ) raises -> Value:
        """Reads attribute `name` of `obj`, calling it with `args` when given."""
        ...

    def release(mut self, ids: List[UInt64]) raises:
        ...
