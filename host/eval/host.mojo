"""What the evaluator asks of the runner, and what it answers."""

from wire.value import Value


trait EvalHost:
    """The runner's side of evaluation. Tests mock it."""

    def observe(
        mut self, obj: Value, model: Int, observer: Int, args: List[Value]
    ) raises -> Value:
        """An observer of a model (positions in Spec.models and Model.observers)."""
        ...

    def call_fn(mut self, `fn`: Int, args: List[Value]) raises -> Value:
        """A planned call of Spec.fns[fn]. A library error comes back as an ERROR value."""
        ...

    def constant(mut self, `const`: Int) raises -> Value:
        """A declared constant, Spec.consts[const]."""
        ...

    def fresh(mut self, obj: Value) raises -> Bool:
        ...

    def same_object(mut self, a: Value, b: Value) raises -> Bool:
        ...

    def shares_memory(mut self, a: Value, b: Value) raises -> Bool:
        ...

    def call_extern(mut self, name: String, args: List[Value]) raises -> Value:
        """A callable the spec doesn't declare, in an observer's reading expression."""
        ...
