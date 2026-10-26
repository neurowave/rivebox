// geo3.as — geometry for the RiveBox world (AnimaScript port of geo3.luau).
// Every mesh is pos(3) normal(3) uv(2) = 32 bytes per vertex, triangle list,
// so any of them can carry a Rive artboard as a texture.
//
// A library module: no protocol class, so no ScriptAsset; world.as imports it
// with `import * as Geo from "./geo3"`.
//
// Port notes: scalars are f64 like Luau numbers and every vertex component is
// rounded to f32 once, where Luau's buffer.writef32 rounded it. Vector maths is
// f32 in both languages, so the same expressions run on Vector here (same
// operation order) to keep the meshes bit-identical where libm agrees.

import { Vector } from "rive/vector";

export class Mesh {
    buf: ArrayBuffer;
    count: i32;
    // Geo.cable's second Luau return value: the cable's length in world units
    len: f64 = 0;
    constructor(buf: ArrayBuffer, count: i32) {
        this.buf = buf;
        this.count = count;
    }
}

const STRIDE: i32 = 32;
const PI: f64 = Math.PI;

class Writer {
    b: ArrayBuffer;
    f: Float32Array;
    o: i32 = 0;
    constructor(n: i32) {
        this.b = new ArrayBuffer(n * STRIDE);
        this.f = Float32Array.wrap(this.b);
    }
    v(px: f64, py: f64, pz: f64, nx: f64, ny: f64, nz: f64, u: f64, w: f64): void {
        let f = this.f;
        let o = this.o;
        f[o] = <f32>px;
        f[o + 1] = <f32>py;
        f[o + 2] = <f32>pz;
        f[o + 3] = <f32>nx;
        f[o + 4] = <f32>ny;
        f[o + 5] = <f32>nz;
        f[o + 6] = <f32>u;
        f[o + 7] = <f32>w;
        this.o = o + 8;
    }
    mesh(count: i32): Mesh {
        return new Mesh(this.b, count);
    }
}

function v3(x: f64, y: f64, z: f64): Vector {
    return Vector.xyz(<f32>x, <f32>y, <f32>z);
}

// Mesh from an indexed [pos.xyz, normal.xyz] (24 B) + uint16 index pair;
// uv carries barycentric coords so the shader can find triangle edges.
export function fromIndexed(vb: ArrayBuffer, ib: ArrayBuffer, idxCount: i32, scale: f64): Mesh {
    let w = new Writer(idxCount);
    let vf = Float32Array.wrap(vb);
    let iu = Uint16Array.wrap(ib);
    for (let k = 0; k < idxCount; k++) {
        let vi = <i32>iu[k] * 6;
        let c = k % 3;
        w.v(<f64>vf[vi] * scale, <f64>vf[vi + 1] * scale, <f64>vf[vi + 2] * scale,
            <f64>vf[vi + 3], <f64>vf[vi + 4], <f64>vf[vi + 5],
            c == 0 ? 1 : 0, c == 1 ? 1 : 0);
    }
    return w.mesh(idxCount);
}

// UV sphere, equirectangular uv (u around +y, v top -> bottom).
export function sphere(r: f64, segU: i32, segV: i32): Mesh {
    let n = segU * segV * 6;
    let w = new Writer(n);
    for (let i = 0; i < segU; i++) {
        for (let j = 0; j < segV; j++) {
            spherePt(w, r, segU, segV, i, j);
            spherePt(w, r, segU, segV, i, j + 1);
            spherePt(w, r, segU, segV, i + 1, j);
            spherePt(w, r, segU, segV, i + 1, j);
            spherePt(w, r, segU, segV, i, j + 1);
            spherePt(w, r, segU, segV, i + 1, j + 1);
        }
    }
    return w.mesh(n);
}

function spherePt(wr: Writer, r: f64, segU: i32, segV: i32, i: i32, j: i32): void {
    let u = <f64>i / <f64>segU;
    let w = <f64>j / <f64>segV;
    let th = u * PI * 2;
    let ph = w * PI;
    let x = Math.sin(ph) * Math.sin(th);
    let y = Math.cos(ph);
    let z = Math.sin(ph) * Math.cos(th);
    wr.v(x * r, y * r, z * r, x, y, z, u, w);
}

// Cylinder segment (curved screen) around the y axis. Angle 0 faces +z.
// u runs a0 -> a1 (left to right when seen from outside), v top -> bottom.
export function arc(R: f64, a0: f64, a1: f64, h: f64, seg: i32, inward: bool = false): Mesh {
    let n = seg * 6;
    let w = new Writer(n);
    let s: f64 = inward ? -1 : 1;
    for (let i = 0; i < seg; i++) {
        arcPt(w, R, a0, a1, h, seg, s, i, true);
        arcPt(w, R, a0, a1, h, seg, s, i, false);
        arcPt(w, R, a0, a1, h, seg, s, i + 1, true);
        arcPt(w, R, a0, a1, h, seg, s, i + 1, true);
        arcPt(w, R, a0, a1, h, seg, s, i, false);
        arcPt(w, R, a0, a1, h, seg, s, i + 1, false);
    }
    return w.mesh(n);
}

function arcPt(wr: Writer, R: f64, a0: f64, a1: f64, h: f64, seg: i32, s: f64, i: i32, top: bool): void {
    let u = <f64>i / <f64>seg;
    let a = a0 + (a1 - a0) * u;
    let x = Math.sin(a) * R;
    let z = Math.cos(a) * R;
    let y = top ? h * 0.5 : -h * 0.5;
    wr.v(x, y, z, Math.sin(a) * s, 0, Math.cos(a) * s, u, top ? 0 : 1);
}

// Closed band (ribbon) around the y axis; u wraps reps times.
export function band(R: f64, h: f64, seg: i32, reps: f64): Mesh {
    let n = seg * 6;
    let w = new Writer(n);
    for (let i = 0; i < seg; i++) {
        bandPt(w, R, h, seg, reps, i, true);
        bandPt(w, R, h, seg, reps, i, false);
        bandPt(w, R, h, seg, reps, i + 1, true);
        bandPt(w, R, h, seg, reps, i + 1, true);
        bandPt(w, R, h, seg, reps, i, false);
        bandPt(w, R, h, seg, reps, i + 1, false);
    }
    return w.mesh(n);
}

function bandPt(wr: Writer, R: f64, h: f64, seg: i32, reps: f64, i: i32, top: bool): void {
    let u = <f64>i / <f64>seg;
    let a = u * PI * 2;
    let x = Math.sin(a) * R;
    let z = Math.cos(a) * R;
    wr.v(x, top ? h * 0.5 : -h * 0.5, z, Math.sin(a), 0, Math.cos(a), u * reps, top ? 0 : 1);
}

// Torus in the xz plane; u along the ring (x reps), v around the tube.
export function torus(R: f64, r: f64, segU: i32, segV: i32, reps: f64): Mesh {
    let n = segU * segV * 6;
    let w = new Writer(n);
    for (let i = 0; i < segU; i++) {
        for (let j = 0; j < segV; j++) {
            torusPt(w, R, r, segU, segV, reps, i, j);
            torusPt(w, R, r, segU, segV, reps, i + 1, j);
            torusPt(w, R, r, segU, segV, reps, i, j + 1);
            torusPt(w, R, r, segU, segV, reps, i + 1, j);
            torusPt(w, R, r, segU, segV, reps, i + 1, j + 1);
            torusPt(w, R, r, segU, segV, reps, i, j + 1);
        }
    }
    return w.mesh(n);
}

function torusPt(wr: Writer, R: f64, r: f64, segU: i32, segV: i32, reps: f64, i: i32, j: i32): void {
    let u = <f64>i / <f64>segU;
    let w = <f64>j / <f64>segV;
    let a = u * PI * 2;
    let c = w * PI * 2;
    let cx = Math.sin(a);
    let cz = Math.cos(a);
    let nx = cx * Math.cos(c);
    let ny = Math.sin(c);
    let nz = cz * Math.cos(c);
    wr.v(cx * R + nx * r, ny * r, cz * R + nz * r, nx, ny, nz, u * reps, w);
}

function bez(a: f64, b: f64, c: f64, d: f64, t: f64): f64 {
    let s = 1 - t;
    return s * s * s * a + 3 * s * s * t * b + 3 * s * t * t * c + t * t * t * d;
}

// Tube swept along a cubic bezier; u = 0..1 along the curve.
export function tube(p0: Vector, p1: Vector, p2: Vector, p3: Vector, r0: f64, r1: f64, seg: i32, sides: i32): Mesh {
    let n = seg * sides * 6;
    let w = new Writer(n);
    let pts = new Array<Vector>(seg + 1);
    for (let i = 0; i <= seg; i++) {
        let t = <f64>i / <f64>seg;
        pts[i] = v3(bez(p0.x, p1.x, p2.x, p3.x, t), bez(p0.y, p1.y, p2.y, p3.y, t), bez(p0.z, p1.z, p2.z, p3.z, t));
    }
    for (let i = 0; i < seg; i++) {
        for (let k = 0; k < sides; k++) {
            tubePt(w, pts, seg, sides, r0, r1, i, k);
            tubePt(w, pts, seg, sides, r0, r1, i + 1, k);
            tubePt(w, pts, seg, sides, r0, r1, i, k + 1);
            tubePt(w, pts, seg, sides, r0, r1, i + 1, k);
            tubePt(w, pts, seg, sides, r0, r1, i + 1, k + 1);
            tubePt(w, pts, seg, sides, r0, r1, i, k + 1);
        }
    }
    return w.mesh(n);
}

function tubePt(wr: Writer, pts: Array<Vector>, seg: i32, sides: i32, r0: f64, r1: f64, i: i32, k: i32): void {
    // frame(i): Luau pts[max(1, i)] / pts[min(seg + 1, i + 2)] (1-based)
    let a = pts[i - 1 < 0 ? 0 : i - 1];
    let cc = pts[i + 1 > seg ? seg : i + 1];
    let tng = Vector.normalized(cc - a);
    let up = Math.abs(<f64>tng.y) > 0.9 ? Vector.xyz(1, 0, 0) : Vector.xyz(0, 1, 0);
    let tx = <f64>tng.x, ty = <f64>tng.y, tz = <f64>tng.z;
    let nx = Vector.normalized(v3(ty * <f64>up.z - tz * <f64>up.y, tz * <f64>up.x - tx * <f64>up.z, tx * <f64>up.y - ty * <f64>up.x));
    let ny = v3(ty * <f64>nx.z - tz * <f64>nx.y, tz * <f64>nx.x - tx * <f64>nx.z, tx * <f64>nx.y - ty * <f64>nx.x);
    let c = pts[i];
    let ang = <f64>k / <f64>sides * PI * 2;
    let ca = Math.cos(ang), sa = Math.sin(ang);
    let dx = <f64>nx.x * ca + <f64>ny.x * sa;
    let dy = <f64>nx.y * ca + <f64>ny.y * sa;
    let dz = <f64>nx.z * ca + <f64>ny.z * sa;
    let t = <f64>i / <f64>seg;
    let r = r0 + (r1 - r0) * t;
    wr.v(<f64>c.x + dx * r, <f64>c.y + dy * r, <f64>c.z + dz * r, dx, dy, dz, t, <f64>k / <f64>sides);
}

// Game case: front face carries the whole texture (u 0..0.86), the spine on
// the left carries the strip at u 0.88..1.0; back and edges sample a dark
// corner of the texture.
export function gameCase(w: f64, h: f64, d: f64): Mesh {
    let n = 36;
    let wr = new Writer(n);
    let x0 = -w / 2, x1 = w / 2, y0 = -h / 2, y1 = h / 2, z0 = -d / 2, z1 = d / 2;
    let dark: StaticArray<f64> = [-1, 0, -1, 1];
    quad(wr, [x0, y1, z1], [x1, y1, z1], [x1, y0, z1], [x0, y0, z1], [0, 0, 1], [0, 0, 0.86, 1]); // front
    quad(wr, [x1, y1, z0], [x0, y1, z0], [x0, y0, z0], [x1, y0, z0], [0, 0, -1], dark); // back
    quad(wr, [x0, y1, z0], [x0, y1, z1], [x0, y0, z1], [x0, y0, z0], [-1, 0, 0], [0.88, 0, 0.98, 1]); // spine (left)
    quad(wr, [x1, y1, z1], [x1, y1, z0], [x1, y0, z0], [x1, y0, z1], [1, 0, 0], dark); // right edge
    quad(wr, [x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1], [0, 1, 0], dark); // top
    quad(wr, [x0, y0, z1], [x1, y0, z1], [x1, y0, z0], [x0, y0, z0], [0, -1, 0], dark); // bottom
    return wr.mesh(n);
}

// uv = u0, v0, u1, v1 ; a = top-left, bb = top-right, c = bottom-right, dd = bottom-left
function quad(v: Writer, a: StaticArray<f64>, bb: StaticArray<f64>, c: StaticArray<f64>, dd: StaticArray<f64>,
    nn: StaticArray<f64>, uv: StaticArray<f64>): void {
    v.v(a[0], a[1], a[2], nn[0], nn[1], nn[2], uv[0], uv[1]);
    v.v(dd[0], dd[1], dd[2], nn[0], nn[1], nn[2], uv[0], uv[3]);
    v.v(bb[0], bb[1], bb[2], nn[0], nn[1], nn[2], uv[2], uv[1]);
    v.v(bb[0], bb[1], bb[2], nn[0], nn[1], nn[2], uv[2], uv[1]);
    v.v(dd[0], dd[1], dd[2], nn[0], nn[1], nn[2], uv[0], uv[3]);
    v.v(c[0], c[1], c[2], nn[0], nn[1], nn[2], uv[2], uv[3]);
}

// Flat floor grid as thin quads (triangle list so it shares the pipeline).
export function grid(size: f64, cells: i32, w: f64): Mesh {
    let lines = (cells + 1) * 2;
    let n = lines * 6;
    let v = new Writer(n);
    let step = size / <f64>cells;
    let h = size / 2;
    for (let i = 0; i <= cells; i++) {
        let c = -h + <f64>i * step;
        let u = <f64>i / <f64>cells;
        // along z
        v.v(c - w, 0, -h, 0, 1, 0, u, 0); v.v(c - w, 0, h, 0, 1, 0, u, 1); v.v(c + w, 0, -h, 0, 1, 0, u, 0);
        v.v(c + w, 0, -h, 0, 1, 0, u, 0); v.v(c - w, 0, h, 0, 1, 0, u, 1); v.v(c + w, 0, h, 0, 1, 0, u, 1);
        // along x
        v.v(-h, 0, c - w, 0, 1, 0, 0, u); v.v(h, 0, c - w, 0, 1, 0, 1, u); v.v(-h, 0, c + w, 0, 1, 0, 0, u);
        v.v(-h, 0, c + w, 0, 1, 0, 0, u); v.v(h, 0, c - w, 0, 1, 0, 1, u); v.v(h, 0, c + w, 0, 1, 0, 1, u);
    }
    return v.mesh(n);
}

// ---------------------------------------------------------------- holographic kit

// Canonical tube: pos.x = t (0..1 along the curve), pos.y = angle around it.
// The vertex shader bends it along a cubic bezier given in the uniforms, so
// energy tubes follow their (moving) end points with no per-frame upload.
export function tubeCanon(seg: i32, sides: i32): Mesh {
    let n = seg * sides * 6;
    let w = new Writer(n);
    for (let i = 0; i < seg; i++) {
        for (let k = 0; k < sides; k++) {
            canonPt(w, seg, sides, i, k);
            canonPt(w, seg, sides, i + 1, k);
            canonPt(w, seg, sides, i, k + 1);
            canonPt(w, seg, sides, i + 1, k);
            canonPt(w, seg, sides, i + 1, k + 1);
            canonPt(w, seg, sides, i, k + 1);
        }
    }
    return w.mesh(n);
}

function canonPt(wr: Writer, seg: i32, sides: i32, i: i32, k: i32): void {
    let t = <f64>i / <f64>seg;
    let a = <f64>k / <f64>sides * PI * 2;
    wr.v(t, a, 0, 0, 0, 0, t, <f64>k / <f64>sides);
}

// Torus with an elliptical cross-section: rr radial half-thickness, ry
// vertical half-thickness (a tall thin ry/rr reads as a machined band).
export function ring(R: f64, rr: f64, ry: f64, segU: i32, segV: i32): Mesh {
    let n = segU * segV * 6;
    let w = new Writer(n);
    for (let i = 0; i < segU; i++) {
        for (let j = 0; j < segV; j++) {
            ringPt(w, R, rr, ry, segU, segV, i, j);
            ringPt(w, R, rr, ry, segU, segV, i + 1, j);
            ringPt(w, R, rr, ry, segU, segV, i, j + 1);
            ringPt(w, R, rr, ry, segU, segV, i + 1, j);
            ringPt(w, R, rr, ry, segU, segV, i + 1, j + 1);
            ringPt(w, R, rr, ry, segU, segV, i, j + 1);
        }
    }
    return w.mesh(n);
}

function ringPt(wr: Writer, R: f64, rr: f64, ry: f64, segU: i32, segV: i32, i: i32, j: i32): void {
    let u = <f64>i / <f64>segU;
    let w = <f64>j / <f64>segV;
    let a = u * PI * 2;
    let c = w * PI * 2;
    let cx = Math.sin(a), cz = Math.cos(a);
    let ox = Math.cos(c) * rr, oy = Math.sin(c) * ry;
    let nx0 = Math.cos(c) / rr, ny0 = Math.sin(c) / ry;
    let nl = Math.sqrt(nx0 * nx0 + ny0 * ny0);
    nx0 /= nl;
    ny0 /= nl;
    wr.v(cx * (R + ox), oy, cz * (R + ox), cx * nx0, ny0, cz * nx0, u, w);
}

// A square-section bar from a to b (frame edges). uv.x runs u0..u1 along the
// bar, uv.y carries `tag` (1 = corner bracket highlight).
function bar(v: Writer, a: Vector, bb: Vector, th: f64, u0: f64, u1: f64, tag: f64): void {
    let d = Vector.normalized(bb - a);
    let up = Math.abs(<f64>d.y) > 0.9 ? Vector.xyz(1, 0, 0) : Vector.xyz(0, 1, 0);
    let s1 = Vector.normalized(Vector.cross3(d, up)) * <f32>th;
    let s2 = Vector.normalized(Vector.cross3(d, s1)) * <f32>th;
    let sides: Array<Vector> = [s1 + s2, s1 - s2, -s1 - s2, -s1 + s2];
    for (let k = 0; k < 4; k++) {
        let o1 = sides[k];
        let o2 = sides[(k + 1) % 4];
        let nn = Vector.normalized(o1 + o2);
        let p1 = a + o1, p2 = bb + o1, p3 = bb + o2, p4 = a + o2;
        v.v(p1.x, p1.y, p1.z, nn.x, nn.y, nn.z, u0, tag);
        v.v(p2.x, p2.y, p2.z, nn.x, nn.y, nn.z, u1, tag);
        v.v(p3.x, p3.y, p3.z, nn.x, nn.y, nn.z, u1, tag);
        v.v(p1.x, p1.y, p1.z, nn.x, nn.y, nn.z, u0, tag);
        v.v(p3.x, p3.y, p3.z, nn.x, nn.y, nn.z, u1, tag);
        v.v(p4.x, p4.y, p4.z, nn.x, nn.y, nn.z, u0, tag);
    }
}

function arcPoint(a0: f64, a1: f64, Ro: f64, u: f64, y: f64): Vector {
    let a = a0 + (a1 - a0) * u;
    return v3(Math.sin(a) * Ro, y, Math.cos(a) * Ro);
}

// Neon frame around an arc panel built by Geo.arc(R, a0, a1, h): top and bottom
// edges follow the curve, plus the two verticals; corner segments are tagged.
export function arcFrame(R: f64, a0: f64, a1: f64, h: f64, th: f64, seg: i32, out: f64): Mesh {
    let n = (seg * 2 + 2) * 24;
    let v = new Writer(n);
    let Ro = R - out;
    let hy = h * 0.5 + out;
    let uo = out / ((a1 - a0) * R);
    for (let i = 0; i < seg; i++) {
        let u0 = <f64>i / <f64>seg, u1 = <f64>(i + 1) / <f64>seg;
        let cu: f64 = (u0 < 0.12 || u1 > 0.88) ? 1 : 0;
        let ua = (-uo + u0 * (1 + 2 * uo));
        let ub = (-uo + u1 * (1 + 2 * uo));
        bar(v, arcPoint(a0, a1, Ro, ua, hy), arcPoint(a0, a1, Ro, ub, hy), th, u0 * 0.35, u1 * 0.35, cu);
        bar(v, arcPoint(a0, a1, Ro, ub, -hy), arcPoint(a0, a1, Ro, ua, -hy), th, 0.5 + (1 - u1) * 0.35, 0.5 + (1 - u0) * 0.35, cu);
    }
    let ul = -uo, ur = 1 + uo;
    bar(v, arcPoint(a0, a1, Ro, ur, hy), arcPoint(a0, a1, Ro, ur, -hy), th, 0.35, 0.5, 1);
    bar(v, arcPoint(a0, a1, Ro, ul, -hy), arcPoint(a0, a1, Ro, ul, hy), th, 0.85, 1.0, 1);
    return v.mesh(n);
}

// Neon edges of a box (game case).
export function boxEdges(w: f64, h: f64, d: f64, th: f64): Mesh {
    let v = new Writer(12 * 24);
    let x = w / 2, y = h / 2, z = d / 2;
    let c: Array<Vector> = [
        v3(-x, -y, -z), v3(x, -y, -z), v3(x, y, -z), v3(-x, y, -z),
        v3(-x, -y, z), v3(x, -y, z), v3(x, y, z), v3(-x, y, z),
    ];
    let e: StaticArray<i32> = [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7];
    for (let k = 1; k <= 12; k++) {
        bar(v, c[e[(k - 1) * 2]], c[e[(k - 1) * 2 + 1]], th, <f64>(k - 1) / 12, <f64>k / 12, k > 8 ? 1 : 0);
    }
    return v.mesh(12 * 24);
}

// Open cone (projector light volume) from radius r0 at y0 to r1 at y1;
// uv.y = 0 at y0 -> 1 at y1, uv.x around.
export function cone(r0: f64, r1: f64, y0: f64, y1: f64, seg: i32): Mesh {
    let n = seg * 6;
    let w = new Writer(n);
    for (let i = 0; i < seg; i++) {
        conePt(w, r0, r1, y0, y1, seg, i, false);
        conePt(w, r0, r1, y0, y1, seg, i + 1, false);
        conePt(w, r0, r1, y0, y1, seg, i, true);
        conePt(w, r0, r1, y0, y1, seg, i + 1, false);
        conePt(w, r0, r1, y0, y1, seg, i + 1, true);
        conePt(w, r0, r1, y0, y1, seg, i, true);
    }
    return w.mesh(n);
}

function conePt(wr: Writer, r0: f64, r1: f64, y0: f64, y1: f64, seg: i32, i: i32, top: bool): void {
    let u = <f64>i / <f64>seg;
    let a = u * PI * 2;
    let r = top ? r1 : r0;
    let y = top ? y1 : y0;
    wr.v(Math.sin(a) * r, y, Math.cos(a) * r, Math.sin(a), 0, Math.cos(a), u, top ? 1 : 0);
}

// Light sheet hanging under an arc panel: from the bottom edge (uv.y = 1)
// down to `drop` below it (uv.y = 0), flaring outward.
export function arcSheet(R: f64, a0: f64, a1: f64, yTop: f64, drop: f64, flare: f64, seg: i32): Mesh {
    let n = seg * 6;
    let w = new Writer(n);
    for (let i = 0; i < seg; i++) {
        sheetPt(w, R, a0, a1, yTop, drop, flare, seg, i, true);
        sheetPt(w, R, a0, a1, yTop, drop, flare, seg, i, false);
        sheetPt(w, R, a0, a1, yTop, drop, flare, seg, i + 1, true);
        sheetPt(w, R, a0, a1, yTop, drop, flare, seg, i + 1, true);
        sheetPt(w, R, a0, a1, yTop, drop, flare, seg, i, false);
        sheetPt(w, R, a0, a1, yTop, drop, flare, seg, i + 1, false);
    }
    return w.mesh(n);
}

function sheetPt(wr: Writer, R: f64, a0: f64, a1: f64, yTop: f64, drop: f64, flare: f64, seg: i32, i: i32, top: bool): void {
    let u = <f64>i / <f64>seg;
    let a = a0 + (a1 - a0) * u;
    let r = top ? R : R - flare;
    let y = top ? yTop : yTop - drop;
    wr.v(Math.sin(a) * r, y, Math.cos(a) * r, -Math.sin(a), 0, -Math.cos(a), u, top ? 1 : 0);
}

// Projection frustum: apex -> four corners of an arc panel (local space of
// Geo.arc). uv.y = 0 at the apex, 1 at the panel; uv.x across each face.
export function frustum(apex: Vector, R: f64, a0: f64, a1: f64, h: f64, seg: i32): Mesh {
    let n = (seg * 2 + 2) * 3;
    let v = new Writer(n);
    let hy = h * 0.5;
    for (let i = 0; i < seg; i++) {
        let u0 = <f64>i / <f64>seg, u1 = <f64>(i + 1) / <f64>seg;
        frustTri(v, apex, arcPoint(a0, a1, R, u0, hy), arcPoint(a0, a1, R, u1, hy), u0, u1);
        frustTri(v, apex, arcPoint(a0, a1, R, u1, -hy), arcPoint(a0, a1, R, u0, -hy), u1, u0);
    }
    frustTri(v, apex, arcPoint(a0, a1, R, 0, -hy), arcPoint(a0, a1, R, 0, hy), 0, 1);
    frustTri(v, apex, arcPoint(a0, a1, R, 1, hy), arcPoint(a0, a1, R, 1, -hy), 0, 1);
    return v.mesh(n);
}

function frustTri(v: Writer, apex: Vector, p1: Vector, p2: Vector, u1: f64, u2: f64): void {
    let nn = Vector.normalized(Vector.cross3(p1 - apex, p2 - apex));
    v.v(apex.x, apex.y, apex.z, nn.x, nn.y, nn.z, (u1 + u2) * 0.5, 0);
    v.v(p1.x, p1.y, p1.z, nn.x, nn.y, nn.z, u1, 1);
    v.v(p2.x, p2.y, p2.z, nn.x, nn.y, nn.z, u2, 1);
}

// Flat square in the xz plane.
export function plane(size: f64): Mesh {
    let v = new Writer(6);
    let h = size / 2;
    v.v(-h, 0, -h, 0, 1, 0, 0, 0); v.v(h, 0, -h, 0, 1, 0, 1, 0); v.v(h, 0, h, 0, 1, 0, 1, 1);
    v.v(-h, 0, -h, 0, 1, 0, 0, 0); v.v(h, 0, h, 0, 1, 0, 1, 1); v.v(-h, 0, h, 0, 1, 0, 0, 1);
    return v.mesh(6);
}

// Catmull-Rom point (same operation order as the Luau expression)
export function catmull(p0: Vector, p1: Vector, p2: Vector, p3: Vector, t: f64): Vector {
    let t2 = t * t, t3 = t * t * t;
    return (p1 * 2 + (p2 - p0) * <f32>t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * <f32>t2 + (p1 * 3 - p0 - p2 * 3 + p3) * <f32>t3) * 0.5;
}

// Long cable bundle along a Catmull-Rom curve through `pts`: a thick main
// tube plus `wraps` thin wires spiralling around it (uv.y >= 2 marks a wire).
// Parallel-transport frames keep the surface from twisting. uv.x = 0..1 along
// the whole length; the returned mesh's `len` is that length in world units.
// hasMinY = false stands in for Luau's `minY = nil`.
export function cable(pts: Array<Vector>, r: f64, per: i32, sides: i32, wraps: i32, minY: f64, hasMinY: bool = true): Mesh {
    let b = new CableBuilder(pts, r, per, sides, wraps, minY, hasMinY);
    b.step(b.rows);
    return b.mesh();
}

// Resumable Geo.cable: the constructor samples the curve and builds the
// frames, step(n) emits the next n rows (tube rows first, then each wire's
// rows: the same vertex order as Luau's single pass). Each ring's points are
// computed once per row and reused by the quads that share them; the values
// are the ones the per-vertex Luau code computed.
export class CableBuilder {
    samples: Array<Vector>;
    nors: Array<Vector>;
    bins: Array<Vector>;
    acc: Array<f64>;
    total: f64;
    m: i32;
    r: f64;
    sides: i32;
    wraps: i32;
    wsides: i32 = 5;
    count: i32;
    rows: i32;
    row: i32 = 0;
    v: Writer;
    ra: Float64Array;
    rb: Float64Array;
    tubeC: Array<f32>;
    tubeS: Array<f32>;
    wireC: Array<f32>;
    wireS: Array<f32>;

    constructor(pts: Array<Vector>, r: f64, per: i32, sides: i32, wraps: i32, minY: f64, hasMinY: bool) {
        let n = pts.length;
        let samples = new Array<Vector>();
        for (let i = 0; i < n - 1; i++) {
            let p0 = pts[i - 1 < 0 ? 0 : i - 1];
            let p1 = pts[i];
            let p2 = pts[i + 1];
            let p3 = pts[i + 2 > n - 1 ? n - 1 : i + 2];
            for (let k = 0; k < per; k++) {
                samples.push(catmull(p0, p1, p2, p3, <f64>k / <f64>per));
            }
        }
        samples.push(pts[n - 1]);
        // never dip through the floor: the spline overshoots where a cable lands,
        // and the floor would slice it (reads as the cable "ending")
        if (hasMinY) {
            let lo = minY + r * 1.15;
            for (let i = 0; i < samples.length; i++) {
                let p = samples[i];
                if (<f64>p.y < lo) {
                    samples[i] = Vector.xyz(p.x, <f32>lo, p.z);
                }
            }
        }
        let m = samples.length;
        // cumulative length
        let acc = new Array<f64>(m);
        acc[0] = 0;
        for (let i = 1; i < m; i++) {
            acc[i] = acc[i - 1] + <f64>Vector.length(samples[i] - samples[i - 1]);
        }
        // parallel transport frames
        let tans = new Array<Vector>(m);
        let nors = new Array<Vector>(m);
        let bins = new Array<Vector>(m);
        for (let i = 0; i < m; i++) {
            let a = samples[i - 1 < 0 ? 0 : i - 1];
            let c = samples[i + 1 > m - 1 ? m - 1 : i + 1];
            tans[i] = Vector.normalized(c - a);
        }
        let up = Math.abs(<f64>tans[0].y) > 0.9 ? Vector.xyz(1, 0, 0) : Vector.xyz(0, 1, 0);
        nors[0] = Vector.normalized(Vector.cross3(tans[0], up));
        bins[0] = Vector.cross3(tans[0], nors[0]);
        for (let i = 1; i < m; i++) {
            let nn = nors[i - 1] - tans[i] * Vector.dot(nors[i - 1], tans[i]);
            if (<f64>Vector.length(nn) < 1e-5) {
                nn = nors[i - 1];
            }
            nors[i] = Vector.normalized(nn);
            bins[i] = Vector.cross3(tans[i], nors[i]);
        }
        this.samples = samples;
        this.nors = nors;
        this.bins = bins;
        this.acc = acc;
        this.total = acc[m - 1];
        this.m = m;
        this.r = r;
        this.sides = sides;
        this.wraps = wraps;
        this.count = (m - 1) * sides * 6 + wraps * (m - 1) * this.wsides * 6;
        this.rows = (m - 1) * (1 + wraps);
        this.v = new Writer(this.count);
        let maxS = (sides > this.wsides ? sides : this.wsides) + 1;
        this.ra = new Float64Array(maxS * 8);
        this.rb = new Float64Array(maxS * 8);
        this.tubeC = angTable(sides, true);
        this.tubeS = angTable(sides, false);
        this.wireC = angTable(this.wsides, true);
        this.wireS = angTable(this.wsides, false);
    }

    // ring of sample i (k = 0..ksides): pos (f64), normal, uv
    fillRing(buf: Float64Array, i: i32, rad: f64, off: Vector, ksides: i32, tag: f64, C: Array<f32>, S: Array<f32>): void {
        let nor = this.nors[i];
        let bin = this.bins[i];
        let c = this.samples[i] + off;
        let u = this.acc[i] / this.total;
        for (let k = 0; k <= ksides; k++) {
            let d = nor * C[k] + bin * S[k];
            let o = k * 8;
            buf[o] = <f64>c.x + <f64>d.x * rad;
            buf[o + 1] = <f64>c.y + <f64>d.y * rad;
            buf[o + 2] = <f64>c.z + <f64>d.z * rad;
            buf[o + 3] = d.x;
            buf[o + 4] = d.y;
            buf[o + 5] = d.z;
            buf[o + 6] = u;
            buf[o + 7] = tag + <f64>k / <f64>ksides;
        }
    }

    put(buf: Float64Array, k: i32): void {
        let o = k * 8;
        this.v.v(buf[o], buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4], buf[o + 5], buf[o + 6], buf[o + 7]);
    }

    emit(ks: i32): void {
        let ra = this.ra, rb = this.rb;
        for (let k = 0; k < ks; k++) {
            this.put(ra, k); this.put(rb, k); this.put(ra, k + 1);
            this.put(rb, k); this.put(rb, k + 1); this.put(ra, k + 1);
        }
    }

    // helical wires: offset rotates with distance along the cable
    woff(i: i32, w: i32): Vector {
        let r = this.r;
        let ang = this.acc[i] / (r * 9) + <f64>w * PI * 2 / <f64>(this.wraps > 1 ? this.wraps : 1);
        return (this.nors[i] * <f32>Math.cos(ang) + this.bins[i] * <f32>Math.sin(ang)) * <f32>(r * 1.12);
    }

    // emit up to n more rows; true once the mesh is complete
    step(n: i32): bool {
        let rowsT = this.m - 1;
        let zero = Vector.xyz(0, 0, 0);
        let end = this.row + n < this.rows ? this.row + n : this.rows;
        for (let row = this.row; row < end; row++) {
            if (row < rowsT) {
                let i = row;
                this.fillRing(this.ra, i, this.r, zero, this.sides, 0, this.tubeC, this.tubeS);
                this.fillRing(this.rb, i + 1, this.r, zero, this.sides, 0, this.tubeC, this.tubeS);
                this.emit(this.sides);
            } else {
                let w = (row - rowsT) / rowsT;
                let i = (row - rowsT) % rowsT;
                let wr = this.r * 0.16;
                this.fillRing(this.ra, i, wr, this.woff(i, w), this.wsides, 2, this.wireC, this.wireS);
                this.fillRing(this.rb, i + 1, wr, this.woff(i + 1, w), this.wsides, 2, this.wireC, this.wireS);
                this.emit(this.wsides);
            }
        }
        this.row = end;
        return end >= this.rows;
    }

    mesh(): Mesh {
        let mesh = this.v.mesh(this.count);
        mesh.len = this.total;
        return mesh;
    }
}

function angTable(ks: i32, cosine: bool): Array<f32> {
    let t = new Array<f32>(ks + 1);
    for (let k = 0; k <= ks; k++) {
        let ang = <f64>k / <f64>ks * PI * 2;
        t[k] = <f32>(cosine ? Math.cos(ang) : Math.sin(ang));
    }
    return t;
}

// ---------------------------------------------------------------- Bit core kit
// Flat-faceted polyhedra in the spirit of Bit (Tron, 1982): every triangle
// carries its face normal; uv carries barycentric corners for wire edges.

const PHI: f64 = (1 + Math.sqrt(5)) / 2;

// face indices are 0-based here (Luau's were 1-based)
const ICO_F: StaticArray<i32> = [
    0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
    1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
    3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
    4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
];

function icoVerts(): Array<Vector> {
    let p = <f32>PHI;
    let vs: Array<Vector> = [
        Vector.xyz(-1, p, 0), Vector.xyz(1, p, 0), Vector.xyz(-1, -p, 0), Vector.xyz(1, -p, 0),
        Vector.xyz(0, -1, p), Vector.xyz(0, 1, p), Vector.xyz(0, -1, -p), Vector.xyz(0, 1, -p),
        Vector.xyz(p, 0, -1), Vector.xyz(p, 0, 1), Vector.xyz(-p, 0, -1), Vector.xyz(-p, 0, 1),
    ];
    for (let i = 0; i < vs.length; i++) {
        vs[i] = Vector.normalized(vs[i]);
    }
    return vs;
}

// Emit triangles (flat array, 3 Vectors per triangle) with flat normals and
// barycentric uv: corners get (1,0), (0,1), (0,0) so the shader knows each
// pixel's distance to the facet edges.
function emitFacets(tris: Array<Vector>): Mesh {
    let n = tris.length / 3;
    let v = new Writer(n * 3);
    for (let t = 0; t < n; t++) {
        let a = tris[t * 3], bb = tris[t * 3 + 1], c = tris[t * 3 + 2];
        let nn = Vector.normalized(Vector.cross3(bb - a, c - a));
        let ctr = (a + bb + c) * <f32>(1.0 / 3.0);
        if (<f64>Vector.dot(nn, ctr) < 0) {
            nn = -nn;
            let tmp = bb;
            bb = c;
            c = tmp;
        }
        v.v(a.x, a.y, a.z, nn.x, nn.y, nn.z, 1, 0);
        v.v(bb.x, bb.y, bb.z, nn.x, nn.y, nn.z, 0, 1);
        v.v(c.x, c.y, c.z, nn.x, nn.y, nn.z, 0, 0);
    }
    return v.mesh(n * 3);
}

class HexGrid {
    v: Writer;
    R: f64;
    N: i32;
    constructor(v: Writer, R: f64, N: i32) {
        this.v = v;
        this.R = R;
        this.N = N;
    }
    // grid point i along a->b, j along a->c
    P(a: Vector, bb: Vector, c: Vector, i: i32, j: i32): Vector {
        let N = <f64>this.N;
        let k = this.N - i - j;
        return Vector.normalized(a * <f32>(<f64>k / N) + bb * <f32>(<f64>i / N) + c * <f32>(<f64>j / N)) * <f32>this.R;
    }
    tri(p1: Vector, p2: Vector, p3: Vector): void {
        let n1 = Vector.normalized(p1), n2 = Vector.normalized(p2), n3 = Vector.normalized(p3);
        let v = this.v;
        v.v(p1.x, p1.y, p1.z, n1.x, n1.y, n1.z, 1, 0);
        v.v(p2.x, p2.y, p2.z, n2.x, n2.y, n2.z, 0, 1);
        v.v(p3.x, p3.y, p3.z, n3.x, n3.y, n3.z, 0, 0);
    }
}

// Geodesic sphere for a hex (Goldberg) lattice: each icosahedron face is
// split into N^2 triangles, projected to radius R. The shader draws the dual
// cell boundaries: hexagons everywhere, plus 12 pentagons at the corners.
export function hexSphere(R: f64, N: i32): Mesh {
    let b = new HexSphereBuilder(R, N);
    b.step(ICO_F.length / 3);
    return b.mesh();
}

// Resumable hexSphere: step(k) emits the next k icosahedron faces (same
// vertex order as one call), so a caller can spread the work over frames.
export class HexSphereBuilder {
    vs: Array<Vector>;
    nf: i32;
    N: i32;
    v: Writer;
    g: HexGrid;
    f: i32 = 0;
    constructor(R: f64, N: i32) {
        this.vs = icoVerts();
        this.nf = ICO_F.length / 3;
        this.N = N;
        this.v = new Writer(this.nf * N * N * 3);
        this.g = new HexGrid(this.v, R, N);
    }
    // returns true once every face is emitted
    step(faces: i32): bool {
        let vs = this.vs;
        let g = this.g;
        let N = this.N;
        let f1 = this.f + faces < this.nf ? this.f + faces : this.nf;
        for (let f = this.f; f < f1; f++) {
            let a = vs[ICO_F[f * 3]], bb = vs[ICO_F[f * 3 + 1]], c = vs[ICO_F[f * 3 + 2]];
            for (let i = 0; i < N; i++) {
                for (let j = 0; j < N - i; j++) {
                    g.tri(g.P(a, bb, c, i, j), g.P(a, bb, c, i + 1, j), g.P(a, bb, c, i, j + 1));
                    if (i + j < N - 1) {
                        g.tri(g.P(a, bb, c, i + 1, j), g.P(a, bb, c, i + 1, j + 1), g.P(a, bb, c, i, j + 1));
                    }
                }
            }
        }
        this.f = f1;
        return f1 >= this.nf;
    }
    mesh(): Mesh {
        return this.v.mesh(this.nf * this.N * this.N * 3);
    }
}

// Icosahedron (calm Bit), radius r.
export function icosa(r: f64): Mesh {
    let vs = icoVerts();
    let tris = new Array<Vector>();
    let rf = <f32>r;
    for (let f = 0; f < ICO_F.length / 3; f++) {
        tris.push(vs[ICO_F[f * 3]] * rf);
        tris.push(vs[ICO_F[f * 3 + 1]] * rf);
        tris.push(vs[ICO_F[f * 3 + 2]] * rf);
    }
    return emitFacets(tris);
}

function spikeTris(tris: Array<Vector>, a: Vector, b: Vector, c: Vector, r: f64, spike: f64): void {
    let tip = Vector.normalized(a + b + c) * <f32>(r * spike);
    tris.push(a); tris.push(b); tris.push(tip);
    tris.push(b); tris.push(c); tris.push(tip);
    tris.push(c); tris.push(a); tris.push(tip);
}

// Stellated icosahedron ("YES" spikes): each face raised to a point at
// r * spike along its normal.
export function stellated(r: f64, spike: f64): Mesh {
    let vs = icoVerts();
    let tris = new Array<Vector>();
    let rf = <f32>r;
    for (let f = 0; f < ICO_F.length / 3; f++) {
        spikeTris(tris, vs[ICO_F[f * 3]] * rf, vs[ICO_F[f * 3 + 1]] * rf, vs[ICO_F[f * 3 + 2]] * rf, r, spike);
    }
    return emitFacets(tris);
}

const OCTA_F: StaticArray<i32> = [0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5];

// Octahedron, optionally stellated ("NO" spikes); spike <= 0 = Luau's nil.
export function octa(r: f64, spike: f64 = 0): Mesh {
    let P: Array<Vector> = [
        Vector.xyz(1, 0, 0), Vector.xyz(-1, 0, 0), Vector.xyz(0, 1, 0),
        Vector.xyz(0, -1, 0), Vector.xyz(0, 0, 1), Vector.xyz(0, 0, -1),
    ];
    let tris = new Array<Vector>();
    let rf = <f32>r;
    for (let f = 0; f < 8; f++) {
        let a = P[OCTA_F[f * 3]] * rf, b = P[OCTA_F[f * 3 + 1]] * rf, c = P[OCTA_F[f * 3 + 2]] * rf;
        if (spike > 0) {
            spikeTris(tris, a, b, c, r, spike);
        } else {
            tris.push(a); tris.push(b); tris.push(c);
        }
    }
    return emitFacets(tris);
}

// Luau's `%`: floored modulo
function fmod(a: f64, b: f64): f64 {
    return a - Math.floor(a / b) * b;
}

let UV_U: f64 = 0;
let UV_V: f64 = 0;

function uvOf(p: Vector): void {
    let q = Vector.normalized(p);
    let qy = <f64>q.y;
    UV_U = fmod(Math.atan2(<f64>q.x, <f64>q.z) / (2 * PI), 1);
    UV_V = Math.acos(Math.max(-1, Math.min(1, qy))) / PI;
}

function fixU(x: f64, cu: f64): f64 {
    if (x - cu > 0.5) {
        return x - 1;
    } else if (cu - x > 0.5) {
        return x + 1;
    }
    return x;
}

// Geodesic sphere (icosahedron subdivided `level` times), flat-faceted, with
// equirectangular uv so a Rive artboard can wrap it.
export function geodesic(r: f64, level: i32): Mesh {
    let vs = icoVerts();
    let tris = new Array<Vector>();
    for (let f = 0; f < ICO_F.length / 3; f++) {
        tris.push(vs[ICO_F[f * 3]]);
        tris.push(vs[ICO_F[f * 3 + 1]]);
        tris.push(vs[ICO_F[f * 3 + 2]]);
    }
    for (let l = 0; l < level; l++) {
        let nt = new Array<Vector>();
        for (let t = 0; t < tris.length / 3; t++) {
            let a = tris[t * 3], b = tris[t * 3 + 1], c = tris[t * 3 + 2];
            let ab = Vector.normalized(a + b);
            let bc = Vector.normalized(b + c);
            let ca = Vector.normalized(c + a);
            nt.push(a); nt.push(ab); nt.push(ca);
            nt.push(ab); nt.push(b); nt.push(bc);
            nt.push(ca); nt.push(bc); nt.push(c);
            nt.push(ab); nt.push(bc); nt.push(ca);
        }
        tris = nt;
    }
    let n = tris.length / 3;
    let v = new Writer(n * 3);
    let rf = <f32>r;
    for (let t = 0; t < n; t++) {
        let a = tris[t * 3] * rf, bb = tris[t * 3 + 1] * rf, c = tris[t * 3 + 2] * rf;
        let nn = Vector.normalized(Vector.cross3(bb - a, c - a));
        let ctr = Vector.normalized(tris[t * 3] + tris[t * 3 + 1] + tris[t * 3 + 2]);
        if (<f64>Vector.dot(nn, ctr) < 0) {
            nn = -nn;
            let tmp = bb;
            bb = c;
            c = tmp;
        }
        uvOf(a);
        let ua = UV_U, va = UV_V;
        uvOf(bb);
        let ub = UV_U, vb = UV_V;
        uvOf(c);
        let uc = UV_U, vc = UV_V;
        let cu = fmod(Math.atan2(<f64>ctr.x, <f64>ctr.z) / (2 * PI), 1);
        // at the poles u is undefined; use the facet centre's
        if (Math.abs(<f64>Vector.normalized(a).y) > 0.999) ua = cu;
        if (Math.abs(<f64>Vector.normalized(bb).y) > 0.999) ub = cu;
        if (Math.abs(<f64>Vector.normalized(c).y) > 0.999) uc = cu;
        v.v(a.x, a.y, a.z, nn.x, nn.y, nn.z, fixU(ua, cu), va);
        v.v(bb.x, bb.y, bb.z, nn.x, nn.y, nn.z, fixU(ub, cu), vb);
        v.v(c.x, c.y, c.z, nn.x, nn.y, nn.z, fixU(uc, cu), vc);
    }
    return v.mesh(n * 3);
}
