// RiveBox post chain: 13-tap downsample / tent upsample bloom (HDR),
// anamorphic streak, chromatic aberration, ACES, vignette, grain.
struct P { a: vec4<f32>, b: vec4<f32>, c: vec4<f32>, d: vec4<f32> };
@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
@group(0) @binding(3) var aux: texture_2d<f32>;
@group(0) @binding(4) var aux2: texture_2d<f32>;
@group(0) @binding(5) var aux3: texture_2d<f32>;

struct V { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };

@vertex fn vs_full(@builtin(vertex_index) i: u32) -> V {
    var o: V;
    let x = f32((i << 1u) & 2u);
    let y = f32(i & 2u);
    o.pos = vec4(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    o.uv = vec2(x, y);
    return o;
}

// p.a.xy = source texel, p.a.z = 1 on the first (thresholded) pass, p.a.w = knee
@fragment fn fs_down(i: V) -> @location(0) vec4<f32> {
    let t = p.a.xy;
    let uv = i.uv;
    let a = textureSample(src, smp, uv + t * vec2(-2.0, -2.0)).rgb;
    let b = textureSample(src, smp, uv + t * vec2(0.0, -2.0)).rgb;
    let c = textureSample(src, smp, uv + t * vec2(2.0, -2.0)).rgb;
    let d = textureSample(src, smp, uv + t * vec2(-2.0, 0.0)).rgb;
    let e = textureSample(src, smp, uv).rgb;
    // (inputs are sanitised in surf.wgsl finish())
    let f = textureSample(src, smp, uv + t * vec2(2.0, 0.0)).rgb;
    let g = textureSample(src, smp, uv + t * vec2(-2.0, 2.0)).rgb;
    let h = textureSample(src, smp, uv + t * vec2(0.0, 2.0)).rgb;
    let k = textureSample(src, smp, uv + t * vec2(2.0, 2.0)).rgb;
    let l = textureSample(src, smp, uv + t * vec2(-1.0, -1.0)).rgb;
    let m = textureSample(src, smp, uv + t * vec2(1.0, -1.0)).rgb;
    let n = textureSample(src, smp, uv + t * vec2(-1.0, 1.0)).rgb;
    let q = textureSample(src, smp, uv + t * vec2(1.0, 1.0)).rgb;
    var c0 = e * 0.125 + (a + c + g + k) * 0.03125 + (b + d + f + h) * 0.0625 + (l + m + n + q) * 0.125;
    if (p.a.z > 0.5) {
        // soft knee threshold + firefly clamp
        let br = max(c0.r, max(c0.g, c0.b));
        let knee = p.a.w;
        let soft = clamp(br - knee * 0.5, 0.0, knee);
        let w = max(soft * soft / (2.0 * knee + 1e-4), br - knee) / max(br, 1e-4);
        c0 = min(c0 * w, vec3(40.0));
    }
    return vec4(c0, 1.0);
}

@fragment fn fs_up(i: V) -> @location(0) vec4<f32> {
    let t = p.a.xy * p.a.z;
    let uv = i.uv;
    var c = textureSample(src, smp, uv).rgb * 4.0;
    c += (textureSample(src, smp, uv + vec2(-t.x, 0.0)).rgb + textureSample(src, smp, uv + vec2(t.x, 0.0)).rgb
        + textureSample(src, smp, uv + vec2(0.0, -t.y)).rgb + textureSample(src, smp, uv + vec2(0.0, t.y)).rgb) * 2.0;
    c += textureSample(src, smp, uv + vec2(-t.x, -t.y)).rgb + textureSample(src, smp, uv + vec2(t.x, -t.y)).rgb
       + textureSample(src, smp, uv + vec2(-t.x, t.y)).rgb + textureSample(src, smp, uv + vec2(t.x, t.y)).rgb;
    return vec4(c / 16.0 * p.a.w, 1.0);
}

// ---------------------------------------------------------------- depth of field
// Layered gather DoF (far field + near field, half res), composited at full
// res with a CoC computed from the full-res anti-aliased depth so in-focus
// edges stay razor sharp.
//   p.a.z focus distance  p.a.w aperture  p.b.x near multiplier  p.b.y in-focus band
@group(0) @binding(6) var aux4: texture_2d<f32>;
@group(0) @binding(7) var aux5: texture_2d<f32>;

// thin-lens circle of confusion: c = K * (1 - F/d), K = blur at infinity
// (aperture x focal length / (F - focal), folded into one number). Physically
// bounded behind the focus plane, unbounded in front. A small tolerance
// (permissible CoC) keeps the subject plane crisp; no hard in-focus band.
fn thinLens(d: f32, F: f32, K: f32, tolF: f32, tolN: f32) -> f32 {
    let c = K * (1.0 - F / max(d, 0.05));
    let cc = select(min(c + tolN, 0.0), max(c - tolF, 0.0), c > 0.0);
    return clamp(cc, -1.0, 1.0);
}
fn cocAt(d: f32) -> f32 {
    return thinLens(d, p.a.z, p.a.w, p.b.y, p.b.x);
}

// depth target -> distance (empty pixels = far away)
fn distAt(uv: vec2<f32>) -> f32 {
    let d = textureSampleLevel(aux, smp, uv, 0.0);
    return mix(200.0, d.r / max(d.a, 1e-4), smoothstep(0.0, 0.05, d.a));
}

// ===== DoF v5: two-layer scatter-as-gather =================================
// Forward renderer with MRT: every pass writes HDR colour + linear camera
// distance. The scene is split into two layers so semi-transparent and
// emissive things get THEIR OWN depth instead of inheriting the depth of
// whatever is behind them:
//   layer A (opaque): cables, orbs, core heart, cases, floor/reflections
//       colour hdrRaw, distance dist (r = d, a = coverage)
//   layer B (transparent / emissive): Rive panels incl. their glows, neon
//       frames, energy tubes, orb shells, beams, Bit edges, glass, sparks
//       colour hdrB (premultiplied rgba), distance distB (r = sum d*w, a = sum w)
// Each layer is blurred with its own CoC (half res, deterministic 121-tap
// gather after Jimenez 2014), then composited back to front at full res:
//   A_fg  over  B  over  A_bg
// where A_fg = opaque things nearer than layer B (blurred foreground cables
// spill over in-focus panels) and in-focus pixels use the full-res sharp
// layers, so focused UI keeps crisp edges.

struct DOut2 { @location(0) a: vec4<f32>, @location(1) b: vec4<f32> };

fn decA(d: vec4<f32>) -> f32 {
    return mix(200.0, d.r / max(d.a, 1e-4), smoothstep(0.0, 0.05, d.a));
}

// A prefilter: full -> half, firefly-weighted colour + signed CoC
@fragment fn fs_dofdown(i: V) -> @location(0) vec4<f32> {
    let t = p.c.xy * p.c.z;
    var acc = vec3(0.0);
    var ws = 0.0;
    var nearC = 0.0;
    var farC = 0.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2(select(-t.x, t.x, (k & 1) == 1), select(-t.y, t.y, k >= 2));
        let uv = i.uv + o;
        let c = textureSampleLevel(src, smp, uv, 0.0).rgb;
        let coc = cocAt(decA(textureSampleLevel(aux, smp, uv, 0.0)));
        let wgt = (0.02 + abs(coc)) / (1.0 + max(c.r, max(c.g, c.b)));
        acc += c * wgt;
        ws += wgt;
        nearC = min(nearC, coc);
        farC = farC + max(coc, 0.0) * 0.25;
    }
    let coc = select(farC, nearC, nearC < -0.02);
    return vec4(acc / ws, coc);
}

// B prefilter: premultiplied rgba average + presence-weighted signed CoC
//   out a = rgba, out b = (coc, presence)
@fragment fn fs_dofdownB(i: V) -> DOut2 {
    let t = p.c.xy * p.c.z;
    var acc = vec4(0.0);
    var cs = 0.0;
    var ws = 0.0;
    var pres = 0.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2(select(-t.x, t.x, (k & 1) == 1), select(-t.y, t.y, k >= 2));
        let uv = i.uv + o;
        acc += textureSampleLevel(src, smp, uv, 0.0);
        let d = textureSampleLevel(aux, smp, uv, 0.0);
        if (d.a > 1e-3) {
            let cw = min(d.a, 1.0);
            cs += cocAt(d.r / d.a) * cw;
            ws += cw;
        }
        pres += min(d.a, 1.0);
    }
    var o: DOut2;
    o.a = acc * 0.25;
    o.b = vec4(select(0.0, cs / max(ws, 1e-5), ws > 0.0), pres * 0.25, 0.0, 1.0);
    return o;
}

// separable tile max: r = max near CoC of A, g = max |CoC| of B
@fragment fn fs_doftile1(i: V) -> @location(0) vec4<f32> {
    let n = i32(ceil(p.b.z)) + 1;
    var m = vec2(0.0);
    for (var k = -n; k <= n; k++) {
        let uv = i.uv + vec2(p.a.x * f32(k), 0.0);
        let a = textureSampleLevel(src, smp, uv, 0.0).a;
        let b = textureSampleLevel(aux, smp, uv, 0.0);
        m = max(m, vec2(max(-a, 0.0), select(0.0, abs(b.r), b.g > 0.02)));
    }
    return vec4(m, 0.0, 1.0);
}
@fragment fn fs_doftile2(i: V) -> @location(0) vec4<f32> {
    let n = i32(ceil(p.b.z)) + 1;
    var m = vec2(0.0);
    for (var k = -n; k <= n; k++) {
        m = max(m, textureSampleLevel(src, smp, i.uv + vec2(0.0, p.a.y * f32(k)), 0.0).rg);
    }
    return vec4(m, 0.0, 1.0);
}

// A gather. src = A half (rgb, coc), aux = tiles, aux2 = B half coc.
// Foreground is measured against the NEARER of the two layers at this pixel,
// so opaque things in front of a panel spill over it.
//   out a = background (rgb, own coc), out b = foreground premultiplied
@fragment fn fs_dofblur(i: V) -> DOut2 {
    let t = p.a.xy;
    let maxR = p.b.z;
    let c0s = textureSampleLevel(src, smp, i.uv, 0.0);
    let c0 = c0s.a;
    let bk = textureSampleLevel(aux2, smp, i.uv, 0.0);
    let refC = select(c0, min(c0, bk.r), bk.g > 0.3);
    let r0 = abs(c0) * maxR;
    let nearT = textureSampleLevel(aux, smp, i.uv, 0.0).r * maxR;
    let R = max(r0, nearT);
    var o: DOut2;
    if (R < 0.35) {
        o.a = vec4(c0s.rgb, c0);
        o.b = vec4(0.0);
        return o;
    }
    let RINGS = 5;
    let sp = R / f32(RINGS);
    let margin = max(sp, 0.5);
    var bg = c0s.rgb;
    var bgW = 1.0;
    var fg = vec3(0.0);
    var fgW = 0.0;
    var fgA = 0.0;
    for (var r = 1; r <= RINGS; r++) {
        let n = r * 8;
        let dist = f32(r) * sp;
        let rot = f32(r) * 0.5 / f32(n);
        for (var k = 0; k < n; k++) {
            let ang = (f32(k) + rot) / f32(n) * 6.2831853;
            let s = textureSampleLevel(src, smp, i.uv + vec2(cos(ang), sin(ang)) * dist * t, 0.0);
            let rs = abs(s.a) * maxR;
            if (s.a < 0.0 && s.a < refC - 0.03) {
                let wv = clamp((rs - dist) / margin + 0.5, 0.0, 1.0);
                fg += s.rgb * wv;
                fgW += wv;
                let rr = max(rs, sp * 0.5);
                fgA += wv * (sp * sp * 0.25) / (rr * rr);
            } else {
                let wv = clamp((min(rs, r0) - dist) / margin + 0.5, 0.0, 1.0);
                bg += s.rgb * wv;
                bgW += wv;
            }
        }
    }
    let a = clamp(fgA, 0.0, 1.0);
    let fgC = select(vec3(0.0), fg / max(fgW, 1e-4), fgW > 1e-4);
    o.a = vec4(bg / bgW, c0);
    o.b = vec4(fgC * a, a);
    return o;
}

// B gather on premultiplied rgba with B's own CoC. Empty pixels are treated
// as "behind everything" and inherit the centre radius, so a blurred element
// fades out smoothly across its own silhouette.
//   out a = premultiplied rgba, out b.r = foreground coverage
@fragment fn fs_dofblurB(i: V) -> DOut2 {
    let t = p.a.xy;
    let maxR = p.b.z;
    let c0 = textureSampleLevel(src, smp, i.uv, 0.0);
    let k0 = textureSampleLevel(aux2, smp, i.uv, 0.0);
    let has0 = k0.g > 0.02;
    let cc = select(1000.0, k0.r, has0);
    let r0 = select(0.0, abs(k0.r) * maxR, has0);
    let tB = textureSampleLevel(aux, smp, i.uv, 0.0).g * maxR;
    let R = max(r0, tB);
    var o: DOut2;
    if (R < 0.35) {
        o.a = c0;
        o.b = vec4(0.0, 0.0, 0.0, 1.0);
        return o;
    }
    let RINGS = 5;
    let sp = R / f32(RINGS);
    let margin = max(sp, 0.5);
    var bg = c0;
    var bgW = 1.0;
    var fg = vec4(0.0);
    var fgW = 0.0;
    var fgA = 0.0;
    for (var r = 1; r <= RINGS; r++) {
        let n = r * 8;
        let dist = f32(r) * sp;
        let rot = f32(r) * 0.5 / f32(n);
        for (var k = 0; k < n; k++) {
            let ang = (f32(k) + rot) / f32(n) * 6.2831853;
            let suv = i.uv + vec2(cos(ang), sin(ang)) * dist * t;
            let s = textureSampleLevel(src, smp, suv, 0.0);
            let kk = textureSampleLevel(aux2, smp, suv, 0.0);
            let has = kk.g > 0.02;
            let cs = select(1000.0, kk.r, has);
            let rs = select(r0, abs(kk.r) * maxR, has);
            if (has && cs < cc - 0.03) {
                let wv = clamp((rs - dist) / margin + 0.5, 0.0, 1.0);
                fg += s * wv;
                fgW += wv;
                let rr = max(rs, sp * 0.5);
                fgA += wv * (sp * sp * 0.25) / (rr * rr);
            } else {
                let wv = clamp((min(rs, r0) - dist) / margin + 0.5, 0.0, 1.0);
                bg += s * wv;
                bgW += wv;
            }
        }
    }
    let bgC = bg / bgW;
    let a = clamp(fgA, 0.0, 1.0);
    let fgC = select(vec4(0.0), fg / max(fgW, 1e-4), fgW > 1e-4);
    // premultiplied "over": fg (coverage a) over the layer's own background
    o.a = fgC * a + bgC * (1.0 - clamp(fgC.a * a, 0.0, 1.0));
    o.b = vec4(a, 0.0, 0.0, 1.0);
    return o;
}

// half-res 4-tap bilinear tent: removes residual ring structure
@fragment fn fs_doftent(i: V) -> @location(0) vec4<f32> {
    let d = p.a.xy * 0.5;
    var acc = textureSampleLevel(src, smp, i.uv + vec2(-d.x, -d.y), 0.0);
    acc += textureSampleLevel(src, smp, i.uv + vec2(d.x, -d.y), 0.0);
    acc += textureSampleLevel(src, smp, i.uv + vec2(-d.x, d.y), 0.0);
    acc += textureSampleLevel(src, smp, i.uv + vec2(d.x, d.y), 0.0);
    return acc * 0.25;
}

// depth-aware upsample of A's background layer (aux4, alpha = half-res CoC)
fn upA(uv: vec2<f32>, cF: f32) -> vec3<f32> {
    let ts = p.a.xy;
    let fp = uv / ts - 0.5;
    let b = floor(fp);
    let f = fp - b;
    var acc = vec3(0.0);
    var ws = 0.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2(f32(k & 1), f32(k >> 1u));
        let suv = (b + o + 0.5) * ts;
        let bw = mix(1.0 - f.x, f.x, o.x) * mix(1.0 - f.y, f.y, o.y);
        let s = textureSampleLevel(aux4, smp, suv, 0.0);
        let wv = bw / (0.15 + abs(s.a - cF) * p.b.z) + 1e-5;
        acc += s.rgb * wv;
        ws += wv;
    }
    return acc / ws;
}

// pack both layers' distances into one full-res texture for the composite
//   r = A distance, g = B distance, b = B presence, a = B fg coverage (half)
@fragment fn fs_dofdist(i: V) -> @location(0) vec4<f32> {
    let dA = textureSampleLevel(src, smp, i.uv, 0.0);
    let dB = textureSampleLevel(aux, smp, i.uv, 0.0);
    let bF = textureSampleLevel(aux2, smp, i.uv, 0.0).r;
    return vec4(decA(dA), dB.r / max(dB.a, 1e-4), dB.a, bF);
}

// full-res composite (HDR out):  A_fg over B over A_bg
//   src = A sharp, aux = B sharp, aux2 = packed distances (fs_dofdist),
//   aux4 = A bg (half), aux5 = A fg (half),
//   aux3 = B dof (half)
// p.b.z <= 0: DoF off, plain B over A
@fragment fn fs_dofcomp(i: V) -> DOut2 {
    let uv = i.uv;
    let As = textureSampleLevel(src, smp, uv, 0.0).rgb;
    let Bs = textureSampleLevel(aux, smp, uv, 0.0);
    let dd = textureSampleLevel(aux2, smp, uv, 0.0);
    let distA = dd.r;
    let distB = dd.g;
    let presB = dd.b;
    let A1s = textureSampleLevel(aux4, smp, uv, 0.0);
    let A2 = textureSampleLevel(aux5, smp, uv, 0.0);
    let Bd = textureSampleLevel(aux3, smp, uv, 0.0);
    let bF = dd.a;
    // front-most distance (B where it has presence) for motion blur
    var front = distA;
    if (presB > 0.3) {
        front = min(front, distB);
    }
    var o: DOut2;
    o.b = vec4(front, 0.0, 0.0, 1.0);
    if (p.b.z <= 0.0) {
        let _u = A1s.r + A2.r + Bd.r + bF + distB;
        o.a = vec4(Bs.rgb + As * (1.0 - clamp(Bs.a, 0.0, 1.0)) + vec3(_u * 0.0), 1.0);
        return o;
    }
    let maxR = p.b.z;
    let cA = cocAt(distA);
    let kA = smoothstep(0.3, 1.0, abs(cA) * maxR);
    let Abg = mix(As, upA(uv, cA), kA);
    var kB = 1.0;
    if (presB > 1e-3) {
        kB = smoothstep(0.3, 1.0, abs(cocAt(distB)) * maxR);
    }
    kB = max(kB, clamp(bF * 3.0, 0.0, 1.0));
    let Bf = mix(Bs, Bd, kB);
    let under = Bf.rgb + Abg * (1.0 - clamp(Bf.a, 0.0, 1.0));
    o.a = vec4(A2.rgb + under * (1.0 - clamp(A2.a, 0.0, 1.0)), 1.0);
    return o;
}

const TOL_N: f32 = 0.22;
fn aces(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3(0.0), vec3(1.0));
}
fn hash2(q: vec2<f32>) -> f32 {
    return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
}

// p.a: x bloom, y exposure, z chroma, w time   p.b: x streak, y grain, z vignette, w flash
@fragment fn fs_comp(i: V) -> @location(0) vec4<f32> {
    let uv = i.uv;
    let cdir = (uv - 0.5);
    let r2 = dot(cdir, cdir);
    let ca = cdir * p.a.z * (0.3 + r2 * 2.5);
    let hr = textureSample(src, smp, uv + ca).r;
    let hg = textureSample(src, smp, uv).g;
    let hb = textureSample(src, smp, uv - ca).b;
    let bl = textureSample(aux, smp, uv).rgb;
    // anamorphic streak: wide horizontal taps across a low bloom level
    var st = vec3(0.0);
    for (var k = -6; k <= 6; k++) {
        let fk = f32(k);
        let w = exp(-abs(fk) * 0.33);
        st += textureSample(aux2, smp, uv + vec2(fk * 0.022, 0.0)).rgb * w;
    }
    st = st / 6.0 * vec3(0.55, 0.75, 1.0);
    // depth of field + motion blur happen upstream (fs_dofcomp, motion.wgsl)
    let sharp = vec3(hr, hg, hb);
    var c = sharp + bl * p.a.x + st * p.b.x + vec3(p.b.w);
    c = aces(c * p.a.y);
    // vignette, then grain in display space
    let vig = 1.0 - p.b.z * smoothstep(0.15, 0.85, r2 * 1.6);
    c = pow(c, vec3(1.0 / 2.2)) * vig;
    let g = hash2(uv * 1024.0 + fract(p.a.w * 7.3) * 100.0) - 0.5;
    c = c + g * p.b.y;
    return vec4(clamp(c, vec3(0.0), vec3(1.0)), 1.0);
}
