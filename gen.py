#!/usr/bin/env python3
"""RiveBox: an original 3D console dashboard concept, built in Rive.

Run:  python3 gen.py   -> writes scene.rml (brand.rml is copied by brand.py)

Every surface in the 3D world is a real Rive artboard built here: a hub menu
whose four rows become the floating blades, an equirectangular skin for the
core orb, a ticker ribbon, four section screens (games list, music player,
memory devices, settings with a gamertag text field), and per-game case art.
world.as renders them to textures and maps them onto geometry.
"""
from __future__ import annotations
from pathlib import Path
import os
from rml import E
from lib import *  # noqa: F401,F403
import lib

OUT = Path(__file__).with_name("scene.rml")

# ------------------------------------------------------------------ fixed ids
ART_MAIN = "0:2"
AB_HUB, AB_CORE, AB_TICK = "0:100", "0:110", "0:120"
AB_GAMES, AB_MUSIC, AB_MEM, AB_SET = "0:130", "0:140", "0:150", "0:160"
AB_CASE, AB_GROW, AB_TROW = "0:170", "0:180", "0:190"
AB_SAT = "0:200"
SCRIPT_GEO, SCRIPT_WORLD, SCRIPT_GUARD = "0:80", "0:81", "0:82"
PHYS = "0:98"
PHYS2 = "0:99"  # the track list's own physics (one per ScrollConstraint)
CONV_STR, CONV_IDX, CONV_P1, CONV_PAD, CONV_NOT = "0:91", "0:92", "0:93", "0:94", "0:95"
CONV_PCT = "0:96"
# decrypt text converter (decrypt.as) + chains that end in it
SCRIPT_DEC, CONV_DECRYPT, CONV_STR_DEC, CONV_IDX_DEC = "0:83", "0:84", "0:85", "0:86"

# brand assets (brand.rml)
BR_BRANDMARK, BR_LOGO, BR_WORDMARK = "3:9", "4:9", "5:12"
ICONS = {"gamedev": "6:9", "designer": "6:18", "dev": "6:27", "animator": "6:36", "swords": "6:45",
         "alien": "6:54", "lightning": "6:63", "hazard": "6:72", "asterisk": "6:81", "shuffle": "7:18"}
BR_STING = "70:915"

VM = "0:40"
VMI = "0:41"
P = {}
_props = [
    ("mode", "Number", 0), ("section", "Number", 0), ("navUp", "Trigger", None), ("navDown", "Trigger", None),
    ("navLeft", "Trigger", None), ("navRight", "Trigger", None), ("accept", "Trigger", None),
    ("back", "Trigger", None), ("gamertag", "String", "PILOT_01"), ("games", "List", None),
    ("game", "Number", 0), ("tracks", "List", None), ("track", "Number", 0), ("playing", "Boolean", True),
    ("setting", "Number", 0), ("opt0", "Boolean", True), ("opt1", "Boolean", True), ("opt2", "Boolean", False),
    ("opt3", "Boolean", True), ("clock", "String", "--:--"), ("clockH", "String", "--"), ("clockM", "String", "--"), ("heroTitle", "String", "ROCKET SQUADRON"),
    ("heroGenre", "String", "ACTION"), ("heroYear", "String", "2026"),
    ("heroBlurb", "String", "Light the boosters, hold formation, fly as one squadron."),
    ("heroColor", "Color", "FF3084FF"), ("device", "Number", 0), ("trackTitle", "String", "BOOT SEQUENCE"),
    ("trackArtist", "String", "RIVEBOX OST"), ("heroPing", "Trigger", None), ("trackPing", "Trigger", None),
    ("heroBlocks", "Number", 412), ("launching", "Boolean", False), ("editing", "Boolean", False), ("fieldDone", "Trigger", None),
    ("logo", "ViewModel", "90:471"),
    # bumped by world.as whenever the camera ARRIVES somewhere (hub, a
    # section, a new section): the Decrypt converter replays on it
    ("cue", "Number", 0),
    # true while the camera is settled at the current place (world.as)
    ("arrived", "Boolean", False),
]
# the imported logo (logo.rml, from the designer's .rev): its view model + showLogo
LOGO_AB, LOGO_VM, LOGO_VMI, LOGO_SHOW, LOGO_SM = "90:547", "90:470", "90:471", "90:473", "90:1003"
for k, (name, _, _) in enumerate(_props):
    P[name] = f"0:{401 + k}"


def vp(name: str) -> str:
    return f"{VM}-{P[name]}"


VM_GAME, VM_GAME_DEF = "0:50", "0:49"
G = {"title": "0:51", "genre": "0:52", "year": "0:53", "blurb": "0:54", "color": "0:55", "index": "0:56",
     "focused": "0:57", "blocks": "0:58", "code": "0:59"}
# mirrors: each list item carries two-way copies of the host properties it
# reads or writes, bound in the instance (the documented row -> host route)
MIRROR_G = [("hMode", "Number", "mode"), ("hSection", "Number", "section"), ("hSel", "Number", "game"),
            ("hTitle", "String", "heroTitle"), ("hGenre", "String", "heroGenre"), ("hYear", "String", "heroYear"),
            ("hBlurb", "String", "heroBlurb"), ("hColor", "Color", "heroColor"), ("hBlocks", "Number", "heroBlocks"),
            ("hPing", "Trigger", "heroPing")]
MIRROR_T = [("hMode", "Number", "mode"), ("hSection", "Number", "section"), ("hSel", "Number", "track"),
            ("hTitle", "String", "trackTitle"), ("hArtist", "String", "trackArtist"), ("hPing", "Trigger", "trackPing")]
for _k, (_n, _t, _h) in enumerate(MIRROR_G):
    G[_n] = f"0:{760 + _k}"
MIRROR_KEY = {"Number": 575, "String": 561, "Color": 555, "Boolean": 593, "Trigger": 687}
VM_TRACK, VM_TRACK_DEF = "0:60", "0:69"
T = {"title": "0:61", "artist": "0:62", "len": "0:63", "index": "0:64", "focused": "0:65"}
for _k, (_n, _t, _h) in enumerate([("hMode", "Number", "mode"), ("hSection", "Number", "section"), ("hSel", "Number", "track"),
                                   ("hTitle", "String", "trackTitle"), ("hArtist", "String", "trackArtist"),
                                   ("hPing", "Trigger", "trackPing")]):
    T[_n] = f"0:{780 + _k}"


def gp(name):
    return f"{VM_GAME}-{G[name]}"


def tp(name):
    return f"{VM_TRACK}-{T[name]}"


GAMES = [
    # fictitious titles, except Rocket Squadron (github.com/neurowave/rocket-squadron)
    ("ROCKET SQUADRON", "ACTION", "2026", "Light the boosters, hold formation, fly as one squadron.", PRISM[5], 412, "RS-01"),
    ("GLASSLINE GP", "RACING", "2005", "Eight hundred horsepower, one racing line, zero patience.", PRISM[1], 288, "GG-02"),
    ("LANTERN OATH", "RPG", "2004", "Every choice leaves a mark. Some of them glow.", PRISM[3], 196, "LO-03"),
    ("BRASS CORRIDOR", "ACTION", "2006", "Cover, roll, reload. The corridor goes on forever.", PRISM[0], 350, "BC-04"),
    ("SPRAYWAVE", "ARCADE", "2002", "Tag the city in motion. Every surface is a canvas.", PRISM[4], 144, "SW-05"),
    ("KILOTON STRIDE", "MECH", "2002", "Twelve metres of armour, piloted at street level.", PRISM[2], 230, "KS-06"),
    ("SUNDIAL RUN", "RACING", "2003", "A sunset that never ends and a state machine that never stops.", PRISM[3], 98, "SR-07"),
    ("PRISM WARS", "STRATEGY", "2026", "Six colours, one order. Command them all.", PRISM[0], 512, "PW-08"),
]
TRACKS = [
    ("BOOT SEQUENCE", "RIVEBOX OST", "2:41"), ("AMBER CORE", "THE ANIMATORS", "3:12"),
    ("STATE MACHINE", "THE RUNTIMES", "4:05"), ("VECTOR FEEDBACK", "PRISM", "3:33"),
    ("BLEND STATE", "WASM QUARTET", "2:58"), ("SIXTY FPS", "RENDERER", "3:47"),
    ("DATA BINDING", "VIEW MODELS", "4:20"), ("ARTBOARD 0", "THE NESTED", "5:01"),
]
SECTIONS = [("GAMES", "8 TITLES  ·  PLAY  ·  BROWSE", "gamedev"),
            ("MUSIC", "SOUNDTRACKS  ·  VISUALIZER", "animator"),
            ("MEMORY", "3 DEVICES  ·  124 GB USED", "hazard"),
            ("SETTINGS", "PLAYER  ·  SYSTEM", "asterisk")]


# ------------------------------------------------------------------ data
def view_models() -> list[E]:
    vm = E("ViewModel", id=VM, name="Dash", defaultInstanceId=VMI)
    inst = E("ViewModelInstance", id=VMI, name="Default", exports=True)
    for name, kind, val in _props:
        pid = P[name]
        vm(E(f"ViewModelProperty{kind}", id=pid, name=name))
        if kind == "List":
            items = GAME_ITEMS if name == "games" else TRACK_ITEMS
            inst(E("ViewModelInstanceList", viewModelPropertyId=pid)(
                *[E("ViewModelInstanceListItem", viewModelId=v, viewModelInstanceId=i) for v, i in items]))
        elif kind == "Trigger":
            inst(E("ViewModelInstanceTrigger", viewModelPropertyId=pid))
        elif kind == "ViewModel":
            vm.kids[-1] = E("ViewModelPropertyViewModel", id=pid, name=name, viewModelReferenceId=LOGO_VM)
            inst(E("ViewModelInstanceViewModel", viewModelPropertyId=pid, propertyValue=val))
        else:
            inst(E(f"ViewModelInstance{kind}", viewModelPropertyId=pid, propertyValue=val))
    for name, pid, val in _LIFT:
        vm(E("ViewModelPropertyString", id=pid, name=name))
        inst(E("ViewModelInstanceString", viewModelPropertyId=pid, propertyValue=val))
    vm(inst)

    game = E("ViewModel", id=VM_GAME, name="Game", defaultInstanceId=VM_GAME_DEF)(
        E("ViewModelPropertyString", id=G["title"], name="title"),
        E("ViewModelPropertyString", id=G["genre"], name="genre"),
        E("ViewModelPropertyString", id=G["year"], name="year"),
        E("ViewModelPropertyString", id=G["blurb"], name="blurb"),
        E("ViewModelPropertyColor", id=G["color"], name="color"),
        E("ViewModelPropertySymbolListIndex", id=G["index"], name="index", symbolTypeValue="itemIndex"),
        E("ViewModelPropertyBoolean", id=G["focused"], name="focused"),
        E("ViewModelPropertyNumber", id=G["blocks"], name="blocks"),
        E("ViewModelPropertyString", id=G["code"], name="code"),
        *[E(f"ViewModelProperty{t}", id=G[n], name=n) for n, t, _ in MIRROR_G])

    def mirrors(table, spec):
        out = []
        for n, t, host in spec:
            v = E(f"ViewModelInstance{t}", viewModelPropertyId=table[n])
            v(bind(vp(host), MIRROR_KEY[t], twoWay=True))
            out.append(v)
        return out

    def ginst(iid, name, g):
        t, ge, y, b, c, bl, code = g
        return E("ViewModelInstance", id=iid, name=name, exports=True)(
            E("ViewModelInstanceString", viewModelPropertyId=G["title"], propertyValue=t),
            E("ViewModelInstanceString", viewModelPropertyId=G["genre"], propertyValue=ge),
            E("ViewModelInstanceString", viewModelPropertyId=G["year"], propertyValue=y),
            E("ViewModelInstanceString", viewModelPropertyId=G["blurb"], propertyValue=b),
            E("ViewModelInstanceColor", viewModelPropertyId=G["color"], propertyValue=c),
            E("ViewModelInstanceSymbolListIndex", viewModelPropertyId=G["index"]),
            E("ViewModelInstanceBoolean", viewModelPropertyId=G["focused"], propertyValue=False),
            E("ViewModelInstanceNumber", viewModelPropertyId=G["blocks"], propertyValue=bl),
            E("ViewModelInstanceString", viewModelPropertyId=G["code"], propertyValue=code),
            *mirrors(G, MIRROR_G))

    game(ginst(VM_GAME_DEF, "Default", GAMES[0]))
    for (_, iid), g in zip(GAME_ITEMS, GAMES):
        game(ginst(iid, g[0].title(), g))

    track = E("ViewModel", id=VM_TRACK, name="Track", defaultInstanceId=VM_TRACK_DEF)(
        E("ViewModelPropertyString", id=T["title"], name="title"),
        E("ViewModelPropertyString", id=T["artist"], name="artist"),
        E("ViewModelPropertyString", id=T["len"], name="len"),
        E("ViewModelPropertySymbolListIndex", id=T["index"], name="index", symbolTypeValue="itemIndex"),
        E("ViewModelPropertyBoolean", id=T["focused"], name="focused"),
        *[E(f"ViewModelProperty{t}", id=T[n], name=n) for n, t, _ in MIRROR_T])

    def tinst(iid, name, tr):
        return E("ViewModelInstance", id=iid, name=name, exports=True)(
            E("ViewModelInstanceString", viewModelPropertyId=T["title"], propertyValue=tr[0]),
            E("ViewModelInstanceString", viewModelPropertyId=T["artist"], propertyValue=tr[1]),
            E("ViewModelInstanceString", viewModelPropertyId=T["len"], propertyValue=tr[2]),
            E("ViewModelInstanceSymbolListIndex", viewModelPropertyId=T["index"]),
            E("ViewModelInstanceBoolean", viewModelPropertyId=T["focused"], propertyValue=False),
            *mirrors(T, MIRROR_T))

    track(tinst(VM_TRACK_DEF, "Default", TRACKS[0]))
    for (_, iid), tr in zip(TRACK_ITEMS, TRACKS):
        track(tinst(iid, tr[0].title(), tr))
    return [vm, game, track]


GAME_ITEMS = [(VM_GAME, f"0:{700 + i}") for i in range(len(GAMES))]
TRACK_ITEMS = [(VM_TRACK, f"0:{720 + i}") for i in range(len(TRACKS))]


def converters() -> list[E]:
    return [
        E("DataConverterToString", id=CONV_STR, name="ToString", decimals=0, round=True),
        E("DataConverterFormula", id=CONV_P1, name="Plus One")(
            E("FormulaTokenInput"), E("FormulaTokenOperation", operationType=0), E("FormulaTokenValue", operationValue=1)),
        E("DataConverterStringPad", id=CONV_PAD, name="Pad2", length=2, text="0", padType=0),
        E("DataConverterGroup", id=CONV_IDX, name="Index Label")(
            E("DataConverterGroupItem", converterId=CONV_P1), E("DataConverterGroupItem", converterId=CONV_STR),
            E("DataConverterGroupItem", converterId=CONV_PAD)),
        E("DataConverterBooleanNegate", id=CONV_NOT, name="Not"),
        E("ScriptedDataConverter", id=CONV_DECRYPT, scriptAssetId=SCRIPT_DEC, name="Decrypt"),
        E("DataConverterGroup", id=CONV_STR_DEC, name="ToString + Decrypt")(
            E("DataConverterGroupItem", converterId=CONV_STR), E("DataConverterGroupItem", converterId=CONV_DECRYPT)),
        E("DataConverterGroup", id=CONV_IDX_DEC, name="Index Label + Decrypt")(
            E("DataConverterGroupItem", converterId=CONV_IDX), E("DataConverterGroupItem", converterId=CONV_DECRYPT)),
        E("ElasticScrollPhysics", id=PHYS, name="Physics", friction=3, speedMultiplier=1.2, elasticFactor=0.7),
        E("ElasticScrollPhysics", id=PHYS2, name="Physics Tracks", friction=3, speedMultiplier=1.2, elasticFactor=0.7),
    ]


# ------------------------------------------------------------------ common pieces
def mono(name, s, size=13, color=FAINT, **kw):
    return text(name, s, size, color, font=F_MONO, spacing=kw.pop("spacing", 1), **kw)


def orb(name, s, size, color=WHITE, weight=900, **kw):
    return text(name, s, size, color, font=F_ORB, weight=weight, **kw)


def inter(name, s, size, color=MUTED, weight=400, **kw):
    return text(name, s, size, color, font=F_INTER, weight=weight, **kw)


def icon(name, key, size, x=0, y=0, id=None):
    """Brand icon (100x100 component, white) placed with its centre at x,y."""
    sc = size / 100
    return E("NestedArtboard", id=id or I(), artboardId=ICONS[key] if key in ICONS else key, name=name,
             x=x - size / 2, y=y - size / 2, scaleX=sc, scaleY=sc)


def prism_bar(name, w, h, x=0, y=0, gap=2, id=None, ids=None):
    seg = (w - gap * 5) / 6
    kids = []
    for k, c in enumerate(PRISM):
        sid = I()
        if ids is not None:
            ids.append(sid)
        kids.append(rect(f"Seg{k}", seg, h, c, x=k * (seg + gap), y=0, ox=0, oy=0, id=sid))
    return node(name, *kids, x=x, y=y, id=id)


def arrow_glyph(kind, color, size):
    """Two small triangles (up/down or left/right) in a fixed slot."""
    h = size / 2
    t = size * 0.28
    if kind == "UD":
        a = [(h - t, h - 2), (h, h - 2 - t), (h + t, h - 2)]
        b = [(h - t, h + 2), (h, h + 2 + t), (h + t, h + 2)]
    else:
        a = [(h - 2, h - t), (h - 2 - t, h), (h - 2, h + t)]
        b = [(h + 2, h - t), (h + 2 + t, h), (h + 2, h + t)]
    slot = box("Arrows", size, size)
    slot(node("A", poly("A1", a, color), poly("A2", b, color)))
    return slot


def brackets(name, w, h, L=18, t=2, color=AMBER, id=None):
    """Four corner L-brackets in a Node, origin top-left of a w x h frame."""
    kids = []
    for cx, cy, sx, sy in ((0, 0, 1, 1), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)):
        kids.append(poly("B", [(cx, cy + sy * L), (cx, cy), (cx + sx * L, cy)], stroke_color=color,
                         stroke_w=t, closed=False))
    return node(name, *kids, id=id)


def barber_prism(name, w, h, seg=60, gap=2, x=0, y=0, id=None):
    """Straight prism segments (6 colours repeating, like prism_bar) in a strip
    long enough to slide left continuously; the caller clips it to the bar.
    One colour cycle = 6 * (seg + gap) px, so the scroll loops seamlessly."""
    kids = []
    n = int(w / (seg + gap)) + 2
    for k in range(n):
        kids.append(rect(f"Seg{k}", seg, h, PRISM[k % len(PRISM)], x=k * (seg + gap), y=0, ox=0, oy=0))
    return node(name, *kids, x=x, y=y, id=id)


def hazard(name, w, h, color=AMBER, step=14, x=0, y=0, id=None):
    kids = []
    n = int((w + h) / step) + 1
    for k in range(n):
        x0 = k * step - h
        kids.append(poly("S", [(x0, h), (x0 + step * 0.5, h), (x0 + h + step * 0.5, 0), (x0 + h, 0)], color))
    cl_src = I()
    clip_shape = E("Shape", id=cl_src, name="ClipR")(E("Rectangle", name="R", width=w, height=h, originX=0, originY=0))
    return node(name, E("ClippingShape", sourceId=cl_src, name="Clip"), clip_shape, *kids, x=x, y=y, id=id)


def sm(name, *parts, id=None):
    return E("StateMachine", id=id or I(), name=name)(*parts)


def seed_layer(target, cond_el=None):
    """A layer that focuses `target` once the machine starts (optionally gated)."""
    hold = Anim("Seed Hold", 1)
    a = I()
    b = I()
    if cond_el is None:
        return layer("Seed", a, [state(hold, E("FocusActionTarget", targetId=target), id=a)]), [hold]
    return layer("Seed", a, [state(hold, go(b, cond_el), id=a),
                             state(hold, E("FocusActionTarget", targetId=target), id=b)]), [hold]


def artboard(aid, name, w, h, vm_id=VM, vmi=VMI, x=0, y=0, comp=True, sm_id=None, flex=None, clip=True):
    st = style(**(flex or {}))
    return E("Artboard", id=aid, name=name, width=w, height=h, x=x, y=y, isComponent=comp or None,
             viewModelId=vm_id, viewModelInstanceId=vmi, defaultStateMachineId=sm_id, styleId=st.attrs["id"],
             clip=clip)(st)


# ================================================================== HUB MENU
HUB_W, HUB_H, ROW_H, ROW_PITCH = 560, 480, 110, 120


def hub_menu() -> E:
    smid = I()
    ab = artboard(AB_HUB, "Hub Menu", HUB_W, HUB_H, x=0, y=1100, sm_id=smid)
    surface = I()
    ab(E("FocusData", canFocus=False, id=I()))
    anims: list[Anim] = []
    layers = []
    listeners = []
    rows = []
    for k, (label, sub, ico) in enumerate(SECTIONS):
        y0 = k * ROW_PITCH
        bg, bgc, bar, idx_c, lab_c, sub_c, chev, chev_c, shim, chip_c, ring = (I() for _ in range(11))
        lab_t = I()
        r = node(f"Row {label}", y=y0, id=(row_n := I()))
        clip_src = I()
        r(
            E("ClippingShape", sourceId=clip_src, name="Row Clip"),
            E("Shape", id=clip_src, name="Clip Rect", x=HUB_W / 2, y=ROW_H / 2)(
                E("Rectangle", name="R", width=HUB_W, height=ROW_H)),
            mono("Index", f"0{k + 1}", 14, FAINT, lp=False, x=26, y=14, cid=idx_c),
            mono("Tag", "// :: pod_" + label.lower(), 11, FAINT, lp=False, x=330, y=16, opacity=0.9),
            orb("Label", label, 42, WHITE, lp=False, x=60, y=30, cid=lab_c, id=lab_t),
            inter("Sub", sub, 15, MUTED, 500, lp=False, x=62, y=80, cid=sub_c),
            icon("Icon", ico, 40, x=495, y=55),
            rect("Chip", 64, 64, BLACK, x=495, y=55, cid=chip_c, id=(chip_n := I())),
            E("Shape", id=ring, name="Ring", x=495, y=55)(E("Ellipse", name="E", width=78, height=78),
                                                         stroke(AMBER, 2, cap="round", trim=E("TrimPath", name="Trim", start=0, end=0.25, modeValue=1))),
            poly("Chevron", [(0, -9), (9, 0), (0, 9)], stroke_color=FAINT, stroke_w=3, closed=False, x=440, y=55,
                 id=chev, cap="square"),
            rect("Shimmer", 70, ROW_H * 1.6, "55FFFFFF", x=-120, y=55, rotation=0.4, id=shim),
            rect("Bar", 8, ROW_H, "FF3F3628", x=0, y=0, ox=0, oy=0, id=bar, cid=(bar_c := I())),
        )
        bgshape = E("Shape", id=bg, name="Row Surface", x=HUB_W / 2, y=ROW_H / 2)(
            E("FocusData", id=I()),
            E("Rectangle", name="R", width=HUB_W, height=ROW_H),
            stroke(LINE, 2),
            fill("E6141414", bgc))
        # chevron stroke colour id
        chev_stroke = r.kids[-3].kids[1]  # Stroke
        chev_stroke.kids[0].attrs["id"] = chev_c
        r(bgshape)
        rows.append(r)

        off = Anim(f"Row{k} Off", 1)
        off.hold(bgc, K_COLOR, "E6141414", "c").hold(lab_c, K_COLOR, "FFE6DDCC", "c").hold(sub_c, K_COLOR, MUTED, "c")
        off.hold(idx_c, K_COLOR, FAINT, "c").hold(chev_c, K_COLOR, FAINT, "c").hold(chev, K_X, 440)
        off.hold(shim, K_OP, 0).hold(bar, K_RW, 4).hold(chip_c, K_COLOR, BLACK, "c").hold(ring, K_OP, 0)
        off.hold(bar_c, K_COLOR, "FF3F3628", "c")
        off.hold(lab_t, K_X, 60)
        onA = Anim(f"Row{k} On", 120, loop="loop")
        onA.hold(bgc, K_COLOR, AMBER, "c").hold(lab_c, K_COLOR, BLACK, "c").hold(sub_c, K_COLOR, "CC000000", "c")
        onA.hold(idx_c, K_COLOR, BLACK, "c").hold(chev_c, K_COLOR, BLACK, "c").hold(bar, K_RW, 14)
        onA.hold(chip_c, K_COLOR, BLACK, "c").hold(ring, K_OP, 1).hold(lab_t, K_X, 72)
        onA.hold(bar_c, K_COLOR, PRISM[(k * 2 + 1) % 6], "c")
        onA.key(chev, K_X, [(0, 444), (30, 456), (60, 444), (90, 456), (120, 444)])
        onA.key(shim, K_X, [(0, -120, "linear"), (70, HUB_W + 120, "hold"), (120, HUB_W + 120)], ease="linear")
        onA.hold(shim, K_OP, 1)
        onA.key(ring, K_ROT, [(0, 0, "linear"), (120, TAU)], ease="linear")
        anims += [off, onA]
        # ---- arrival (tertiary motion inside the blade): when the camera
        # lands at the hub, each row slides in from the left with a glitch
        # flicker and its icon chip pops, staggered by row
        d = 10 + k * 7
        rin = Anim(f"Row{k} In", d + 40)
        rin.key(row_n, K_X, [(0, -70), (d, -70), (d + 26, 6), (d + 36, 0)], curve=EASE_OUT)
        # (0.001, not 0: a fully transparent ancestor makes the row unfocusable,
        # and the hub seeds focus on row 1 while it is still hidden)
        rin.key(row_n, K_OP, [(0, 0.001, "hold"), (d, 0.001, "hold"), (d + 2, 0.7, "hold"), (d + 4, 0.2, "hold"),
                              (d + 6, 1, "hold"), (d + 9, 0.6, "hold"), (d + 11, 1)])
        for kk in (K_SX, K_SY):
            rin.key(chip_n, kk, [(0, 0), (d + 8, 0), (d + 22, 1.18), (d + 32, 1)], curve=BACK_OUT)
        rhide = Anim(f"Row{k} Away", 1)
        rhide.hold(row_n, K_OP, 0.001).hold(row_n, K_X, -70).hold(chip_n, K_SX, 0).hold(chip_n, K_SY, 0)
        rshown = Anim(f"Row{k} Here", 1)
        rshown.hold(row_n, K_OP, 1).hold(row_n, K_X, 0).hold(chip_n, K_SX, 1).hold(chip_n, K_SY, 1)
        # leaving for the start screen: the text encrypts out first (Decrypt
        # converter), then the row glitches off and slides away, staggered
        do_ = 26 + k * 4
        rout = Anim(f"Row{k} Out", do_ + 18)
        rout.key(row_n, K_OP, [(0, 1, "hold"), (do_, 1, "hold"), (do_ + 2, 0.3, "hold"), (do_ + 4, 0.9, "hold"),
                               (do_ + 6, 0.2, "hold"), (do_ + 8, 0.6, "hold"), (do_ + 10, 0.001)])
        rout.key(row_n, K_X, [(0, 0), (do_ - 6, 0), (do_ + 14, -60)], curve=EASE_IN_OUT)
        for kk in (K_SX, K_SY):
            rout.key(chip_n, kk, [(0, 1), (do_ - 10, 1), (do_ + 2, 1.15), (do_ + 12, 0)], curve=EASE_IN_OUT)
        anims += [rin, rhide, rshown, rout]
        a0, a1, a2, a3 = I(), I(), I(), I()
        layers.append(layer(f"Row {label} Arrive", a0, [
            state(rhide, go(a1, cond(vp("arrived"), "bool", True), cond(vp("mode"), "num", 1)), id=a0, x=160, y=1200 + k * 200),
            state(rin, go(a2, exit_pct=100), go(a3, cond(vp("mode"), "num", 0)), id=a1, x=420, y=1200 + k * 200, reset=True),
            state(rshown, go(a3, cond(vp("mode"), "num", 0)), id=a2, x=680, y=1200 + k * 200),
            state(rout, go(a0, exit_pct=100), id=a3, x=940, y=1200 + k * 200, reset=True),
        ]))
        s_off, s_on = I(), I()
        layers.append(layer(f"Row {label}", s_off, [
            state(off, go(s_on, cond(vp("section"), "num", k), ms=140), id=s_off, x=160, y=k * 200),
            state(onA, go(s_off, cond(vp("section"), "num", k, op="notEqual"), ms=220), id=s_on, x=420, y=k * 200),
        ]))
        listeners += [
            listener(bg, f"Focus {label}", [on("focus")], [write(vp("section"), "num", k)]),
            E("StateMachineListenerSingle", targetId=bg, listenerTypeValue="enter", name=f"Hover {label}")(
                E("FocusActionTarget", targetId=bg)),
            E("StateMachineListenerSingle", targetId=bg, listenerTypeValue="click", name=f"Pick {label}")(
                E("FocusActionTarget", targetId=bg), fire(vp("accept"))),
        ]
        if k == 0:
            first = bg
    for r in rows:
        ab(r)
    hold = Anim("Hub Idle", 1)
    anims.append(hold)
    idle, dn, up = I(), I(), I()
    router = layer("Router", idle, [
        state(hold, go(dn, cond(vp("navDown"), "trig"), cond(vp("mode"), "num", 1)),
              go(up, cond(vp("navUp"), "trig"), cond(vp("mode"), "num", 1)), id=idle, x=160, y=900),
        state(hold, E("FocusActionTraversal", traversalKind="down"), go(idle), id=dn, x=420, y=820),
        state(hold, E("FocusActionTraversal", traversalKind="up"), go(idle), id=up, x=420, y=980),
    ])
    seed, seed_anims = seed_layer(first)
    anims += seed_anims
    ab(sm("Hub SM", *listeners, router, seed, *layers, id=smid))
    for a in anims:
        ab(a.el)
    return ab


# ================================================================== CORE SKIN (equirect 2:1)
def core_skin() -> E:
    W, H = 1024, 512
    smid = I()
    ab = artboard(AB_CORE, "Core Skin", W, H, x=700, y=1100, sm_id=smid)
    spin = Anim("Core Live", 480, loop="loop")
    kids = []
    # brand marks + gamertag at two longitudes
    for k, u in enumerate((0.25, 0.75)):
        cx = W * u
        rings = []
        for j, (rad, wdt, col, sp) in enumerate(((150, 3, "B3E0CBA6", 1), (176, 2, "66E0CBA6", -1.5), (200, 6, "40E0CBA6", 0.7))):
            rid = I()
            trim_id = I()
            rings.append(E("Shape", id=rid, name=f"Ring{j}", x=cx, y=H / 2)(
                E("Ellipse", name="E", width=rad * 2, height=rad * 1.4),
                stroke(col, wdt, cap="round", trim=E("TrimPath", id=trim_id, name="T", start=0, end=0.3 + 0.2 * j, modeValue=1))))
            spin.key(rid, K_ROT, [(0, 0, "linear"), (480, TAU * sp)], ease="linear")
            spin.key(trim_id, K_TRIM_END, [(0, 0.2), (240, 0.75), (480, 0.2)], curve=EASE_IN_OUT)
        mark = I()
        kids += [
            orb("Tag", "PILOT_01", 34, AMBER, lp=False, x=cx - 140, y=H / 2 + 108, bind=vp("gamertag"), align="center",
                spacing=3),
            mono("Ver", "// :: RIVEBOX CORE", 16, "FFFFE2B0", lp=False, x=cx - 90, y=H / 2 - 150),
            E("NestedArtboard", id=mark, artboardId=BR_BRANDMARK, name="Mark", x=cx - 110, y=H / 2 - 110,
              scaleX=2.2, scaleY=2.2),
            *rings,
        ]
        spin.key(mark, K_OP, [(0, 1), (60, 0.55), (120, 1), (360, 1), (390, 0.4, "hold"), (396, 1), (480, 1)])
    # latitude lines + meridian ticks
    for j in range(1, 8):
        kids.append(rect(f"Lat{j}", W, 1.5, "33E0CBA6", x=W / 2, y=j * H / 8))
    for j in range(32):
        kids.append(rect(f"Tick{j}", 2, 18 if j % 4 else 40, "59E0CBA6", x=j * W / 32, y=H / 2))
    # blinking data cells
    for j in range(40):
        cid = I()
        x = (j * 97) % W
        y = 40 + (j * 53) % (H - 80)
        kids.append(rect(f"Cell{j}", 10, 10, PRISM[j % 6], x=x, y=y, id=cid, opacity=0))
        ph = (j * 23) % 480
        spin.key(cid, K_OP, [(0, 0, "hold"), (ph, 1, "hold"), (min(479, ph + 40), 0, "hold"), (480, 0)])
    # prism equator band, scrolling around the sphere (two copies wrap)
    band = I()
    seg = W / 6
    bkids = []
    for rep in range(2):
        for k, c in enumerate(PRISM):
            bkids.append(rect("P", seg - 4, 14, c, x=rep * W + k * seg, y=0, ox=0, oy=0))
    kids.append(node("Prism Band", *bkids, x=0, y=H / 2 - 7, id=band))
    spin.key(band, K_X, [(0, 0, "linear"), (480, -W)], ease="linear")
    # polar caps glow
    for y0, y1 in ((0, 70), (H, H - 70)):
        g = E("Shape", name="Cap", x=W / 2, y=(y0 + y1) / 2)(
            E("Rectangle", name="R", width=W, height=70),
            E("Fill", name="F")(E("LinearGradient", name="G", startX=0, startY=(y0 - y1) / 2, endX=0, endY=(y1 - y0) / 2)(
                E("GradientStop", colorValue="66E0CBA6", position=0), E("GradientStop", colorValue="00E0CBA6", position=1))))
        kids.append(g)
    kids.append(rect("Base", W, H, "66120A02", x=W / 2, y=H / 2))
    ab(*kids)
    s = I()
    ab(sm("Core SM", layer("Live", s, [state(spin, id=s, x=160, y=0)]), id=smid))
    ab(spin.el)
    return ab


# ================================================================== TICKER
def ticker() -> E:
    W, H = 2048, 64
    smid = I()
    ab = artboard(AB_TICK, "Ticker", W, H, x=1800, y=1100, sm_id=smid)
    anim = Anim("Scroll", 900, loop="loop")
    msg = "  //  RIVEBOX ONLINE  //  PLAYER = "
    nid = I()
    blocks = []
    for rep in range(3):
        tid = I()
        sid = I()
        t = E("Text", id=tid, name="Line", x=rep * 1024, y=12, wrapValue="noWrap")(
            E("TextStylePaint", id=sid, name="TS", fontSize=30, fontAssetId=F_MONO, letterSpacing=3)(fill(AMBER)),
            E("TextValueRun", styleId=sid, text=msg, name="A"),
            E("TextValueRun", styleId=sid, text="PILOT_01", name="B")(bind(vp("gamertag"), K_TEXT)),
            E("TextValueRun", styleId=sid, text="  //  runtime_state = ACTIVE  //  60 FPS", name="C"))
        blocks.append(t)
    ab(node("Track", *blocks, id=nid))
    anim.key(nid, K_X, [(0, 0, "linear"), (900, -1024)], ease="linear")
    s = I()
    ab(sm("Ticker SM", layer("Scroll", s, [state(anim, id=s)]), id=smid))
    ab(anim.el)
    return ab


# ================================================================== LIST ROWS
def list_row(aid, name, vm_id, vmi, paths, w, h, x, y, kind) -> E:
    smid = I()
    ab = artboard(aid, name, w, h, vm_id=vm_id, vmi=vmi, x=x, y=y, sm_id=smid, clip=False)
    root, bgc, bar, t_c, i_c, g_c, chev = I(), I(), I(), I(), I(), I(), I()
    rb = box("Row", w, h, id=root, flexDirectionValue="row", layoutAlignmentType="centerLeft",
             paddingLeft=18, paddingRight=18, gapHorizontal=14)
    rb(E("FocusData", id=I()))
    rb(fill("FF101010", bgc))
    rb(stroke(LINE, 1))
    rb(mono("Idx", "01", 14, FAINT, bind=paths["index"], conv=CONV_IDX, cid=i_c))
    if kind == "game":
        dot = box("Dot", 10, 10)
        dot(fill(AMBER, bind=paths["color"]))
        rb(dot)
    rb(orb("Title", "TITLE", 22, WHITE, 700, bind=paths["title"], cid=t_c))
    rb(spacer())
    rb(mono("Meta", "META", 13, MUTED, bind=paths["genre" if kind == "game" else "artist"], cid=g_c))
    rb(poly("Chev", [(0, -6), (6, 0), (0, 6)], stroke_color=BLACK, stroke_w=2.5, closed=False, id=chev, opacity=0))
    ab(rb)
    ab(rect("Bar", 4, h, AMBER, x=0, y=0, ox=0, oy=0, id=bar))
    off = Anim("Off", 1)
    off.hold(bgc, K_COLOR, "FF101010", "c").hold(t_c, K_COLOR, WHITE, "c").hold(i_c, K_COLOR, FAINT, "c")
    off.hold(g_c, K_COLOR, MUTED, "c").hold(bar, K_RW, 4).hold(chev, K_OP, 0)
    onA = Anim("On", 60, loop="loop")
    onA.hold(bgc, K_COLOR, AMBER, "c").hold(t_c, K_COLOR, BLACK, "c").hold(i_c, K_COLOR, BLACK, "c")
    onA.hold(g_c, K_COLOR, "B3000000", "c").hold(bar, K_RW, 10).hold(chev, K_OP, 1)
    onA.key(bar, K_OP, [(0, 1), (30, 0.4), (60, 1)])
    s0, s1 = I(), I()
    writes_focus = [write(paths["focused"], "bool", True), write_from(paths["index"], "num", paths["hSel"]),
                    write_from(paths["title"], "str", paths["hTitle"])]
    if kind == "game":
        rid_c = I()
        writes_focus += [
            write_from(paths["genre"], "str", paths["hGenre"]),
            write_from(paths["year"], "str", paths["hYear"]),
            write_from(paths["blurb"], "str", paths["hBlurb"]),
            E("ListenerViewModelChange", fromViewModelProperty=True, fromDataBindId=rid_c)(
                E("BindablePropertyColor")(bind(paths["color"], 638, id=rid_c), bind(paths["hColor"], 638, direction=True))),
            write_from(paths["blocks"], "num", paths["hBlocks"]),
        ]
    else:
        writes_focus += [write_from(paths["artist"], "str", paths["hArtist"])]
    writes_focus.append(fire(paths["hPing"]))
    hold = Anim("Seed Hold", 1)
    ab(sm("Row SM",
          listener(root, "Focus", [on("focus")], writes_focus),
          listener(root, "Blur", [on("blur")], [write(paths["focused"], "bool", False)]),
          E("StateMachineListenerSingle", targetId=root, listenerTypeValue="down", name="Press")(
              E("FocusActionTarget", targetId=root)),
          layer("Focus", s0, [state(off, go(s1, cond(paths["focused"], "bool", True), ms=120), id=s0, x=160, y=0),
                              state(onA, go(s0, cond(paths["focused"], "bool", False), ms=200), id=s1, x=420, y=0)]),
          id=smid))
    # staggered entrance: each row flies in when its screen opens, delayed by
    # its own index (one gated state per index -> a real cascade, no script)
    sec_i = 0 if kind == "game" else 1
    hid = Anim("Row Hidden", 1)
    hid.hold(root, K_OP, 0).hold(root, K_X, 90).hold(bar, K_OP, 0)
    shown = Anim("Row Shown", 1)
    shown.hold(root, K_OP, 1).hold(root, K_X, 0).hold(bar, K_OP, 1)
    ent_h, ent_s = I(), I()
    gate = [cond(paths["hMode"], "num", 2)]
    away = [go(ent_h, cond(paths["hMode"], "num", 2, op="notEqual"))]
    enters, ent_states = [], []
    for k in range(8):
        d = 14 + k * 4
        a = Anim(f"Row In {k}", d + 26)
        a.key(root, K_OP, [(0, 0, "hold"), (d, 0, "hold"), (d + 2, 0.6, "hold"), (d + 4, 0.15, "hold"), (d + 6, 1)])
        a.key(root, K_X, [(0, 90), (d, 90), (d + 22, 0)], curve=EASE_OUT)
        a.key(bar, K_OP, [(0, 0, "hold"), (d + 8, 0, "hold"), (d + 10, 1)])
        enters.append(a)
        sid = I()
        ent_states.append(state(a, go(ent_s, exit_pct=100), *away, id=sid, x=420, y=200 + k * 60, reset=True))
    hidden_state = state(hid, *[go(st.attrs["id"], *gate, cond(paths["index"], "int", k))
                                for k, st in enumerate(ent_states)], id=ent_h, x=160, y=300)
    entrance = layer("Entrance", ent_h, [hidden_state, *ent_states, state(shown, *away, id=ent_s, x=680, y=300)])
    sm_el = [c for c in ab.kids if getattr(c, "tag", "") == "StateMachine"][-1]
    sm_el(entrance)
    for an in (off, onA, hold, hid, shown, *enters):
        ab(an.el)
    return ab


# ================================================================== CASE ART (atlas tile)
def case_art() -> E:
    W, H = 256, 360
    FW = 220  # front face; spine at 225..251
    smid = I()
    ab = artboard(AB_CASE, "Case Art", W, H, vm_id=VM_GAME, vmi=VM_GAME_DEF, x=4000, y=1100, sm_id=smid)
    shim = I()
    live = Anim("Case Live", 180, loop="loop")
    spine_t = I()
    ab(
        rect("Shine", 50, 520, "40FFFFFF", x=-80, y=H / 2, rotation=0.5, id=shim),
        orb("Title", "TITLE", 26, WHITE, 900, lp=False, x=16, y=150, bind=gp("title"), wrap=True, width=190,
            line_height=30),
        mono("Genre", "GENRE", 12, AMBER, lp=False, x=16, y=124, bind=gp("genre"), spacing=3),
        mono("Code", "CODE", 11, FAINT, lp=False, x=16, y=318, bind=gp("code")),
        mono("Year", "2026", 11, FAINT, lp=False, x=170, y=318, bind=gp("year")),
        E("NestedArtboard", artboardId=BR_LOGO, name="Logo", x=16, y=20, scaleX=0.36, scaleY=0.36),
        mono("Brand", "RIVEBOX", 11, WHITE, lp=False, x=62, y=28, spacing=4),
        mono("Brand2", "// :: game_disc", 9, FAINT, lp=False, x=62, y=44),
        hazard("Hazard", 188, 26, x=16, y=264),
        E("Shape", name="Band", x=FW / 2, y=96)(E("Rectangle", name="R", width=FW, height=8), fill(AMBER, bind=gp("color"))),
        # spine
        E("Text", id=spine_t, name="Spine Title", x=232, y=330, rotation=-1.5707964, wrapValue="noWrap")(
            E("TextStylePaint", id=(sid := I()), name="TS", fontSize=16, fontAssetId=F_ORB)(fill(BLACK),
                                                                                         E("TextStyleAxis", tag=WGHT, axisValue=900, name="W")),
            E("TextValueRun", styleId=sid, text="TITLE", name="R")(bind(gp("title"), K_TEXT))),
        E("Shape", name="Spine", x=238, y=H / 2)(E("Rectangle", name="R", width=26, height=H), fill(AMBER, bind=gp("color"))),
        E("Shape", name="Front", x=FW / 2, y=H / 2)(E("Rectangle", name="R", width=FW, height=H), stroke("FF333333", 2),
                                                   fill("FF0C0C0C")),
        rect("Base", W, H, BLACK, x=W / 2, y=H / 2),
    )
    live.key(shim, K_X, [(0, -80, "linear"), (60, 320, "hold"), (180, 320)], ease="linear")
    s = I()
    ab(sm("Case SM", layer("Live", s, [state(live, id=s)]), id=smid))
    ab(live.el)
    return ab


# ================================================================== SATELLITES (atlas of floating 3D panels)
SAT_W, SAT_H, SAT_CW, SAT_CH = 1040, 1000, 500, 310
SAT_CELLS = [(10 + c * 520, 10 + r * 330) for r in range(3) for c in range(2)]


def _sat_plate(x0, y0, kicker, title, kids):
    """One floating panel: dark glass plate, amber hairline, corner brackets, header."""
    w, h = SAT_CW, SAT_CH
    plate = E("Shape", name="Plate", x=w / 2, y=h / 2)(
        E("Rectangle", name="R", width=w, height=h),
        stroke("40E0CBA6", 1.5),
        E("Fill", name="F")(E("LinearGradient", name="G", startX=0, startY=-h / 2, endX=0, endY=h / 2)(
            E("GradientStop", colorValue="E60E0B07", position=0), E("GradientStop", colorValue="D9000000", position=1))))
    head = [
        mono("Kicker", kicker, 13, AMBER, lp=False, x=24, y=20, spacing=3),
        orb("Title", title, 22, WHITE, 900, lp=False, x=24, y=42),
        rect("Rule", w - 48, 1, "33E0CBA6", x=24, y=78, ox=0, oy=0),
    ]
    return node(f"Cell {kicker}", *kids, *head, brackets("Br", w - 12, h - 12, 16, 2, color="80E0CBA6"), plate, x=x0, y=y0)


def _bar(name, x, y, w, h, color, sid):
    """Horizontal meter: a track plus a fill whose scaleX (node sid) is keyed."""
    return node(name,
                node("Fill", rect("F", w, h, color, x=0, y=0, ox=0, oy=0), id=sid),
                rect("Track", w, h, "26FFFFFF", x=0, y=0, ox=0, oy=0), x=x, y=y)


def satellites() -> E:
    MONO = "FFD9CBB2"
    smid = I()
    ab = artboard(AB_SAT, "Satellites", SAT_W, SAT_H, x=0, y=3400, sm_id=smid, clip=True)
    layers, anims = [], []

    def loop(name, frames):
        a = Anim(name, frames, loop="loop")
        anims.append(a)
        sid = I()
        layers.append(layer(name, sid, [state(a, id=sid, x=160, y=len(layers) * 100)]))
        return a

    cells = []
    # 0 SYSTEM -------------------------------------------------------------
    sys_a = loop("System Live", 360)
    bars = []
    kids = [orb("Clock", "--:--", 64, WHITE, 900, lp=False, x=24, y=96, bind=vp("clock")),
            mono("Date", "FRI // 02.10.2026", 13, MUTED, lp=False, x=26, y=172, spacing=2)]
    for k, (lab, base) in enumerate((("CPU", 0.42), ("GPU", 0.66), ("MEM", 0.31))):
        sid = I()
        bars.append(sid)
        kids += [mono(f"L{k}", lab, 12, FAINT, lp=False, x=24, y=206 + k * 28, spacing=2),
                 _bar(f"Bar{k}", 80, 212 + k * 28, 300, 6, MONO, sid)]
        f = [(0, base), (70 + k * 13, base + 0.18), (150, base - 0.08), (230 + k * 9, base + 0.25), (360, base)]
        sys_a.key(sid, K_SX, f, curve=EASE_IN_OUT)
    kids.append(mono("Up", "UPTIME 04:12:55", 12, FAINT, lp=False, x=330, y=172))
    cells.append(_sat_plate(*SAT_CELLS[0], "SYSTEM // NV-RIVE", "CONSOLE STATUS", kids))
    # 1 NOW PLAYING ----------------------------------------------------------
    np_a = loop("Now Playing Live", 600)
    eq = []
    import math as _m
    kids = [orb("Track", "TRACK", 30, WHITE, 900, lp=False, x=24, y=96, bind=vp("trackTitle")),
            mono("Artist", "ARTIST", 13, MUTED, lp=False, x=26, y=136, bind=vp("trackArtist"), spacing=2)]
    for k in range(18):
        sid = I()
        eq.append(sid)
        kids.append(node(f"EQ{k}", rect("B", 14, 70, MONO if k % 5 else MONO, x=0, y=0, ox=0, oy=1), x=26 + k * 20,
                         y=250, id=sid))
        f = []
        for j in range(0, 601, 30):
            v = 0.15 + 0.85 * abs(_m.sin(k * 0.7 + j * 0.031 * (1 + (k % 3) * 0.35))) * (0.5 + 0.5 * abs(_m.sin(j * 0.011 + k)))
            f.append((j, round(v, 3)))
        np_a.key(sid, K_SY, f, curve=EASE_IN_OUT)
    prog = I()
    kids += [_bar("Progress", 24, 272, 452, 3, WHITE, prog), mono("T0", "01:12", 11, FAINT, lp=False, x=24, y=282),
             mono("T1", "04:05", 11, FAINT, lp=False, x=436, y=282)]
    np_a.key(prog, K_SX, [(0, 0.05, "linear"), (600, 1.0)], ease="linear")
    cells.append(_sat_plate(*SAT_CELLS[1], "NOW PLAYING", "SOUNDTRACK", kids))
    # 2 FRIENDS ----------------------------------------------------------------
    fr_a = loop("Friends Live", 480)
    sel = I()
    names = [("STATE_MACHINE", "SPRAYWAVE", True), ("BONE_RIG", "ROCKET SQUADRON", True),
             ("MESH_DEFORM", "OFFLINE", False), ("NESTED_ART", "GLASSLINE GP", True)]
    kids = [node("Sel", rect("S", 452, 40, "1FE0CBA6", x=0, y=0, ox=0, oy=0), rect("E", 3, 40, MONO, x=0, y=0, ox=0, oy=0),
                 x=24, y=96, id=sel)]
    dots = []
    for k, (n, gname, on_) in enumerate(names):
        d = I()
        dots.append((d, on_))
        kids += [node("Dot", E("Shape", name="D", x=0, y=0)(E("Ellipse", name="E", width=10, height=10),
                                                         fill(MONO if on_ else FAINT)), x=40, y=116 + k * 48, id=d),
                 orb(f"N{k}", n, 17, WHITE if on_ else FAINT, 700, lp=False, x=58, y=106 + k * 48),
                 mono(f"G{k}", gname, 12, MUTED if on_ else FAINT, lp=False, x=330, y=110 + k * 48, spacing=2)]
    f = []
    for k, fr in enumerate((0, 120, 240, 360)):
        f += [(fr, 96 + k * 48, "hold"), (fr + 100, 96 + k * 48)]
    fr_a.key(sel, K_Y, [(0, 96), (100, 96), (120, 144), (220, 144), (240, 240), (340, 240), (360, 96), (480, 96)],
             curve=EASE_OUT)
    for d, on_ in dots:
        if on_:
            fr_a.key(d, K_OP, [(0, 1), (60, 0.35), (120, 1)] * 1 + [(240, 0.35), (360, 1), (480, 1)], curve=EASE_IN_OUT)
    cells.append(_sat_plate(*SAT_CELLS[2], "FRIENDS // 3 ONLINE", "RIVE NET", kids))
    # 3 MILESTONE --------------------------------------------------------------
    ac_a = loop("Milestone Live", 420)
    badge = I()
    shine = I()
    g, rid = reveal_mod("Milestone Reveal", 18)
    hexpts = [(60 * _m.cos(a), 60 * _m.sin(a)) for a in [i * _m.pi / 3 + _m.pi / 6 for i in range(6)]]
    kids = [
        node("Badge", icon("Bolt", "lightning", 56, 0, 0),
             poly("Hex", hexpts, AMBER), poly("Ring", [(p[0] * 1.18, p[1] * 1.18) for p in hexpts], None,
                                              stroke_color="59E0CBA6", stroke_w=2), x=96, y=196, id=badge),
        mono("K2", "MILESTONE REACHED", 12, MONO, lp=False, x=190, y=130, spacing=3),
        orb("AT", "FIRST LISTENER", 24, WHITE, 900, lp=False, x=190, y=152, modifiers=[g]),
        inter("AD", "Bound a view model to a 3D surface.", 14, MUTED, lp=False, x=190, y=190),
        orb("GS", "+50 XP", 30, AMBER, 900, lp=False, x=190, y=224),
        rect("Shine", 40, 360, "26FFFFFF", x=-60, y=SAT_CH / 2, rotation=0.5, id=shine),
    ]
    ac_a.key(badge, K_SX, [(0, 0.0, "hold"), (20, 0.0), (44, 1.12), (60, 1.0), (380, 1.0), (410, 0.0, "hold"), (420, 0.0)],
             curve=BACK_OUT)
    ac_a.key(badge, K_SY, [(0, 0.0, "hold"), (20, 0.0), (44, 1.12), (60, 1.0), (380, 1.0), (410, 0.0, "hold"), (420, 0.0)],
             curve=BACK_OUT)
    ac_a.key(badge, K_ROT, [(0, -1.2), (20, -1.2), (70, 0.0), (420, 0.0)], curve=EASE_OUT)
    key_reveal(ac_a, rid, 50, 40)
    ac_a.key(shine, K_X, [(0, -80, "hold"), (110, -80, "linear"), (170, 580, "hold"), (420, 580)], ease="linear")
    csrc = I()
    kids = [E("ClippingShape", sourceId=csrc, name="Cell Clip"),
            E("Shape", id=csrc, name="CellR")(E("Rectangle", name="R", width=SAT_CW, height=SAT_CH, originX=0, originY=0)),
            node("Clipped", *kids)]
    cells.append(_sat_plate(*SAT_CELLS[3], "PLAYER XP // 12,450", "MILESTONE", kids))
    # 4 NETWORK ----------------------------------------------------------------
    nw_a = loop("Network Live", 300)
    spark = I()
    pts = []
    for k in range(0, 49):
        x = k * 19
        y = 40 - (14 * _m.sin(k * 0.8) + 9 * _m.sin(k * 2.3 + 1) + (18 if k % 11 == 0 else 0))
        pts.append((x, round(y, 1)))
    line = poly("Line", pts, None, closed=False, stroke_color=MONO, stroke_w=2)
    clip_src = I()
    kids = [
        orb("Ping", "12 MS", 44, WHITE, 900, lp=False, x=24, y=94),
        mono("PL", "LATENCY // US-WEST", 12, MUTED, lp=False, x=26, y=152, spacing=2),
        mono("Up", "UP 4.2 MB/S", 12, FAINT, lp=False, x=330, y=104, spacing=2),
        mono("Dn", "DN 88.0 MB/S", 12, FAINT, lp=False, x=330, y=124, spacing=2),
        node("Spark", E("ClippingShape", sourceId=clip_src, name="Clip"),
             E("Shape", id=clip_src, name="ClipR")(E("Rectangle", name="R", width=452, height=90, originX=0, originY=0)),
             node("Scroll", line, id=spark), rect("Base", 452, 1, "33E0CBA6", x=0, y=80, ox=0, oy=0), x=24, y=186),
    ]
    nw_a.key(spark, K_X, [(0, 0, "linear"), (300, -456)], ease="linear")
    cells.append(_sat_plate(*SAT_CELLS[4], "NETWORK // ONLINE", "CONNECTED", kids))
    # 5 PLAYER -----------------------------------------------------------------
    pl_a = loop("Player Live", 480)
    trim = I()
    xp = I()
    kids = [
        node("Lvl", E("Shape", name="Arc", x=0, y=0, rotation=-1.5707964)(
            E("Ellipse", name="E", width=150, height=150),
            stroke(MONO, 8, cap="round", trim=E("TrimPath", id=trim, name="T", start=0, end=0.6, modeValue=1))),
             E("Shape", name="Track", x=0, y=0)(E("Ellipse", name="E", width=150, height=150), stroke("26FFFFFF", 8)),
             E("NestedArtboard", artboardId=BR_LOGO, name="Logo", x=-30, y=-30, scaleX=0.6, scaleY=0.6), x=110, y=196),
        orb("Tag", "PILOT_01", 26, WHITE, 900, lp=False, x=214, y=124, bind=vp("gamertag")),
        mono("Lv", "LEVEL 42 // ANIMATOR", 12, MONO, lp=False, x=216, y=162, spacing=2),
        _bar("XP", 216, 196, 260, 5, MONO, xp),
        mono("XPL", "XP 8,420 / 10,000", 11, FAINT, lp=False, x=216, y=212),
    ]
    pl_a.key(trim, K_TRIM_END, [(0, 0.1), (200, 0.84), (420, 0.84), (480, 0.1)], curve=EASE_IN_OUT)
    pl_a.key(xp, K_SX, [(0, 0.2), (200, 0.84), (420, 0.84), (480, 0.2)], curve=EASE_IN_OUT)
    cells.append(_sat_plate(*SAT_CELLS[5], "PROFILE", "PLAYER ONE", kids))

    ab(*cells)
    ab(sm("Satellites SM", *layers, id=smid))
    for a in anims:
        ab(a.el)
    return ab

# ===== SPLIT: sections


# ================================================================== SECTION SCREENS
SW, SH = 1100, 620


def reveal_mod(name="Reveal", y=24):
    """Per-glyph rise-in. Returns (group element, range id) — key modifyFrom 0->1 to reveal."""
    rid = I()
    g = E("TextModifierGroup", id=I(), name=name, modifyOpacity=True, modifyTranslation=True, invertOpacity=True,
          opacity=0, y=y)(E("TextModifierRange", id=rid, name="Sweep", modifyFrom=1, modifyTo=1.2,
                            falloffFrom=1.15, falloffTo=1.2))
    return g, rid


def key_reveal(anim: Anim, rid: str, start: int, dur: int):
    anim.key(rid, K_MOD_FROM, [(0, -0.2, "hold"), (start, -0.2), (start + dur, 1.0)], curve=EASE_OUT)
    anim.key(rid, K_FALL_FROM, [(0, 0.0, "hold"), (start, 0.0), (start + dur, 1.2)], curve=EASE_OUT)
    anim.key(rid, K_MOD_TO, [(0, 1.2, "hold")])
    anim.key(rid, K_FALL_TO, [(0, 1.2, "hold")])


def screen_shell(aid, idx, title, kicker, ico, sm_id, x, y):
    """Common chrome for a section screen. Returns (artboard, content box, ids)."""
    ab = artboard(aid, f"Screen {title.title()}", SW, SH, x=x, y=y, sm_id=sm_id,
                  flex={"flexDirectionValue": "column", "paddingLeft": 40, "paddingRight": 40, "paddingTop": 30,
                        "paddingBottom": 26, "gapVertical": 16})
    ids = {}
    ab(E("FocusData", canFocus=False, id=I()))
    # header
    hdr = box("Header", layoutWidthScaleType="fill", flexDirectionValue="row", layoutAlignmentType="centerLeft",
              gapHorizontal=18)
    chip = box("Icon Chip", 64, 64, layoutAlignmentType="center")
    chip(fill(AMBER))
    chip(nested("Glyph", ICONS[ico], 40, 40))
    hdr(chip)
    tcol = box("Titles", flexDirectionValue="column", gapVertical=2)
    g, rid = reveal_mod()
    ids["title_rev"] = rid
    tcol(mono("Kicker", kicker, 13, AMBER, spacing=3))
    tcol(orb("Title", title, 54, WHITE, 900, modifiers=[g]))
    hdr(tcol)
    hdr(spacer())
    rcol = box("Readout", flexDirectionValue="column", gapVertical=4, layoutAlignmentType="topRight")
    rcol(mono("R1", f"// :: section_index = {idx + 1} / 4", 12, FAINT))
    rcol(mono("R2", "runtime_state = ACTIVE", 12, FAINT))
    pb = box("Prism", 180, 6)
    pb(prism_bar("Bar", 180, 6))
    rcol(pb)
    hdr(rcol)
    ab(hdr)
    rule = box("Rule", 0, 2, layoutWidthScaleType="fill")
    rule(fill(LINE))
    ab(rule)
    content = box("Content", layoutWidthScaleType="fill", layoutHeightScaleType="fill", flexDirectionValue="row",
                  gapHorizontal=28)
    ab(content)
    foot = box("Footer", layoutWidthScaleType="fill", flexDirectionValue="row", layoutAlignmentType="centerLeft",
               gapHorizontal=22)
    for glyph, label in (("ENTER", "SELECT"), ("ESC", "BACK"), ("UD", "NAVIGATE"), ("LR", "SECTION")):
        b = box("Prompt", flexDirectionValue="row", layoutAlignmentType="centerLeft", gapHorizontal=8)
        btn = (box("Btn", 26, 26, layoutAlignmentType="center", cornerRadiusTL=13) if glyph in ("UD", "LR") else
               box("Btn", 0, 26, layoutAlignmentType="center", cornerRadiusTL=5, paddingLeft=8, paddingRight=8))
        btn(stroke(AMBER, 2), arrow_glyph(glyph, AMBER, 14) if glyph in ("UD", "LR") else mono("G", glyph, 12, AMBER))
        b(btn, mono("L", label, 12, MUTED, spacing=2))
        foot(b)
    foot(spacer())
    foot(mono("Clock", "--:--", 13, FAINT, bind=vp("clock")))
    ab(foot)
    # glass plate behind everything (drawn last = behind)
    frame = node("Frame", brackets("Brackets", SW - 16, SH - 16, 26, 3, color="99E0CBA6"), x=8, y=8)
    ab(frame)
    ab(E("Shape", name="Plate", x=SW / 2, y=SH / 2)(
        E("Rectangle", name="R", width=SW, height=SH),
        stroke("33E0CBA6", 2),
        E("Fill", name="F")(E("LinearGradient", name="G", startX=0, startY=-SH / 2, endX=0, endY=SH / 2)(
            E("GradientStop", colorValue="F20A0A0A", position=0), E("GradientStop", colorValue="E6000000", position=1)))))
    ids["frame"] = frame.attrs["id"]
    ids["content"] = content.attrs["id"]
    ids["header"] = hdr.attrs["id"]
    return ab, content, ids


def screen_flow(idx, ids, extra_in=None, first=None):
    """Glitch-in layer: Hidden -> In (when this screen becomes active) -> Hold -> Hidden."""
    hide = Anim("Hidden", 1)
    hide.hold(ids["content"], K_OP, 0).hold(ids["header"], K_OP, 0).hold(ids["frame"], K_OP, 0)
    key_reveal(hide, ids["title_rev"], 0, 1)
    hide.hold(ids["title_rev"], K_MOD_FROM, -0.2)
    inn = Anim("In", 50)
    # brand glitch: 0 -> .2 -> 1 -> .5 -> 1 on hold keys
    for oid, d in ((ids["frame"], 0), (ids["header"], 4), (ids["content"], 10)):
        inn.key(oid, K_OP, [(0, 0, "hold"), (d + 2, 0.2, "hold"), (d + 5, 1, "hold"), (d + 8, 0.5, "hold"),
                            (d + 11, 1, "hold"), (50, 1)])
    key_reveal(inn, ids["title_rev"], 4, 34)
    inn.key(ids["content"], K_Y, [(0, 40), (10, 40), (36, 0)], curve=EASE_OUT)
    if extra_in:
        extra_in(inn)
    hold = Anim("Shown", 1)
    shown_kids = [E("FocusActionTarget", targetId=first)] if first else [E("FocusActionTraversal", traversalKind="next")]
    hold.hold(ids["content"], K_OP, 1).hold(ids["header"], K_OP, 1).hold(ids["frame"], K_OP, 1)
    hold.hold(ids["title_rev"], K_MOD_FROM, 1.0).hold(ids["title_rev"], K_FALL_FROM, 1.2)
    h, i, s = I(), I(), I()
    lay = layer("Screen Flow", h, [
        # every screen builds in when the dashboard enters section mode (they all
        # stand on the arc, so neighbours stay visible while the camera flies)
        state(hide, go(i, cond(vp("mode"), "num", 2)), id=h, x=160, y=0),
        state(inn, go(s, exit_pct=100), go(h, cond(vp("mode"), "num", 2, op="notEqual")), id=i, x=420, y=0, reset=True),
        state(hold, *shown_kids, go(h, cond(vp("mode"), "num", 2, op="notEqual")), id=s, x=680, y=0),
    ])
    return lay, [hide, inn, hold]


def armed(name, gate, extra, actions, x=160, y=1200):
    """Idle -> (gate holds for 250 ms) -> Armed -> accept & extra -> act -> Armed.
    The accept press that opened a screen never also activates something on it."""
    wait = Anim(f"{name} Wait", 15)
    hold = Anim(f"{name} Hold", 1)
    i, w, a, f = I(), I(), I(), I()
    neg = [cond(c.attrs["_path"], c.attrs["_kind"], c.attrs["_val"], op="notEqual") for c in []]
    back = [go(i, cond(vp("mode"), "num", 2, op="notEqual"))]
    for p, k, v in gate:
        if p != vp("mode"):
            back.append(go(i, cond(p, k, v, op="notEqual")))
    lay = layer(name, i, [
        state(hold, go(w, *[cond(p, k, v) for p, k, v in gate]), id=i, x=x, y=y),
        state(wait, go(a, exit_pct=100), *back, id=w, x=x + 220, y=y),
        state(hold, go(f, cond(vp("accept"), "trig"), *extra), *back, id=a, x=x + 440, y=y),
        state(hold, *actions, go(a), id=f, x=x + 660, y=y),
    ])
    return lay, [wait, hold]


def router(idx, target):
    """navUp/navDown (fired by the host's key listeners) move focus with the
    runtime's directional traversal, only while this screen is the active one."""
    hold = Anim("Router Idle", 1)
    i, d, u = I(), I(), I()
    gate = [cond(vp("mode"), "num", 2), cond(vp("section"), "num", idx)]
    lay = layer("Router", i, [
        state(hold, go(d, cond(vp("navDown"), "trig"), *gate), go(u, cond(vp("navUp"), "trig"), *gate), id=i, x=160, y=600),
        state(hold, E("FocusActionTraversal", traversalKind="down"), go(i), id=d, x=420, y=520),
        state(hold, E("FocusActionTraversal", traversalKind="up"), go(i), id=u, x=420, y=680),
    ])
    return [lay], [hold]


# ------------------------------------------------------------------ GAMES
def screen_games() -> E:
    smid = I()
    ab, content, ids = screen_shell(AB_GAMES, 0, "GAMES", "SECTION 01 // LIBRARY", "gamedev", smid, 0, 1800)
    # list
    left = box("List Col", 470, 0, layoutHeightScaleType="fill", flexDirectionValue="column", gapVertical=10)
    left(mono("Count", "8 TITLES INSTALLED  //  SCROLL", 12, MUTED, spacing=2))
    vpb = box("Viewport", 470, 0, layoutHeightScaleType="fill", clip=True, flexDirectionValue="column")
    cont = box("Rows", 470, 0, layoutHeightScaleType="hug", flexDirectionValue="column", gapVertical=6, paddingBottom=40)
    cont(E("ScrollConstraint", id=I(), name="Scroll", directionValue="vertical", physicsId=PHYS)(
        bind(vp("game"), K_SCROLLIDX, "0:97")))
    cont(E("ArtboardComponentList", id=I(), name="Game Rows")(bind(vp("games"), 800)))
    vpb(cont)
    left(vpb)
    content(left)
    # hero panel
    hero = box("Hero", layoutWidthScaleType="fill", layoutHeightScaleType="fill", flexDirectionValue="column",
               paddingLeft=26, paddingTop=22, paddingRight=26, paddingBottom=22, gapVertical=10, clip=True)
    band = I()
    hb = box("Band", 0, 10, layoutWidthScaleType="fill", id=band)
    hb(fill(AMBER, bind=vp("heroColor")))
    hero(hb)
    hg, hrid = reveal_mod("Hero Reveal", 30)
    meta = box("Meta", flexDirectionValue="row", gapHorizontal=12, layoutAlignmentType="centerLeft")
    meta(mono("Genre", "GENRE", 13, AMBER, bind=vp("heroGenre"), spacing=3), mono("Sep", "//", 13, FAINT),
         mono("Year", "2026", 13, MUTED, bind=vp("heroYear")))
    hero(meta)
    # wraps to two lines for long titles (ROCKET SQUADRON) instead of clipping
    hero(orb("Hero Title", "ROCKET SQUADRON", 40, WHITE, 900, bind=vp("heroTitle"), modifiers=[hg], wrap=True, w_fill=True,
             line_height=42))
    blurb_w = box("Blurb Col", 470, 0, flexDirectionValue="column")
    blurb_w(inter("Blurb", "", 18, MUTED, 400, bind=vp("heroBlurb"), wrap=True, w_fill=True))
    hero(blurb_w)
    hero(spacer(grow_w=False, grow_h=True))
    stats = box("Stats", layoutWidthScaleType="fill", flexDirectionValue="row", gapHorizontal=12)
    for lab, b, cv in (("SIZE MB", vp("heroBlocks"), CONV_STR), ("PLAYERS", None, None), ("RATING", None, None)):
        tile = box("Tile", 0, 74, layoutWidthScaleType="fill", flexBasis=0, flexDirectionValue="column", paddingLeft=14,
                   paddingTop=10, gapVertical=4)
        tile(fill(SURF))
        tile(orb("V", {"PLAYERS": "1-4", "RATING": "T"}.get(lab, "0"), 28, AMBER, 900, bind=b, conv=cv))
        tile(mono("L", lab, 11, MUTED, spacing=2))
        stats(tile)
    hero(stats)
    play = box("Play", 0, 52, layoutWidthScaleType="fill", flexDirectionValue="row", layoutAlignmentType="centerLeft",
               paddingLeft=16, gapHorizontal=12)
    play_c = I()
    play(fill(AMBER, play_c))
    btn = box("Key", 0, 30, layoutAlignmentType="center", cornerRadiusTL=6, paddingLeft=10, paddingRight=10)
    btn(fill(BLACK), mono("G", "ENTER", 12, AMBER, spacing=2))
    play(btn, orb("L", "PLAY", 20, BLACK, 900))
    hero(play)
    hero(fill(SURF2))
    hero(stroke(LINE, 1))
    content(hero)

    flow, fa = screen_flow(0, ids)
    rt, ra = router(0, AB_GAMES)
    # hero re-reveal whenever focus moves to another game
    hz = Anim("Hero Idle", 120, loop="loop")
    hz.key(play_c, K_COLOR, [(0, AMBER), (60, "FFFFC468"), (120, AMBER)], "c")
    hz.hold(hrid, K_MOD_FROM, 1.0).hold(hrid, K_FALL_FROM, 1.2).hold(hrid, K_MOD_TO, 1.2).hold(hrid, K_FALL_TO, 1.2)
    hin = Anim("Hero In", 36)
    key_reveal(hin, hrid, 0, 30)
    hin.key(band, K_SX, [(0, 0.0), (24, 1.0)], curve=EASE_OUT)
    hi, hn = I(), I()
    hero_layer = layer("Hero", hi, [
        state(hz, id=hi, x=160, y=300),
        state(hin, go(hi, exit_pct=100), id=hn, x=420, y=300, reset=True),
    ], any_transitions=[go(hn, cond(vp("heroPing"), "trig"))])
    ab(sm("Games SM", flow, *rt, hero_layer, id=smid))
    for a in fa + ra + [hz, hin]:
        ab(a.el)
    return ab


# ------------------------------------------------------------------ MUSIC
def screen_music() -> E:
    smid = I()
    ab, content, ids = screen_shell(AB_MUSIC, 1, "MUSIC", "SECTION 02 // SOUNDTRACKS", "animator", smid, 1200, 1800)
    left = box("List Col", 470, 0, layoutHeightScaleType="fill", flexDirectionValue="column", gapVertical=10)
    left(mono("Count", "RIVEBOX OST  //  8 TRACKS", 12, MUTED, spacing=2))
    vpb = box("Viewport", 470, 0, layoutHeightScaleType="fill", clip=True, flexDirectionValue="column")
    cont = box("Rows", 470, 0, flexDirectionValue="column", gapVertical=6, paddingBottom=40)
    cont(E("ScrollConstraint", id=I(), name="Scroll", directionValue="vertical", physicsId=PHYS2)(
        bind(vp("track"), K_SCROLLIDX, "0:97")))
    cont(E("ArtboardComponentList", id=I(), name="Track Rows")(bind(vp("tracks"), 800)))
    vpb(cont)
    left(vpb)
    content(left)
    right = box("Now Playing", layoutWidthScaleType="fill", layoutHeightScaleType="fill", flexDirectionValue="column",
                paddingLeft=26, paddingTop=22, paddingRight=26, paddingBottom=22, gapVertical=8)
    right(fill(SURF2), stroke(LINE, 1))
    st_txt = I()
    right(mono("State", "NOW PLAYING", 13, AMBER, spacing=3, run_id=st_txt))
    g, rid = reveal_mod("Track Reveal", 26)
    right(orb("Track", "TRACK", 36, WHITE, 900, bind=vp("trackTitle"), modifiers=[g]))
    right(inter("Artist", "ARTIST", 18, MUTED, 500, bind=vp("trackArtist")))
    # visualizer: 24 bars, each its own looping rhythm
    viz = box("Visualizer", 0, 190, layoutWidthScaleType="fill", flexDirectionValue="row", layoutAlignmentType="bottomLeft",
              gapHorizontal=5)
    bars = []
    playA = Anim("Viz Play", 240, loop="loop")
    stopA = Anim("Viz Stop", 1)
    for k in range(24):
        bid = I()
        col = PRISM[k * 6 // 24]
        slot = box("Slot", 0, 190, layoutWidthScaleType="fill", flexBasis=0, layoutAlignmentType="bottomCenter")
        slot(node("N", rect("Bar", 14, 190, col, id=bid, ox=0.5, oy=1, x=7, y=190)))
        viz(slot)
        bars.append(bid)
        import math
        frames = []
        per = [30, 40, 24, 48, 36][k % 5]
        for f in range(0, 241, per // 2 if per // 2 else 12):
            v = 0.15 + 0.85 * abs(math.sin(k * 0.7 + f * 0.13)) * (0.5 + 0.5 * abs(math.cos(k * 1.3 + f * 0.031)))
            frames.append((f, round(v, 3)))
        if frames[-1][0] != 240:
            frames.append((240, frames[0][1]))
        playA.key(bid, K_SY, frames, curve=(0.3, 0, 0.2, 1))
        stopA.hold(bid, K_SY, 0.04)
    right(viz)
    right(spacer(grow_w=False, grow_h=True))
    prog = box("Progress", 0, 6, layoutWidthScaleType="fill", clip=True)
    prog(fill(LINE))
    pfill = I()
    prog(node("PN", rect("Fill", 620, 6, AMBER, ox=0, oy=0, id=pfill)))
    right(prog)
    playA.key(pfill, K_SX, [(0, 0.0, "linear"), (240, 1.0)], ease="linear")
    right(mono("Hint", "ENTER  //  PLAY / PAUSE", 12, FAINT, spacing=2))
    content(right)
    flow, fa = screen_flow(1, ids)
    rt, ra = router(1, AB_MUSIC)
    s_play, s_stop = I(), I()
    vis = layer("Visualizer", s_play, [
        state(playA, go(s_stop, cond(vp("playing"), "bool", False), ms=300), id=s_play, x=160, y=300),
        state(stopA, go(s_play, cond(vp("playing"), "bool", True), ms=200), id=s_stop, x=420, y=300),
    ])
    # A toggles play/pause while this screen is active
    tog, togA = armed("Toggle", [(vp("mode"), "num", 2), (vp("section"), "num", 1)], [],
                      [write_from(vp("playing"), "bool", vp("playing"), CONV_NOT)])
    hold = togA[1]
    tz = Anim("Track Idle", 1)
    tz.hold(rid, K_MOD_FROM, 1.0).hold(rid, K_FALL_FROM, 1.2).hold(rid, K_MOD_TO, 1.2).hold(rid, K_FALL_TO, 1.2)
    tin = Anim("Track In", 30)
    key_reveal(tin, rid, 0, 26)
    a0, a1 = I(), I()
    trk = layer("Track", a0, [state(tz, id=a0, x=160, y=1100), state(tin, go(a0, exit_pct=100), id=a1, x=420, y=1100, reset=True)],
                any_transitions=[go(a1, cond(vp("trackPing"), "trig"))])
    ab(sm("Music SM", flow, *rt, vis, tog, trk, id=smid))
    for a in fa + ra + togA + [playA, stopA, tz, tin]:
        ab(a.el)
    return ab


# ------------------------------------------------------------------ MEMORY
DEVICES = [("INTERNAL DRIVE", "84 / 500 GB", 0.17, "hazard"),
           ("EXPANSION CARD", "29 / 80 GB", 0.36, "lightning"),
           ("RIVE CLOUD", "11 / 512 GB", 0.02, "shuffle")]


def screen_memory() -> E:
    smid = I()
    ab, content, ids = screen_shell(AB_MEM, 2, "MEMORY", "SECTION 03 // STORAGE", "hazard", smid, 2400, 1800)
    left = box("Devices", 470, 0, layoutHeightScaleType="fill", flexDirectionValue="column", gapVertical=12)
    anims = []
    listeners = []
    off_on = []
    first = None
    for k, (name, sub, used, ico) in enumerate(DEVICES):
        card, cbg, ct, cs, cbar = I(), I(), I(), I(), I()
        c = box("Device", 470, 104, id=card, flexDirectionValue="row", layoutAlignmentType="centerLeft", paddingLeft=18,
                gapHorizontal=16)
        c(E("FocusData", id=I()))
        c(fill("FF101010", cbg), stroke(LINE, 1))
        ib = box("Ico", 56, 56, layoutAlignmentType="center")
        ib(fill(BLACK), nested("G", ICONS[ico], 34, 34))
        c(ib)
        col = box("Text", flexDirectionValue="column", gapVertical=6)
        col(orb("Name", name, 22, WHITE, 900, cid=ct), mono("Sub", sub, 12, MUTED, cid=cs))
        meter = box("Meter", 300, 6, clip=True)
        meter(fill(LINE))
        meter(node("MN", rect("Used", 300 * used, 6, AMBER, ox=0, oy=0, id=cbar)))
        col(meter)
        c(col)
        left(c)
        off = Anim(f"Dev{k} Off", 1)
        off.hold(cbg, K_COLOR, "FF101010", "c").hold(ct, K_COLOR, WHITE, "c").hold(cs, K_COLOR, MUTED, "c")
        onA = Anim(f"Dev{k} On", 1)
        onA.hold(cbg, K_COLOR, AMBER, "c").hold(ct, K_COLOR, BLACK, "c").hold(cs, K_COLOR, "B3000000", "c")
        anims += [off, onA]
        a, b = I(), I()
        off_on.append(layer(f"Device {k}", a, [
            state(off, go(b, cond(vp("device"), "num", k), ms=140), id=a, x=160, y=k * 160),
            state(onA, go(a, cond(vp("device"), "num", k, op="notEqual"), ms=200), id=b, x=420, y=k * 160)]))
        listeners += [listener(card, f"Focus {k}", [on("focus")], [write(vp("device"), "num", k)]),
                      E("StateMachineListenerSingle", targetId=card, listenerTypeValue="down", name=f"Press {k}")(
                          E("FocusActionTarget", targetId=card))]
        if first is None:
            first = card
    content(left)
    # right: block ring + save grid
    right = box("Usage", layoutWidthScaleType="fill", layoutHeightScaleType="fill", flexDirectionValue="row",
                paddingLeft=24, paddingTop=20, gapHorizontal=26)
    right(fill(SURF2), stroke(LINE, 1))
    ring_slot = box("Ring", 240, 240)
    trim = I()
    ring_spin = I()
    pct_run = I()
    ring_slot(node("RingArt",
                   orb("Pct", "17%", 46, WHITE, 900, lp=False, x=70, y=88, run_id=pct_run),
                   mono("Used", "USED", 12, MUTED, lp=False, x=100, y=146, spacing=3),
                   E("Shape", id=ring_spin, name="Arc", x=120, y=120, rotation=-1.5707964)(
                       E("Ellipse", name="E", width=200, height=200),
                       stroke(AMBER, 16, cap="butt", trim=E("TrimPath", id=trim, name="T", start=0, end=0.17, modeValue=1))),
                   E("Shape", name="Track", x=120, y=120)(E("Ellipse", name="E", width=200, height=200), stroke(LINE, 16)),
                   ))
    right(ring_slot)
    grid = box("Saves", layoutWidthScaleType="fill", flexDirectionValue="column", gapVertical=8)
    grid(mono("SL", "SAVED GAMES", 12, AMBER, spacing=3))
    cells = []
    for r in range(4):
        row = box("Row", flexDirectionValue="row", gapHorizontal=8)
        for cidx in range(3):
            cid = I()
            cell = box("Save", 64, 64, id=cid, layoutAlignmentType="center", opacity=1)
            cell(fill(SURF), stroke(LINE, 1))
            cell(mono("N", f"{r * 3 + cidx + 1:02d}", 12, FAINT))
            row(cell)
            cells.append(cid)
        grid(row)
    right(grid)
    content(right)
    # per-device usage states: ring animates to the device's fill, saves cascade in
    dev_states = []
    dev_anims = []
    sids = [I() for _ in DEVICES]
    for k, (_, _, used, _) in enumerate(DEVICES):
        a = Anim(f"Usage {k}", 40)
        a.key(trim, K_TRIM_END, [(0, 0.0), (32, max(used, 0.02))], curve=BACK_OUT)
        a.key(ring_spin, K_ROT, [(0, -1.5707964 - 1.2), (36, -1.5707964)], curve=EASE_OUT)
        n_saves = [9, 5, 2][k]
        for j, cid in enumerate(cells):
            vis = 1 if j < n_saves else 0.15
            a.key(cid, K_OP, [(0, 0, "hold"), (2 + j * 2, 0.0), (8 + j * 2, vis)], curve=EASE_OUT)
            a.key(cid, K_SX, [(0, 0.6), (2 + j * 2, 0.6), (12 + j * 2, 1.0)], curve=BACK_OUT)
            a.key(cid, K_SY, [(0, 0.6), (2 + j * 2, 0.6), (12 + j * 2, 1.0)], curve=BACK_OUT)
        dev_anims.append(a)
        trans = [go(sids[j], cond(vp("device"), "num", j)) for j in range(len(DEVICES)) if j != k]
        dev_states.append(state(a, *trans, id=sids[k], x=160 + k * 220, y=800, reset=True))
    # text for percent: one run per device keyed with KeyFrameString
    usage = layer("Usage", sids[0], dev_states)
    flow, fa = screen_flow(2, ids, first=first)
    rt, ra = router(2, AB_MEM)
    sa = []
    ab(sm("Memory SM", *listeners, flow, *rt, usage, *off_on, id=smid))
    for a in fa + ra + sa + anims + dev_anims:
        ab(a.el)
    # percent labels via string keyframes
    for k, (_, _, used, _) in enumerate(DEVICES):
        ko = E("KeyedObject", objectId=pct_run)(E("KeyedProperty", propertyKey=268)(
            E("KeyFrameString", frame=0, value=f"{max(1, round(used * 100))}%", interpolationType="hold")))
        dev_anims[k].el(ko)
    return ab


# ------------------------------------------------------------------ SETTINGS
SETTINGS = [("PLAYER NAME", None), ("VIBRATION", "opt0"), ("SURROUND SOUND", "opt1"), ("AUTO SIGN-IN", "opt2"),
            ("60 HZ MODE", "opt3")]


def screen_settings() -> E:
    smid = I()
    ab, content, ids = screen_shell(AB_SET, 3, "SETTINGS", "SECTION 04 // SYSTEM", "asterisk", smid, 3600, 1800)
    left = box("Options", 560, 0, layoutHeightScaleType="fill", flexDirectionValue="column", gapVertical=8)
    anims, listeners, layers = [], [], []
    first = None
    hold = Anim("Opt Idle", 1)
    anims.append(hold)
    for k, (label, opt) in enumerate(SETTINGS):
        rid, bg, lc, vc, knob, track_c = I(), I(), I(), I(), I(), I()
        r = box("Option", 560, 64, id=rid, flexDirectionValue="row", layoutAlignmentType="centerLeft", paddingLeft=18,
                paddingRight=18, gapHorizontal=14)
        r(E("FocusData", id=I()))
        r(fill("FF101010", bg), stroke(LINE, 1))
        r(mono("Idx", f"{k + 1:02d}", 13, FAINT))
        r(orb("Label", label, 20, WHITE, 800, cid=lc))
        r(spacer())
        if opt is None:
            r(orb("Value", "PILOT_01", 20, AMBER, 900, bind=vp("gamertag"), cid=vc))
            r(mono("Edit", "[ ENTER ] EDIT", 11, FAINT))
        else:
            sw = box("Switch", 64, 30)
            sw(node("SW", rect("Knob", 22, 22, WHITE, x=17, y=15, id=knob),
                    rect("Track", 64, 30, LINE, x=32, y=15, r=15, cid=track_c, stroke_color="FF333333")))
            r(sw)
            onS, offS = Anim(f"{opt} On", 1), Anim(f"{opt} Off", 1)
            onS.hold(knob, K_X, 47).hold(track_c, K_COLOR, PRISM[3], "c")
            offS.hold(knob, K_X, 17).hold(track_c, K_COLOR, LINE, "c")
            a, b = I(), I()
            layers.append(layer(f"Switch {opt}", a, [
                state(onS if _props_default(opt) else offS,
                      go(b, cond(vp(opt), "bool", not _props_default(opt)), ms=220, interp=BACK_OUT), id=a, x=160, y=k * 140),
                state(offS if _props_default(opt) else onS,
                      go(a, cond(vp(opt), "bool", _props_default(opt)), ms=220, interp=BACK_OUT), id=b, x=420, y=k * 140)]))
            anims += [onS, offS]
            # A toggles the focused switch
            tl, tla = armed(f"Toggle {opt}", [(vp("mode"), "num", 2), (vp("section"), "num", 3)],
                            [cond(vp("setting"), "num", k)], [write_from(vp(opt), "bool", vp(opt), CONV_NOT)], y=k * 140 + 800)
            layers.append(tl)
            anims += tla
        left(r)
        off = Anim(f"Opt{k} Off", 1)
        off.hold(bg, K_COLOR, "FF101010", "c").hold(lc, K_COLOR, WHITE, "c")
        onA = Anim(f"Opt{k} On", 1)
        onA.hold(bg, K_COLOR, "FF2A1A04", "c").hold(lc, K_COLOR, AMBER, "c")
        anims += [off, onA]
        a, b = I(), I()
        layers.append(layer(f"Option {k}", a, [
            state(off, go(b, cond(vp("setting"), "num", k), ms=120), id=a, x=1200, y=k * 140),
            state(onA, go(a, cond(vp("setting"), "num", k, op="notEqual"), ms=200), id=b, x=1400, y=k * 140)]))
        listeners += [listener(rid, f"Focus {k}", [on("focus")], [write(vp("setting"), "num", k)]),
                      E("StateMachineListenerSingle", targetId=rid, listenerTypeValue="down", name=f"Press {k}")(
                          E("FocusActionTarget", targetId=rid)),
                      E("StateMachineListenerSingle", targetId=rid, listenerTypeValue="click", name=f"Tap {k}")(
                          fire(vp("accept")))]
        if first is None:
            first = rid
    content(left)
    # right: gamertag preview card
    card = box("Card", layoutWidthScaleType="fill", layoutHeightScaleType="fill", flexDirectionValue="column",
               paddingLeft=24, paddingTop=22, paddingRight=24, gapVertical=12)
    card(fill(SURF2), stroke(LINE, 1))
    card(mono("K", "PLAYER CARD", 12, AMBER, spacing=3))
    av = box("Avatar", 120, 120, layoutAlignmentType="center")
    av(fill(AMBER), nested("Alien", ICONS["alien"], 80, 80))
    card(av)
    card(orb("Tag", "PILOT_01", 30, WHITE, 900, bind=vp("gamertag")))
    card(mono("Live", "// :: live_sync = TRUE", 12, FAINT))
    card(inter("Hint", "Press Enter on PLAYER NAME to rename. The name is data-bound into this card, "
                       "the ribbon and every game case at once.", 15, MUTED, 400, wrap=True, w_fill=True))
    content(card)
    flow, fa = screen_flow(3, ids, first=first)
    rt, ra = router(3, AB_SET)
    sa = []
    ab(sm("Settings SM", *listeners, flow, *rt, *layers, id=smid))
    for a in fa + ra + sa + anims:
        ab(a.el)
    return ab


def _props_default(name):
    for n, _, v in _props:
        if n == name:
            return v
    return None

# ===== SPLIT: main


# ================================================================== MAIN ARTBOARD
MW, MH = 1600, 900
ID_WORLD, ID_FIELD, ID_SURFACE, ID_CATCH = "0:20", "0:21", "0:22", "0:23"
CONV_SCROLL, CONV_INC, CONV_DEC = "0:97", "0:89", "0:88"


def more_converters():
    return [
        E("DataConverterFormula", id=CONV_SCROLL, name="Scroll Window")(
            E("FormulaTokenFunction", functionType=1), E("FormulaTokenValue", operationValue=0),
            E("FormulaTokenArgumentSeparator"), E("FormulaTokenInput"), E("FormulaTokenOperation", operationType=1),
            E("FormulaTokenValue", operationValue=3), E("FormulaTokenParenthesisClose")),
        E("DataConverterFormula", id=CONV_INC, name="Next Section")(
            E("FormulaTokenFunction", functionType=0), E("FormulaTokenValue", operationValue=3),
            E("FormulaTokenArgumentSeparator"), E("FormulaTokenInput"), E("FormulaTokenOperation", operationType=0),
            E("FormulaTokenValue", operationValue=1), E("FormulaTokenParenthesisClose")),
        E("DataConverterFormula", id=CONV_DEC, name="Prev Section")(
            E("FormulaTokenFunction", functionType=1), E("FormulaTokenValue", operationValue=0),
            E("FormulaTokenArgumentSeparator"), E("FormulaTokenInput"), E("FormulaTokenOperation", operationType=1),
            E("FormulaTokenValue", operationValue=1), E("FormulaTokenParenthesisClose")),
    ]


def text_field(ids):
    """The real Rive TextInput: the gamertag, two-way bound to the view model."""
    wrap = box("Field", 300, 44, clip=True, id=ID_FIELD, layoutAlignmentType="centerLeft", paddingLeft=12,
               cornerRadiusTL=4)
    wrap.attrs["isTargetOpaque"] = True
    ids["field_bg"] = I()
    ids["field_stroke"] = I()
    wrap(E("Fill", name="F")(solid("FF0A0A0A", ids["field_bg"])))
    wrap(E("Stroke", name="St", thickness=2)(solid(LINE, ids["field_stroke"])))
    ti = I()
    ids["input"] = ti
    tbox = box("Text Box", 276, 30)
    guard = E("ScriptedLayout", id=I(), scriptAssetId=SCRIPT_GUARD, name="Field Guard")(
        E("FocusData", canFocus=False, id=I()))
    ids["guard"] = guard.attrs["id"]
    tbox(guard)
    guard(E("TextInput", id=ti, name="Player Name Input", multiline=False, verticalAlignValue="middle", selectAllOnFocus=True)(
        E("TextStyle", id=I(), name="TS", fontSize=24, fontAssetId=F_ORB)(E("TextStyleAxis", tag=WGHT, axisValue=900, name="W")),
        E("TextInputText", name="Text")(fill(WHITE, ids.setdefault("input_col", I()))),
        E("TextInputSelection", name="Sel")(fill("66FFA41C")),
        E("TextInputCursor", name="Cursor")(fill(AMBER)),
        E("FocusData", id=I()),
        bind(vp("gamertag"), 817, twoWay=True, sourceToTargetRunsFirst=True)))
    wrap(tbox)
    return wrap


def hud(ids) -> E:
    """Minimal HUD: no chrome at all. The gamertag TextInput stays (Settings > Gamertag focuses it) but its card is
    only shown while editing (Field On / Field Off states)."""
    root = fill_box("HUD", flexDirectionValue="column", paddingLeft=40, paddingRight=40, paddingTop=28, paddingBottom=26)
    root(spacer(grow_w=False, grow_h=True))
    # gamertag editor card, bottom-centre, hidden unless editing
    edit_row = box("Edit Row", layoutWidthScaleType="fill", flexDirectionValue="row", layoutAlignmentType="center")
    pw_ = I()
    player = box("Player", id=pw_, flexDirectionValue="column", layoutAlignmentType="centerLeft", gapVertical=6,
                 paddingLeft=14, paddingRight=14, paddingTop=12, paddingBottom=12, opacity=0.001)
    player(fill("B3000000"), stroke(LINE, 1))
    player(mono("PL", "PLAYER NAME  //  ENTER TO SAVE", 11, AMBER, spacing=2))
    player(text_field(ids))
    edit_row(player)
    root(edit_row)
    ids["hud"] = root.attrs["id"]
    ids["player_card"] = pw_
    return root


def _brand_letters():
    """The RIVE wordmark letter paths, lifted from the brand file (brand.rml)."""
    import xml.etree.ElementTree as ET
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "brand.rml")).read()
    i0 = src.index('name="Wordmark" id="5:12">')
    i1 = src.index('</Artboard>', i0)
    body = src[src.index('<Node', i0):src.index('<StateMachine', i0)]
    root = ET.fromstring(body)
    out = {}

    def conv(el):
        if el.tag in ("Fill", "DataBindContext"):
            return None
        attrs = {k: v for k, v in el.attrib.items() if k != "id"}
        e = E(el.tag, **attrs)
        for c in el:
            k = conv(c)
            if k is not None:
                e(k)
        return e

    for sh in root:
        out[sh.attrib["name"]] = (float(sh.attrib.get("x", 0)), float(sh.attrib.get("y", 0)),
                                  [conv(c) for c in sh if c.tag != "Fill"])
    return out


ROW_L, ROW_R, ROW_MID = 421, 578, 14


def title_overlay(ids) -> E:
    """Start screen: the designer's logo animation (logo.rml, NuRiveWordmark01)
    driven by its own view model's showLogo, plus a PRESS START prompt.
    Transparent: the 3D world (far away) shows through."""
    ov = fill_box("Title", layoutTypeValue="stack", layoutAlignmentType="center")
    ids["title"] = ov.attrs["id"]
    _TITLE_ID[0] = ov.attrs["id"]
    stage = box("Title Stage", 1000, 320, flexDirectionValue="column", layoutAlignmentType="center")
    logo = box("Logo", 500, 250, layoutTypeValue="stack")
    # nested with its own state machine running, bound to Dash/logo (LogoVM)
    logo(node("Logo Node", E("NestedArtboard", artboardId=LOGO_AB, name="Rive Logo", x=0, y=0, scaleX=0.625, scaleY=0.625,
                             dataBindPathIds=f"{VM}-{P['logo']}")(
        E("NestedStateMachine", animationId=LOGO_SM, name="Logo SM"))))
    stage(logo)
    # PRESS START is revealed by a white hairline that draws across it (the
    # line beat from the brand film): the glyphs light up as the line passes
    wrap = box("Start Wrap", 1000, 28, layoutTypeValue="stack")
    ids["t_start"] = wrap.attrs["id"]
    ids["t_lineL"], ids["t_lineL_r"], ids["t_lineR"], ids["t_lineR_r"] = I(), I(), I(), I()
    wrap(node("Reveal Lines",
        E("Shape", id=ids["t_lineL"], name="Line L", x=ROW_L - 8, y=ROW_MID)(
            E("Rectangle", id=ids["t_lineL_r"], name="R", width=0, height=1.4, originX=1, originY=0.5), fill(WHITE)),
        E("Shape", id=ids["t_lineR"], name="Line R", x=ROW_R + 8, y=ROW_MID)(
            E("Rectangle", id=ids["t_lineR_r"], name="R", width=0, height=1.4, originX=0, originY=0.5), fill(WHITE))))
    st = box("Start Row", 1000, 28, flexDirectionValue="row", layoutAlignmentType="center", gapHorizontal=10)
    # icon + brackets sized to the cap height of PRESS START (9 px at 13 px),
    # nudged by CAP_DY so their bounding box lines up with the letters
    CAP, CAP_DY = 9.0, 0.0
    slot = box("Icon Slot", 21, CAP, id=(slot_id := I()))
    ids["t_slot"] = slot_id
    sl = node("Slot Art", y=CAP_DY)
    sl(poly("BL", [(2.6, 0.6), (0.8, 0.6), (0.8, CAP - 0.6), (2.6, CAP - 0.6)], stroke_color=AMBER, stroke_w=1.6, closed=False))
    sl(poly("BR", [(18.4, 0.6), (20.2, 0.6), (20.2, CAP - 0.6), (18.4, CAP - 0.6)], stroke_color=AMBER, stroke_w=1.6, closed=False))
    ids["t_icons"] = []
    for key in ("lightning", "gamedev", "asterisk", "alien", "swords", "hazard"):
        iid = I()
        sl(icon(key, key, CAP * 1.18, x=10.5, y=CAP / 2, id=iid))
        ids["t_icons"].append(iid)
    slot(sl)
    st(slot)
    g_ps, ps_rid = reveal_mod("Press Reveal", 0)
    ids["t_press_rev"] = ps_rid
    ps = mono("Press", "PRESS START", 13, AMBER, spacing=5, weight=700, id=(psid := I()), modifiers=[g_ps])
    ids["t_press"] = psid
    st(ps)
    wrap(st)
    stage(wrap)
    stage(box("Gap2", 10, 8))
    hint = mono("Hint", "ENTER  //  CLICK", 9, MUTED, spacing=2.5, id=(hid := I()))
    ids["t_hint"] = hid
    stage(hint)
    ov(stage)
    return ov


def title_anims(ids):
    """Intro (logo In plays via showLogo=true), idle loop for the held title,
    and the start beat (showLogo=false -> the logo's own Out)."""
    intro = Anim("Title Intro", 120)
    intro.hold(ids["title"], K_OP, 1).hold(ids["hud"], K_OP, 0)
    intro.hold(ID_FIELD, K_OP, 0)
    # line draws left->right across the row, the glyphs reveal behind its
    # leading edge, then the tail retracts off the right end
    # hairlines shoot OUT from both ends of the row, then retract outward
    LW = 190
    intro.hold(ids["t_start"], K_OP, 1)
    for sh_, r, sgn, x0 in ((ids["t_lineL"], ids["t_lineL_r"], -1, ROW_L - 8), (ids["t_lineR"], ids["t_lineR_r"], 1, ROW_R + 8)):
        intro.key(r, K_RW, [(0, 0, "hold"), (50, 0), (68, LW), (90, 0)], curve=EASE_IN_OUT)
        intro.key(sh_, K_X, [(0, x0, "hold"), (68, x0), (90, x0 + LW * sgn)], curve=EASE_IN_OUT)
        intro.key(sh_, K_OP, [(0, 1, "hold"), (84, 1), (92, 0)])
    intro.key(ids["t_slot"], K_OP, [(0, 0, "hold"), (50, 0), (56, 1)], curve=EASE_OUT)
    # glyph sweep tracks the line's leading edge (same curve, slightly behind)
    pr = ids["t_press_rev"]
    intro.key(pr, K_MOD_FROM, [(0, -0.2, "hold"), (52, -0.2), (70, 1.0)], curve=EASE_OUT)
    intro.key(pr, K_FALL_FROM, [(0, -0.05, "hold"), (52, -0.05), (70, 1.2)], curve=EASE_OUT)
    intro.key(pr, K_MOD_TO, [(0, 1.2, "hold")])
    intro.key(pr, K_FALL_TO, [(0, 1.2, "hold")])
    intro.key(ids["t_hint"], K_OP, [(0, 0, "hold"), (84, 0), (108, 1)], curve=EASE_OUT)
    intro.key(ids["t_press"], K_OP, [(0, 1, "hold")])
    for k, iid in enumerate(ids["t_icons"]):
        intro.key(iid, K_OP, [(0, 1 if k == 0 else 0, "hold")])

    # idle: prompt breathes, the slot cycles brand icons
    idle = Anim("Title Idle", 144, loop="loop")
    idle.key(ids["t_press"], K_OP, [(0, 1), (72, 0.35), (144, 1)], curve=EASE_IN_OUT)
    n = len(ids["t_icons"])
    for k, iid in enumerate(ids["t_icons"]):
        f = k * (144 // n)
        frames = [(0, 1 if k == 0 else 0, "hold")]
        if k > 0:
            frames.append((f, 1, "hold"))
        frames.append((f + 144 // n, 0, "hold"))
        if k == 0:
            frames = [(0, 1, "hold"), (144 // n, 0, "hold")]
        idle.key(iid, K_OP, frames)

    # start: prompt flashes, title punches forward and dissolves; HUD lands
    # once the camera has finished its dive (~3 s)
    start = Anim("Title Start", 190)
    start.key(ids["t_press"], K_OP, [(0, 1, "hold"), (3, 0.1, "hold"), (6, 1, "hold"), (9, 0.1, "hold"),
                                     (12, 1, "hold"), (15, 0.1, "hold"), (18, 1)])
    start.key(ID_FIELD, K_OP, [(0, 0, "hold"), (140, 0), (186, 1)], curve=EASE_IN_OUT)
    # the logo plays its own Out (~25 frames); the prompt flashes, then the
    # whole title layer fades as the camera dives
    start.key(ids["t_start"], K_OP, [(0, 1, "hold"), (20, 1), (34, 0)], curve=EASE_IN_OUT)
    start.key(ids["t_hint"], K_OP, [(0, 1), (12, 0)], curve=EASE_IN_OUT)
    start.key(ids["title"], K_OP, [(0, 1, "hold"), (40, 1), (60, 0)], curve=EASE_IN_OUT)
    start.key(ids["hud"], K_OP, [(0, 0, "hold"), (140, 0), (186, 1)], curve=EASE_IN_OUT)
    return intro, idle, start


def launch_overlay(ids) -> E:
    ov = fill_box("Launch", layoutTypeValue="stack", layoutAlignmentType="center", opacity=0)
    ids["launch"] = ov.attrs["id"]
    # (~70% of the original size)
    center = box("Launch Center", flexDirectionValue="column", layoutAlignmentType="center", gapVertical=11)
    hz = box("Hazard", 364, 28, clip=True)
    hz(hazard("Stripes", 400, 28, step=14, id=(hzn := I())))
    ids["launch_hz"] = hzn
    center(hz)
    center(mono("K", "LOADING DISC", 12, AMBER, spacing=5))
    g, rid = reveal_mod("Launch Reveal", 40)
    ids["launch_rev"] = rid
    center(orb("Title", "ROCKET SQUADRON", 56, WHITE, 640, bind=vp("heroTitle"), modifiers=[g]))
    # barber-pole loader: diagonal prism stripes scrolling through a clipped
    # rectangle (loops seamlessly every 6 stripes)
    bar = box("Bar", 364, 12, clip=True)
    bar(fill(LINE))
    bar(barber_prism("Barber", 364 + 6 * 62 * 3, 12, seg=60, gap=2, id=(bn := I())))
    ids["launch_bar"] = bn
    center(bar)
    center(mono("H", "// :: this is where the game would boot", 10, FAINT))
    ov(center)
    ov(fill("F2000000"))
    return ov


def main_artboard() -> E:
    ids: dict = {}
    smid = "0:9"
    ab = E("Artboard", id=ART_MAIN, name="RiveBox", width=MW, height=MH, viewModelId=VM, viewModelInstanceId=VMI,
           defaultStateMachineId=smid, clip=True, styleId="0:3")(E("LayoutComponentStyle", id="0:3", name="AS"))
    ab(fill(BLACK))
    stack = fill_box("Root", layoutTypeValue="stack")
    world_box = fill_box("World Layer")
    world = E("ScriptedLayout", id=ID_WORLD, scriptAssetId=SCRIPT_WORLD, name="World 3D")(
        E("FocusData", id=I()),
        *[E("ScriptInputArtboard", artboardId=a, name=n) for n, a in (
            ("hub", AB_HUB), ("core", AB_CORE), ("ticker", AB_TICK), ("games", AB_GAMES), ("music", AB_MUSIC),
            ("memory", AB_MEM), ("settings", AB_SET), ("caseArt", AB_CASE), ("sats", AB_SAT))],
        E("ScriptInputNumber", name="section", propertyValue=0)(bind(vp("section"), K_SIN)),
        E("ScriptInputNumber", name="mode", propertyValue=0)(bind(vp("mode"), K_SIN)))
    world_box(world)
    stack(launch_overlay(ids))
    stack(title_overlay(ids))
    stack(hud(ids))
    stack(world_box)
    # click catcher behind everything: a press anywhere outside the field hands
    # focus back to the dashboard (and ends gamertag editing)
    catcher = fill_box("Click Catcher", id=ID_CATCH)
    catcher(fill("01000000"))
    stack(catcher)
    ab(stack)

    anims: list[Anim] = []
    # ---- flow: Title (intro -> idle) -> Start (camera dive) -> Hub <-> Section, Launch
    SHOW_LOGO = f"{VM}-{P['logo']}-{LOGO_SHOW}"
    intro, idleT, startT = title_anims(ids)
    hubA = Anim("Hub", 40)
    hubA.hold(ids["title"], K_OP, 0).hold(ids["hud"], K_OP, 1).hold(ID_FIELD, K_OP, 1)
    secA = Anim("Section", 1)
    secA.hold(ids["title"], K_OP, 0).hold(ids["hud"], K_OP, 1).hold(ID_FIELD, K_OP, 1)
    launch = Anim("Launch", 170)
    launch.key(ids["launch"], K_OP, [(0, 0), (12, 1), (150, 1), (170, 0)], curve=EASE_IN_OUT)
    launch.key(ids["launch_hz"], K_X, [(0, 0, "linear"), (170, -80)], ease="linear")
    # loader: the prism segments scroll left continuously through the clipped
    # bar (3 colour cycles of 372 px over the 170-frame overlay)
    launch.key(ids["launch_bar"], K_X, [(0, 0, "linear"), (170, -6 * 62 * 3)], ease="linear")
    key_reveal(launch, ids["launch_rev"], 10, 40)
    launch.hold(ids["title"], K_OP, 0).hold(ids["hud"], K_OP, 1)
    anims += [intro, idleT, startT, hubA, secA, launch]
    # returning from the hub: the camera pulls out (mode 0) with the title layer
    # hidden; the logo (showLogo) only comes back once we're nearly home
    # (the pull-out is a ~4.6 s eased flight now: the logo waits until the
    # camera is gliding into its final rest, ~80% of the way)
    retA = Anim("Title Return", 113)
    retA.hold(ids["title"], K_OP, 0)
    retA.key(ids["hud"], K_OP, [(0, 1), (28, 1), (44, 0)], curve=EASE_IN_OUT)
    retA.key(ID_FIELD, K_OP, [(0, 1), (28, 1), (44, 0)], curve=EASE_IN_OUT)
    anims.append(retA)
    sb, si_, sst, sh, ss, sl, sr_ = I(), I(), I(), I(), I(), I(), I()
    flow = layer("Flow", sb, [
        state(intro, write(vp("mode"), "num", 0), write(SHOW_LOGO, "bool", True), E("FocusActionTarget", targetId=ID_WORLD),
              go(si_, exit_pct=100), go(sst, cond(vp("accept"), "trig")), id=sb, x=160, y=0, reset=True),
        state(idleT, go(sst, cond(vp("accept"), "trig")), id=si_, x=160, y=200),
        state(startT, write(vp("mode"), "num", 1), write(SHOW_LOGO, "bool", False), go(sh, exit_pct=100), id=sst, x=420, y=200, reset=True),
        # back on the hub returns to the start screen (exit time keeps a
        # section's back press from chaining straight through)
        state(hubA, write(vp("mode"), "num", 1), go(ss, cond(vp("accept"), "trig")),
              go(sr_, cond(vp("back"), "trig"), exit_pct=100), id=sh, x=420, y=0),
        state(retA, write(vp("mode"), "num", 0), go(sb, exit_pct=100), id=sr_, x=160, y=-200, reset=True),
        # (launching is consumed on ENTRY to Launch: clearing it on re-entry to
        # Section raced the Section -> Launch check in the same frame, so the
        # sequence played twice)
        state(secA, write(vp("mode"), "num", 2), go(sh, cond(vp("back"), "trig")),
              go(sl, cond(vp("launching"), "bool", True)), id=ss, x=680, y=0),
        state(launch, write(vp("launching"), "bool", False), go(ss, exit_pct=100), id=sl, x=680, y=200, reset=True),
    ])
    play, playA = armed("Play", [(vp("mode"), "num", 2), (vp("section"), "num", 0)], [],
                        [write(vp("launching"), "bool", True)], y=1400)
    anims += playA
    # ---- section switching with left/right while inside a section
    hold = Anim("Idle", 1)
    anims.append(hold)
    si, sr, slf = I(), I(), I()
    switch = layer("Switch", si, [
        state(hold, go(sr, cond(vp("navRight"), "trig"), cond(vp("mode"), "num", 2)),
              go(slf, cond(vp("navLeft"), "trig"), cond(vp("mode"), "num", 2)), id=si, x=160, y=300),
        state(hold, write_from(vp("section"), "num", vp("section"), CONV_INC), go(si), id=sr, x=420, y=260),
        state(hold, write_from(vp("section"), "num", vp("section"), CONV_DEC), go(si), id=slf, x=420, y=360),
    ])
    # ---- editing the gamertag: A on SETTINGS > GAMERTAG focuses the real TextInput
    edit, editA = armed("Edit", [(vp("mode"), "num", 2), (vp("section"), "num", 3)], [cond(vp("setting"), "num", 0)],
                        [E("FocusActionTarget", targetId=ids["input"])], y=500)
    anims += editA
    # ---- field focus styling
    fo, fn = Anim("Field Off", 1), Anim("Field On", 60, loop="loop")
    fo.hold(ids["field_stroke"], K_COLOR, LINE, "c").hold(ids["field_bg"], K_COLOR, "FF0A0A0A", "c")
    fo.hold(ids["player_card"], K_OP, 0.001).hold(ids["input_col"], K_COLOR, "00FFFFFF", "c")
    fn.hold(ids["input_col"], K_COLOR, WHITE, "c")
    fn.key(ids["player_card"], K_OP, [(0, 1), (60, 1)])
    fn.key(ids["field_stroke"], K_COLOR, [(0, AMBER), (30, "FFFFE2B0"), (60, AMBER)], "c")
    fn.hold(ids["field_bg"], K_COLOR, "FF1E1406", "c")
    anims += [fo, fn]
    def keys(name, keys_, pads, trig):
        return listener(ID_WORLD, name, [on_key(*keys_, phase=3), on_pad(*pads)], [fire(vp(trig))])

    listeners = [
        keys("Up", ["up", "w"], [12], "navUp"),
        keys("Down", ["down", "s"], [13], "navDown"),
        keys("Left", ["left", "a"], [14, 4], "navLeft"),
        keys("Right", ["right", "d"], [15, 5], "navRight"),
        listener(ID_WORLD, "Accept", [on_key("enter", "space", "kpEnter"), on_pad(0)], [fire(vp("accept"))]),
        listener(ID_WORLD, "Back", [on_key("escape", "backspace"), on_pad(1)], [fire(vp("back"))]),
        # the text field: Enter / Escape hands focus back to the dashboard
        listener(ids["input"], "Field Done", [on_key("escape", "enter", "kpEnter", phase=4), on_pad(1, 0)],
                 [E("FocusActionTarget", targetId=ID_WORLD)]),
        listener(ID_WORLD, "Field Done Trig", [on_vm(vp("fieldDone"))], [E("FocusActionTarget", targetId=ID_WORLD)]),
        listener(ids["input"], "Field Focus", [on("focus")], [write(vp("editing"), "bool", True)]),
        listener(ids["input"], "Field Blur", [on("blur")], [write(vp("editing"), "bool", False)]),
        E("StateMachineListenerSingle", targetId=ID_CATCH, listenerTypeValue="down", name="Click Outside")(
            E("FocusActionTarget", targetId=ID_WORLD)),
        E("StateMachineListenerSingle", targetId=ID_FIELD, listenerTypeValue="down", name="Field Press")(
            E("FocusActionTarget", targetId=ids["input"])),
    ]
    f0, f1 = I(), I()
    field_layer = layer("Field", f0, [
        state(fo, go(f1, cond(vp("editing"), "bool", True), ms=150), id=f0, x=160, y=900),
        state(fn, go(f0, cond(vp("editing"), "bool", False), ms=250), id=f1, x=420, y=900),
    ])
    ab(sm("RiveBox SM", *listeners, flow, switch, edit, play, field_layer, id=smid))
    for a in anims:
        ab(a.el)
    return ab, ids


# ================================================================== decrypt pass
def decrypt_texts(parts):
    """Route every UI string through the Decrypt converter.

    - bound runs: add the converter (chained after ToString / Index Label)
    - static runs on dashboard-VM artboards: lift the literal into a string
      property on the dashboard view model and bind it through Decrypt, so the
      text is data-bound and scrambles in like the rest
    Skipped: the start screen (its PRESS START beat is hand-timed) and runs
    whose text an animation keys."""
    keyed = set()

    def scan_keys(e):
        if not isinstance(e, E):
            return
        if e.tag == "KeyedObject":
            keyed.add(e.attrs.get("objectId"))
        for k in e.kids:
            scan_keys(k)

    for p in parts:
        scan_keys(p)
    skip_ids = {_TITLE_ID[0]} if _TITLE_ID[0] else set()
    n_lift = [0]
    n_conv = [0]

    def walk(e, dash, skipping):
        if not isinstance(e, E):
            return
        if e.attrs.get("id") in skip_ids:
            skipping = True
        if e.tag == "TextValueRun" and not skipping and e.attrs.get("id") not in keyed:
            dbc = [k for k in e.kids if isinstance(k, E) and k.tag == "DataBindContext"]
            if dbc:
                d = dbc[0]
                cv = d.attrs.get("converterId")
                if cv is None:
                    d.attrs["converterId"] = CONV_DECRYPT
                    n_conv[0] += 1
                elif cv == CONV_STR:
                    d.attrs["converterId"] = CONV_STR_DEC
                    n_conv[0] += 1
                elif cv == CONV_IDX:
                    d.attrs["converterId"] = CONV_IDX_DEC
                    n_conv[0] += 1
            elif dash and e.attrs.get("text", "").strip():
                name = f"txt{len(_LIFT)}"
                pid = f"0:{5000 + len(_LIFT)}"
                _LIFT.append((name, pid, e.attrs["text"]))
                e(E("DataBindContext", sourcePathIds=f"{VM}-{pid}", propertyKey=K_TEXT, converterId=CONV_DECRYPT))
                n_lift[0] += 1
        for k in e.kids:
            walk(k, dash, skipping)

    for p in parts:
        if isinstance(p, E) and p.tag == "Artboard":
            walk(p, p.attrs.get("viewModelId") == VM, False)
    print(f"decrypt: {n_conv[0]} bound runs, {n_lift[0]} literals lifted to the view model")


_LIFT: list = []
_TITLE_ID = [None]


# ================================================================== assemble
def build():
    lib._state_pos[0] = 0
    parts = []
    main, _ = main_artboard()
    parts.append(main)
    parts += [list_row(AB_GROW, "Game Row", VM_GAME, VM_GAME_DEF, {k: gp(k) for k in G}, 470, 56, 0, 2600, "game"),
              list_row(AB_TROW, "Track Row", VM_TRACK, VM_TRACK_DEF, {k: tp(k) for k in T}, 470, 56, 600, 2600, "track"),
              hub_menu(), core_skin(), ticker(), screen_games(), screen_music(), screen_memory(), screen_settings(),
              case_art(), satellites()]
    decrypt_texts(parts)
    parts += view_models()
    parts += converters() + more_converters()
    for aid, nm in ((AB_HUB, "Hub Menu"), (AB_CORE, "Core Skin"), (AB_TICK, "Ticker"), (AB_GAMES, "Screen Games"),
                    (AB_MUSIC, "Screen Music"), (AB_MEM, "Screen Memory"), (AB_SET, "Screen Settings"),
                    (AB_CASE, "Case Art"), (AB_GROW, "Game Row"), (AB_TROW, "Track Row"), (AB_SAT, "Satellites")):
        parts.append(E("ComponentAsset", artboardId=aid, name=nm))
    # AnimaScript (scripting: wasm): geo3.as is a library module imported by
    # world.as, so it needs no ScriptAsset (SCRIPT_GEO stays reserved)
    parts.append(E("ScriptAsset", id=SCRIPT_WORLD, file="world.as", name="world"))
    parts.append(E("ScriptAsset", id=SCRIPT_GUARD, file="fieldguard.as", name="fieldguard"))
    parts.append(E("ScriptAsset", id=SCRIPT_DEC, file="decrypt.as", name="decrypt"))
    body = "\n".join(str(p) for p in parts)
    OUT.write_text('<Rive version="1" kind="fragment">\n' + body + "\n</Rive>\n")
    print("wrote", OUT, len(body.splitlines()), "lines")


if __name__ == "__main__":
    build()
