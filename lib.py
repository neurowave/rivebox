"""Shared RML helpers for the RiveBox generator.

All ids come from one allocator so the generated file is deterministic.
Brand assets (fonts 1:x, RiveTheme 2:x, marks 3-9:x, AnimBrandmark 70:x) are
loaded from brand.rml.
"""
from __future__ import annotations
from rml import E, Ids

I = Ids(0, 1000)

# ---------------------------------------------------------------- brand palette
BLACK = "FF000000"
WHITE = "FFFFFFFF"
SURF = "FF141414"
SURF2 = "FF0A0A0A"
LINE = "FF2A2A2A"
MUTED = "FFA0A0A0"
FAINT = "FF5C5C5C"
AMBER = "FFFFA41C"
PRISM = ["FFF30058", "FFFF483C", "FFFFA41C", "FF71FF19", "FF19F2FF", "FF3084FF"]
PRISM_NAMES = ["pink", "red", "amber", "green", "cyan", "blue"]

F_ORB = "1:1"     # Orbitron (variable, wght)
F_INTER = "1:2"   # Inter (variable)
F_MONO = "1:3"    # Iosevka (mono)
WGHT = 2003265652

TAU = 6.2831855

# property keys
K_X, K_Y, K_ROT, K_SX, K_SY, K_OP = 13, 14, 15, 16, 17, 18
K_RW, K_RH = 20, 21
K_LW, K_LH = 7, 8
K_COLOR = 37
K_STROKE_W = 47
K_TRIM_END, K_TRIM_START, K_TRIM_OFF = 115, 114, 116
K_TEXT = 268
K_SIN = 243   # ScriptInputNumber.propertyValue
K_SIB = 245   # ScriptInputBoolean.propertyValue
K_CANFOCUS = 953
K_SCROLLIDX = 763
K_MOD_FROM, K_MOD_TO, K_FALL_FROM, K_FALL_TO, K_MOD_OFF = 327, 336, 317, 318, 319

UNIT_KEYS = ("padding", "margin", "gap", "position")


# ---------------------------------------------------------------- layout
def style(**kw) -> E:
    """LayoutComponentStyle; every padding/margin/gap/position gets its *UnitsValue twin."""
    attrs = {}
    for k, v in kw.items():
        attrs[k] = v
        if k.startswith(UNIT_KEYS) and not k.endswith("UnitsValue") and f"{k}UnitsValue" not in kw:
            attrs[f"{k}UnitsValue"] = "points"
    return E("LayoutComponentStyle", id=I(), name="S", **attrs)


def box(name: str, w=0, h=0, *, id=None, clip=False, opacity=None, x=None, y=None,
        rotation=None, origin=None, **st) -> E:
    st.setdefault("layoutWidthScaleType", "fixed" if w else "hug")
    st.setdefault("layoutHeightScaleType", "fixed" if h else "hug")
    s = style(**st)
    b = E("LayoutComponent", id=id or I(), name=name, width=w, height=h, styleId=s.attrs["id"],
          clip=clip, opacity=opacity, x=x, y=y, rotation=rotation)(s)
    if origin:
        b(E("ComponentOrigin", originX=origin[0], originY=origin[1], name="O"))
    return b


def fill_box(name: str, **kw) -> E:
    return box(name, layoutWidthScaleType="fill", layoutHeightScaleType="fill",
               widthUnitsValue="auto", heightUnitsValue="auto", **kw)


def spacer(name="Spacer", grow_w=True, grow_h=False) -> E:
    return box(name, layoutWidthScaleType="fill" if grow_w else "fixed",
               layoutHeightScaleType="fill" if grow_h else "fixed")


def solid(color: str, id=None, bind=None) -> E:
    c = E("SolidColor", id=id, colorValue=color, name="C")
    if bind:
        c(E("DataBindContext", sourcePathIds=bind, propertyKey=K_COLOR))
    return c


def fill(color: str, id=None, bind=None) -> E:
    return E("Fill", name="F")(solid(color, id, bind))


def stroke(color: str, w=1.0, id=None, sid=None, bind=None, cap=None, trim=None) -> E:
    s = E("Stroke", id=sid, name="St", thickness=w, cap=cap)(solid(color, id, bind))
    if trim is not None:
        s(trim)
    return s


def rect(name: str, w, h, color=None, *, x=0, y=0, r=0, id=None, rid=None, cid=None, ox=None, oy=None,
         stroke_color=None, stroke_w=1.0, opacity=None, rotation=None, sid=None, bind=None) -> E:
    shape = E("Shape", id=id or I(), name=name, x=x, y=y, opacity=opacity, rotation=rotation)(
        E("Rectangle", id=rid, name="R", width=w, height=h, cornerRadiusTL=r if r else None,
          originX=ox, originY=oy))
    if stroke_color:
        shape(stroke(stroke_color, stroke_w, sid=sid))
    if color:
        shape(fill(color, cid, bind))
    return shape


def poly(name: str, pts, color=None, *, x=0, y=0, id=None, cid=None, closed=True, stroke_color=None,
         stroke_w=1.0, opacity=None, rotation=None, cap=None) -> E:
    p = E("PointsPath", name="P", isClosed=closed)(*[E("StraightVertex", x=px, y=py) for px, py in pts])
    s = E("Shape", id=id or I(), name=name, x=x, y=y, opacity=opacity, rotation=rotation)(p)
    if stroke_color:
        s(stroke(stroke_color, stroke_w, cap=cap))
    if color:
        s(fill(color, cid))
    return s


def node(name: str, *kids, x=0, y=0, id=None, opacity=None, rotation=None, sx=None, sy=None) -> E:
    return E("Node", id=id or I(), name=name, x=x, y=y, opacity=opacity, rotation=rotation,
             scaleX=sx, scaleY=sy)(*kids)


def text(name: str, s: str, size, color=WHITE, *, font=F_ORB, weight=None, spacing=0.0, bind=None,
         conv=None, id=None, cid=None, run_id=None, wrap=False, w_fill=False, width=None,
         align=None, opacity=None, modifiers=None, lp=True, line_height=None, x=None, y=None,
         color_bind=None) -> E:
    tid = id or I()
    sid = I()
    run = E("TextValueRun", id=run_id, styleId=sid, text=s, name="R")
    if bind:
        run(E("DataBindContext", sourcePathIds=bind, propertyKey=K_TEXT, converterId=conv))
    tsp = E("TextStylePaint", id=sid, name="TS", fontSize=size, fontAssetId=font, letterSpacing=spacing or None,
            lineHeight=line_height)(fill(color, cid, color_bind))
    if weight:
        tsp(E("TextStyleAxis", tag=WGHT, axisValue=weight, name="W"))
    t = E("Text", id=tid, name=name, opacity=opacity, alignValue=align, x=x, y=y,
          **({"sizingValue": "autoHeight", "wrapValue": "wrap"} if wrap else {"wrapValue": "noWrap"}))
    if width is not None:
        t.attrs["width"] = width
    if lp:
        t(E("LayoutParticipant", layoutWidthScaleType="fill" if w_fill else "hug",
            layoutHeightScaleType="hug", name="LP"))
    t(tsp, run)
    if modifiers:
        t(*modifiers)
    return t


def nested(name: str, artboard: str, w, h, *, fit="contain", id=None, opacity=None) -> E:
    """A fixed slot holding a NestedArtboardLeaf scaled to fit."""
    b = box(name, w, h, opacity=opacity, id=id)
    b(E("NestedArtboardLeaf", artboardId=artboard, fit=fit, name=name + " Leaf"))
    return b


# ---------------------------------------------------------------- binds / data
def bind(path: str, key: int, conv=None, **kw) -> E:
    return E("DataBindContext", sourcePathIds=path, propertyKey=key, converterId=conv, **kw)


BP = {
    "num": ("BindablePropertyNumber", 636, "TransitionValueNumberComparator"),
    "int": ("BindablePropertyInteger", 686, "TransitionValueNumberComparator"),
    "bool": ("BindablePropertyBoolean", 634, "TransitionValueBooleanComparator"),
    "str": ("BindablePropertyString", 635, "TransitionValueStringComparator"),
    "trig": ("BindablePropertyTrigger", 686, "TransitionValueTriggerComparator"),
}


def cond(path: str, kind: str, value=None, op=None) -> E:
    el, key, comp = BP[kind]
    c = E("TransitionViewModelCondition", opValue=op)(
        E("TransitionPropertyViewModelComparator")(E(el)(bind(path, key))))
    if kind == "trig":
        c(E(comp))
    else:
        c(E(comp, value=value))
    return c


def write(path: str, kind: str, value) -> E:
    el, key, _ = BP[kind]
    return E("ListenerViewModelChange")(E(el, propertyValue=value)(bind(path, key, direction=True)))


def write_from(path_from: str, kind: str, path_to: str, conv=None) -> E:
    """Write a value read from one property (optionally converted) into another."""
    el, key, _ = BP[kind]
    rid = I()
    return E("ListenerViewModelChange", fromViewModelProperty=True, fromDataBindId=rid)(
        E(el)(bind(path_from, key, conv, id=rid), bind(path_to, key, direction=True)))


def fire(path: str) -> E:
    return write(path, "trig", 1)


# ---------------------------------------------------------------- animation
def kf(kind: str, frame, value, ease="cubic", curve=(0.25, 0.1, 0.25, 1.0)) -> E:
    el = {"d": "KeyFrameDouble", "c": "KeyFrameColor", "b": "KeyFrameBool", "u": "KeyFrameUint",
          "id": "KeyFrameId"}[kind]
    if kind in ("b", "id", "u"):
        ease = "hold"
    k = E(el, frame=frame, value=value, interpolationType=ease)
    if ease == "cubic":
        k(E("CubicEaseInterpolator", x1=curve[0], y1=curve[1], x2=curve[2], y2=curve[3]))
    return k


EASE_OUT = (0.16, 1.0, 0.3, 1.0)
EASE_IN_OUT = (0.65, 0.0, 0.35, 1.0)
BACK_OUT = (0.34, 1.56, 0.64, 1.0)


class Anim:
    """LinearAnimation builder: anim.key(obj, prop, [(frame, value), ...], kind='d', ease=...)."""

    def __init__(self, name: str, duration: int, loop: str | None = None, fps=None):
        self.id = I()
        self.el = E("LinearAnimation", id=self.id, name=name, duration=duration,
                    loopValue=loop, fps=fps)
        self.objs: dict[str, E] = {}

    def key(self, obj: str, prop: int, frames, kind="d", ease="cubic", curve=(0.25, 0.1, 0.25, 1.0)):
        ko = self.objs.get(obj)
        if ko is None:
            ko = E("KeyedObject", objectId=obj)
            self.objs[obj] = ko
            self.el(ko)
        kp = E("KeyedProperty", propertyKey=prop)
        for i, fr in enumerate(frames):
            f, v = fr[0], fr[1]
            e = fr[2] if len(fr) > 2 else ease
            if i == len(frames) - 1 and e == "cubic":
                e = "linear"
            kp(kf(kind, f, v, e, curve))
        ko(kp)
        return self

    def hold(self, obj, prop, value, kind="d"):
        return self.key(obj, prop, [(0, value, "hold")], kind)


# ---------------------------------------------------------------- state machines
def layer(name: str, entry_to: str, states: list[E], any_transitions: list[E] | None = None) -> E:
    return E("StateMachineLayer", id=I(), name=name)(
        E("AnyState", x=600, y=-160)(any_transitions or []),
        E("ExitState", x=900, y=-160),
        E("EntryState", x=-120, y=0)(E("StateTransition", stateToId=entry_to)),
        states)


_state_pos = [0]


def state(anim: Anim | str, *kids, id=None, x=None, y=None, speed=None, reset=None) -> E:
    _state_pos[0] += 1
    n = _state_pos[0]
    aid = anim.id if isinstance(anim, Anim) else anim
    return E("AnimationState", id=id or I(), animationId=aid,
             x=x if x is not None else 160 + (n % 6) * 180,
             y=y if y is not None else ((n // 6) % 8) * 120 + 60, speed=speed, reset=reset)(*kids)


def go(to: str, *conds, ms=0, exit_pct=None, interp=None, early=None) -> E:
    t = E("StateTransition", stateToId=to, duration=ms or None, enableEarlyExit=early)
    if exit_pct is not None:
        t.attrs.update(enableExitTime=True, exitTimeIsPercetange=True, exitTime=exit_pct)
    if interp:
        t.attrs["interpolationType"] = "cubic"
        t(E("CubicEaseInterpolator", x1=interp[0], y1=interp[1], x2=interp[2], y2=interp[3]))
    t(*conds)
    return t


def listener(target: str, name: str, inputs: list[E], actions: list[E]) -> E:
    return E("StateMachineListener", targetId=target, name=name)(*inputs, *actions)


def on_key(*keys, phase=1, mods=None) -> E:
    return E("ListenerInputTypeKeyboard", listenerTypeValue="keyboard")(
        *[E("KeyboardInput", keyType=k, keyPhase=phase, modifiers=mods) for k in keys])


def on_pad(*idx) -> E:
    return E("ListenerInputTypeGamepad", listenerTypeValue="gamepad")(
        *[E("GamepadInput", kind="button", mapping="standard", inputIndex=i, buttonPhase=1) for i in idx])


def on(kind: str) -> E:
    return E("ListenerInputType", listenerTypeValue=kind)


def on_vm(path: str) -> E:
    return E("ListenerInputTypeViewModel", viewModelPathIds=path, listenerTypeValue="viewModel")
