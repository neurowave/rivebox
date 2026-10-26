// world.as — the RiveBox 3D world (AnimaScript port of world.luau).
//
// A 3D console dashboard whose every surface is a live Rive artboard. Each UI
// artboard (hub menu, four section screens, satellites, game-case art) is
// instanced against the shared root view model, advanced with its own state
// machines, rendered to a Canvas every frame and sampled as a texture by
// surf.wgsl. Pointer events are ray-cast back onto the 3D surfaces and
// forwarded into the right artboard in its own coordinates, so listeners,
// focus and scrolling work on curved geometry.
//
// The script owns only what is computed: geometry, camera, springs,
// particles. All UI, data, focus and navigation live in RML.
//
// Port notes:
// * Luau numbers are f64, so every scalar here is f64. Vector and Mat4 are f32
//   in both languages, so positions stay in Vector with the same operation
//   order (casts mark where Luau converted a number to float).
// * Multiple return values go through module-level scratch globals.
// * Arrays are 0-based; functions that took a 1-based index in Luau
//   (bladeModel(i), screenFrame(i), ...) still take it 1-based, because the
//   index feeds their maths.
// * math.random is Luau's PCG32 (LuauRng below) with a fixed seed: Luau seeds
//   it from a pointer, so each Luau run drew different motes; here every run
//   draws the same ones (same distribution).
// * CLI 1.7+ derives a pipeline's layout from every binding its shader module
//   declares: one GPUBindGroupLayout.fromShader per module, shared by all of
//   that module's pipelines, and every declared slot filled (1x1 placeholder
//   where a pass doesn't read it).

import { Layout, Context } from "rive/host";
import { Artboard } from "rive/artboard";
import { ViewModel, PropertyNumber, PropertyBoolean, PropertyString, PropertyTrigger } from "rive/data";
import { Renderer } from "rive/renderer";
import { Canvas } from "rive/canvas";
import { ImageSampler, ImageWrap, ImageFilter } from "rive/image";
import { BlendMode } from "rive/paint";
import { Mat2D } from "rive/mat2d";
import { Mat4 } from "rive/mat4";
import { Vector } from "rive/vector";
import { Color } from "rive/color";
import { PointerEvent, KeyboardEvent, ScrollEvent } from "rive/events";
import { clock, date } from "rive/os";
import {
    GPUBindGroup, GPUBindGroupLayout, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBlendState,
    GPUBuffer, GPUCanvas, GPUColorAttachment, GPUColorTargetDesc, GPUDepthStencilDesc, GPUPassDesc, GPUPipeline,
    GPUPipelineDesc, GPURenderPass, GPUSampler, GPUShaderModule, GPUTexture, GPUTextureDesc, GPUTextureView,
    GPUTextureViewDesc, GPUVertexAttribute, GPUVertexBufferLayout,
} from "rive/gpu";
import {
    BlendFactor, BufferUsage, CompareFunction, CullMode, Filter, LoadOp, StoreOp, TextureAspect, TextureFormat,
    VertexFormat, VertexStepMode, WrapMode,
} from "rive/gpu_enums";
import * as Geo from "./geo3";

// ---------------------------------------------------------------- colour
class Rgb {
    r: f64;
    g: f64;
    b: f64;
    constructor(r: f64, g: f64, b: f64) {
        this.r = r;
        this.g = g;
        this.b = b;
    }
}

const PRISM: StaticArray<Rgb> = [
    new Rgb(0.953, 0.0, 0.345),
    new Rgb(1.0, 0.282, 0.235),
    new Rgb(1.0, 0.643, 0.110),
    new Rgb(0.443, 1.0, 0.098),
    new Rgb(0.098, 0.949, 1.0),
    new Rgb(0.188, 0.518, 1.0),
];
const AMBER: Rgb = PRISM[2];
// warm silver: still reads monochrome, but lit by the amber core
const NEUT: Rgb = new Rgb(0.80, 0.70, 0.54);
const DIMN: Rgb = new Rgb(0.40, 0.31, 0.19);
const DEEP: Rgb = DIMN;
const NO_C: Rgb = new Rgb(1.0, 0.36, 0.12);
const MOTE_DIM: Rgb = new Rgb(0.75, 0.62, 0.42);

function col(c: Rgb, k: f64): Rgb {
    return new Rgb(c.r * k, c.g * k, c.b * k);
}

// ---------------------------------------------------------------- constants
const PI: f64 = Math.PI;
const FOV: f64 = 0.74;
// section screens: full at <= SCREEN_FADE0 screens from the focused one, gone at SCREEN_FADE1
const SCREEN_FADE0: f64 = 1.25;
const SCREEN_FADE1: f64 = 2.0;
// start screen <-> dashboard flight: seconds, lift-off curve, lens widening at peak speed
// (fraction of FOV), motion blur shutter (0.5 = 180 deg), streak cap (uv) and radial zoom blur
const DIVE_S: f64 = 3.2;
const PULL_S: f64 = 2.0;
const DIVE_LIFT: f64 = 0.7;
const DIVE_FOV: f64 = 0.3;
const DIVE_SHUTTER: f64 = 1.0;
const DIVE_MAXLEN: f64 = 0.07;
const DIVE_ZOOMBLUR: f64 = 0.06;
const MOTION_BLUR: bool = true;
const DOF: bool = true;
const UBO: u32 = 288;
const HDR: TextureFormat = TextureFormat.rgba16float;
const SAMPLES: u32 = 4;
// 3D render resolution: at most this many pixels (2560x1440) before the adaptive
// step; then, while frames take longer than FRAME_SLOW, drop the scale in steps
const PIX_BUDGET: f64 = 2560 * 1440;
const FRAME_SLOW: f64 = 0.021;
const Q_MIN: f64 = 0.5;
const LEVELS: i32 = 6;
const FLOOR_Y: f64 = -3.0;
// hex sphere around the whole dashboard (radius 30); the dive punches through it
const HEXC: Vector = Vector.xyz(0, 2, -4);
const HEXR: f64 = 30;
const NPART: i32 = 900;
const RNG_SEED: u64 = 1;
// geometry build / start-up replay budget per host call (seconds of clock());
// the host's watchdog stops a call at 200 ms
const BUILD_BUDGET: f64 = 0.05;
const BUILD_LOG: bool = false;
const HEX_FACES_PER_JOB: i32 = 4;
const CABLE_ROWS_PER_JOB: i32 = 60;

// hub menu artboard: four 520x110 rows stacked at 120px pitch
const HUB_W: f64 = 560, HUB_H: f64 = 480, ROW_H: f64 = 110, ROW_PITCH: f64 = 120;
const BLADE_W: f64 = 3.3, BLADE_H: f64 = 0.66, BLADE_R: f64 = 3.4;
const SCREEN_W: f64 = 5.4, SCREEN_H: f64 = 3.04, SCREEN_R: f64 = 5.0;
const CASE_W: f64 = 0.62, CASE_H: f64 = 0.86, CASE_D: f64 = 0.1;
const TILE_W: f64 = 256, TILE_H: f64 = 360;
const ATLAS_C: i32 = 4, ATLAS_R: i32 = 2;
// satellites atlas (gen.py SAT_*): six 500x310 cells
const SAT_W: f64 = 1040, SAT_H: f64 = 1000, SAT_CW: f64 = 500, SAT_CH: f64 = 310;
const SAT_PW: f64 = 2.5, SAT_R: f64 = 6;
const SAT_PH: f64 = SAT_PW * SAT_CH / SAT_CW;
// each satellite: world position, bob phase, scale (5 numbers per satellite)
const SATS: StaticArray<f64> = [
    -5.6, 2.5, -3.2, 0.0, 1.0,  // system
    8.6, 3.0, -7.5, 1.3, 1.15,  // now playing
    -7.8, -0.6, -2.2, 2.1, 1.0, // friends
    2.4, 3.9, -10.5, 0.7, 1.3,  // achievement
    9.6, -2.0, -2.5, 2.9, 1.0,  // network
    -4.6, -1.9, 3.2, 1.8, 0.75, // player (foreground)
];
const NSATS: i32 = 6;

// section screens live on a wide arc in world space; the camera travels to them
const ARC_C: Vector = Vector.xyz(0.4, 0.05, -6);
const ARC_R: f64 = 7;
const ARC_A0: f64 = 0.19, ARC_STEP: f64 = 0.62;

const REFL: f64 = 0.2;
const D_NAMES: StaticArray<string> = ["d1", "d2", "d3", "d4", "d5", "d6"];
const U_NAMES: StaticArray<string> = ["u1", "u2", "u3", "u4", "u5"];
const BIT_KEYS: StaticArray<string> = ["inner", "neutral", "yes", "no", "outer"];
const GLASS_KEYS: StaticArray<string> = ["outer", "neutral", "yes", "no"];
const DOF_KEYS: StaticArray<string> = ["aH", "bH", "bK", "t1", "t2", "aBg", "aFg", "bD", "bF", "aBgT", "aFgT", "bDT"];

// ---------------------------------------------------------------- helpers
function V(x: f64, y: f64, z: f64): Vector {
    return Vector.xyz(<f32>x, <f32>y, <f32>z);
}

function clamp(x: f64, a: f64, b: f64): f64 {
    return Math.max(a, Math.min(b, x));
}

function lerp(a: f64, b: f64, t: f64): f64 {
    return a + (b - a) * t;
}

function smooth(t0: f64): f64 {
    let t = clamp(t0, 0, 1);
    return t * t * (3 - 2 * t);
}

function mixc(a: Rgb, b: Rgb, k: f64): Rgb {
    return new Rgb(lerp(a.r, b.r, k), lerp(a.g, b.g, k), lerp(a.b, b.b, k));
}

function tr(x: f64, y: f64, z: f64): Mat4 {
    return Mat4.fromTranslation(<f32>x, <f32>y, <f32>z);
}

function rotX(a: f64): Mat4 {
    return Mat4.fromRotationX(<f32>a);
}

function rotY(a: f64): Mat4 {
    return Mat4.fromRotationY(<f32>a);
}

function rotZ(a: f64): Mat4 {
    return Mat4.fromRotationZ(<f32>a);
}

function scl(x: f64, y: f64, z: f64): Mat4 {
    return Mat4.fromScale(<f32>x, <f32>y, <f32>z);
}

function vlerp(a: Vector, b: Vector, t: f64): Vector {
    return Vector.lerp(a, b, <f32>t);
}

// scratch outputs for functions that return two numbers in Luau
let OX: f64 = 0;
let OZ: f64 = 0;
let OV: Vector = Vector.xyz(0, 0, 0);
let OV2: Vector = Vector.xyz(0, 0, 0);

// Exact critically damped spring step (closed form): unconditionally stable
// at ANY frame rate. Explicit-Euler springs blow up when dt * wn gets large
// (a 30 fps screen recording sent the focus puller to infinity and DoF
// switched off). -> OX (x), OZ (v)
function critStep(x: f64, v: f64, target: f64, wn: f64, dt: f64): void {
    let d = x - target;
    let e = Math.exp(-wn * dt);
    let tmp = (v + wn * d) * dt;
    OX = target + (d + tmp) * e;
    OZ = (v - wn * tmp) * e;
}

// generic spring with stiffness k and damping c, sub-stepped so each step
// stays inside the semi-implicit Euler stability region at low frame rates
// -> OX (x), OZ (v)
function springStep(x0: f64, v0: f64, target: f64, k: f64, c: f64, dt: f64): void {
    let n = Math.max(1, Math.ceil(dt * Math.max(c, Math.sqrt(k)) / 0.5));
    let h = dt / n;
    let x = x0, v = v0;
    for (let i = 1; <f64>i <= n; i++) {
        v += ((target - x) * k - v * c) * h;
        x += v * h;
    }
    OX = x;
    OZ = v;
}

// Luau's math.random: PCG32 with Luau's increment, two draws per double
class LuauRng {
    state: u64 = 0;
    next32(): u32 {
        let old = this.state;
        this.state = old * 6364136223846793005 + 105;
        let xorshifted = <u32>(((old >> 18) ^ old) >> 27);
        let rot = <u32>(old >> 59);
        return (xorshifted >> rot) | (xorshifted << ((32 - rot) & 31));
    }
    seed(s: u64): void {
        this.state = 0;
        this.next32();
        this.state += s;
        this.next32();
    }
    random(): f64 {
        let rl = this.next32();
        let rh = this.next32();
        // ldexp(double(rl | rh << 32), -64)
        return <f64>(<u64>rl | (<u64>rh << 32)) * reinterpret<f64>(<u64>959 << 52);
    }
}

function colorTarget(fmt: TextureFormat, blend: GPUBlendState? = null): GPUColorTargetDesc {
    let c = new GPUColorTargetDesc();
    c.format = fmt;
    c.blend = blend;
    return c;
}

function blendState(sc: BlendFactor, dc: BlendFactor, sa: BlendFactor, da: BlendFactor): GPUBlendState {
    let b = new GPUBlendState();
    b.srcColor = sc;
    b.dstColor = dc;
    b.srcAlpha = sa;
    b.dstAlpha = da;
    return b;
}

function attachment(view: GPUTextureView?, resolve: GPUTextureView?, r: f32, g: f32, b: f32, a: f32): GPUColorAttachment {
    let c = new GPUColorAttachment();
    c.view = view;
    c.resolveTarget = resolve;
    c.loadOp = LoadOp.clear;
    c.storeOp = StoreOp.store;
    c.clearR = r;
    c.clearG = g;
    c.clearB = b;
    c.clearA = a;
    return c;
}

function rtex(w: f64, h: f64, fmt: TextureFormat, samples: u32 = 1): GPUTexture {
    let d = new GPUTextureDesc();
    d.width = <u32>w;
    d.height = <u32>h;
    d.format = fmt;
    d.renderTarget = true;
    d.sampleCount = samples;
    return new GPUTexture(d);
}

// ---------------------------------------------------------------- types
class Surf {
    inst: Artboard;
    canvas: Canvas;
    view: GPUTextureView;
    w: f64;
    h: f64;
    s: f64;
    live: bool = true;
    constructor(inst: Artboard, canvas: Canvas, view: GPUTextureView, w: f64, h: f64, s: f64) {
        this.inst = inst;
        this.canvas = canvas;
        this.view = view;
        this.w = w;
        this.h = h;
        this.s = s;
    }
}

class Obj {
    alpha: f64 = 1;
    vbuf: GPUBuffer;
    count: u32;
    ubo: GPUBuffer;
    bind: GPUBindGroup;
    uboR: GPUBuffer;
    bindR: GPUBindGroup;
    add: bool;
    refl: bool;
    constructor(vbuf: GPUBuffer, count: u32, ubo: GPUBuffer, bind: GPUBindGroup, uboR: GPUBuffer, bindR: GPUBindGroup,
        add: bool, refl: bool) {
        this.vbuf = vbuf;
        this.count = count;
        this.ubo = ubo;
        this.bind = bind;
        this.uboR = uboR;
        this.bindR = bindR;
        this.add = add;
        this.refl = refl;
    }
}

class Mote {
    a: f64 = 0;
    r: f64 = 0;
    y: f64 = 0;
    v: f64 = 0;
    c: f64 = 0;
    s: f64 = 0;
    ph: f64 = 0;
}

// Cables: big dark tentacle bundles that run from the far dark into the
// foreground and past the camera, for depth. { radius, sway, phase, points }
class CableDef {
    r: f64;
    sway: f64;
    ph: f64;
    pts: Array<Vector>;
    constructor(r: f64, sway: f64, ph: f64, pts: Array<Vector>) {
        this.r = r;
        this.sway = sway;
        this.ph = ph;
        this.pts = pts;
    }
}

// dense centreline for camera collision avoidance, plus bounding spheres over
// chunks of 32 centreline points (broad phase)
class CableLine {
    r: f64;
    pts: Array<Vector>;
    bc: Array<Vector>;
    br: Array<f64>;
    constructor(r: f64, pts: Array<Vector>, bc: Array<Vector>, br: Array<f64>) {
        this.r = r;
        this.pts = pts;
        this.bc = bc;
        this.br = br;
    }
}

// one arrival group: per-element spring (value, velocity)
class ArrG {
    a: Array<f64>;
    v: Array<f64>;
    constructor(a: Array<f64>, v: Array<f64>) {
        this.a = a;
        this.v = v;
    }
}

function arcCable(rad: f64, a: f64, y: f64): Vector {
    return V(0.4 + rad * Math.sin(a), y, -6 + rad * Math.cos(a));
}

function makeCables(): Array<CableDef> {
    let c = new Array<CableDef>();
    // hub foreground: sweeps down past the lower-left of the hub camera, then away along the floor
    c.push(new CableDef(0.34, 0.25, 0.0, [V(-13, 10, 1), V(-6.5, 3.4, 7.6), V(-3.2, -1.3, 7.9), V(-1.6, -2.66, 3.5),
        V(2.2, -2.66, -7), V(6, -2.66, -22), V(8, -2.66, -48)]));
    // hub foreground: drops in from the upper right and loops away up into the dark
    c.push(new CableDef(0.24, 0.35, 1.7, [V(15, 11, 3), V(6.6, 4.6, 7.4), V(3.6, 2.9, 7.3), V(1.6, 6.2, -0.5),
        V(-2, 12, -15), V(-4, 20, -30)]));
    // far sweep behind the core
    c.push(new CableDef(0.75, 0.5, 3.1, [V(-28, 13, -32), V(-13, 2, -17), V(-5, -2.3, -11), V(6, -2.3, -15),
        V(18, 4, -27), V(32, 15, -42)]));
    // overhead tentacle across the top
    c.push(new CableDef(0.46, 0.6, 4.4, [V(-20, 9, -1), V(-7, 5.6, -4), V(3, 6.4, -7.5), V(14, 9.5, -12), V(26, 14, -18)]));
    // section foreground: sags down from above between the camera and the screens
    c.push(new CableDef(0.16, 0.2, 5.0, [arcCable(4.6, -0.3, 7), arcCable(4.0, 0.5, 1.75), arcCable(4.2, 1.15, 2.4),
        arcCable(3.8, 1.75, 1.6), arcCable(4.6, 2.6, 8)]));
    // section background beyond the arc: huge, snaking down from the dark
    c.push(new CableDef(0.9, 0.7, 0.9, [arcCable(15, -0.2, 16), arcCable(13, 0.5, 3), arcCable(14, 1.2, -2.1),
        arcCable(12, 1.9, 2.5), arcCable(16, 2.6, 18)]));
    // hanging tentacles far away
    c.push(new CableDef(0.32, 0.45, 2.6, [V(-8, 22, -21), V(-7.2, 6, -23), V(-9, -1.2, -24), V(-11, -2.68, -21)]));
    c.push(new CableDef(0.3, 0.45, 3.9, [V(13, 22, -17), V(11.6, 5, -16), V(13, -1.4, -15), V(15, -2.7, -11)]));
    c.push(new CableDef(0.26, 0.4, 1.1, [V(20, 20, -2), V(17, 4, 0), V(18.5, -2.74, 3), V(14, -2.74, 9)]));
    // ---- start-screen field: giant cables around the far vantage (z 40..190)
    // leading lines along the floor that converge on the dashboard
    c.push(new CableDef(1.3, 0.05, 0.4, [V(-34, -2.6, 200), V(-16, -2.6, 128), V(-6, -2.6, 64), V(-7, -2.62, 30),
        V(-12, -2.66, 14), V(-24, -2.7, 6)]));
    c.push(new CableDef(1.1, 0.05, 2.9, [V(44, -2.6, 190), V(23, -2.6, 112), V(10, -2.6, 56), V(12, -2.62, 26),
        V(17, -2.66, 12), V(28, -2.7, 4)]));
    // colossal arch over the dive path
    c.push(new CableDef(2.2, 0.6, 1.4, [V(-70, -3, 72), V(-30, 34, 88), V(8, 46, 96), V(46, 28, 84), V(76, -3, 62)]));
    // tentacle dropping right beside the start camera (soft, out of focus)
    // (moved 8 units left of the dive path: the camera used to fly through it)
    c.push(new CableDef(0.9, 0.5, 3.7, [V(-5, 70, 156), V(-14, 30, 134), V(-20, 15, 124), V(-34, 6, 116), V(-48, -2.6, 104)]));
    c.push(new CableDef(0.55, 0.6, 5.3, [V(-44, 70, 150), V(-34, 26, 136), V(-30, 10, 130), V(-30, -2.6, 118)]));
    // hanging cluster in the mid-ground
    c.push(new CableDef(0.7, 0.45, 0.7, [V(26, 70, 48), V(21, 20, 44), V(16, 3, 40), V(19, -2.7, 30), V(30, -2.7, 16)]));
    c.push(new CableDef(0.8, 0.45, 4.1, [V(-38, 66, 52), V(-30, 18, 48), V(-27, -2.7, 40), V(-14, -2.7, 24)]));
    c.push(new CableDef(1.6, 0.3, 2.2, [V(70, 60, 130), V(40, 16, 120), V(28, -2.6, 100), V(18, -2.6, 70), V(9, -2.6, 40)]));
    // start screen hero X: two big close-up cables crossing just behind the
    // RIVE logo (~32 units in front of the start camera). The dive hops up and
    // to the right through the gap between their upper arms (see diveHop)
    c.push(new CableDef(1.8, 0.12, 0.6, [V(-41.3, -3.2, 128.7), V(-26.7, 3.8, 125.5), V(-18.5, 7.7, 123.8),
        V(-14.0, 9.9, 122.8), V(-8.5, 12.6, 121.6), V(0.6, 16.9, 119.6), V(15.2, 24.0, 116.4)]));
    c.push(new CableDef(1.2, 0.12, 3.3, [V(4.5, -4.8, 135.2), V(-6.3, -0.5, 127.2), V(-11.9, 6.3, 122.2),
        V(-13.7, 9.6, 119.8), V(-15.5, 13.8, 116.8), V(-18.5, 20.6, 112.0), V(-23.4, 31.5, 104.3)]));
    return c;
}

const CABLES: Array<CableDef> = makeCables();

// ---------------------------------------------------------------- placement
// resting blade placement (shared by build and the per-frame transforms)
// i is 1-based -> OV (position), OX (yaw)
function bladeBase(i: f64): void {
    let k = i - 2.5; // -1.5 .. 1.5
    let y = -k * 0.92;
    let x = 3.55 + 0.36 * k * k;
    let z = 1.45 - 0.3 * k * k;
    OV = V(x, y, z);
    OX = -0.32 - 0.04 * k * k;
}

// arc mesh centred on the origin, concave toward +z (the camera)
function arcMesh(w: f64, h: f64, R: f64, seg: i32): Geo.Mesh {
    let span = w / R;
    return Geo.arc(R, PI + span / 2, PI - span / 2, h, seg, true);
}

// Section screens stand on a wide arc around ARC_C, all facing it, so the
// camera travels between them through real depth. screenFrame(i) gives the
// resting pose of screen i (position + yaw); the screen's normal points at the
// arc centre, i.e. back toward the hub.
// (order runs from the high-angle end so the NEXT section is to the camera's
// RIGHT: Games on the left ... Settings on the right, matching the arrows)
function arcAngle(i0: f64): f64 {
    return ARC_A0 + (3 - i0) * ARC_STEP;
}

// i is 1-based -> OV2 (position), OZ (yaw)
function screenFrame(i: f64): void {
    let a = arcAngle(i - 1);
    OV2 = V(<f64>ARC_C.x + Math.sin(a) * ARC_R, <f64>ARC_C.y + (i - 2.5) * -0.05, <f64>ARC_C.z + Math.cos(a) * ARC_R);
    OZ = a;
}

// start-screen dive path: eye/at for path parameter z (0 = hub, 1 = far
// start vantage), given the hub-side eye/at -> OV (eye), OV2 (at)
function diveEye(eye: Vector, at: Vector, z: f64, t: f64): void {
    if (z <= 0.0005) {
        OV = eye;
        OV2 = at;
        return;
    }
    let drift = t * 0.03;
    let farEye = V(-18 + Math.sin(drift) * 4, 17 + Math.sin(t * 0.07) * 1.5, 150 + Math.cos(drift) * 4);
    let farAt = V(0.6, -0.6, -4);
    let k = z * z * (3 - 2 * z);
    let kd = Math.pow(k, 1.6);
    // swoop: the path bows down through the cable field
    let mid = V(-9, 6.0, 70);
    let a1 = vlerp(eye, mid, kd);
    let a2 = vlerp(mid, farEye, kd);
    let e = vlerp(a1, a2, kd);
    // diveHop: lift up and right through the gap in the hero X behind the
    // logo, peaking where the path crosses the cables (~32 units in)
    let dir = Vector.normalized(farAt - farEye);
    let along = <f64>Vector.dot(e - farEye, dir);
    // sin^2 window: zero slope AND finite curvature at both ends, so the hop
    // eases in and out instead of snapping the view when it finishes
    let hw = Math.sin(PI * clamp(along / 84, 0, 1));
    hw = hw * hw;
    let upV = Vector.normalized(Vector.cross3(Vector.cross3(dir, Vector.xyz(0, 1, 0)), dir));
    let rtV = Vector.normalized(Vector.cross3(dir, upV));
    e = e + (upV * <f32>5.0 + rtV * <f32>1.6) * <f32>hw;
    // (1-(1-k)^2.2 instead of k^0.7: same early swing toward the far target,
    // but finite slope at k = 0, so the look direction doesn't snap at lift-off)
    OV2 = vlerp(at, farAt, 1 - Math.pow(1 - k, 2.2));
    OV = e;
}

// q (flow progress) -> z lookup: integrate how fast the image changes along
// the path (travel / distance to the hub + view rotation) and invert it
function buildFlowLut(breath: bool): Array<f64> {
    let N = 400;
    let eye0 = V(-1.0, 0.7, 11.2), at0 = V(1.4, -0.1, 0);
    let F = V(0.5, 0, 0);
    let cum = new Array<f64>(N + 1);
    cum[0] = 0;
    diveEye(eye0, at0, 0, 0);
    let pe = OV, pa = OV2;
    let pd = Vector.normalized(pa - pe);
    for (let i = 1; i <= N; i++) {
        let z = <f64>i / <f64>N;
        diveEye(eye0, at0, z, 0);
        let e = OV, a = OV2;
        let d = Vector.normalized(a - e);
        let travel = <f64>Vector.length(e - pe) / Math.max(<f64>Vector.length(e - F), 3);
        // a breath at the hex wall (r = 30 around (0, y, -4)): count flow
        // there up to 2.4x so the flight eases through it instead of
        // punching past at peak speed (both directions)
        let rw = <f64>Vector.length(e - HEXC);
        if (breath) {
            let q = (rw - HEXR) / 7;
            travel *= 1 + 1.4 * Math.exp(-(q * q));
        }
        let turn = Math.acos(clamp(<f64>Vector.dot(d, pd), -1, 1));
        // (+ a constant floor so the near-static first stretch off the hub
        // isn't raced through)
        cum[i] = cum[i - 1] + travel + turn * 1.2 + 0.0015;
        pe = e;
        pd = d;
    }
    let total = cum[N];
    let M = 256;
    let lut = new Array<f64>(M + 1);
    let j = 1; // 1-based like the Luau loop: cum[j] here is Luau's cum[j + 1]
    for (let m = 0; m <= M; m++) {
        let target = <f64>m / <f64>M * total;
        while (j < N && cum[j] < target) {
            j += 1;
        }
        let c0 = cum[j - 1], c1 = cum[j];
        let f = c1 > c0 ? (target - c0) / (c1 - c0) : 0;
        lut[m] = (<f64>(j - 1) + clamp(f, 0, 1)) / <f64>N;
    }
    // smooth the mapping (its slope has kinks where the path's flow changes
    // character, e.g. lift-off from the hub); endpoints stay pinned
    for (let it = 0; it < 24; it++) {
        let prev = lut[0];
        for (let m = 1; m < M; m++) {
            let cur = lut[m];
            lut[m] = (prev + cur * 2 + lut[m + 1]) * 0.25;
            prev = cur;
        }
    }
    return lut;
}

// uniform block beyond the two matrices (see surf.wgsl `U`), 10 vec4:
//  0 eye.xyz, time   1 tint.rgb, alpha   2 params   3 uvr   4 mode
//  5 fx.xyz, reflK   6..9 c[16]
const UB: StaticArray<f64> = new StaticArray<f64>(40);

function ubBegin(tint: Rgb, alpha: f64): void {
    for (let k = 0; k < 40; k++) {
        UB[k] = 0;
    }
    UB[4] = tint.r;
    UB[5] = tint.g;
    UB[6] = tint.b;
    UB[7] = alpha;
    UB[14] = 1;
    UB[15] = 1;
}

function ubParams(a: f64, b: f64, c: f64, d: f64): void {
    UB[8] = a;
    UB[9] = b;
    UB[10] = c;
    UB[11] = d;
}

function ubUvr(a: f64, b: f64, c: f64, d: f64): void {
    UB[12] = a;
    UB[13] = b;
    UB[14] = c;
    UB[15] = d;
}

function ubMode(a: f64, b: f64, c: f64, d: f64): void {
    UB[16] = a;
    UB[17] = b;
    UB[18] = c;
    UB[19] = d;
}

function ubFx(a: f64, b: f64, c: f64): void {
    UB[20] = a;
    UB[21] = b;
    UB[22] = c;
}

function ubC(i: i32, a: f64, b: f64, c: f64, d: f64): void {
    UB[24 + i * 4] = a;
    UB[25 + i * 4] = b;
    UB[26 + i * 4] = c;
    UB[27 + i * 4] = d;
}

const MIRROR: Mat4 = tr(0, 2 * FLOOR_Y, 0) * scl(1, -1, 1);

// pickArc / route results
let PICK_UV: Vector = Vector.xy(0, 0);
let R_INST: Artboard? = null;
let R_LP: Vector = Vector.xy(0, 0);
let R_WHICH: string = "";

// ---------------------------------------------------------------- the layout
export class World extends Layout {
    @input hub: Artboard? = null;
    @input games: Artboard? = null;
    @input music: Artboard? = null;
    @input memory: Artboard? = null;
    @input settings: Artboard? = null;
    @input caseArt: Artboard? = null;
    @input sats: Artboard? = null;
    @input section: f64 = 0;
    @input mode: f64 = 0;

    context: Context? = null;
    ready: bool = false;
    // staged build: setup done, next geometry job, in-progress pieces, and the
    // advance() steps recorded while loading (replayed once ready)
    coreBuilt: bool = false;
    jobIdx: i32 = 0;
    bview: GPUTextureView? = null;
    hexB: Geo.HexSphereBuilder? = null;
    bladeMesh: Geo.Mesh? = null;
    frameMesh: Geo.Mesh? = null;
    cableB: Geo.CableBuilder? = null;
    cableEp: Array<Vector> = [];
    pendingDt: Array<f64> = [];
    rng: LuauRng = new LuauRng();
    hubSurf: Surf? = null;
    satSurf: Surf? = null;
    secList: Array<Surf> = [];
    cases: Array<Artboard> = [];
    caseCanvas: Canvas? = null;
    caseView: GPUTextureView? = null;

    gpu: GPUCanvas? = null;
    depth: GPUTextureView? = null;
    msaa: GPUTextureView? = null;
    hdr: GPUTextureView? = null;
    bloom: Array<GPUTextureView> = [];
    bw: Array<f64> = [];
    bh: Array<f64> = [];
    pipeTex: GPUPipeline? = null;
    pipeAdd: GPUPipeline? = null;
    pipeScrim: GPUPipeline? = null;
    pipeGlass: GPUPipeline? = null;
    pipeTexB: GPUPipeline? = null;
    pipeAddB: GPUPipeline? = null;
    dofP: Map<string, GPUPipeline> = new Map<string, GPUPipeline>();
    dofT: Map<string, GPUTextureView> = new Map<string, GPUTextureView>();
    msaaB: GPUTextureView? = null;
    msaaDB: GPUTextureView? = null;
    hdrB: GPUTextureView? = null;
    distB: GPUTextureView? = null;
    hdrC: GPUTextureView? = null;
    distF: GPUTextureView? = null;
    snapBind: GPUBindGroup? = null;
    distP: GPUTextureView? = null;
    glass: Map<string, Obj> = new Map<string, Obj>();
    cableLines: Array<CableLine> = [];
    pipePart: GPUPipeline? = null;
    pDown: GPUPipeline? = null;
    pUp: GPUPipeline? = null;
    pComp: GPUPipeline? = null;
    pMotion: GPUPipeline? = null;
    pMotion2: GPUPipeline? = null;
    motionBind2: GPUBindGroup? = null;
    hdrM: GPUTextureView? = null;
    pTaa: GPUPipeline? = null;
    frameN: f64 = 0;
    hdrRaw: GPUTextureView? = null;
    motionUbo: GPUBuffer? = null;
    motionBind: GPUBindGroup? = null;
    prevVP: Mat4? = null;
    prevVPT: Mat4? = null;
    focusT: f64 = 46;
    focusV: f64 = 0;
    prevHdr: GPUTextureView? = null;
    pCopy: GPUPipeline? = null;
    copyBind: GPUBindGroup? = null;
    msaaD: GPUTextureView? = null;
    dist: GPUTextureView? = null;
    pDofDown: GPUPipeline? = null;
    objLayout: GPUBindGroupLayout? = null;
    postLayout: GPUBindGroupLayout? = null;
    motLayout: GPUBindGroupLayout? = null;
    partLayout: GPUBindGroupLayout? = null;
    placeholder: GPUTextureView? = null;
    dw: f64 = 1;
    dh: f64 = 1;
    focusD: f64 = 10;
    dofK: f64 = 1;
    postBind: Map<string, GPUBindGroup> = new Map<string, GPUBindGroup>();
    postUbo: Map<string, GPUBuffer> = new Map<string, GPUBuffer>();
    psampler: GPUSampler? = null;
    partBuf: GPUBuffer? = null;
    partUbo: GPUBuffer? = null;
    partBind: GPUBindGroup? = null;
    partData: ArrayBuffer = new ArrayBuffer(NPART * 32);
    partF: Float32Array = Float32Array.wrap(this.partData);
    partCount: i32 = 0;
    sampler: GPUSampler? = null;
    blank: Canvas? = null;
    // render pass descriptors (Luau built these tables every frame)
    passA: GPUPassDesc? = null;
    passB: GPUPassDesc? = null;
    fsAtt: GPUColorAttachment = attachment(null, null, 0, 0, 0, 1);
    fsPass: GPUPassDesc = new GPUPassDesc();
    twoA: GPUColorAttachment = attachment(null, null, 0, 0, 0, 0);
    twoB: GPUColorAttachment = attachment(null, null, 0, 0, 0, 0);
    twoPass: GPUPassDesc = new GPUPassDesc();
    pass: GPURenderPass? = null;

    objs: Map<string, Obj> = new Map<string, Obj>();
    blades: Array<Obj> = [];
    frames: Array<Obj> = [];
    beams: Array<Obj> = [];
    orbs: Array<Obj> = [];
    orbShells: Array<Obj> = [];
    tubes: Array<Obj> = [];
    caseObjs: Array<Obj> = [];
    caseEdges: Array<Obj> = [];
    screens: Array<Obj> = [];
    screenFrames: Array<Obj> = [];
    screenBeams: Array<Obj> = [];
    satObjs: Array<Obj> = [];
    satFrames: Array<Obj> = [];
    cables: Array<Obj> = [];
    bit: Map<string, Obj> = new Map<string, Obj>();
    bitW: Array<f64> = [1, 0, 0]; // eased weights: neutral, yes, no
    bitPop: f64 = 1; // scale spring for the shape snap
    bitPopV: f64 = 0;
    bitMood: f64 = 0; // 0 neutral, 1 yes, 2 no
    bitT: f64 = 0; // seconds left in the current mood
    bitIdle: f64 = 6; // countdown to the next idle "thought"
    cableLen: Array<f64> = [];
    apex: Array<Vector> = [];
    reveal: Array<f64> = [1, 1, 1, 1];
    bladeReveal: f64 = 0;
    tz: f64 = 1; // title <-> hub: 1 = far away on the start screen, 0 = in the dashboard
    tzV: f64 = 0;
    ripple: f64 = 0;
    rippleK: f64 = 0;
    flash: f64 = 0;
    glitch: f64 = 0;
    camAt: Vector = Vector.xyz(0, 0, 0);
    fovK: f64 = 0;
    zoomK: f64 = 0;
    // start <-> hub flight: eased timeline on a flow-normalised progress
    tq: f64 = 1;
    tqV: f64 = 0;
    tqFrom: f64 = 1;
    tqTo: f64 = 1;
    tqClock: f64 = 0;
    tqDur: f64 = 1;
    flightBell: f64 = 0;
    flowLut: Array<f64>? = null;
    flowLutOut: Array<f64>? = null;
    hexVis: f64 = 1;
    avoidOff: Vector = Vector.xyz(0, 0, 0);
    avoidV: Vector = Vector.xyz(0, 0, 0);
    camDt: f64 = 1.0 / 60.0;

    sizeX: f64 = 1;
    sizeY: f64 = 1;
    scale: f64 = 1;
    rs: f64 = 1;
    // adaptive resolution (see PIX_BUDGET)
    q: f64 = 1;
    ftAvg: f64 = 1.0 / 60.0;
    liveT: f64 = 0;
    lastDrop: f64 = 0;
    time: f64 = 0;
    scratch: ArrayBuffer = new ArrayBuffer(512);
    sf: Float32Array = Float32Array.wrap(this.scratch);
    v4: StaticArray<f32> = new StaticArray<f32>(4);
    isampler: ImageSampler = ImageSampler(ImageWrap.clamp, ImageWrap.clamp, ImageFilter.bilinear);
    proj: Mat4 = Mat4.identity();
    view: Mat4 = Mat4.identity();
    viewProj: Mat4 = Mat4.identity();
    eye: Vector = Vector.xyz(0, 0, 9);

    // springs / eased state
    sec: f64 = 0; // eased section index
    secV: f64 = 0;
    s: f64 = 0; // 0 hub .. 1 section
    sv: f64 = 0;
    focusPop: Array<f64> = [1, 0, 0, 0];
    pointer: Vector = Vector.xy(0, 0);
    pointerT: Vector = Vector.xy(0, 0);
    tiltP: Vector = Vector.xy(0, 0);
    tiltV: Vector = Vector.xy(0, 0);
    boost: f64 = 0;
    lastSection: f64 = 0;
    lastMode: f64 = 0;
    lastBitMode: f64 = 0;
    lastGame: f64 = 0;
    caseSpin: f64 = 0;
    gameF: f64 = 0;

    // view model handles
    pGame: PropertyNumber? = null;
    pPlaying: PropertyBoolean? = null;
    pClock: PropertyString? = null;
    pClockH: PropertyString? = null;
    pClockM: PropertyString? = null;
    pFieldDone: PropertyTrigger? = null;
    pAccept: PropertyTrigger? = null;
    pCue: PropertyNumber? = null;
    pArrived: PropertyBoolean? = null;
    // arrival choreography: per-element 0->1 springs (value, velocity) that
    // restart whenever their group comes on screen; overshoot = secondary motion
    arr: Map<string, ArrG> = new Map<string, ArrG>();
    cueArm: f64 = 0;
    cueSent: bool = true;
    pEditing: PropertyBoolean? = null;
    clockT: f64 = 0;

    motes: Array<Mote> = [];
    bladeHit: Array<Mat4> = [];
    screenHit: Array<Mat4> = [];
    capture: bool = false;
    corePos: Vector = Vector.xyz(0, 0, 0);
    debugPick: bool = false;

    constructor() {
        super();
        this.rng.seed(RNG_SEED);
    }

    log(msg: string): void {
        let c = this.context;
        if (c != null) {
            c.log(msg);
        }
    }

    // ---- arrival choreography -------------------------------------------
    // A group ("blades", "orbs", "sats", "screen", "cases", "core") holds one
    // spring per element. arrive() resets them all to 0 with a staggered start
    // (negative initial value = waits), and stepArrive() runs an underdamped
    // spring to 1, so each element lands with a little overshoot and settle.
    arrive(group: string, n: i32, stagger: f64, lead: f64): void {
        let a = new Array<f64>(n);
        let v = new Array<f64>(n);
        for (let i = 1; i <= n; i++) {
            // spring position starts below 0: the clamp in arrK() holds the element
            // hidden until the spring has travelled up to 0 = its stagger slot
            a[i - 1] = -(lead + <f64>(i - 1) * stagger) * 3;
            v[i - 1] = 0;
        }
        this.arr.set(group, new ArrG(a, v));
    }

    // park a group off-stage (held until the next arrive())
    hideGroup(group: string, n: i32): void {
        let a = new Array<f64>(n);
        let v = new Array<f64>(n);
        for (let i = 0; i < n; i++) {
            a[i] = -1e6;
            v[i] = 0;
        }
        this.arr.set(group, new ArrG(a, v));
    }

    stepArrive(dt: f64): void {
        let groups = this.arr.values();
        for (let g = 0; g < groups.length; g++) {
            let a = groups[g].a;
            let v = groups[g].v;
            for (let i = 0; i < a.length; i++) {
                if (a[i] < 0) {
                    // waiting in the queue: march up at a constant rate (3 units/s)
                    a[i] = Math.min(0, a[i] + dt * 3);
                } else {
                    // underdamped spring 0 -> 1 (~0.7 s, ~15% overshoot)
                    springStep(a[i], v[i], 1, 60, 8.5, dt);
                    a[i] = OX;
                    v[i] = OZ;
                }
            }
        }
    }

    // 0..1(+overshoot) arrival of element i (1-based) in a group (1 when never armed)
    arrK(group: string, i: i32): f64 {
        if (!this.arr.has(group)) {
            return 1;
        }
        let a = this.arr.get(group).a;
        if (i < 1 || i > a.length) {
            return 1;
        }
        return Math.max(a[i - 1], 0);
    }

    makeObj(m: Geo.Mesh, view: GPUTextureView, add: bool, refl: bool = true): Obj? {
        let lay = this.objLayout;
        let smp = this.sampler;
        if (lay == null || smp == null) {
            return null;
        }
        let ubo = new GPUBuffer(BufferUsage.uniform, UBO);
        let bind = new GPUBindGroup(lay, [new GPUBindGroupUBO(0, ubo)], [new GPUBindGroupTexture(1, view)],
            [new GPUBindGroupSampler(2, smp)]);
        let uboR = new GPUBuffer(BufferUsage.uniform, UBO);
        let bindR = new GPUBindGroup(lay, [new GPUBindGroupUBO(0, uboR)], [new GPUBindGroupTexture(1, view)],
            [new GPUBindGroupSampler(2, smp)]);
        let vbuf = new GPUBuffer(BufferUsage.vertex, <u32>m.buf.byteLength, m.buf, true);
        return new Obj(vbuf, <u32>m.count, ubo, bind, uboR, bindR, add, refl);
    }

    makeSurf(ab: Artboard?, vm: ViewModel, w: f64, h: f64, s: f64): Surf? {
        let context = this.context;
        if (ab == null || context == null) {
            return null;
        }
        let inst = ab.instance(vm);
        inst.width = w;
        inst.height = h;
        let canvas = context.canvas(<u32>Math.floor(w * s), <u32>Math.floor(h * s));
        if (canvas == null) {
            return null;
        }
        let view = canvas.image.view();
        if (view == null) {
            return null;
        }
        return new Surf(inst, canvas, view, w, h, s);
    }

    renderSurf(sf: Surf): void {
        let r = sf.canvas.beginFrame(Color.rgba(0, 0, 0, 0));
        if (r == null) {
            return;
        }
        r.save();
        r.transform(Mat2D.withUniformScale(<f32>sf.s));
        sf.inst.draw(r);
        r.restore();
        sf.canvas.endFrame();
    }

    fullPipe(module: GPUShaderModule, layout: GPUBindGroupLayout, entry: string, fmt: TextureFormat,
        n: i32 = 1, blend: GPUBlendState? = null): GPUPipeline {
        let d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.vertexEntryPoint = "vs_full";
        d.fragmentModule = module;
        d.fragmentEntryPoint = entry;
        d.colorTargets = n == 2 ? [colorTarget(fmt), colorTarget(fmt)] : [colorTarget(fmt, blend)];
        d.bindGroupLayouts = [layout];
        return new GPUPipeline(d);
    }

    surfPipe(sh: GPUShaderModule, lay: GPUBindGroupLayout, layout: GPUVertexBufferLayout, fs: string,
        b0: GPUBlendState, b1: GPUBlendState, write: bool): GPUPipeline {
        let ds = new GPUDepthStencilDesc();
        ds.format = TextureFormat.depth32float;
        ds.compare = CompareFunction.lessEqual;
        ds.write = write;
        let d = new GPUPipelineDesc();
        d.bindGroupLayouts = [lay];
        d.vertexModule = sh;
        d.vertexEntryPoint = "vs_main";
        d.fragmentModule = sh;
        d.fragmentEntryPoint = fs;
        d.vertexBuffers = [layout];
        d.colorTargets = [colorTarget(HDR, b0), colorTarget(HDR, b1)];
        d.depthStencil = ds;
        d.cullMode = CullMode.none;
        d.sampleCount = SAMPLES;
        return new GPUPipeline(d);
    }

    // ------------------------------------------------------------ setup
    build(): void {
        let context = this.context;
        let gpu = this.gpu;
        if (context == null || gpu == null || this.coreBuilt) {
            return;
        }
        let vm = context.rootViewModel();
        if (vm == null) {
            return;
        }
        let sh = context.shader("surf");
        if (sh == null) {
            this.log("world: shader surf missing");
            return;
        }
        let post = context.shader("post");
        let part = context.shader("part");
        let taa = context.shader("taa");
        if (taa != null) {
            let tl = GPUBindGroupLayout.fromShader(taa, 0);
            if (tl != null) {
                this.pTaa = this.fullPipe(taa, tl, "fs_taa", HDR);
            }
        }
        let mot = context.shader("motion");
        if (mot != null) {
            let ml = GPUBindGroupLayout.fromShader(mot, 0);
            if (ml != null) {
                this.motLayout = ml;
                this.pMotion = this.fullPipe(mot, ml, "fs_motion", HDR);
                this.pMotion2 = this.fullPipe(mot, ml, "fs_motionGap", HDR);
                this.pCopy = this.fullPipe(mot, ml, "fs_copy", HDR);
            }
        }
        if (post == null || part == null) {
            this.log("world: post/part shader missing");
            return;
        }
        let objLayout = GPUBindGroupLayout.fromShader(sh, 0);
        let postLayout = GPUBindGroupLayout.fromShader(post, 0);
        let partLayout = GPUBindGroupLayout.fromShader(part, 0);
        if (objLayout == null || postLayout == null || partLayout == null) {
            this.log("world: bind group layout rejected");
            return;
        }
        this.objLayout = objLayout;
        this.postLayout = postLayout;
        this.partLayout = partLayout;
        // never rendered to: fills the slots a pass declares but doesn't read
        let phd = new GPUTextureDesc();
        phd.width = 1;
        phd.height = 1;
        phd.format = HDR;
        this.placeholder = new GPUTexture(phd).view();

        let layout = new GPUVertexBufferLayout();
        layout.stride = 32;
        layout.attributes = [
            new GPUVertexAttribute(VertexFormat.float3, 0, 0),
            new GPUVertexAttribute(VertexFormat.float3, 1, 12),
            new GPUVertexAttribute(VertexFormat.float2, 2, 24),
        ];
        let pre = blendState(BlendFactor.one, BlendFactor.oneMinusSrcAlpha, BlendFactor.one, BlendFactor.oneMinusSrcAlpha);
        let add = blendState(BlendFactor.one, BlendFactor.one, BlendFactor.one, BlendFactor.one);
        // second target: distance for depth of field (r = dist, a = coverage)
        let dblend = blendState(BlendFactor.srcAlpha, BlendFactor.oneMinusSrcAlpha, BlendFactor.one, BlendFactor.oneMinusSrcAlpha);
        this.pipeTex = this.surfPipe(sh, objLayout, layout, "fs_main", pre, dblend, true);
        this.pipeAdd = this.surfPipe(sh, objLayout, layout, "fs_main", add, dblend, false);
        // smoked-glass scrim: premultiplied "over" without depth write, so it
        // dims what's behind a surface (the hex wall's body) without hiding later
        // draws from the depth test
        this.pipeScrim = this.surfPipe(sh, objLayout, layout, "fs_main", pre, dblend, false);
        // LAYER B (transparent / emissive) pipelines: same shader, fs_mainB writes
        // premultiplied distance (d*w, w) so glows carry their own depth.
        // Panels: premultiplied over (colour AND distance), depth written so the
        // glows behind them are occluded. Glows: additive colour and distance.
        this.pipeTexB = this.surfPipe(sh, objLayout, layout, "fs_mainB", pre, pre, true);
        this.pipeAddB = this.surfPipe(sh, objLayout, layout, "fs_mainB", add, add, false);
        // refractive glass bodies (layer B): premultiplied over, depth-tested but
        // not written, so the glowing facet edges drawn after still land on top
        this.pipeGlass = this.surfPipe(sh, objLayout, layout, "fs_mainB", pre, pre, false);
        let playout = new GPUVertexBufferLayout();
        playout.stride = 32;
        playout.stepMode = VertexStepMode.instance;
        playout.attributes = [
            new GPUVertexAttribute(VertexFormat.float4, 0, 0),
            new GPUVertexAttribute(VertexFormat.float4, 1, 16),
        ];
        let pds = new GPUDepthStencilDesc();
        pds.format = TextureFormat.depth32float;
        pds.compare = CompareFunction.lessEqual;
        pds.write = false;
        let ppd = new GPUPipelineDesc();
        ppd.bindGroupLayouts = [partLayout];
        ppd.vertexModule = part;
        ppd.vertexEntryPoint = "vs_part";
        ppd.fragmentModule = part;
        ppd.fragmentEntryPoint = "fs_part";
        ppd.vertexBuffers = [playout];
        ppd.colorTargets = [colorTarget(HDR, add), colorTarget(HDR, add)];
        ppd.depthStencil = pds;
        ppd.cullMode = CullMode.none;
        ppd.sampleCount = SAMPLES;
        this.pipePart = new GPUPipeline(ppd);
        let pbuf = new GPUBuffer(BufferUsage.vertex, <u32>(NPART * 32));
        this.partBuf = pbuf;
        let pubo = new GPUBuffer(BufferUsage.uniform, 112);
        this.partUbo = pubo;
        this.partBind = new GPUBindGroup(partLayout, [new GPUBindGroupUBO(0, pubo)]);
        this.pDown = this.fullPipe(post, postLayout, "fs_down", HDR);
        this.pUp = this.fullPipe(post, postLayout, "fs_up", HDR, 1, add);
        // DoF v5 (two layers, see post.wgsl)
        this.pDofDown = this.fullPipe(post, postLayout, "fs_dofdown", HDR);
        let P = this.dofP;
        P.set("downB", this.fullPipe(post, postLayout, "fs_dofdownB", HDR, 2));
        P.set("tile1", this.fullPipe(post, postLayout, "fs_doftileA", HDR));
        P.set("tile2", this.fullPipe(post, postLayout, "fs_doftileB", HDR));
        P.set("blurA", this.fullPipe(post, postLayout, "fs_dofblur", HDR, 2));
        P.set("blurB", this.fullPipe(post, postLayout, "fs_dofblurB", HDR, 2));
        P.set("tent", this.fullPipe(post, postLayout, "fs_doftent", HDR));
        P.set("comp", this.fullPipe(post, postLayout, "fs_dofcomp", HDR, 2));
        P.set("dist", this.fullPipe(post, postLayout, "fs_dofdist", HDR));
        this.pComp = this.fullPipe(post, postLayout, "fs_comp", <TextureFormat>gpu.format);
        this.psampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
        this.sampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.repeat, WrapMode.clampToEdge,
            <CompareFunction>0xFFFFFFFF, 8);
        let blank = context.canvas(4, 4);
        if (blank == null) {
            return;
        }
        let br = blank.beginFrame(Color.rgba(255, 255, 255, 255));
        if (br != null) {
            blank.endFrame();
        }
        this.blank = blank;
        let bv = blank.image.view();
        if (bv == null) {
            return;
        }
        let bview: GPUTextureView = bv;

        // live artboards
        let hubS = this.makeSurf(this.hub, vm, HUB_W, HUB_H, 2.5);
        // (core skin + ticker surfaces removed: nothing samples them since the
        // Rive mark and the rotating text were cut)
        let g0 = this.makeSurf(this.games, vm, 1100, 620, 2);
        let g1 = this.makeSurf(this.music, vm, 1100, 620, 2);
        let g2 = this.makeSurf(this.memory, vm, 1100, 620, 2);
        let g3 = this.makeSurf(this.settings, vm, 1100, 620, 2);
        let satS = this.makeSurf(this.sats, vm, SAT_W, SAT_H, 2);
        if (hubS == null || g0 == null || g1 == null || g2 == null || g3 == null || satS == null) {
            this.log("world: artboard inputs missing");
            return;
        }
        this.hubSurf = hubS;
        this.satSurf = satS;
        this.secList = [g0, g1, g2, g3];
        // one canvas holds every game case: each case artboard is instanced
        // with that game's own view model from the `games` list
        let list = vm.getList("games");
        let caseCanvas = context.canvas(<u32>(TILE_W * <f64>ATLAS_C), <u32>(TILE_H * <f64>ATLAS_R));
        if (caseCanvas == null) {
            return;
        }
        this.caseCanvas = caseCanvas;
        let cv = caseCanvas.image.view();
        if (cv == null) {
            return;
        }
        this.caseView = cv;
        let caseArt = this.caseArt;
        if (list != null && caseArt != null) {
            let n = list.length < ATLAS_C * ATLAS_R ? list.length : ATLAS_C * ATLAS_R;
            for (let i = 0; i < n; i++) {
                let ci = caseArt.instance(list.get(i));
                ci.width = TILE_W;
                ci.height = TILE_H;
                this.cases.push(ci);
            }
        }
        this.pGame = vm.getNumber("game");
        this.pPlaying = vm.getBoolean("playing");
        this.pClock = vm.getString("clock");
        this.pClockH = vm.getString("clockH");
        this.pClockM = vm.getString("clockM");
        this.pFieldDone = vm.getTrigger("fieldDone");
        this.pAccept = vm.getTrigger("accept");
        this.pCue = vm.getNumber("cue");
        this.pArrived = vm.getBoolean("arrived");
        this.pEditing = vm.getBoolean("editing");

        // geometry: built in budgeted jobs (buildJob), see buildStep()
        this.bview = bview;
        this.coreBuilt = true;
    }

    // One slice of the geometry build (the Luau build() did all of it in one
    // call; interpreted wasm with debugger probes would blow the 200 ms
    // watchdog). Objects are created in the same order as Luau's build().
    // Returns false once every job has run.
    buildJob(k: i32): bool {
        let bview = this.bview!;
        if (k == 0) {
            // Bit core, pared back: plasma heart, a spinning inner icosahedron, the
            // morphing Bit shape (neutral / YES / NO) and one faint faceted shell.
            this.put("plasma", Geo.sphere(0.62, 48, 24), bview, false);
            this.bitPut("inner", Geo.icosa(0.92), bview);
            this.bitPut("neutral", Geo.icosa(1.22), bview);
            this.bitPut("yes", Geo.stellated(1.08, 1.72), bview);
            this.bitPut("no", Geo.octa(1.12, 2.05), bview);
            this.bitPut("outer", Geo.stellated(1.78, 1.0), bview);
            // refractive bodies for the prism shapes (same meshes; bound to the
            // opaque-scene snapshot in makeTargets)
            for (let gi = 0; gi < GLASS_KEYS.length; gi++) {
                let nm = GLASS_KEYS[gi];
                let src: Geo.Mesh;
                if (nm == "outer") {
                    src = Geo.stellated(1.78, 1.0);
                } else if (nm == "neutral") {
                    src = Geo.icosa(1.22);
                } else if (nm == "yes") {
                    src = Geo.stellated(1.08, 1.72);
                } else {
                    src = Geo.octa(1.12, 2.05);
                }
                let o = this.makeObj(src, bview, false, false);
                if (o != null) {
                    this.glass.set(nm, o);
                }
            }
            this.put("floor", Geo.plane(90), bview, true, false);
            this.put("haze", Geo.sphere(70, 48, 24), bview, true, false);
            return true;
        }
        if (k == 1) {
            // hex sphere (was a 24-tall band): r = 30 around the hub, ~5.8k cells
            // (built a few icosahedron faces per job)
            let hb = this.hexB;
            if (hb == null) {
                hb = new Geo.HexSphereBuilder(30, 24);
                this.hexB = hb;
            }
            if (!hb.step(HEX_FACES_PER_JOB)) {
                this.jobIdx -= 1; // run this job again
            }
            return true;
        }
        if (k == 2) {
            let hb = this.hexB!;
            let hexSphere = hb.mesh();
            this.hexB = null;
            this.put("wall", hexSphere, bview, true, false);
            this.put("wallScrim", hexSphere, bview, false, false);
            return true;
        }
        if (k == 3) {
            this.put("pillar", Geo.cone(1.25, 0.18, 0, 1, 64), bview, true, false);
            this.put("pad", Geo.ring(1.55, 0.05, 0.012, 160, 6), bview, true, false);
            this.put("pad2", Geo.ring(2.4, 0.02, 0.006, 160, 4), bview, true, false);
            return true;
        }
        if (k >= 4 && k <= 7) {
            let i = k - 3; // blade 1..4
            let span = BLADE_W / BLADE_R;
            let bA0 = PI + span / 2, bA1 = PI - span / 2;
            if (i == 1) {
                this.bladeMesh = arcMesh(BLADE_W, BLADE_H, BLADE_R, 28);
                this.frameMesh = Geo.arcFrame(BLADE_R, bA0, bA1, BLADE_H, 0.012, 28, 0.03);
            }
            let hubS = this.hubSurf!;
            let o = this.makeObj(this.bladeMesh!, hubS.view, false);
            if (o != null) {
                this.blades.push(o);
            }
            let fr = this.makeObj(this.frameMesh!, bview, true);
            if (fr != null) {
                this.frames.push(fr);
            }
            // projector beam: from this blade's orb (in blade-local space) to the panel corners
            bladeBase(<f64>i);
            let p = OV, yaw = OX;
            let ow = V(<f64>p.x - BLADE_W * 0.5 * Math.cos(yaw) - 0.5, p.y, <f64>p.z - BLADE_W * 0.5 * Math.sin(-yaw) * 0.2);
            let d = ow - p;
            let c = Math.cos(-yaw), sn = Math.sin(-yaw);
            let ap = V(<f64>d.x * c + <f64>d.z * sn, d.y, -<f64>d.x * sn + <f64>d.z * c);
            this.apex.push(ap);
            let bm = this.makeObj(Geo.frustum(ap, BLADE_R - 0.01, bA0, bA1, BLADE_H, 20), bview, true);
            if (bm != null) {
                this.beams.push(bm);
            }
            let orb = this.makeObj(Geo.sphere(0.16, 32, 16), bview, false);
            if (orb != null) {
                this.orbs.push(orb);
            }
            let osh = this.makeObj(Geo.sphere(0.24, 32, 16), bview, true);
            if (osh != null) {
                this.orbShells.push(osh);
            }
            let tb = this.makeObj(Geo.tubeCanon(72, 8), bview, true);
            if (tb != null) {
                this.tubes.push(tb);
            }
            let tb2 = this.makeObj(Geo.tubeCanon(72, 6), bview, true);
            if (tb2 != null) {
                this.tubes.push(tb2);
            }
            if (i == 4) {
                this.bladeMesh = null;
                this.frameMesh = null;
            }
            return true;
        }
        if (k == 8) {
            let sspan = SCREEN_W / SCREEN_R;
            let sA0 = PI + sspan / 2, sA1 = PI - sspan / 2;
            let scr = arcMesh(SCREEN_W, SCREEN_H, SCREEN_R, 64);
            let sfr = Geo.arcFrame(SCREEN_R, sA0, sA1, SCREEN_H, 0.014, 48, 0.06);
            let sbeam = Geo.frustum(V(0, -SCREEN_H * 0.5 - 2.2, -SCREEN_R + 2.6), SCREEN_R - 0.01, sA0, sA1, SCREEN_H, 32);
            for (let i = 0; i < 4; i++) {
                let o = this.makeObj(scr, this.secList[i].view, false);
                if (o != null) {
                    this.screens.push(o);
                }
                let f = this.makeObj(sfr, bview, true);
                if (f != null) {
                    this.screenFrames.push(f);
                }
                let bmm = this.makeObj(sbeam, bview, true);
                if (bmm != null) {
                    this.screenBeams.push(bmm);
                }
            }
            let satS = this.satSurf!;
            let spanS = SAT_PW / SAT_R;
            let satMesh = arcMesh(SAT_PW, SAT_PH, SAT_R, 20);
            let satFr = Geo.arcFrame(SAT_R, PI + spanS / 2, PI - spanS / 2, SAT_PH, 0.007, 20, 0.02);
            for (let q = 0; q < NSATS; q++) {
                let o = this.makeObj(satMesh, satS.view, false);
                if (o != null) {
                    this.satObjs.push(o);
                }
                let f = this.makeObj(satFr, bview, true);
                if (f != null) {
                    this.satFrames.push(f);
                }
            }
            return true;
        }
        if (k >= 9 && k < 9 + CABLES.length) {
            let cb = CABLES[k - 9];
            let b = this.cableB;
            if (b == null) {
                let ep = this.extend(cb.pts, cb.r);
                this.cableEp = ep;
                b = new Geo.CableBuilder(ep, cb.r, 22, 12, 2, FLOOR_Y, true);
                this.cableB = b;
                this.jobIdx -= 1; // emit the rows in the next slices
                return true;
            }
            if (!b.step(CABLE_ROWS_PER_JOB)) {
                this.jobIdx -= 1;
                return true;
            }
            this.cableB = null;
            this.finishCable(cb, this.cableEp, b.mesh(), bview);
            return true;
        }
        if (k == 9 + CABLES.length) {
            let cv = this.caseView!;
            let cm = Geo.gameCase(CASE_W, CASE_H, CASE_D);
            let ce = Geo.boxEdges(CASE_W * 1.02, CASE_H * 1.02, CASE_D * 1.1, 0.006);
            for (let i = 0; i < this.cases.length; i++) {
                let o = this.makeObj(cm, cv, false);
                if (o != null) {
                    this.caseObjs.push(o);
                }
                let e = this.makeObj(ce, bview, true);
                if (e != null) {
                    this.caseEdges.push(e);
                }
            }
            // motes: three families (core swarm, rising data sparks, deep dust)
            // (field order = Luau's table constructor order = random draw order)
            let rng = this.rng;
            for (let i = 1; i <= NPART; i++) {
                let fam = i <= 380 ? 0 : (i <= 640 ? 1 : 2);
                let m = new Mote();
                m.a = rng.random() * PI * 2;
                m.r = fam == 0 ? 1.9 + rng.random() * 3.2 : (fam == 1 ? rng.random() * 9 : 6 + rng.random() * 16);
                m.y = fam == 1 ? FLOOR_Y + rng.random() * 9 : (rng.random() - 0.5) * 9;
                m.v = fam == 0 ? 0.08 + rng.random() * 0.3 : 0.01 + rng.random() * 0.05;
                m.c = rng.random() < 0.55 ? 3 : <f64>((i % 6) + 1);
                m.s = fam == 2 ? 0.03 + rng.random() * 0.05 : 0.012 + rng.random() * 0.03;
                m.ph = <f64>fam + rng.random() * 0.999;
                this.motes.push(m);
            }
            return true;
        }
        return false;
    }

    finishCable(cb: CableDef, ep: Array<Vector>, mesh: Geo.Mesh, bview: GPUTextureView): void {
        let len = mesh.len;
        // dense centreline for camera collision avoidance
        let cl = new Array<Vector>();
        let n = ep.length;
        let minY = FLOOR_Y + cb.r * 1.15;
        for (let i = 1; i <= n - 1; i++) {
            let p0 = ep[(i - 1 > 1 ? i - 1 : 1) - 1], p1 = ep[i - 1], p2 = ep[i], p3 = ep[(i + 2 < n ? i + 2 : n) - 1];
            let segLen = <f64>Vector.length(p2 - p1);
            let steps = <i32>Math.max(2, Math.ceil(segLen / 0.6));
            for (let k = 0; k < steps; k++) {
                let q = Geo.catmull(p0, p1, p2, p3, <f64>k / <f64>steps);
                cl.push(V(q.x, Math.max(<f64>q.y, minY), q.z));
            }
        }
        // bounding spheres over chunks of 32 centreline points (broad phase)
        let bc = new Array<Vector>();
        let brs = new Array<f64>();
        for (let c0 = 0; c0 < cl.length; c0 += 32) {
            let c1 = c0 + 31 < cl.length - 1 ? c0 + 31 : cl.length - 1;
            let cen = Vector.xyz(0, 0, 0);
            for (let q = c0; q <= c1; q++) {
                cen = cen + cl[q];
            }
            cen = cen * <f32>(1.0 / <f64>(c1 - c0 + 1));
            let rad: f64 = 0;
            for (let q = c0; q <= c1; q++) {
                rad = Math.max(rad, <f64>Vector.length(cl[q] - cen));
            }
            bc.push(cen);
            brs.push(rad);
        }
        this.cableLines.push(new CableLine(cb.r + cb.sway * 0.7, cl, bc, brs));
        let o = this.makeObj(mesh, bview, false, false);
        if (o != null) {
            this.cables.push(o);
            this.cableLen.push(len);
        }
    }

    // run the setup (pipelines, surfaces) and then geometry jobs until the
    // time budget is spent; sets `ready` when everything exists
    buildStep(): void {
        if (this.ready) {
            return;
        }
        let t0 = clock();
        if (!this.coreBuilt) {
            this.build();
            if (!this.coreBuilt) {
                return;
            }
        }
        while (clock() - t0 < BUILD_BUDGET) {
            let k = this.jobIdx;
            this.jobIdx = k + 1;
            let tj = clock();
            if (!this.buildJob(k)) {
                this.ready = true;
                if (BUILD_LOG) this.log("world: built in " + (k + 1).toString() + " jobs, " + this.pendingDt.length.toString() + " frames recorded");
                return;
            }
            if (BUILD_LOG) this.log("world: job " + k.toString() + " " + ((clock() - tj) * 1000).toString() + " ms");
        }
    }

    put(name: string, m: Geo.Mesh, view: GPUTextureView, isAdd: bool, refl: bool = true): void {
        let o = this.makeObj(m, view, isAdd, refl);
        if (o != null) {
            this.objs.set(name, o);
        }
    }

    bitPut(name: string, m: Geo.Mesh, view: GPUTextureView): void {
        let o = this.makeObj(m, view, true);
        if (o != null) {
            this.bit.set(name, o);
        }
    }

    // continue a cable from b away from a; follow the floor if it hits it
    outward(p0: Vector, dd: Vector): Vector {
        let rad = V(p0.x, 0, <f64>p0.z + 4);
        if (<f64>Vector.length(rad) < 1e-3) {
            return dd;
        }
        rad = Vector.normalized(rad);
        let hz = Vector.xyz(dd.x, 0, dd.z);
        if (<f64>Vector.dot(hz, rad) < 0.5) {
            let nd = Vector.normalized(Vector.xyz(dd.x, 0, dd.z) * <f32>0.3 + rad * <f32>1.4);
            return Vector.normalized(Vector.xyz(nd.x, dd.y, nd.z));
        }
        return dd;
    }

    tail(a: Vector, b: Vector, floorY: f64): Array<Vector> {
        let d = Vector.normalized(b - a);
        d = this.outward(b, d);
        let res = new Array<Vector>();
        let p = b;
        for (let it = 0; it < 3; it++) {
            let step: f64 = 60;
            let q = p + d * <f32>step;
            if (<f64>q.y < floorY) {
                let k = <f64>d.y < -1e-3 ? (floorY - <f64>p.y) / <f64>d.y : 0;
                let hit = p + d * <f32>Math.max(k, 0);
                hit = V(hit.x, floorY, hit.z);
                res.push(hit);
                let hd = Vector.xyz(d.x, 0, d.z);
                if (<f64>Vector.length(hd) < 0.2) {
                    hd = V(<f64>d.x + 0.3, 0, <f64>d.z - 0.6);
                }
                d = this.outward(hit, Vector.normalized(hd));
                p = hit;
                q = p + d * <f32>step;
            }
            res.push(q);
            p = q;
            d = Vector.normalized(d + Vector.xyz(0, <f32>0.08, 0) * <f32>(<f64>p.y > 20 ? 1 : 0));
        }
        return res;
    }

    extend(pts: Array<Vector>, r: f64): Array<Vector> {
        let out = new Array<Vector>();
        let floorY = FLOOR_Y + r * 0.9;
        let head = this.tail(pts[1], pts[0], floorY);
        for (let k = head.length - 1; k >= 0; k--) {
            out.push(head[k]);
        }
        for (let k = 0; k < pts.length; k++) {
            out.push(pts[k]);
        }
        let tl = this.tail(pts[pts.length - 2], pts[pts.length - 1], floorY);
        for (let k = 0; k < tl.length; k++) {
            out.push(tl[k]);
        }
        return out;
    }

    // ------------------------------------------------------------ lifecycle
    override init(context: Context): bool {
        this.context = context;
        this.gpu = context.gpuCanvas();
        return true;
    }

    postGroup(name: string, src: GPUTextureView, aux: GPUTextureView? = null, aux2: GPUTextureView? = null,
        aux3: GPUTextureView? = null, aux4: GPUTextureView? = null, aux5: GPUTextureView? = null): void {
        let lay = this.postLayout;
        let ph = this.placeholder;
        let smp = this.psampler;
        if (lay == null || ph == null || smp == null) {
            return;
        }
        let ubo = new GPUBuffer(BufferUsage.uniform, 64);
        // every slot post.wgsl declares is filled (1x1 placeholder when unused)
        let tex: Array<GPUBindGroupTexture> = [
            new GPUBindGroupTexture(1, src),
            new GPUBindGroupTexture(3, aux != null ? aux : ph),
            new GPUBindGroupTexture(4, aux2 != null ? aux2 : ph),
            new GPUBindGroupTexture(5, aux3 != null ? aux3 : ph),
            new GPUBindGroupTexture(6, aux4 != null ? aux4 : ph),
            new GPUBindGroupTexture(7, aux5 != null ? aux5 : ph),
        ];
        this.postUbo.set(name, ubo);
        this.postBind.set(name, new GPUBindGroup(lay, [new GPUBindGroupUBO(0, ubo)], tex, [new GPUBindGroupSampler(2, smp)]));
    }

    motionGroup(ubo: GPUBuffer, src: GPUTextureView, dist: GPUTextureView): GPUBindGroup? {
        let lay = this.motLayout;
        let smp = this.psampler;
        if (lay == null || smp == null) {
            return null;
        }
        return new GPUBindGroup(lay, [new GPUBindGroupUBO(0, ubo)],
            [new GPUBindGroupTexture(1, src), new GPUBindGroupTexture(3, dist)], [new GPUBindGroupSampler(2, smp)]);
    }

    override resize(width: f64, height: f64, scale: f64): void {
        // Luau sizes arrive as an f32 vector; keep the same precision
        this.sizeX = <f64><f32>width;
        this.sizeY = <f64><f32>height;
        this.scale = scale;
        let gpu = this.gpu;
        if (gpu == null) {
            return;
        }
        // render the 3D at full device resolution (Retina 2x), and supersample
        // 1.5x on 1x displays; 4x MSAA on top, then a filtered downscale
        let rs = Math.max(1.5, Math.min(scale, 2));
        // cap the pixel count (Retina laptops and 5K screens), then apply the adaptive step
        let px = Math.max(1, this.sizeX * this.sizeY);
        rs = Math.min(rs, Math.sqrt(PIX_BUDGET / px)) * this.q;
        this.rs = Math.max(0.35, rs);
        rs = this.rs;
        let w = Math.max(1, Math.floor(this.sizeX * rs));
        let h = Math.max(1, Math.floor(this.sizeY * rs));
        gpu.resize(<u32>w, <u32>h);
        this.proj = Mat4.perspective(<f32>FOV, <f32>(this.sizeX / Math.max(1, this.sizeY)), <f32>0.1, 160);
        this.buildStep();
        if (!this.ready) {
            return;
        }
        this.makeTargets();
    }

    // render targets, post bind groups and pass descriptors for the current size
    makeTargets(): void {
        let w = Math.max(1, Math.floor(this.sizeX * this.rs));
        let h = Math.max(1, Math.floor(this.sizeY * this.rs));
        let msaa = rtex(w, h, HDR, SAMPLES).view();
        this.msaa = msaa;
        let dvd = new GPUTextureViewDesc();
        dvd.aspect = TextureAspect.depthOnly;
        let depth = rtex(w, h, TextureFormat.depth32float, SAMPLES).view(dvd);
        this.depth = depth;
        let hdr = rtex(w, h, HDR).view();
        this.hdr = hdr;
        let msaaD = rtex(w, h, HDR, SAMPLES).view();
        this.msaaD = msaaD;
        let dist = rtex(w, h, HDR).view();
        this.dist = dist;
        let hdrRaw = rtex(w, h, HDR).view();
        this.hdrRaw = hdrRaw;
        // the glass refracts LAST frame's motion-blurred HDR (prevHdr); sampling
        // the target being rendered would be undefined (and read as solid colour)
        let prevHdr = rtex(w, h, HDR).view();
        this.prevHdr = prevHdr;
        // glass bodies sample the snapshot
        let lay = this.objLayout, smp0 = this.sampler;
        if (lay != null && smp0 != null) {
            for (let gi = 0; gi < GLASS_KEYS.length; gi++) {
                let key = GLASS_KEYS[gi];
                if (this.glass.has(key)) {
                    let o = this.glass.get(key);
                    o.bind = new GPUBindGroup(lay, [new GPUBindGroupUBO(0, o.ubo)], [new GPUBindGroupTexture(1, prevHdr)],
                        [new GPUBindGroupSampler(2, smp0)]);
                }
            }
        }
        let mu = new GPUBuffer(BufferUsage.uniform, 160);
        if (this.pMotion != null) {
            this.motionUbo = mu;
        }
        this.bloom = [];
        this.bw = [];
        this.bh = [];
        let bw = w, bh = h;
        for (let i = 0; i < LEVELS; i++) {
            bw = Math.max(1, Math.floor(bw / 2));
            bh = Math.max(1, Math.floor(bh / 2));
            this.bloom.push(rtex(bw, bh, HDR).view());
            this.bw.push(bw);
            this.bh.push(bh);
        }
        let pd = this.pDown, pu = this.pUp, pc = this.pComp;
        if (pd == null || pu == null || pc == null) {
            return;
        }
        for (let i = 1; i <= LEVELS; i++) {
            this.postGroup(D_NAMES[i - 1], i == 1 ? hdr : this.bloom[i - 2]);
        }
        for (let i = LEVELS - 1; i >= 1; i--) {
            this.postGroup(U_NAMES[i - 1], this.bloom[i]);
        }
        // ---- DoF v5: layer B targets, half-res chain, composite
        let msaaB = rtex(w, h, HDR, SAMPLES).view();
        let msaaDB = rtex(w, h, HDR, SAMPLES).view();
        this.msaaB = msaaB;
        this.msaaDB = msaaDB;
        let hdrB = rtex(w, h, HDR).view(), distB = rtex(w, h, HDR).view();
        let hdrC = rtex(w, h, HDR).view(), distF = rtex(w, h, HDR).view();
        this.hdrB = hdrB;
        this.distB = distB;
        this.hdrC = hdrC;
        this.distF = distF;
        let dofDiv = 2 * Math.max(1, this.rs);
        let dw = Math.max(1, Math.floor(w / dofDiv)), dh = Math.max(1, Math.floor(h / dofDiv));
        this.dw = dw;
        this.dh = dh;
        let T = new Map<string, GPUTextureView>();
        for (let k = 0; k < DOF_KEYS.length; k++) {
            T.set(DOF_KEYS[k], rtex(dw, dh, HDR).view());
        }
        this.dofT = T;
        if (this.pDofDown != null && this.dofP.has("comp")) {
            this.postGroup("v_dA", hdrRaw, dist);
            this.postGroup("v_dB", hdrB, distB);
            this.postGroup("v_t1", T.get("aH"), T.get("bK"));
            this.postGroup("v_t2", T.get("t1"));
            this.postGroup("v_bA", T.get("aH"), T.get("t2"), T.get("bK"));
            this.postGroup("v_bB", T.get("bH"), T.get("t2"), T.get("bK"));
            this.postGroup("v_tA", T.get("aBg"));
            this.postGroup("v_tF", T.get("aFg"));
            this.postGroup("v_tB", T.get("bD"));
            let distP = rtex(w, h, HDR).view();
            this.distP = distP;
            this.postGroup("v_dd", dist, distB, T.get("bF"));
            this.postGroup("v_c", hdrRaw, hdrB, distP, T.get("bDT"), T.get("aBgT"), T.get("aFgT"));
        }
        // motion blur / copy read the DoF composite and its front distance
        let mu2 = this.motionUbo;
        if (this.pMotion != null && mu2 != null) {
            this.motionBind = this.motionGroup(mu2, hdrC, distF);
        }
        // gap-fill pass: pass 1 writes hdrM, pass 2 reads it
        if (this.pMotion2 != null && mu2 != null) {
            let hm = rtex(w, h, HDR).view();
            this.hdrM = hm;
            this.motionBind2 = this.motionGroup(mu2, hm, distF);
        }
        if (this.pCopy != null && mu2 != null) {
            this.copyBind = this.motionGroup(mu2, hdrC, distF);
            // the glass snapshot copies layer A (opaque scene) before layer B
            this.snapBind = this.motionGroup(mu2, hdrRaw, dist);
        }
        this.postGroup("c", hdr, this.bloom[0], this.bloom[2]);
        // scene pass descriptors: layer A (cleared, depth stored), layer B
        // (cleared colour + distance, SHARED depth buffer, loaded)
        let pa = new GPUPassDesc();
        pa.color = [attachment(msaa, hdrRaw, 0, 0, 0, 1), attachment(msaaD, dist, 0, 0, 0, 0)];
        pa.depthView = depth;
        pa.depthLoadOp = LoadOp.clear;
        pa.depthStoreOp = StoreOp.store;
        pa.depthClearValue = 1;
        this.passA = pa;
        let pb = new GPUPassDesc();
        pb.color = [attachment(msaaB, hdrB, 0, 0, 0, 0), attachment(msaaDB, distB, 0, 0, 0, 0)];
        pb.depthView = depth;
        pb.depthLoadOp = LoadOp.load;
        pb.depthStoreOp = StoreOp.store;
        this.passB = pb;
        this.fsPass.color = [this.fsAtt];
        this.twoPass.color = [this.twoA, this.twoB];
    }

    // ------------------------------------------------------------ advance
    kick(b: f64, ripple: bool): void {
        this.boost = Math.min(2.5, this.boost + b);
        this.glitch = Math.min(1.5, this.glitch + b * 0.5);
        if (ripple) {
            this.ripple = 0;
            this.rippleK = 1;
        }
    }

    override advance(dt0: f64): bool {
        // While the geometry is still being built (budgeted across calls), the
        // frames' dts are recorded; once ready they are replayed through step()
        // in order (a few per call), so every spring, timeline and artboard ends
        // up exactly where Luau's one-shot build had it.
        if (!this.ready || this.pendingDt.length > 0) {
            this.pendingDt.push(dt0);
            if (!this.ready) {
                this.buildStep();
                if (this.ready) {
                    this.makeTargets();
                }
                return true;
            }
            let t0 = clock();
            let q = this.pendingDt;
            let n = 0;
            while (n < q.length && (n == 0 || clock() - t0 < BUILD_BUDGET)) {
                this.step(q[n]);
                n++;
            }
            this.pendingDt = q.slice(n);
            return true;
        }
        this.adapt(dt0);
        return this.step(dt0);
    }

    // drop the 3D resolution while the browser can't keep up (frames slower than
    // FRAME_SLOW on average); never raises it again during a visit, so it can't oscillate
    adapt(dt0: f64): void {
        this.liveT += dt0;
        if (this.liveT < 2) {
            return;
        }
        this.ftAvg = this.ftAvg * 0.92 + Math.min(dt0, 0.1) * 0.08;
        if (this.ftAvg > FRAME_SLOW && this.q > Q_MIN && this.liveT - this.lastDrop > 1.5) {
            this.q = Math.max(Q_MIN, this.q * 0.8);
            this.lastDrop = this.liveT;
            this.ftAvg = 1.0 / 60.0;
            this.resize(this.sizeX, this.sizeY, this.scale);
            this.log("rivebox: 3D resolution scale " + this.rs.toString());
        }
    }

    // the per-frame body (Luau's advance)
    step(dt0: f64): bool {
        // (raised from 1/20: at 1/20 a slow host, e.g. while screen recording,
        // made every animation run in slow motion; springs are now stable to
        // 1/10, beyond that we accept slow motion over a jump)
        let dt = Math.min(dt0, 1.0 / 10.0);
        this.time += dt;
        let section = Math.floor(this.section + 0.5);
        let mode = Math.floor(this.mode + 0.5);
        if (this.debugPick && (section != this.lastSection || mode != this.lastMode)) {
            this.log("DBG mode=" + mode.toString() + " section=" + section.toString());
        }
        if (section != this.lastSection) {
            this.lastSection = section;
            this.kick(1.2, true);
            if (mode >= 2) {
                this.hideGroup("cases", 8);
                this.hideGroup("screen", 1);
            }
        }
        if (mode != this.lastMode) {
            if (mode == 1 && this.lastMode == 0) {
                this.hideGroup("core", 1);
                this.hideGroup("blades", 4);
                this.hideGroup("orbs", 4);
                this.hideGroup("tubes", 4);
                this.hideGroup("sats", 6);
            }
            if (mode >= 2) {
                this.hideGroup("cases", 8);
                this.hideGroup("screen", 1);
            }
            if (mode >= 2 && this.lastMode < 2) {
                for (let k = 0; k < 4; k++) {
                    this.reveal[k] = 0;
                }
                this.flash = 0.35;
            }
            if (mode == 1 && this.lastMode == 0) {
                this.bladeReveal = 0;
            }
            // (no camera kick when leaving for the start screen: the shake + FOV
            // pop on the first frame read as a jerk at lift-off)
            if (mode != 0) {
                this.kick(1.6, true);
            }
            this.lastMode = mode;
        }
        let pg = this.pGame;
        let g = pg != null ? pg.value : 0;
        if (g != this.lastGame) {
            this.lastGame = g;
            this.kick(0.5, false);
        }
        // Bit moods: YES when a section opens, NO on back, an idle blink now and then
        if (mode != this.lastBitMode) {
            if (mode == 2 && this.lastBitMode == 1) {
                this.bitMood = 1;
                this.bitT = 1.3;
                this.bitPopV += 6;
            } else if (mode == 1 && this.lastBitMode == 2) {
                this.bitMood = 2;
                this.bitT = 1.8;
                this.bitPopV += 5;
            }
            this.lastBitMode = mode;
        }
        this.bitIdle -= dt;
        if (this.bitIdle <= 0 && this.bitMood == 0) {
            this.bitMood = this.rng.random() < 0.65 ? 1 : 2;
            this.bitT = 0.7;
            this.bitPopV += 4;
            this.bitIdle = 5 + this.rng.random() * 6;
        }
        if (this.bitMood != 0) {
            this.bitT -= dt;
            if (this.bitT <= 0) {
                this.bitMood = 0;
                this.bitPopV += 3;
            }
        }
        for (let k = 1; k <= 3; k++) {
            let want: f64 = this.bitMood == <f64>(k - 1) ? 1 : 0;
            this.bitW[k - 1] = lerp(this.bitW[k - 1], want, 1 - Math.exp(-dt * 14));
        }
        springStep(this.bitPop, this.bitPopV, 1, 120, 9, dt);
        this.bitPop = OX;
        this.bitPopV = OZ;
        this.boost *= Math.max(0, 1 - dt * 2.6);
        this.glitch *= Math.max(0, 1 - dt * 4.5);
        this.flash *= Math.max(0, 1 - dt * 6);
        this.ripple += dt * 9;
        this.rippleK *= Math.max(0, 1 - dt * 0.9);
        this.fovK = lerp(this.fovK, this.boost, 1 - Math.exp(-dt * 6));
        if (this.s > 0.35) {
            for (let k = 1; k <= 4; k++) {
                // the selected screen materialises once the camera has (nearly)
                // arrived; neighbours fill in early so the flight shows content
                if (Math.abs(<f64>(k - 1) - this.sec) < 1.6) {
                    this.reveal[k - 1] = Math.min(1, this.reveal[k - 1] + dt * 1.3);
                }
            }
        }
        this.bladeReveal = Math.min(1, this.bladeReveal + dt * 0.9);

        // arrival cue: fires on the rising edge of "the camera has (nearly)
        // arrived". Elements spring in staggered, and the Decrypt converter on
        // every string replays (cue property), so text resolves as things land.
        {
            let arrived = false;
            if (mode == 1) {
                // the hub assembles during the last part of the dive, while the
                // camera is still flying in (cinematic), not after it stops
                arrived = this.tz < 0.24 && this.s < 0.3;
            } else if (mode >= 2) {
                arrived = this.s > 0.7 && Math.abs(this.sec - section) < 0.35;
            }
            let key = mode * 10 + (mode >= 2 ? section : 0);
            let pa = this.pArrived;
            if (pa != null && pa.value != arrived) {
                pa.value = arrived;
            }
            if (arrived && (!this.cueSent || key != this.cueArm)) {
                this.cueSent = true;
                this.cueArm = key;
                let pcue = this.pCue;
                if (pcue != null) {
                    pcue.value = pcue.value + 1;
                }
                let hubHidden = this.arr.has("blades") && this.arr.get("blades").a.length > 0 && this.arr.get("blades").a[0] < -1e5;
                if (mode == 1 && hubHidden) {
                    // only after the dive from the start screen; backing out of a
                    // section returns to the exact same menu, no re-entrance
                    this.arrive("blades", 4, 0.11, 0);
                    this.arrive("orbs", 4, 0.11, 0.08);
                    this.arrive("tubes", 4, 0.11, 0.3);
                    this.arrive("sats", 6, 0.1, 0.2);
                    this.arrive("core", 1, 0, 0);
                } else if (mode >= 2) {
                    this.arrive("screen", 1, 0, 0);
                    this.arrive("cases", 8, 0.06, 0.2);
                }
            } else if (!arrived) {
                this.cueSent = false;
            }
        }
        this.stepArrive(dt);
        // hex sphere: hidden for the pull-out back to the start screen (fades
        // out before the camera reaches it) and stays hidden there; fades back
        // in as the dive starts, well before the camera punches through it
        {
            let want: f64 = this.tqTo == 1 ? 0 : 1;
            let rate: f64 = want < this.hexVis ? 5 : 2.5;
            this.hexVis = lerp(this.hexVis, want, 1 - Math.exp(-dt * rate));
            if (Math.abs(this.hexVis - want) < 0.002) {
                this.hexVis = want;
            }
        }

        // section index: a soft, slightly underdamped spring (~1.4 s) so the camera's
        // flight between screens along the arc is slow enough to read
        springStep(this.sec, this.secV, section, 7.5, 4.6, dt);
        this.sec = OX;
        this.secV = OZ;
        // start screen <-> dashboard: a fixed-length, eased flight (not a
        // spring): q is progress measured in "screen flow" (camera travel
        // relative to its distance from the hub), so the move reads at an even
        // pace instead of whipping near the hub and crawling far away. tz (the
        // path parameter) is looked up from q.
        let tzT: f64 = mode == 0 ? 1 : 0;
        if (tzT != this.tqTo) {
            this.tqFrom = this.tq;
            this.tqTo = tzT;
            this.tqClock = 0;
            let span = Math.max(0.3, Math.abs(tzT - this.tq));
            this.tqDur = (tzT == 0 ? DIVE_S : PULL_S) * span;
        }
        this.tqClock += dt;
        {
            let x = clamp(this.tqClock / this.tqDur, 0, 1);
            // dive: build up slowly, long feathered brake into the hub;
            // pull-out: slow lift-off, long glide out to the far vantage
            let ez: f64;
            if (this.tqTo == 0) {
                let w = Math.pow(x, DIVE_LIFT);
                ez = w * w * w * (w * (w * 6 - 15) + 10);
            } else {
                // pull-out: Beta(3,5) CDF: zero velocity AND zero acceleration at lift-off
                // Beta(2,4) CDF: starts moving at once, long glide out to the far vantage
                let u = 1 - x;
                ez = 1 - (Math.pow(u, 5) + 5 * x * Math.pow(u, 4));
            }
            // lens bell for the flight: 0 at both ends with zero slope, peaking a
            // little before the middle. Drives the wide FOV + zoom blur, so the
            // lens opens and closes smoothly instead of snapping on a threshold
            if (Math.abs(this.tqTo - this.tqFrom) > 0.01 && x < 1) {
                let sb = Math.sin(PI * x);
                this.flightBell = sb * sb;
            } else {
                this.flightBell = 0;
            }
            let q = lerp(this.tqFrom, this.tqTo, ez);
            this.tqV = (q - this.tq) / Math.max(dt, 1e-4);
            this.tq = q;
        }
        {
            let lut = this.tqTo == 1 ? this.flowLutOut : this.flowLut;
            let nz = this.tq;
            if (lut != null) {
                let n = lut.length - 1;
                let f = clamp(this.tq, 0, 1) * <f64>n;
                let i0 = <i32>Math.min(Math.floor(f), <f64>(n - 1));
                nz = lerp(lut[i0], lut[i0 + 1], f - <f64>i0);
            }
            this.tzV = (nz - this.tz) / Math.max(dt, 1e-4);
            this.tz = nz;
        }
        // hub <-> section: underdamped spring for a little overshoot
        let target: f64 = mode >= 2 ? 1 : 0;
        springStep(this.s, this.sv, target, 13, 5.4, dt);
        this.s = OX;
        this.sv = OZ;
        this.gameF = lerp(this.gameF, g, 1 - Math.exp(-dt * 8));
        for (let i = 1; i <= 4; i++) {
            let want: f64 = <f64>(i - 1) == section ? 1 : 0;
            this.focusPop[i - 1] = lerp(this.focusPop[i - 1], want, 1 - Math.exp(-dt * 10));
        }
        this.pointer = vlerp(this.pointer, this.pointerT, 1 - Math.exp(-dt * 4));
        // mouse tilt: a weighted, slightly under-damped follow (camera has mass,
        // settles with a hint of overshoot)
        {
            let tx = clamp(<f64>this.pointerT.x, -1, 1);
            let ty = clamp(<f64>this.pointerT.y, -1, 1);
            springStep(<f64>this.tiltP.x, <f64>this.tiltV.x, tx, 26, 7.5, dt);
            let x = OX, vx = OZ;
            springStep(<f64>this.tiltP.y, <f64>this.tiltV.y, ty, 26, 7.5, dt);
            let y = OX, vy = OZ;
            this.tiltP = Vector.xy(<f32>x, <f32>y);
            this.tiltV = Vector.xy(<f32>vx, <f32>vy);
        }
        this.caseSpin += dt;

        // clock
        this.clockT -= dt;
        let pc = this.pClock;
        if (pc != null && this.clockT <= 0) {
            this.clockT = 1;
            pc.value = date("%H:%M");
            let ph = this.pClockH, pmn = this.pClockM;
            if (ph != null) ph.value = date("%H");
            if (pmn != null) pmn.value = date("%M");
        }

        // advance every live artboard; sections only while visible
        let hs = this.hubSurf;
        if (hs != null) hs.inst.advance(dt);
        let ss = this.satSurf;
        if (ss != null) ss.inst.advance(dt);
        for (let i = 0; i < this.secList.length; i++) {
            let sf = this.secList[i];
            sf.live = this.s > 0.02 && Math.abs(<f64>i - this.sec) < SCREEN_FADE1;
            sf.inst.advance(dt);
        }
        for (let i = 0; i < this.cases.length; i++) {
            this.cases[i].advance(dt);
        }
        // previous frame's camera for motion blur: tracked in advance (which runs
        // every frame) so it is right even when draw is skipped or replayed
        this.prevVP = this.viewProj;
        // camera and pick transforms are computed here (advance shares state with
        // the pointer handlers; draw may run on a deferred replay)
        this.camDt = dt;
        this.viewProj = this.cameraFor();
        // focus puller: critically damped (~0.2 s), in log-distance so long pulls
        // (start screen -> hub) don't overshoot and short ones stay snappy
        {
            let cur = Math.log(Math.max(this.focusD, 0.5));
            let tgt = Math.log(Math.max(this.focusT, 0.5));
            // (snappier during the dive so the pull onto the hex wall lands in time)
            let wn: f64 = this.tz > 0.05 ? 30 : 16;
            critStep(cur, this.focusV, tgt, wn, dt);
            let nx = OX, nv = OZ;
            // guard: never let a bad frame poison the focus state
            if (isNaN(nx) || isNaN(nv) || Math.abs(nx) > 10) {
                nx = tgt;
                nv = 0;
            }
            this.focusV = nv;
            this.focusD = Math.exp(nx);
        }
        let bh = new Array<Mat4>(4);
        let sh = new Array<Mat4>(4);
        for (let i = 1; i <= 4; i++) {
            bh[i - 1] = this.bladeModel(i);
            sh[i - 1] = this.screenModel(i);
        }
        this.bladeHit = bh;
        this.screenHit = sh;
        for (let i = 0; i < this.motes.length; i++) {
            let m = this.motes[i];
            let fam = Math.floor(m.ph);
            m.a += dt * m.v * (1 + this.boost * 1.5);
            if (fam == 1) {
                m.y += dt * (0.35 + this.boost * 0.8);
                if (m.y > 6) {
                    m.y = FLOOR_Y;
                }
            } else {
                m.y += dt * 0.06;
                if (m.y > 4.5) {
                    m.y = -4.5;
                }
            }
        }
        return true;
    }

    // ------------------------------------------------------------ transforms
    // i is 1-based; returns the model, alpha -> M_ALPHA
    bladeModel(i: i32): Mat4 {
        let fi = <f64>i;
        bladeBase(fi);
        let p = OV, yaw = OX;
        let f = this.focusPop[i - 1];
        let t = this.time;
        // clamp: the camera spring undershoots below 0 on return, which used to
        // pull the blades inward past their rest pose
        let s = Math.max(this.s, 0);
        let sec = Math.floor(this.section + 0.5);
        let bob = Math.sin(t * 1.3 + fi * 1.7) * 0.03;
        let out = f * 0.42;
        // in section mode: unselected blades scatter outward, selected one dives
        let away: f64 = fi - 1 == sec ? 0 : 1;
        let scatter = s * away;
        let x = <f64>p.x + out + scatter * (2.5 + fi * 0.4);
        let y = <f64>p.y + bob + scatter * (<f64>p.y * 1.4);
        let z = <f64>p.z + out * 0.5 - scatter * 1.5 + s * (1 - away) * 1.2;
        // arrival: each blade swings in from the right on its own spring,
        // slightly late after the one above it (overshoot = settle wobble)
        let ak = this.arrK("blades", i);
        let ain = 1 - ak;
        x += ain * 1.4;
        z -= ain * 0.6;
        let sc = (1 + f * 0.1) * (0.8 + 0.2 * ak);
        M_ALPHA = clamp(1 - s * (1 + away * 1.5), 0, 1) * clamp(ak * 1.6, 0, 1);
        let wob = f * Math.sin(t * 2.4 + fi) * 0.04 + ain * 0.35;
        return tr(x, y, z) * rotY(yaw + f * 0.12 + scatter * 0.8 - ain * 0.9) * rotX(wob) * rotZ(f * -0.025) * scl(sc, sc, sc);
    }

    orbPos(i: i32): Vector {
        let fi = <f64>i;
        bladeBase(fi);
        let p = OV, yaw = OX;
        let bob = Math.sin(this.time * 1.3 + fi * 1.7) * 0.03;
        let f = this.focusPop[i - 1];
        // the orb sits just left of its blade
        return V(<f64>p.x - BLADE_W * 0.5 * Math.cos(yaw) - 0.5 + f * 0.12, <f64>p.y + bob,
            <f64>p.z - BLADE_W * 0.5 * Math.sin(-yaw) * 0.2);
    }

    // eased position/yaw along the arc for the (fractional) section index -> OV2, OZ
    sectionPos(): void {
        let sf = clamp(this.sec, 0, 3);
        let a = arcAngle(sf);
        OV2 = V(<f64>ARC_C.x + Math.sin(a) * ARC_R, ARC_C.y, <f64>ARC_C.z + Math.cos(a) * ARC_R);
        OZ = a;
    }

    // i is 1-based; alpha -> M_ALPHA
    screenModel(i: i32): Mat4 {
        let fi = <f64>i;
        let s = this.s;
        let e = smooth(s);
        screenFrame(fi);
        let fp = OV2, ya = OZ;
        bladeBase(fi);
        let bp = OV;
        // from its blade on the hub it flies out to its slot on the arc
        let pos = vlerp(bp, fp, e);
        let sc = lerp(0.25, 0.82, e);
        let focus = clamp(1 - Math.abs((fi - 1) - this.sec), 0, 1);
        let m = tr(pos.x, <f64>pos.y + Math.sin(this.time * 0.5 + fi) * 0.04 * e, pos.z)
            * rotY(lerp(-0.4, ya + PI, e))
            * rotX(Math.sin(this.time * 0.4 + fi) * 0.01 + (1 - e) * 0.5)
            * scl(sc, sc, sc)
            * tr(0, 0, SCREEN_R);
        // arrival: the focused screen settles in with a spring (tilt + scale)
        let ak = focus > 0.5 ? this.arrK("screen", 1) : 1;
        m = m * tr(0, 0, -SCREEN_R) * rotX((1 - ak) * -0.22)
            * scl(0.94 + 0.06 * ak, 0.94 + 0.06 * ak, 1) * tr(0, 0, SCREEN_R);
        // neighbours further along the arc fade out (and stop rendering) instead of popping
        let far = Math.abs((fi - 1) - this.sec);
        let fade = 1 - smooth(clamp((far - SCREEN_FADE0) / (SCREEN_FADE1 - SCREEN_FADE0), 0, 1));
        M_ALPHA = clamp((s - 0.15) * 2.2, 0, 1) * lerp(0.28, 1, focus) * fade;
        return m;
    }

    // game cases orbit just in front of the Games screen, facing the camera;
    // i is 1-based; focus -> M_ALPHA
    caseModel(i: i32, n: i32): Mat4 {
        let fi = <f64>i;
        let g = this.gameF;
        screenFrame(1);
        let fp = OV2, ya = OZ;
        let inward = V(-Math.sin(ya), 0, -Math.cos(ya));
        let side = V(Math.cos(ya), 0, -Math.sin(ya));
        let c = fp + inward * <f32>1.7 + side * <f32>3.25 + V(0, -0.25, 0);
        let step = PI * 2 / <f64>n;
        let a = ((fi - 1) - g) * step;
        let R = 0.85;
        let focus = clamp(1 - Math.abs((fi - 1) - g), 0, 1);
        let p = c + side * <f32>(Math.sin(a) * R) + inward * <f32>(Math.cos(a) * R * 0.9);
        let y = <f64>p.y + focus * 0.1 + Math.sin(this.time * 1.3 + fi) * 0.03;
        let spin = (1 - focus) * 0.9 + focus * Math.sin(this.time * 0.8) * 0.25;
        let sc = 0.6 + focus * 0.5;
        // the carousel floats ~2 units in front of the Games screen, outside its
        // focal plane. Push the whole carousel back along the camera rays (one
        // shared factor, so the cases keep their depth order) until the front,
        // selected case sits near the screen's depth; scaling by the same factor
        // keeps it identical on screen.
        let eye = this.eye;
        let front = c + inward * <f32>(R * 0.9);
        // (0.85: just inside the lens's near tolerance, so the whole carousel is
        // sharp but stays in front of the Music screen next to it)
        let k = clamp(<f64>Vector.length(fp - eye) * 0.85 / Math.max(<f64>Vector.length(front - eye), 0.1), 1, 2);
        let pw = eye + (V(p.x, y, p.z) - eye) * <f32>k;
        p = pw;
        y = <f64>pw.y;
        sc *= k;
        // arrival: cases pop in one by one around the carousel
        let ak = this.arrK("cases", i);
        sc *= ak;
        y -= (1 - Math.min(ak, 1)) * 0.4;
        M_ALPHA = focus;
        return tr(p.x, y, p.z) * rotY(ya + PI + a * 0.6 + spin) * scl(sc, sc, sc);
    }

    // k is 1-based
    satModel(k: i32): Mat4 {
        let o = (k - 1) * 5;
        let sp1 = SATS[o], sp2 = SATS[o + 1], sp3 = SATS[o + 2], sp4 = SATS[o + 3], sp5 = SATS[o + 4];
        let t = this.time;
        let e = smooth(this.s);
        let p = V(sp1, sp2 + Math.sin(t * 0.35 + sp4) * 0.12, sp3);
        // each satellite turns to face the camera loosely (billboard yaw, lagged)
        let d = this.eye - p;
        let yaw = Math.atan2(<f64>d.x, <f64>d.z);
        // arrival: each satellite flips in around its own axis, staggered
        let ak = this.arrK("sats", k);
        let sc = sp5 * lerp(1, 0.92, e) * (0.6 + 0.4 * ak);
        return tr(p.x, <f64>p.y + (1 - ak) * -0.6, p.z)
            * rotY(yaw + Math.sin(t * 0.21 + sp4) * 0.08 + (1 - ak) * 1.4)
            * rotX(Math.sin(t * 0.27 + sp4 * 2) * 0.04)
            * scl(sc, sc, sc)
            * tr(0, 0, SAT_R);
    }

    // Keep the camera out of the cables: a soft, continuous push away from every
    // cable centreline inside a clearance zone (no state, so it never pops).
    // Quadratic falloff = C1-smooth path.
    avoidCables(eye: Vector): Vector {
        let out = eye;
        for (let it = 0; it < 2; it++) {
            let push = Vector.xyz(0, 0, 0);
            for (let li = 0; li < this.cableLines.length; li++) {
                let cl = this.cableLines[li];
                let zone = cl.r + 1.6;
                let z2 = (zone + 0.6) * (zone + 0.6);
                let pts = cl.pts;
                let nChunks = cl.bc.length;
                for (let ch = 0; ch < nChunks; ch++) {
                    // broad phase: only test centreline points in 32-point chunks
                    // whose bounding sphere is within reach (identical result)
                    if (<f64>Vector.length(out - cl.bc[ch]) > cl.br[ch] + zone + 0.6) {
                        continue;
                    }
                    let k0 = ch * 32;
                    let k1 = k0 + 31 < pts.length - 1 ? k0 + 31 : pts.length - 1;
                    for (let k = k0; k <= k1; k++) {
                        let d = out - pts[k];
                        let dd = <f64>Vector.dot(d, d);
                        if (dd < z2) {
                            let dl = Math.sqrt(dd);
                            if (dl < zone && dl > 1e-4) {
                                let pen = (zone - dl) / zone;
                                push = push + d * <f32>(pen * pen * zone * 0.5 / dl);
                            }
                        }
                    }
                }
            }
            out = out + push;
        }
        return out;
    }

    screenDist(i: f64, eye: Vector): f64 {
        // the arc mesh is offset by +R then bent back by R: its middle sits at fp
        screenFrame(clamp(i, 1, 4));
        return <f64>Vector.length(OV2 - eye);
    }

    cameraFor(): Mat4 {
        let t = this.time;
        let e = smooth(this.s);
        let boost = this.boost;
        let px = <f64>this.pointer.x, py = <f64>this.pointer.y;
        // hub: fixed framing (the menu must sit in the same place every time you
        // come back to the hub, so no slow orbit, just a small bounded breath)
        let hubEye = V(-1.0 + Math.sin(t * 0.21) * 0.06, 0.7 + Math.sin(t * 0.13) * 0.04, 11.2);
        let hubAt = V(1.05, -0.1, 0.0);
        // the camera leans toward the focused menu item: looks at it a little and
        // cranes to its height, so moving through the menu reads as a camera move
        let selY: f64 = 0, selW: f64 = 0;
        for (let i = 1; i <= 4; i++) {
            bladeBase(<f64>i);
            selY += <f64>OV.y * this.focusPop[i - 1];
            selW += this.focusPop[i - 1];
        }
        selY = selW > 0.01 ? selY / selW : 0;
        hubAt = hubAt + V(0.35, selY * 0.45, 0);
        hubEye = hubEye + V(selY * -0.25, selY * 0.35, 0);
        // section: fly to a point in front of the current screen on the arc
        this.sectionPos();
        let sp = OV2, sa = OZ;
        let inward = V(-Math.sin(sa), 0, -Math.cos(sa));
        let side = V(Math.cos(sa), 0, -Math.sin(sa));
        let secEye = sp + inward * <f32>7.0 + side * <f32>(0.9 + Math.sin(t * 0.11) * 0.3) + V(0, 0.55 + Math.sin(t * 0.17) * 0.12, 0);
        let secAt = sp + inward * <f32>0.6 + side * <f32>1.0 + V(0, -0.1, 0);
        // the move arcs up and back mid-flight (crane), instead of a straight lerp
        let lift = Math.sin(clamp(e, 0, 1) * PI) * 1.1;
        // travelling between sections: dolly back and up so the whole arc reads
        let travel = clamp(Math.abs(this.secV) * 0.9, 0, 1) * e;
        secEye = secEye + inward * <f32>(travel * 2.4) + V(0, travel * 0.8, 0);
        let swoop = Math.sin(clamp(e, 0, 1) * PI);
        let eye = vlerp(hubEye, secEye, e) + V(px * 0.5 - swoop * 1.6, -py * 0.3 + lift, lift * 1.2)
            + side * <f32>(travel * Math.sin(t * 0.4) * 0.3);
        let at = vlerp(hubAt, secAt, e) + V(px * 0.12, -py * 0.08, 0);
        // start screen: pulled WAY out, high above the floor, the dashboard a
        // speck in the fog; the cables tower around the camera. The dive eases in
        // slow, accelerates through the cables and brakes hard at the hub.
        if (this.flowLut == null) {
            this.flowLut = buildFlowLut(true);
            this.flowLutOut = buildFlowLut(false);
        }
        diveEye(eye, at, clamp(this.tz, 0, 1), t);
        eye = OV;
        at = OV2;
        let shk = boost * 0.006;
        eye = eye + V(Math.sin(t * 41) * shk, Math.cos(t * 37) * shk, 0);
        // mouse tilt: orbit the camera around a pivot ~12 units down the line of
        // sight (the hub menu / section screen plane), so near things swing
        // against far ones like a real 3D view; plus a touch of roll. Calmed
        // during flights so the long moves stay clean.
        let mtx = <f64>this.tiltP.x, mty = <f64>this.tiltP.y;
        let tiltK = 1 - 0.8 * this.flightBell;
        {
            let fwd = at - eye;
            let dist = <f64>Vector.length(fwd);
            let dir = fwd * <f32>(1 / Math.max(dist, 1e-3));
            let pivot = eye + dir * <f32>Math.min(dist, 12);
            // right = dir x worldUp, up = right x dir (written out)
            let right = Vector.normalized(Vector.xyz(-dir.z, 0, dir.x));
            let rx = <f64>right.x, ry = <f64>right.y, rz = <f64>right.z;
            let dx = <f64>dir.x, dy = <f64>dir.y, dz = <f64>dir.z;
            let up = V(ry * dz - rz * dy, rz * dx - rx * dz, rx * dy - ry * dx);
            let yaw = -mtx * 0.085 * tiltK;
            let pitch = mty * 0.055 * tiltK;
            let rel = eye - pivot;
            // yaw about world up, pitch about camera right (small angles)
            let cy = Math.cos(yaw), sy = Math.sin(yaw);
            rel = V(<f64>rel.x * cy + <f64>rel.z * sy, rel.y, -<f64>rel.x * sy + <f64>rel.z * cy);
            let cpt = Math.cos(pitch), spt = Math.sin(pitch);
            let rd = <f64>Vector.dot(rel, up);
            let fd = <f64>Vector.dot(rel, dir);
            let relR = rel - up * <f32>rd - dir * <f32>fd;
            rel = relR + up * <f32>(rd * cpt - fd * spt) + dir * <f32>(rd * spt + fd * cpt);
            let shift = (pivot + rel) - eye;
            eye = eye + shift;
            at = at + shift * <f32>(1 - Math.min(dist, 12) / Math.max(dist, 1e-3));
        }
        // cable avoidance, low-passed (critically damped, ~0.25 s) so the camera
        // glides around cables instead of being shoved frame to frame
        {
            let want = this.avoidCables(eye) - eye;
            let dtc = this.camDt;
            let wn: f64 = 11;
            // (sub-stepped: stable at low frame rates)
            let n = Math.max(1, Math.ceil(dtc * wn / 0.4));
            let h = dtc / n;
            for (let i = 1; <f64>i <= n; i++) {
                this.avoidV = this.avoidV + ((want - this.avoidOff) * <f32>(wn * wn) - this.avoidV * <f32>(2 * wn)) * <f32>h;
                this.avoidOff = this.avoidOff + this.avoidV * <f32>h;
            }
            eye = eye + this.avoidOff;
        }
        // banking: the camera leans into every move like a crane/drone operator
        // (hub <-> section, section travel, the start dive), plus a slow float
        let diveBank = Math.sin(clamp(this.tz, 0, 1) * PI) * 0.11;
        let roll = clamp(this.sv * 0.03 + this.secV * -0.09 + this.tqV * 0.08 + swoop * 0.05 + diveBank
            + (mtx * 0.014 + <f64>this.tiltV.x * 0.012) * tiltK, -0.2, 0.2)
            + Math.sin(t * 0.21) * 0.008 + Math.sin(t * 0.13 + 1.3) * 0.005;
        this.eye = eye;
        this.camAt = at;
        // focus: the camera target on the hub; in a section, pull focus to the
        // nearest screen's centre so mid-flight the arriving screen stays readable
        let secP = clamp(this.sec, 0, 3);
        let s0 = Math.floor(secP);
        let fs = secP - s0;
        let secD = lerp(this.screenDist(s0 + 1, eye), this.screenDist(s0 + 2, eye), fs * fs * (3 - 2 * fs));
        // hub: focus on the menu blades' SURFACE (the arc mesh sits R in front of
        // its pivot), weighted by focus so a selection change pulls focus smoothly
        let hubD: f64 = 0, hubW: f64 = 0;
        for (let i = 1; i <= 4; i++) {
            let bm = this.bladeModel(i);
            let wgt = 0.15 + this.focusPop[i - 1];
            hubD += <f64>Vector.length(bm.transformPoint(0, 0, <f32>-BLADE_R) - eye) * wgt;
            hubW += wgt;
        }
        let ft = lerp(hubD / hubW, secD, smooth(clamp((this.s - 0.3) / 0.6, 0, 1)));
        this.focusT = lerp(ft, 46, smooth(clamp(this.tz, 0, 1)));
        // dive: pull focus onto the hex sphere as the camera approaches and
        // punches through it (ray vs sphere, entry point), then back to the hub
        if (this.tz > 0.02 && this.hexVis > 0.5) {
            let dir = Vector.normalized(at - eye);
            let oc = eye - HEXC;
            let B = <f64>Vector.dot(oc, dir);
            let C = <f64>Vector.dot(oc, oc) - HEXR * HEXR;
            let disc = B * B - C;
            if (C > 0 && disc > 0) {
                let tHit = -B - Math.sqrt(disc);
                if (tHit > 0) {
                    // diving in: pull onto the shell as it approaches. Pulling out
                    // it is only in front after the crossing, so ease in slowly
                    let wk: f64;
                    if (this.tqTo == 0) {
                        wk = smooth(clamp((30 - tHit) / 14, 0, 1)) * smooth(clamp((tHit - 0.4) / 1.6, 0, 1));
                    } else {
                        wk = smooth(clamp((tHit - 1.0) / 8, 0, 1)) * smooth(clamp((40 - tHit) / 14, 0, 1)) * 0.85;
                    }
                    this.focusT = lerp(this.focusT, Math.max(tHit, 0.8), wk);
                }
            }
        }
        this.dofK = 1;
        this.view = Mat4.lookAtVector(eye, at, V(Math.sin(roll), Math.cos(roll), 0));
        let aspect = this.sizeX / Math.max(1, this.sizeY);
        // dive: the lens opens wide while the camera is travelling (speed-driven,
        // so it is exactly the normal lens at rest at either end)
        let zoomK = this.flightBell;
        this.zoomK = zoomK;
        let dive = zoomK * DIVE_FOV;
        this.proj = Mat4.perspective(<f32>Math.min(FOV * (1 + this.fovK * 0.02 + lift * 0.03 + dive), 1.75), <f32>aspect,
            <f32>0.1, 260);
        this.viewProj = this.proj * this.view;
        return this.viewProj;
    }

    // ------------------------------------------------------------ uniforms
    writeU(ubo: GPUBuffer, model: Mat4, reflK: f64): void {
        let b = this.scratch;
        let mvp = this.viewProj * model;
        mvp.writeToBuffer(b, 0);
        model.writeToBuffer(b, 64);
        let f = this.sf;
        let e = this.eye;
        f[32] = e.x;
        f[33] = e.y;
        f[34] = e.z;
        f[35] = <f32>this.time;
        for (let k = 4; k < 40; k++) {
            f[32 + k] = <f32>UB[k];
        }
        f[32 + 23] = <f32>reflK;
        ubo.update(0, b, UBO, 0);
    }

    // uniforms from UB (ubBegin & co) -> the object (and its floor mirror)
    setU(o: Obj?, model: Mat4): void {
        if (o == null) {
            return;
        }
        this.writeU(o.ubo, model, 0);
        if (o.refl) {
            this.writeU(o.uboR, MIRROR * model, REFL);
        }
        o.alpha = UB[7];
    }

    objNamed(name: string): Obj? {
        return this.objs.has(name) ? this.objs.get(name) : null;
    }

    bitNamed(name: string): Obj? {
        return this.bit.has(name) ? this.bit.get(name) : null;
    }

    glassNamed(name: string): Obj? {
        return this.glass.has(name) ? this.glass.get(name) : null;
    }

    // ------------------------------------------------------------ draw helpers
    fullscreen(gpu: GPUCanvas, view: GPUTextureView, pipe: GPUPipeline, bind: GPUBindGroup, w: f64, h: f64, load: bool): void {
        let att = this.fsAtt;
        att.view = view;
        att.loadOp = load ? LoadOp.load : LoadOp.clear;
        let pass = gpu.beginRenderPass(this.fsPass);
        pass.setViewport(0, 0, <f32>w, <f32>h);
        pass.setPipeline(pipe);
        pass.setBindGroup(0, bind);
        pass.draw(3);
        pass.finish();
    }

    two(gpu: GPUCanvas, a1: GPUTextureView, b1: GPUTextureView, pipe: GPUPipeline, bind: GPUBindGroup, ww: f64, hh: f64): void {
        this.twoA.view = a1;
        this.twoB.view = b1;
        let ps = gpu.beginRenderPass(this.twoPass);
        ps.setViewport(0, 0, <f32>ww, <f32>hh);
        ps.setPipeline(pipe);
        ps.setBindGroup(0, bind);
        ps.draw(3);
        ps.finish();
    }

    post4(name: string, a0: f64, a1: f64, a2: f64, a3: f64, b0: f64, b1: f64, b2: f64, b3: f64,
        c0: f64 = 0, c1: f64 = 0, c2: f64 = 0, c3: f64 = 0): void {
        let f = this.sf;
        f[0] = <f32>a0;
        f[1] = <f32>a1;
        f[2] = <f32>a2;
        f[3] = <f32>a3;
        f[4] = <f32>b0;
        f[5] = <f32>b1;
        f[6] = <f32>b2;
        f[7] = <f32>b3;
        f[8] = <f32>c0;
        f[9] = <f32>c1;
        f[10] = <f32>c2;
        f[11] = <f32>c3;
        for (let k = 12; k < 16; k++) {
            f[k] = 0;
        }
        this.postUbo.get(name).update(0, this.scratch, 64, 0);
    }

    drawObj(o: Obj?, mirrored: bool): void {
        let pass = this.pass;
        if (o != null && pass != null && o.alpha > 0.004) {
            pass.setBindGroup(0, mirrored ? o.bindR : o.bind);
            pass.setVertexBuffer(0, o.vbuf);
            pass.draw(o.count);
        }
    }

    drawList(list: Array<Obj>, mirrored: bool): void {
        for (let i = 0; i < list.length; i++) {
            this.drawObj(list[i], mirrored);
        }
    }

    // LAYER A (opaque): the reflected world, floor, cables, orbs, heart,
    // cases. LAYER B (transparent / emissive, own targets + own depth):
    // Rive panels and everything that glows or is see-through.
    opaque(mirrored: bool, showCases: f64): void {
        this.drawObj(this.objNamed("plasma"), mirrored);
        this.drawList(this.orbs, mirrored);
        if (showCases > 0.01) {
            this.drawList(this.caseObjs, mirrored);
        }
        this.drawList(this.cables, mirrored);
    }

    panels(mirrored: bool): void {
        if (this.s > 0.02) {
            for (let i = 0; i < this.screens.length; i++) {
                if (this.secList[i].live) {
                    this.drawObj(this.screens[i], mirrored);
                }
            }
        }
        if (this.s < 0.98) {
            this.drawList(this.blades, mirrored);
        }
        this.drawList(this.satObjs, mirrored);
    }

    light(mirrored: bool, showCases: f64): void {
        for (let k = 0; k < BIT_KEYS.length; k++) {
            this.drawObj(this.bitNamed(BIT_KEYS[k]), mirrored);
        }
        this.drawList(this.tubes, mirrored);
        this.drawList(this.orbShells, mirrored);
        if (this.s < 0.98) {
            this.drawList(this.frames, mirrored);
            this.drawList(this.beams, mirrored);
        }
        if (this.s > 0.02) {
            for (let i = 0; i < this.screenFrames.length; i++) {
                if (this.secList[i].live) {
                    this.drawObj(this.screenFrames[i], mirrored);
                    this.drawObj(this.screenBeams[i], mirrored);
                }
            }
        }
        if (showCases > 0.01) {
            this.drawList(this.caseEdges, mirrored);
        }
        this.drawList(this.satFrames, mirrored);
    }

    bitU(o: Obj?, m: Mat4, tint: Rgb, a: f64, edgeW: f64, body: f64, glow: f64, hot: f64, energy: f64, flyCalm: f64): void {
        if (o != null) {
            ubBegin(tint, a);
            ubParams(edgeW, body, glow * flyCalm, 0);
            ubMode(11, energy, hot, 0.15 + this.boost * 0.2);
            this.setU(o, m);
        }
    }

    glassU(o: Obj?, m: Mat4, tint: Rgb, a: f64, ior: f64, th: f64): void {
        if (o != null) {
            ubBegin(tint, a);
            ubParams(ior, th, 0.035, 0.5);
            ubMode(13, 0, 0, 0);
            this.setU(o, m);
        }
    }

    // ------------------------------------------------------------ draw
    override draw(renderer: Renderer): void {
        let gpu = this.gpu;
        let depth = this.depth, msaa = this.msaa, hdr = this.hdr;
        let pt = this.pipeTex, pa = this.pipeAdd, pp = this.pipePart;
        let pd = this.pDown, pu = this.pUp, pc = this.pComp;
        let passA = this.passA, passB = this.passB;
        if (!this.ready || gpu == null || depth == null || msaa == null || hdr == null || pt == null || pa == null || pp == null
            || pd == null || pu == null || pc == null || passA == null || passB == null || gpu.width == 0
            || this.bloom.length < LEVELS) {
            return;
        }
        let t = this.time;
        let s = this.s;
        let boost = this.boost;
        let ppl = this.pPlaying;
        let playing = ppl != null ? ppl.value : false;
        let beat = playing ? Math.pow(0.5 + 0.5 * Math.sin(t * 8.4), 6) : 0;

        // 1. render every live Rive artboard into its canvas
        let hs = this.hubSurf;
        if (hs != null) this.renderSurf(hs);
        let ss = this.satSurf;
        if (ss != null) this.renderSurf(ss);
        for (let i = 0; i < this.secList.length; i++) {
            let sf = this.secList[i];
            if (sf.live) {
                this.renderSurf(sf);
            }
        }
        let cc = this.caseCanvas;
        if (cc != null && this.cases.length > 0 && s > 0.02) {
            let r = cc.beginFrame(Color.rgba(0, 0, 0, 0));
            if (r != null) {
                for (let i = 0; i < this.cases.length; i++) {
                    let tcx = i % ATLAS_C;
                    let tcy = i / ATLAS_C;
                    r.save();
                    r.transform(Mat2D.withTranslation(<f32>(<f64>tcx * TILE_W), <f32>(<f64>tcy * TILE_H)));
                    this.cases[i].draw(r);
                    r.restore();
                }
                cc.endFrame();
            }
        }

        // 2. camera: computed once per frame in advance()
        let e = smooth(s);
        let section = Math.floor(this.section + 0.5);

        // Subdued palette: one hue family (Rive amber). Prism colours appear
        // only inside the Rive UI itself; amber is reserved for what is
        // selected or alive.
        let AMB = AMBER;
        // (pushed back along the hub sight line to the blades' focal plane, ~14.4
        // from the eye, and scaled x1.146 so it reads the same size on screen)
        let cHub = V(-0.68, -0.144, -3.17);
        // in sections the core rises and hangs behind the arc of screens, like a sun
        let cSec = V(0.6, 2.4, -14);
        let cp = vlerp(cHub, cSec, e);
        this.corePos = cp;
        // arrival: a soft pop with overshoot when the camera lands at the hub
        let coreK = this.arrK("core", 1);
        let coreScale = (1 + beat * 0.04 + boost * 0.025) * lerp(1.12 * 1.146, 1.6, e) * (0.85 + 0.15 * coreK);
        let cy = <f64>cp.y + Math.sin(t * 0.6) * 0.05;
        let coreAt = tr(cp.x, cy, cp.z) * scl(coreScale, coreScale, coreScale);
        let energy = 0.25 + boost * 0.3 + beat * 0.5;
        let plasma = this.objNamed("plasma");
        if (plasma != null) {
            let hp = 1 + (this.bitPop - 1) * 0.6;
            ubBegin(col(AMB, 0.9), 1);
            ubParams(0, 0.55 + boost * 0.15 + beat * 0.2 + this.bitW[1] * 0.4, 0, 0);
            ubMode(6, energy * 0.6, 0, 0);
            this.setU(plasma, coreAt * rotY(t * 0.1) * scl(hp, hp, hp));
        }
        // Bit layers
        let bw = this.bitW;
        let pop = this.bitPop;
        let spinA = rotY(t * 0.5) * rotX(t * 0.31);
        let spinB = rotY(-t * 0.23) * rotZ(t * 0.17);
        let jitter = this.bitMood == 2 ? tr(Math.sin(t * 61) * 0.03, 0, Math.cos(t * 53) * 0.03) : Mat4.identity();
        // while the camera flies past the core (hub <-> section) it is huge,
        // out of focus and smeared: calm the wireframe so it doesn't flash white.
        // Zero at rest in the hub and in sections.
        let flyCalm = 1 - 0.5 * Math.sin(clamp(e, 0, 1) * PI);
        this.bitU(this.bitNamed("inner"), coreAt * spinA, col(NEUT, 0.35), 1, 0.03, 0.12, 0.7, 0.1, energy, flyCalm);
        let sN = pop * (0.94 + 0.06 * Math.sin(t * 1.7));
        this.bitU(this.bitNamed("neutral"), coreAt * jitter * spinB * scl(sN, sN, sN), col(NEUT, 0.55), bw[0], 0.02, 0.1, 0.9, 0.1,
            energy, flyCalm);
        let sY = pop * lerp(0.6, 1, bw[1]);
        this.bitU(this.bitNamed("yes"), coreAt * spinB * rotY(t * 0.9) * scl(sY, sY, sY), col(AMB, 0.9), bw[1], 0.022, 0.16, 1.3, 0.18,
            energy, flyCalm);
        let sNo = pop * lerp(0.6, 1, bw[2]);
        this.bitU(this.bitNamed("no"), coreAt * jitter * spinA * scl(sNo, sNo, sNo), col(NO_C, 0.8), bw[2], 0.022, 0.16, 1.2, 0.25,
            energy, flyCalm);
        this.bitU(this.bitNamed("outer"), coreAt * rotY(t * 0.06) * rotX(0.3), col(NEUT, 0.3), 1, 0.01, 0.03, 0.55, 0.0, energy, flyCalm);
        // refractive bodies: same poses as the Bit layers
        this.glassU(this.glassNamed("outer"), coreAt * rotY(t * 0.06) * rotX(0.3), new Rgb(0.92, 0.86, 0.76), 0.85, 1.5, 1.8);
        this.glassU(this.glassNamed("neutral"), coreAt * jitter * spinB * scl(sN, sN, sN), new Rgb(1, 0.9, 0.7), bw[0], 1.55, 1.4);
        this.glassU(this.glassNamed("yes"), coreAt * spinB * rotY(t * 0.9) * scl(sY, sY, sY), AMB, bw[1], 1.5, 0.8);
        this.glassU(this.glassNamed("no"), coreAt * jitter * spinA * scl(sNo, sNo, sNo), NO_C, bw[2], 1.5, 0.8);
        let pillar = this.objNamed("pillar");
        if (pillar != null) {
            let ph = cy - FLOOR_Y - 1.0;
            ubBegin(col(NEUT, 0.04 + energy * 0.03), 1 - e);
            ubParams(0.6, 1, 0, 0);
            ubMode(5, 0, 0, 0);
            this.setU(pillar, tr(cp.x, FLOOR_Y, cp.z) * scl(coreScale, Math.max(0.1, ph), coreScale));
        }
        let padM = tr(cp.x, FLOOR_Y + 0.01, cp.z) * scl(coreScale, coreScale, coreScale);
        let pad = this.objNamed("pad");
        if (pad != null) {
            ubBegin(col(NEUT, 0.3), 1 - e);
            ubParams(0, 1, 0, 0);
            ubMode(7, boost * 0.5, 1, 0);
            this.setU(pad, padM * rotY(t * 0.2));
        }
        let pad2 = this.objNamed("pad2");
        if (pad2 != null) {
            ubBegin(col(DEEP, 0.35), 1 - e);
            ubParams(0, 1, 0, 0);
            ubMode(7, 0, 0.6, 0);
            this.setU(pad2, padM * rotY(-t * 0.14));
        }
        let floor = this.objNamed("floor");
        if (floor != null) {
            let secI = section + 1;
            let fpos: Vector;
            if (s > 0.5) {
                screenFrame(secI);
                fpos = OV2;
            } else {
                bladeBase(secI);
                fpos = OV;
            }
            ubBegin(col(DIMN, 0.75), 1);
            ubMode(3, 0, 0, 0);
            ubC(0, cp.x, 0, cp.z, 0.2 + energy * 0.15);
            ubC(1, this.ripple, this.rippleK * 0.8, 0, 0);
            ubC(2, fpos.x, 0, fpos.z, 0.25 + boost * 0.15);
            ubC(3, AMB.r, AMB.g, AMB.b, 0);
            this.setU(floor, tr(0.8, FLOOR_Y, -4));
        }
        let haze = this.objNamed("haze");
        if (haze != null) {
            ubBegin(col(mixc(NEUT, AMB, 0.6), 0.07 + energy * 0.03), 1);
            ubMode(8, 0, 0, 0);
            ubC(0, cp.x, cy, cp.z, 0);
            this.setU(haze, tr(this.eye.x, this.eye.y, this.eye.z));
        }
        let wallK = smooth(clamp((this.tz - 0.12) / 0.14, 0, 1));
        let wall = this.objNamed("wall");
        if (wall != null) {
            ubBegin(col(DEEP, 0.3), this.hexVis);
            ubMode(9, 0, wallK, 0);
            this.setU(wall, tr(HEXC.x, HEXC.y, HEXC.z) * rotY(t * 0.003));
        }
        let wallScrim = this.objNamed("wallScrim");
        if (wallScrim != null) {
            ubBegin(col(DEEP, 0.3), this.hexVis);
            ubMode(9, 1, wallK, 0);
            this.setU(wallScrim, tr(HEXC.x, HEXC.y, HEXC.z) * rotY(t * 0.003));
        }

        // hub blades: hologram panels projected from their orbs
        let orbP = new Array<Vector>(4);
        let orbK = new Array<f64>(4);
        let hubA = clamp(1 - s * 1.6, 0, 1);
        for (let i = 1; i <= this.blades.length; i++) {
            let o = this.blades[i - 1];
            let m = this.bladeModel(i);
            let a = M_ALPHA;
            let f = this.focusPop[i - 1];
            let v0 = (<f64>(i - 1) * ROW_PITCH) / HUB_H;
            let vh = ROW_H / HUB_H;
            let tint = mixc(col(NEUT, 0.5), col(AMB, 1.0), f);
            let rv = clamp(this.bladeReveal * 1.6 - <f64>(i - 1) * 0.15, 0, 1);
            ubBegin(tint, a);
            ubParams(0.35 + f * 0.45, 1.0 - f * 0.3, 0.07, 0);
            ubUvr(0, v0, 1, vh);
            ubMode(0, f * boost * 0.3, BLADE_W / BLADE_H, (1 - f) * 0.3);
            ubFx(rv, 0.0003 + f * 0.0003, this.glitch * (0.15 + f * 0.5));
            this.setU(o, m);
            if (i - 1 < this.frames.length) {
                ubBegin(tint, a * (0.3 + f * 0.6));
                ubParams(0, 0.7 + f * 0.4, 0, 0);
                ubMode(4, f * 0.5 + boost * 0.2, <f64>i, 0);
                this.setU(this.frames[i - 1], m);
            }
            if (i - 1 < this.beams.length) {
                ubBegin(col(tint, 0.04 + f * 0.08), a);
                ubParams(0.8, 1, 0, 0);
                ubMode(5, 0, 0, 0);
                this.setU(this.beams[i - 1], m);
            }
            // the orb's resting spot sits ~4 units in FRONT of its plate (it only
            // looks adjacent through perspective), so it fell outside the plate's
            // focus. Slide it back along the camera ray to the plate surface and
            // scale it up to match: identical on screen, same depth as the plate.
            let op = this.orbPos(i);
            let span = BLADE_W / BLADE_R;
            let edge = m.transformPoint(<f32>(-Math.sin(span / 2) * BLADE_R), 0, <f32>(-Math.cos(span / 2) * BLADE_R));
            let edge2 = m.transformPoint(<f32>(Math.sin(span / 2) * BLADE_R), 0, <f32>(-Math.cos(span / 2) * BLADE_R));
            if (<f64>Vector.length(edge2 - op) < <f64>Vector.length(edge - op)) {
                edge = edge2;
            }
            let dO = <f64>Vector.length(op - this.eye);
            let k = clamp(<f64>Vector.length(edge - this.eye) / Math.max(dO, 0.1), 1, 2);
            orbP[i - 1] = this.eye + (op - this.eye) * <f32>k;
            orbK[i - 1] = k;
        }
        let corePt = V(cp.x, cy, cp.z);
        for (let i = 1; i <= this.orbs.length; i++) {
            let o = this.orbs[i - 1];
            let f = this.focusPop[i - 1];
            let p = orbP[i - 1];
            // arrival: orbs pop in on a spring (overshoot), the energy tubes then
            // fade/grow in a beat later
            let ok = this.arrK("orbs", i);
            let sc = (1 + f * 0.2 + beat * 0.06) * orbK[i - 1] * ok;
            let m = tr(p.x, p.y, p.z) * rotY(t * (0.5 + f)) * scl(sc, sc, sc);
            ubBegin(mixc(col(NEUT, 0.55), col(AMB, 1.5), f), hubA);
            ubParams(0, 0.35 + f * 0.6, 0, 0);
            ubMode(6, f * 0.4 + boost * 0.2, 0, 0);
            this.setU(o, m);
            if (i - 1 < this.orbShells.length) {
                ubBegin(mixc(col(NEUT, 0.45), col(AMB, 0.85), f), hubA);
                ubParams(1.0 + f * 0.5, 0, 0, 0);
                ubMode(2, 0, 0, 0);
                this.setU(this.orbShells[i - 1], m);
            }
            for (let k = 0; k <= 1; k++) {
                let ti = (i - 1) * 2 + k;
                if (ti < this.tubes.length) {
                    let fk = <f64>k;
                    let d = Vector.normalized(p - corePt);
                    let p0 = corePt + d * <f32>1.55 * <f32>coreScale;
                    let p1 = p0 + d * <f32>1.1 + V(0, (fk - 0.5) * 0.6, 0.6);
                    let p2 = p - V(1.1, (fk - 0.5) * -0.3, -0.25);
                    let tint = mixc(col(NEUT, 0.4), col(AMB, 0.9), f);
                    let r0 = k == 0 ? 0.045 : 0.014;
                    let tk = clamp(this.arrK("tubes", i), 0, 1);
                    ubBegin(tint, hubA * (0.25 + f * 0.6) * tk);
                    ubMode(1, f * 0.6 + boost * 0.2, 0, 0);
                    ubC(0, p0.x, p0.y, p0.z, r0);
                    ubC(1, p1.x, p1.y, p1.z, r0 * 0.55);
                    ubC(2, p2.x, p2.y, p2.z, t * (fk + 1) * 0.4);
                    ubC(3, p.x, p.y, p.z, k == 0 ? 0 : 2.5);
                    this.setU(this.tubes[ti], Mat4.identity());
                }
            }
        }
        for (let i = 1; i <= this.screens.length; i++) {
            let o = this.screens[i - 1];
            let m = this.screenModel(i);
            let a = M_ALPHA;
            let rv = this.reveal[i - 1];
            let focus = clamp(1 - Math.abs(<f64>(i - 1) - this.sec), 0, 1);
            ubBegin(mixc(col(NEUT, 0.7), col(AMB, 0.8), focus * 0.5), a);
            ubParams(0.3, 1.1, 0.05, 0);
            ubMode(0, boost * 0.3, SCREEN_W / SCREEN_H, (1 - focus) * 0.45);
            ubFx(rv, 0.0003, this.glitch * 0.6);
            this.setU(o, m);
            if (i - 1 < this.screenFrames.length) {
                ubBegin(mixc(col(NEUT, 0.45), col(AMB, 0.7), focus), a);
                ubParams(0, 0.55, 0, 0);
                ubMode(4, 0.3 + boost * 0.5, 9 + <f64>i, 0);
                this.setU(this.screenFrames[i - 1], m);
            }
            if (i - 1 < this.screenBeams.length) {
                ubBegin(col(NEUT, 0.015 + (1 - rv) * 0.08), a * focus);
                ubParams(0.85, 1, 0, 0);
                ubMode(5, 0, 0, 0);
                this.setU(this.screenBeams[i - 1], m);
            }
        }
        // satellites: six live Rive panels from one atlas, scattered through depth
        for (let k = 1; k <= this.satObjs.length; k++) {
            let o = this.satObjs[k - 1];
            let m = this.satModel(k);
            let cx = <f64>((k - 1) % 2);
            let cyy = <f64>((k - 1) / 2);
            let sa = lerp(1, 0.55, e);
            ubBegin(col(NEUT, 0.55), sa);
            ubParams(0.25, 0.95, 0.05, 0);
            ubUvr((10 + cx * 520) / SAT_W, (10 + cyy * 330) / SAT_H, SAT_CW / SAT_W, SAT_CH / SAT_H);
            ubMode(0, 0, SAT_PW / SAT_PH, 0.12);
            ubFx(clamp(this.bladeReveal * 1.4 - <f64>k * 0.08, 0, 1), 0.0003, this.glitch * 0.3);
            this.setU(o, m);
            if (k - 1 < this.satFrames.length) {
                ubBegin(col(NEUT, 0.4), sa * 0.6);
                ubParams(0, 0.5, 0, 0);
                ubMode(4, 0.2, 30 + <f64>k, 0);
                this.setU(this.satFrames[k - 1], m);
            }
        }
        for (let k = 0; k < this.cables.length; k++) {
            let cb = CABLES[k];
            ubBegin(col(NEUT, 0.9), 1);
            ubParams(0, 0, 0, this.cableLen[k]);
            ubMode(10, boost * 0.4 + beat * 0.3, cb.ph, 0);
            ubC(0, cp.x, cy, cp.z, 0);
            ubC(1, cb.sway, 0, 0, 0);
            ubC(2, AMB.r, AMB.g, AMB.b, 0);
            this.setU(this.cables[k], Mat4.identity());
        }
        let showCases = clamp((s - 0.3) * 2, 0, 1) * clamp(1 - Math.abs(this.sec) * 3.5, 0, 1);
        let n = this.caseObjs.length;
        for (let i = 1; i <= n; i++) {
            let o = this.caseObjs[i - 1];
            let m = this.caseModel(i, n);
            let f = M_ALPHA;
            let cx = <f64>((i - 1) % ATLAS_C);
            let cyy = <f64>((i - 1) / ATLAS_C);
            ubBegin(mixc(col(NEUT, 0.6), col(AMB, 0.8), f), showCases);
            ubParams(0.3 + f * 0.3, 1.0, 0.04, 0);
            ubUvr(cx / <f64>ATLAS_C, cyy / <f64>ATLAS_R, 1 / <f64>ATLAS_C, 1 / <f64>ATLAS_R);
            ubMode(0, 0, CASE_W / CASE_H, (1 - f) * 0.4);
            ubFx(1, 0.0003, this.glitch * f * 0.5);
            this.setU(o, m);
            if (i - 1 < this.caseEdges.length) {
                ubBegin(mixc(col(NEUT, 0.5), col(AMB, 0.8), f), showCases * (0.25 + f * 0.6));
                ubParams(0, 0.6 + f * 0.4, 0, 0);
                ubMode(4, f * 0.4, 20 + <f64>i, 0);
                this.setU(this.caseEdges[i - 1], m);
            }
        }

        // particles: write instance data (pos, size, colour) for this frame
        let pf = this.partF;
        let nP = 0;
        for (let mi = 0; mi < this.motes.length; mi++) {
            let m = this.motes[mi];
            let fam = Math.floor(m.ph);
            let wp: Vector;
            // motes are mostly silver dust; one in six glows amber
            let cc4 = (m.c == 3 || m.c == 2) ? AMBER : MOTE_DIM;
            let k = 1.0;
            if (fam == 0) {
                wp = V(Math.sin(m.a) * m.r + <f64>cp.x, m.y * 0.5 + cy + Math.sin(t + m.ph * 9) * 0.25, Math.cos(m.a) * m.r * 0.7 + <f64>cp.z);
                k = 0.7;
            } else if (fam == 1) {
                wp = V(Math.sin(m.a) * m.r - 0.5, m.y, Math.cos(m.a) * m.r * 0.6 - 2);
                k = 0.55 * clamp((m.y - FLOOR_Y) * 0.8, 0, 1) * clamp((6 - m.y) * 0.5, 0, 1);
            } else {
                wp = V(Math.sin(m.a) * m.r, m.y, Math.cos(m.a) * m.r * 0.5 - 8);
                k = 0.35;
            }
            let o = nP * 8;
            pf[o] = wp.x;
            pf[o + 1] = wp.y;
            pf[o + 2] = wp.z;
            pf[o + 3] = <f32>(m.s * 0.7 * (1 + boost * 0.4));
            pf[o + 4] = <f32>(cc4.r * k);
            pf[o + 5] = <f32>(cc4.g * k);
            pf[o + 6] = <f32>(cc4.b * k);
            pf[o + 7] = 1;
            nP += 1;
        }
        this.partCount = nP;
        let partBuf = this.partBuf;
        let partUbo = this.partUbo;
        if (partBuf != null && partUbo != null) {
            partBuf.update(0, this.partData, <u32>(nP * 32), 0);
            let b = this.scratch;
            this.viewProj.writeToBuffer(b, 0);
            // camera basis for billboarding
            let fwd = Vector.normalized(this.camAt - this.eye);
            let right = Vector.normalized(Vector.cross3(fwd, Vector.xyz(0, 1, 0)));
            let up = Vector.cross3(right, fwd);
            let f = this.sf;
            f[16] = right.x;
            f[17] = right.y;
            f[18] = right.z;
            f[19] = 0;
            f[20] = up.x;
            f[21] = up.y;
            f[22] = up.z;
            f[23] = 0;
            f[24] = <f32>Math.min(3, Math.abs(this.sv) * 0.6 + boost * 0.4);
            // NDC units per pixel of the 3D target (the spark shader's minimum size)
            f[25] = <f32>(2 / Math.max(1, this.sizeY * this.rs));
            f[26] = 0;
            f[27] = 0;
            partUbo.update(0, b, 112, 0);
        }

        // 3. scene pass: HDR, 4x MSAA, resolved into hdrRaw
        let pass = gpu.beginRenderPass(passA);
        this.pass = pass;
        pass.setViewport(0, 0, <f32>gpu.width, <f32>gpu.height);
        // reflections stay in layer A: they sit on the floor and blur with it
        pass.setPipeline(pt);
        this.opaque(true, showCases);
        this.panels(true);
        pass.setPipeline(pa);
        this.light(true, showCases);
        this.drawObj(haze, false);
        this.drawObj(floor, false);
        this.drawObj(pillar, false);
        this.drawObj(pad, false);
        this.drawObj(pad2, false);
        pass.setPipeline(pt);
        this.opaque(false, showCases);
        // hex wall AFTER the opaque cables, depth-tested: cables beyond the wall
        // are dimmed by its smoked-glass body and the lattice glows over them;
        // cables in front of it occlude it
        let pscrim = this.pipeScrim;
        if (pscrim != null) {
            pass.setPipeline(pscrim);
            this.drawObj(wallScrim, false);
        }
        pass.setPipeline(pa);
        this.drawObj(wall, false);
        pass.finish();
        // glass refracts the opaque scene: snapshot layer A
        let prevHdr = this.prevHdr;
        let pCopy = this.pCopy;
        let snapBind = this.snapBind;
        if (pCopy != null && snapBind != null && prevHdr != null) {
            this.fullscreen(gpu, prevHdr, pCopy, snapBind, gpu.width, gpu.height, false);
        }
        // LAYER B: cleared colour + distance, SHARED depth buffer (so layer-A
        // objects in front still occlude panels and glows)
        pass = gpu.beginRenderPass(passB);
        this.pass = pass;
        pass.setViewport(0, 0, <f32>gpu.width, <f32>gpu.height);
        let ptB = this.pipeTexB, paB = this.pipeAddB, pg = this.pipeGlass;
        if (ptB != null && paB != null) {
            pass.setPipeline(ptB);
            this.panels(false);
            if (pg != null) {
                pass.setPipeline(pg);
                for (let gi = 0; gi < GLASS_KEYS.length; gi++) {
                    this.drawObj(this.glassNamed(GLASS_KEYS[gi]), false);
                }
            }
            pass.setPipeline(paB);
            this.light(false, showCases);
        }
        let partBind = this.partBind;
        if (partBuf != null && partBind != null) {
            pass.setPipeline(pp);
            pass.setBindGroup(0, partBind);
            pass.setVertexBuffer(0, partBuf);
            pass.draw(6, <u32>nP);
        }
        pass.finish();
        this.pass = null;

        // 3a. depth of field (two layers) -> hdrC (+ front distance distF)
        let ap = 0.85;
        let band = 0.1;
        let B = this.postBind;
        let P = this.dofP, T = this.dofT;
        let dw = this.dw, dh = this.dh;
        let hv0 = 1 / dw, hv1 = 1 / dh, hv2 = this.focusD, hv3 = ap;
        let sh0 = 0.22, sh1 = band, sh2 = DOF ? dw * 0.019 : 0, sh3 = 0.0;
        let hdrC = this.hdrC, distF = this.distF;
        let pdd = this.pDofDown;
        if (hdrC != null && distF != null && pdd != null && P.has("comp") && B.has("v_c")) {
            if (DOF) {
                let ft0 = 1 / <f64>gpu.width, ft1 = 1 / <f64>gpu.height, ft2 = <f64>gpu.width / dw * 0.25;
                this.post4("v_dA", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3, ft0, ft1, ft2, 0);
                this.fullscreen(gpu, T.get("aH"), pdd, B.get("v_dA"), dw, dh, false);
                this.post4("v_dB", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3, ft0, ft1, ft2, 0);
                this.two(gpu, T.get("bH"), T.get("bK"), P.get("downB"), B.get("v_dB"), dw, dh);
                this.post4("v_t1", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.fullscreen(gpu, T.get("t1"), P.get("tile1"), B.get("v_t1"), dw, dh, false);
                this.post4("v_t2", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.fullscreen(gpu, T.get("t2"), P.get("tile2"), B.get("v_t2"), dw, dh, false);
                this.post4("v_bA", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.two(gpu, T.get("aBg"), T.get("aFg"), P.get("blurA"), B.get("v_bA"), dw, dh);
                this.post4("v_bB", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.two(gpu, T.get("bD"), T.get("bF"), P.get("blurB"), B.get("v_bB"), dw, dh);
                this.post4("v_tA", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.fullscreen(gpu, T.get("aBgT"), P.get("tent"), B.get("v_tA"), dw, dh, false);
                this.post4("v_tF", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.fullscreen(gpu, T.get("aFgT"), P.get("tent"), B.get("v_tF"), dw, dh, false);
                this.post4("v_tB", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.fullscreen(gpu, T.get("bDT"), P.get("tent"), B.get("v_tB"), dw, dh, false);
                this.frameN += 1;
            }
            let distP = this.distP;
            if (distP != null && P.has("dist") && B.has("v_dd")) {
                this.post4("v_dd", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
                this.fullscreen(gpu, distP, P.get("dist"), B.get("v_dd"), gpu.width, gpu.height, false);
            }
            this.post4("v_c", hv0, hv1, hv2, hv3, sh0, sh1, sh2, sh3);
            this.two(gpu, hdrC, distF, P.get("comp"), B.get("v_c"), gpu.width, gpu.height);
        }

        // 3b. camera motion blur (180-degree shutter) from reprojected depth
        let pm = this.pMotion, mu = this.motionUbo, mb = this.motionBind;
        let copyBind = this.copyBind;
        if (!MOTION_BLUR && pCopy != null && copyBind != null) {
            this.fullscreen(gpu, hdr, pCopy, copyBind, gpu.width, gpu.height, false);
        } else if (pm != null && mu != null && mb != null) {
            let b = this.scratch;
            let ivp = Mat4.identity();
            Mat4.invert(ivp, this.viewProj);
            ivp.writeToBuffer(b, 0);
            let pvp0 = this.prevVP;
            let pvp = pvp0 != null ? pvp0 : this.viewProj;
            pvp.writeToBuffer(b, 64);
            let ey = this.eye;
            // shutter opens up during the start-screen dive (and the Esc pull-out):
            // 180 deg normally, up to a ~3x longer streak at peak dive speed
            let diveK = this.flightBell;
            let shutter = lerp(0.5, DIVE_SHUTTER, diveK);
            let maxLen = lerp(0.05, DIVE_MAXLEN, diveK);
            // zoom blur: radial streaks out from the screen centre while diving
            // (on top of the reprojected camera motion), gone at rest
            let zk = this.zoomK;
            let f = this.sf;
            f[32] = ey.x;
            f[33] = ey.y;
            f[34] = ey.z;
            f[35] = <f32>(zk * DIVE_ZOOMBLUR);
            f[36] = <f32>shutter;
            f[37] = <f32>lerp(maxLen, DIVE_MAXLEN, zk);
            f[38] = <f32>(1 / <f64>gpu.width);
            f[39] = <f32>(1 / <f64>gpu.height);
            mu.update(0, b, 160, 0);
            // long streaks (dive / pull-out zoom) get the gap-fill second pass;
            // at rest and for ordinary camera moves one pass is enough
            let pm2 = this.pMotion2, mb2 = this.motionBind2, hm = this.hdrM;
            if (DIVE_MAXLEN > 0.1 && pm2 != null && mb2 != null && hm != null && (diveK > 0.002 || zk > 0.002)) {
                this.fullscreen(gpu, hm, pm, mb, gpu.width, gpu.height, false);
                this.fullscreen(gpu, hdr, pm2, mb2, gpu.width, gpu.height, false);
            } else {
                this.fullscreen(gpu, hdr, pm, mb, gpu.width, gpu.height, false);
            }
        }

        // 4. bloom: 6-level downsample / upsample chain
        let sw = <f64>gpu.width, shh = <f64>gpu.height;
        for (let i = 1; i <= LEVELS; i++) {
            this.post4(D_NAMES[i - 1], 1 / sw, 1 / shh, i == 1 ? 1 : 0, 1.2, 0, 0, 0, 0);
            this.fullscreen(gpu, this.bloom[i - 1], pd, B.get(D_NAMES[i - 1]), this.bw[i - 1], this.bh[i - 1], false);
            sw = this.bw[i - 1];
            shh = this.bh[i - 1];
        }
        for (let i = LEVELS - 1; i >= 1; i--) {
            this.post4(U_NAMES[i - 1], 1 / this.bw[i], 1 / this.bh[i], 1.0, 1.0, 0, 0, 0, 0);
            this.fullscreen(gpu, this.bloom[i - 1], pu, B.get(U_NAMES[i - 1]), this.bw[i - 1], this.bh[i - 1], true);
        }
        this.prevVPT = this.viewProj;
        // 5. composite: bloom + anamorphic streak + aberration + ACES + grain
        this.post4("c", 0.18 + boost * 0.05, 0.92, 0.0012 + this.glitch * 0.004, t, 0.035, 0.018, 0.7, this.flash * 0.08);
        this.fullscreen(gpu, gpu.colorView(), pc, B.get("c"), gpu.width, gpu.height, false);

        renderer.save();
        renderer.transform(Mat2D.withUniformScale(<f32>(1 / this.rs)));
        renderer.drawImage(gpu.image, this.isampler, BlendMode.srcOver, 1);
        renderer.restore();
    }

    // ------------------------------------------------------------ picking
    // ray through a screen point, in the local space of `model`; returns the hit
    // on an arc built by arcMesh(w, h, R) as artboard-local uv (0..1) in PICK_UV
    pickArc(p: Vector, model: Mat4, w: f64, h: f64, R: f64): bool {
        // arcMesh(w, h, R): a cylinder patch of radius R around the local y axis,
        // angles pi +- span/2 (the side facing -z), u left -> right, v top -> bottom
        let mvp = this.viewProj * model;
        let inv = Mat4.identity();
        if (!Mat4.invert(inv, mvp)) {
            if (this.debugPick) this.log("invert failed");
            return false;
        }
        let nx = <f64>p.x / this.sizeX * 2 - 1;
        let ny = 1 - <f64>p.y / this.sizeY * 2;
        let v4 = this.v4;
        inv.transformVec4(v4, <f32>nx, <f32>ny, -1, 1);
        let ax = <f64>v4[0], ay = <f64>v4[1], az = <f64>v4[2], aw = <f64>v4[3];
        inv.transformVec4(v4, <f32>nx, <f32>ny, 1, 1);
        let bx = <f64>v4[0], by = <f64>v4[1], bz = <f64>v4[2], bw = <f64>v4[3];
        let o = V(ax / aw, ay / aw, az / aw);
        let d = Vector.normalized(V(bx / bw, by / bw, bz / bw) - o);
        let ox = <f64>o.x, oy = <f64>o.y, oz = <f64>o.z;
        let dx = <f64>d.x, dy = <f64>d.y, dz = <f64>d.z;
        let A = dx * dx + dz * dz;
        let B = 2 * (ox * dx + oz * dz);
        let C = ox * ox + oz * oz - R * R;
        let disc = B * B - 4 * A * C;
        if (disc < 0 || A < 1e-8) {
            if (this.debugPick) this.log("nohit");
            return false;
        }
        let sq = Math.sqrt(disc);
        let span = w / R;
        let found = false;
        let bestT = Infinity;
        for (let r = 0; r < 2; r++) {
            let tt = r == 0 ? (-B - sq) / (2 * A) : (-B + sq) / (2 * A);
            if (tt > 0 && tt < bestT) {
                let hx = ox + dx * tt;
                let hy = oy + dy * tt;
                let hz = oz + dz * tt;
                let a = Math.atan2(hx, hz);
                if (a < 0) {
                    a += PI * 2;
                }
                let u = ((PI + span / 2) - a) / span;
                let v = 0.5 - hy / h;
                if (u >= 0 && u <= 1 && v >= 0 && v <= 1) {
                    PICK_UV = Vector.xy(<f32>u, <f32>v);
                    bestT = tt;
                    found = true;
                }
            }
        }
        return found;
    }

    // -> R_INST / R_LP / R_WHICH (R_INST null = no hit)
    route(pos: Vector): void {
        R_INST = null;
        if (!this.ready) {
            if (this.debugPick) this.log("route: not ready");
            return;
        }
        if (this.s > 0.6) {
            let i = <i32>Math.floor(this.section + 0.5);
            if (i >= 0 && i < this.screenHit.length && i < this.secList.length) {
                let m = this.screenHit[i];
                let sf = this.secList[i];
                if (this.pickArc(pos, m, SCREEN_W, SCREEN_H, SCREEN_R)) {
                    R_INST = sf.inst;
                    R_LP = Vector.xy(<f32>(<f64>PICK_UV.x * sf.w), <f32>(<f64>PICK_UV.y * sf.h));
                    R_WHICH = "screen";
                }
            }
            return;
        }
        // nearest blade first: the focused one pops toward the camera
        let hub = this.hubSurf;
        for (let i = 0; i < this.bladeHit.length; i++) {
            if (hub != null && this.pickArc(pos, this.bladeHit[i], BLADE_W, BLADE_H, BLADE_R)) {
                R_INST = hub.inst;
                R_LP = Vector.xy(<f32>(<f64>PICK_UV.x * HUB_W), <f32>(<f64>i * ROW_PITCH + <f64>PICK_UV.y * ROW_H));
                R_WHICH = "hub";
                return;
            }
        }
    }

    override keyboardEvent(e: KeyboardEvent): bool {
        if (this.debugPick) {
            this.log("world key " + e.key.toString() + " " + e.phase);
        }
        return false;
    }

    override pointerDown(event: PointerEvent): void {
        // start screen: a click anywhere presses start, like Enter
        let acc = this.pAccept;
        if (this.ready && Math.floor(this.mode + 0.5) == 0 && acc != null) {
            acc.fire();
            event.hit();
            return;
        }
        // any press on the 3D world ends player-name editing (focus back to the dashboard)
        let ed = this.pEditing;
        let fd = this.pFieldDone;
        if (ed != null && fd != null && ed.value) {
            fd.fire();
        }
        this.route(event.position);
        let inst = R_INST;
        if (inst != null) {
            inst.pointerDown(new PointerEvent(event.id, R_LP));
            this.capture = true;
            event.hit();
        }
    }

    override pointerMove(event: PointerEvent): void {
        if (this.sizeX > 0) {
            this.pointerT = Vector.xy(<f32>(<f64>event.position.x / this.sizeX * 2 - 1), <f32>(<f64>event.position.y / this.sizeY * 2 - 1));
        }
        this.route(event.position);
        let inst = R_INST;
        if (inst != null) {
            inst.pointerMove(new PointerEvent(event.id, R_LP));
            if (this.capture) {
                event.hit();
            }
        }
    }

    override pointerExit(event: PointerEvent): void {
        // mouse left the window: drift the tilt back to centre
        this.pointerT = Vector.xy(0, 0);
    }

    // mouse wheel / trackpad: scroll the list on the 3D screen under the pointer
    override pointerScroll(event: ScrollEvent): void {
        this.route(event.position);
        let inst = R_INST;
        if (inst != null) {
            let fwd = new ScrollEvent(event.id, R_LP, event.delta, event.phase, event.precise, event.timeStamp);
            if (inst.pointerScroll(fwd) != 0) {
                event.hit();
            }
        }
    }

    override pointerUp(event: PointerEvent): void {
        this.route(event.position);
        let inst = R_INST;
        if (inst != null) {
            inst.pointerUp(new PointerEvent(event.id, R_LP));
        }
        this.capture = false;
    }
}

// bladeModel / screenModel / caseModel second return value
let M_ALPHA: f64 = 0;
