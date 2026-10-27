"""Models through their `build` calls, and the arguments of a call."""

from check.spec import Spec
from check.types import Types, MODEL as T_MODEL
from mcheck.source import Source
from wire.value import Value

from .sizes import Sizes
from .value import draw_value


trait Builder:
    """Makes a value of a model by calling one of its `build` targets. The runner
    implements it by calling the driver; a raise means the library could not make the
    value, which makes the example invalid."""

    def build(mut self, model: Int, build: Int, args: List[Value]) raises -> Value:
        ...


comptime MODEL_SPAN = 1000
comptime PARAM_SPAN = 1001


def default_marker() -> Value:
    """Stands in `draw_args`' result for a parameter left to its default."""
    return Value(.INVALID, word=1)


def not_drawn_marker() -> Value:
    """Stands in `draw_args`' result for a receiver, which the caller supplies."""
    return Value(.INVALID, word=0)


def is_default(v: Value) -> Bool:
    return v.kind == .INVALID and v.word == 1


def is_not_drawn(v: Value) -> Bool:
    return v.kind == .INVALID and v.word == 0


def _model_args(mut spec: Spec, model: Int, t: Int, targs: List[Int]) -> Int:
    """Param type `t` of a build of `model`, with its type arguments filled in."""
    if len(targs) == 0:
        return t
    var names = spec.models[model].tparams.copy()
    return spec.types.substitute(t, names, targs)


def draw_model[
    B: Builder
](
    mut src: Source,
    mut spec: Spec,
    model: Int,
    mut builder: B,
    sizes: Sizes,
    targs: List[Int] = List[Int](),
    depth: Int = 0,
) raises -> Value:
    """A value of `model`: one of its builds, its arguments drawn by their declared
    types (a model-typed argument recursively, to a bounded depth), and the builder
    called. A build that raises rejects the example; it is never a failure."""
    var builds = len(spec.models[model].builds)
    if builds == 0:
        raise Error(t"gen: model {spec.models[model].name} has no build")
    src.start_span(MODEL_SPAN)
    var allowed = [
        b
        for b in range(builds)
        if depth < sizes.max_model_depth
        or not any([spec.types.kind(p.type) == T_MODEL for p in spec.models[model].builds[b].params])
    ]
    if len(allowed) == 0:
        src.reject()
    var b = allowed[src.draw_choice(len(allowed))]
    var args = List[Value]()
    for i in range(len(spec.models[model].builds[b].params)):
        var t = _model_args(spec, model, spec.models[model].builds[b].params[i].type, targs)
        args.append(_draw_arg(src, spec, t, builder, sizes, depth))
    var out = Value.none()
    try:
        out = builder.build(model, b, args)
    except:
        src.reject()
    src.stop_span()
    return out^


def _draw_arg[
    B: Builder
](
    mut src: Source, mut spec: Spec, t: Int, mut builder: B, sizes: Sizes, depth: Int
) raises -> Value:
    """One value of type `t`; a model type goes through `draw_model`."""
    if spec.types.kind(t) == T_MODEL:
        var name = spec.types.info(t).name
        var targs = spec.types.info(t).args.copy()
        var model = spec.model_named(name)
        if model is None:
            raise Error(t"gen: no model named {name}")
        return draw_model(src, spec, model.value(), builder, sizes, targs, depth + 1)
    return draw_value(src, spec.types, t, sizes, depth)


def draw_args[
    B: Builder
](
    mut src: Source,
    mut spec: Spec,
    func: Int,
    sizes: Sizes,
    mut builder: B,
    tenv: List[Int] = List[Int](),
    defaults: Bool = True,
) raises -> List[Value]:
    """One value per parameter of `spec.fns[func]`, in order, each in its own span.

    `tenv` gives a type for each of the function's type parameters, in order. A
    parameter with a default is left to it (`default_marker`) one time in four when
    `defaults` is set; a receiver is `not_drawn_marker`, for the caller to supply.
    A parameter of model type is built through `builder`.
    """
    var out = List[Value]()
    for i in range(len(spec.fns[func].params)):
        if i == 0 and spec.fns[func].receiver:
            out.append(not_drawn_marker())
            continue
        src.start_span(PARAM_SPAN)
        if defaults and spec.fns[func].params[i].default != 0 and src.draw_below(4) == 0:
            out.append(default_marker())
            src.stop_span()
            continue
        var t = spec.fns[func].params[i].type
        if len(tenv) > 0:
            var names = spec.fns[func].tparams.copy()
            t = spec.types.substitute(t, names, tenv)
        out.append(_draw_arg(src, spec, t, builder, sizes, 0))
        src.stop_span()
    return out^
