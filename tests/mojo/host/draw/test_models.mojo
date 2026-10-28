from std.testing import assert_equal, assert_true, assert_false, TestSuite

from host.draw.models import (
    Builder,
    PARAM_SPAN,
    default_marker,
    draw_args,
    draw_model,
    is_default,
    is_not_drawn,
)
from host.draw.sizes import Sizes
from mcheck.source import Source
from spec.ast import Ast, NodeKind
from spec.spec import Spec, Model, Build, Param, Fn, Observer, Partition
from spec.types import Types
from value.value import Value


struct Recorder(Builder):
    """Records each build call; builds of model 0 listed in `failing` raise."""

    var models: List[Int]
    var builds: List[Int]
    var args: List[List[Value]]
    var failing: List[Int]

    def __init__(out self):
        self.models = List[Int]()
        self.builds = List[Int]()
        self.args = List[List[Value]]()
        self.failing = List[Int]()

    def build(mut self, model: Int, build: Int, args: List[Value]) raises -> Value:
        for f in self.failing:
            if f == build and model == 0:
                raise Error("the library refused")
        self.models.append(model)
        self.builds.append(build)
        self.args.append(args.copy())
        return Value.handle(UInt64(len(self.builds)), "m.Frame")


def param(name: String, t: Int, default: Int = 0) -> Param:
    return Param(name, t, default, 0)


def make_spec() -> Spec:
    """m.Frame has two builds, m.Box one (a u8), m.Chain a recursive one and a leaf."""
    var types = Types()
    var frame = types.model("m.Frame", [], False)
    var box = types.model("m.Box", [], False)
    var chain = types.model("m.Chain", [], False)
    var i32 = types.fixed(32, True)
    var spec = Spec("m", Ast("", "m.spec"), types^)
    var none = List[String]()
    var frame_builds = List[Build]()
    frame_builds.append(Build("m.make", [param("n", i32), param("name", spec.types.string())], 0))
    frame_builds.append(
        Build(
            "m.from_rows",
            [param("rows", spec.types.list_of(spec.types.fixed(8, False))), param("box", box)],
            0,
        )
    )
    spec.models.append(
        Model("m.Frame", 0, False, frame, none.copy(), none.copy(), List[Observer](), frame_builds^, List[Int](), List[Int](), List[Int]())
    )
    var box_builds = List[Build]()
    box_builds.append(Build("m.box", [param("x", spec.types.fixed(8, False))], 0))
    spec.models.append(
        Model("m.Box", 0, False, box, none.copy(), none.copy(), List[Observer](), box_builds^, List[Int](), List[Int](), List[Int]())
    )
    var chain_builds = List[Build]()
    chain_builds.append(Build("m.link", [param("next", chain)], 0))
    chain_builds.append(Build("m.leaf", List[Param](), 0))
    spec.models.append(
        Model("m.Chain", 0, False, chain, none.copy(), none.copy(), List[Observer](), chain_builds^, List[Int](), List[Int](), List[Int]())
    )
    return spec^


def test_both_builds_are_used() raises:
    var spec = make_spec()
    var rec = Recorder()
    var src = Source(1)
    var sizes = Sizes()
    for _ in range(200):
        src.reset_generate()
        var v = draw_model(src, spec, 0, rec, sizes)
        assert_true(v.kind == .Handle)
    var first = 0
    var second = 0
    for i in range(len(rec.builds)):
        if rec.models[i] != 0:
            continue
        if rec.builds[i] == 0:
            first += 1
            assert_equal(len(rec.args[i]), 2)
            assert_true(rec.args[i][0].kind == .Int)
            assert_true(rec.args[i][1].kind == .String)
        else:
            second += 1
            assert_equal(len(rec.args[i]), 2)
            assert_true(rec.args[i][0].kind == .List)
            # The model-typed argument is the handle the builder returned for the box.
            assert_true(rec.args[i][1].kind == .Handle)
    assert_equal(first + second, 200)
    assert_true(first > 60 and second > 60)
    # Each from_rows call was preceded by a Box build.
    var boxes = 0
    for m in rec.models:
        boxes += 1 if m == 1 else 0
    assert_equal(boxes, second)


def test_a_raising_build_rejects() raises:
    var spec = make_spec()
    var rec = Recorder()
    rec.failing = [0]
    var src = Source(2)
    var sizes = Sizes()
    var rejected = 0
    var built = 0
    for _ in range(100):
        src.reset_generate()
        try:
            _ = draw_model(src, spec, 0, rec, sizes)
            built += 1
        except:
            assert_true(src.invalid)
            rejected += 1
    assert_true(rejected > 20 and built > 20)
    # Nothing built with the failing build was recorded.
    for i in range(len(rec.builds)):
        if rec.models[i] == 0:
            assert_equal(rec.builds[i], 1)


def test_model_depth_is_bounded() raises:
    var spec = make_spec()
    var rec = Recorder()
    var src = Source(3)
    var sizes = Sizes()
    var deepest = 0
    for _ in range(300):
        src.reset_generate()
        var before = len(rec.builds)
        _ = draw_model(src, spec, 2, rec, sizes)
        deepest = max(deepest, len(rec.builds) - before)
    # sizes.max_model_depth links, then a leaf.
    assert_true(deepest <= sizes.max_model_depth + 1)
    assert_true(deepest >= 2)


def test_draw_args() raises:
    var spec = make_spec()
    var i32 = spec.types.fixed(32, True)
    var box = spec.types.model("m.Box", [], False)
    var params = List[Param]()
    params.append(param("recv", box))
    params.append(param("a", i32))
    params.append(param("b", spec.types.string(), 7))
    params.append(param("c", box))
    spec.fns.append(
        Fn("m.f", "m.f", "f", NodeKind.METHOD, 0, -1, List[String](), List[String](), params^, True,
           spec.types.unit(), List[Partition](), List[Int]())
    )
    var rec = Recorder()
    var src = Source(4)
    var sizes = Sizes()
    var defaults = 0
    for _ in range(400):
        src.reset_generate()
        var args = draw_args(src, spec, 0, sizes, rec)
        assert_equal(len(args), 4)
        assert_true(is_not_drawn(args[0]))
        assert_true(args[1].kind == .Int)
        if is_default(args[2]):
            defaults += 1
        else:
            assert_true(args[2].kind == .String)
        assert_true(args[3].kind == .Handle)
        var param_spans = 0
        for s in src.rec.spans:
            if s.label == PARAM_SPAN:
                param_spans += 1
        assert_equal(param_spans, 3)
    assert_true(defaults > 60 and defaults < 140)
    src.reset_generate()
    for _ in range(50):
        src.reset_generate()
        assert_false(is_default(draw_args(src, spec, 0, sizes, rec, defaults=False)[2]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
