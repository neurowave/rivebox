// RiveBox holographic material. Every 3D object in the dashboard goes through
// this one shader. Output is linear HDR (rgba16float, 4x MSAA): anything above
// ~1.0 feeds the bloom chain in post.wgsl.
//
// mode.x: 0 holo panel (live Rive artboard)   1 energy tube (bezier in VS)
//         2 holo shell (iridescent lattice)   3 floor (AA grid, pools, ripples)
//         4 neon frame                        5 light volume / beam
//         6 plasma core                       7 gyroscope ring
//         9 far hex wall
struct U {
    mvp: mat4x4<f32>,
    model: mat4x4<f32>,
    cam: vec4<f32>,      // xyz camera position, w time
    tint: vec4<f32>,     // rgb colour, a opacity
    params: vec4<f32>,   // x rim, y emissive, z scanlines, w u-scroll
    uvr: vec4<f32>,      // atlas rect: xy offset, zw scale
    mode: vec4<f32>,     // x mode, y pulse/energy, z aspect | speed, w dim
    fx: vec4<f32>,       // x reveal 0..1, y chroma, z glitch, w reflection strength
    c0: vec4<f32>,       // tube: bezier p0 + r0   floor: core pos + strength
    c1: vec4<f32>,       // tube: p1 + r1          floor: ripple radius, ripple strength
    c2: vec4<f32>,       // tube: p2 + phase       floor: focus pool pos + strength
    c3: vec4<f32>,       // tube: p3 + twist       floor: second colour
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var tex: texture_2d<f32>;
@group(0) @binding(2) var samp: sampler;

const FLOOR_Y: f32 = -3.0;
const TAU: f32 = 6.2831853;

struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) n: vec3<f32>,
    @location(1) w: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) lp: vec3<f32>,
};

fn bez(t: f32) -> vec3<f32> {
    let s = 1.0 - t;
    return s * s * s * u.c0.xyz + 3.0 * s * s * t * u.c1.xyz + 3.0 * s * t * t * u.c2.xyz + t * t * t * u.c3.xyz;
}
fn bezd(t: f32) -> vec3<f32> {
    let s = 1.0 - t;
    return 3.0 * s * s * (u.c1.xyz - u.c0.xyz) + 6.0 * s * t * (u.c2.xyz - u.c1.xyz) + 3.0 * t * t * (u.c3.xyz - u.c2.xyz);
}

@vertex
fn vs_main(@location(0) p: vec3<f32>, @location(1) n: vec3<f32>, @location(2) uv: vec2<f32>) -> VOut {
    var o: VOut;
    var lp = p;
    var ln = n;
    if (u.mode.x > 0.5 && u.mode.x < 1.5) {
        // energy tube swept along the uniform bezier; radius breathes with
        // travelling bulges so the strands look alive
        let t = p.x;
        let c = bez(t);
        let tg = normalize(bezd(t) + vec3(1e-5, 0.0, 0.0));
        var up = vec3(0.0, 1.0, 0.0);
        if (abs(tg.y) > 0.9) { up = vec3(1.0, 0.0, 0.0); }
        let nx = normalize(cross(tg, up));
        let ny = normalize(cross(tg, nx));
        let tw = u.c3.w * t * TAU + u.c2.w;
        let a = p.y + tw;
        let d = nx * cos(a) + ny * sin(a);
        let bulge = 1.0 + 0.45 * pow(0.5 + 0.5 * sin(t * 26.0 - u.cam.w * (5.0 + u.mode.y * 8.0)), 6.0) * (0.3 + u.mode.y);
        let taper = mix(u.c0.w, u.c1.w, t) * bulge * (0.55 + 0.45 * sin(t * 3.14159));
        lp = c + d * taper;
        ln = d;
    }
    if (u.mode.x > 9.5) {
        // cable: slow tentacle sway, pinned at both ends
        let pin = sin(uv.x * 3.14159);
        let ph = uv.x * u.params.w * 0.12 + u.mode.z;
        let t = u.cam.w;
        // sway, but cables resting on the floor only lift, never sink into it
        let sw = vec3(sin(t * 0.31 + ph), cos(t * 0.23 + ph * 1.3) * 0.6, sin(t * 0.19 + ph * 0.7)) * u.c1.x * pin;
        let rest = smoothstep(1.2, 0.0, p.y - FLOOR_Y);
        lp = lp + vec3(sw.x, mix(sw.y, abs(sw.y), rest), sw.z);
    }
    o.pos = u.mvp * vec4(lp, 1.0);
    o.w = (u.model * vec4(lp, 1.0)).xyz;
    o.n = normalize((u.model * vec4(ln, 0.0)).xyz + vec3(0.0, 1e-6, 0.0));
    o.uv = uv;
    o.lp = lp;
    return o;
}

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}
fn hash3(p: vec3<f32>) -> f32 {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}
fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let w = f * f * (3.0 - 2.0 * f);
    let a = mix(mix(hash3(i), hash3(i + vec3(1.0, 0.0, 0.0)), w.x), mix(hash3(i + vec3(0.0, 1.0, 0.0)), hash3(i + vec3(1.0, 1.0, 0.0)), w.x), w.y);
    let b = mix(mix(hash3(i + vec3(0.0, 0.0, 1.0)), hash3(i + vec3(1.0, 0.0, 1.0)), w.x), mix(hash3(i + vec3(0.0, 1.0, 1.0)), hash3(i + vec3(1.0, 1.0, 1.0)), w.x), w.y);
    return mix(a, b, w.z);
}
fn fbm(p: vec3<f32>) -> f32 {
    var s = 0.0;
    var a = 0.5;
    var q = p;
    for (var k = 0; k < 4; k++) {
        s += a * noise3(q);
        q = q * 2.03 + vec3(1.7, 9.2, 3.1);
        a *= 0.5;
    }
    return s;
}
// thin-film iridescence leaning on the Rive prism hues
fn irid(h: f32) -> vec3<f32> {
    return 0.5 + 0.5 * cos(TAU * (h + vec3(0.0, 0.33, 0.67)));
}
fn toLinear(c: vec3<f32>) -> vec3<f32> {
    return pow(max(c, vec3(0.0)), vec3(2.2));
}

fn fogK(w: vec3<f32>) -> f32 {
    let d = length(u.cam.xyz - w);
    return exp(-max(d - 9.0, 0.0) * 0.075);
}
// HDR guard: a single Inf/NaN pixel turns into a screen-sized bloom blob
fn sane(c: vec3<f32>) -> vec3<f32> {
    var o = clamp(c, vec3(0.0), vec3(40.0));
    if (!(o.x <= 40.0 && o.y <= 40.0 && o.z <= 40.0)) { o = vec3(0.0); }
    return o;
}

fn finish(rgbIn: vec3<f32>, a: f32, w: vec3<f32>) -> vec4<f32> {
    let rgb = sane(rgbIn);
    let fog = fogK(w);
    // reflected copies (mirrored through the floor) fade with depth below it
    if (u.fx.w > 0.0) {
        let f = exp(-max(FLOOR_Y - w.y, 0.0) * 0.55) * u.fx.w * fog;
        return vec4(rgb * f, a * f);
    }
    return vec4(rgb * fog, a * mix(0.35, 1.0, fog));
}

// Depth of field: every object writes its camera distance into a second
// MSAA target (r = distance, a = coverage weight), blended over what's behind
// it. MSAA resolve gives anti-aliased depth edges for the CoC.
struct FOut {
    @location(0) c: vec4<f32>,
    @location(1) d: vec4<f32>,
};

// Depth for DoF must be STABLE: a weighted blend of several layers' distances
// is a distance that belongs to nothing, and it flickers as translucent or
// animated content moves (the "wobble"). So: solid things write full weight,
// panels write where they have ink (thresholded, binary apart from AA), and
// glows / translucent layers write nothing.
fn dofWeight(mode: f32, a: f32, op: f32) -> f32 {
    if (u.fx.w > 0.0) { return 0.0; }            // floor reflections: floor wins
    let vis = step(0.5, op);
    if (mode < 0.5) { return step(0.15, a) * vis; }   // live panels (ink only)
    if (mode > 12.5) { return vis; }             // refractive prism body
    if (mode > 11.5) { return vis; }             // prism glass
    if (mode > 10.5) { return vis; }             // Bit core layers
    if (mode > 9.5) { return vis; }              // cables
    if (mode > 8.5) { return step(0.35, a) * vis; } // hex wall: its lines (a = ink)
    if (mode > 7.5) { return 0.0; }              // haze dome
    if (mode > 6.5) { return vis; }              // gyro rings
    if (mode > 5.5) { return vis; }              // plasma heart
    if (mode > 4.5) { return 0.0; }              // light beams
    if (mode > 3.5) { return vis; }              // neon frames sit on their panels
    if (mode > 2.5) { return 1.0; }              // floor
    if (mode > 1.5) { return 0.0; }              // glass shell
    return vis;                                  // energy tubes (menu links)
}

// hex sphere (Goldberg lattice on a geodesic icosphere, see Geo.hexSphere):
// uv = barycentrics of the small triangle. The dual cell boundary is where the
// two largest barycentrics are equal; distance to it in world units uses the
// small-triangle edge length. Returns (edge distance, cell key xyz).
const HEX_TRI: f32 = 1.31;      // small triangle edge (R=30, N=24)
const HEX_LINE: f32 = 0.022;    // half line width (world units)
fn geoField(uv: vec2<f32>, lp: vec3<f32>) -> vec4<f32> {
    let bc = vec3(uv.x, uv.y, 1.0 - uv.x - uv.y);
    let m1 = max(bc.x, max(bc.y, bc.z));
    let m3 = min(bc.x, min(bc.y, bc.z));
    let m2 = bc.x + bc.y + bc.z - m1 - m3;
    // barycentric difference -> perpendicular distance (equilateral tri)
    let e = (m1 - m2) * HEX_TRI * 0.8660254 * 0.5;
    // reconstruct the triangle's corners from screen derivatives so each cell
    // (= the corner with the largest barycentric) gets a stable key
    let dpx = dpdx(lp); let dpy = dpdy(lp);
    let dux = dpdx(uv); let duy = dpdy(uv);
    let det = dux.x * duy.y - dux.y * duy.x;
    var key = floor(lp * 0.5);
    if (abs(det) > 1e-12) {
        let inv = 1.0 / det;
        // E = [P1-P3, P2-P3] = dp * J^-1
        let e1 = (dpx * duy.y - dpy * dux.y) * inv;
        let e2 = (dpy * dux.x - dpx * duy.x) * inv;
        let p3 = lp - e1 * uv.x - e2 * uv.y;
        var c = p3;
        if (bc.x >= m1) { c = p3 + e1; } else if (bc.y >= m1) { c = p3 + e2; }
        key = floor(c * 1.5 + 0.5);
    }
    return vec4(e, key);
}
fn hexInk2(uv: vec2<f32>, lp: vec3<f32>, wy: f32) -> f32 {
    let e = geoField(uv, lp).x;
    return (1.0 - smoothstep(HEX_LINE * 0.5, HEX_LINE * 2.0, e)) * step(FLOOR_Y + 0.5, wy);
}

@fragment
fn fs_main(i: VOut, @builtin(front_facing) ff: bool) -> FOut {
    let c = shade(i, ff);
    var o: FOut;
    o.c = c;
    var a = c.a;
    if (u.mode.x < 0.5) {
        let uv = u.uvr.xy + vec2(fract(max(i.uv.x, 0.0) + u.params.w), clamp(i.uv.y, 0.0, 1.0)) * u.uvr.zw;
        a = textureSampleLevel(tex, samp, uv, 0.0).a;
    }
    if (u.mode.x > 8.5 && u.mode.x < 9.5) {
        a = hexInk2(i.uv, i.lp, i.w.y);
    }
    o.d = vec4(length(u.cam.xyz - i.w), 0.0, 0.0, clamp(dofWeight(u.mode.x, a, u.tint.a), 0.0, 1.0));
    return o;
}

// Layer B (transparent / emissive): distance is accumulated additively as
// (d*w, w) where w is how much this fragment shows (coverage or brightness),
// so glows and translucent parts carry their OWN depth into the DoF
@fragment
fn fs_mainB(i: VOut, @builtin(front_facing) ff: bool) -> FOut {
    let c = shade(i, ff);
    var o: FOut;
    o.c = c;
    var a = c.a;
    if (u.mode.x < 0.5) {
        let uv = u.uvr.xy + vec2(fract(max(i.uv.x, 0.0) + u.params.w), clamp(i.uv.y, 0.0, 1.0)) * u.uvr.zw;
        a = textureSampleLevel(tex, samp, uv, 0.0).a;
    }
    let lum = dot(c.rgb, vec3(0.3, 0.59, 0.11));
    let wgt = clamp(max(max(a, c.a), lum * 2.0), 0.0, 1.0);
    o.d = vec4(length(u.cam.xyz - i.w) * wgt, 0.0, 0.0, wgt);
    return o;
}

fn shade(i: VOut, ff: bool) -> vec4<f32> {
    let t = u.cam.w;
    // derivatives first, in uniform control flow
    let fw = fwidth(i.w.xz);
    var n = normalize(i.n);
    if (!ff) { n = -n; }
    let v = normalize(u.cam.xyz - i.w);
    let ndv = clamp(abs(dot(n, v)), 0.0, 1.0);
    let fres = pow(1.0 - ndv, 3.0);
    let mode = u.mode.x;
    let tint = u.tint.rgb;
    let op = u.tint.a;

    // ------------------------------------------------------------ Prism Poly glass
    // Port of the designers' prism.wgsl: chromatic refraction of the frame
    // behind it (last frame's HDR, tex), Fresnel transparency, key + point
    // light Blinn-Phong, view-dependent iridescence, rim glow.
    // params: x ior, y transparency, z fresnel power, w refraction strength
    // c0 point light pos + intensity, c1 light rgb + radius, c2 glow rgb + amount,
    // c3.xy 1/viewport
    if (mode > 11.5 && mode < 12.5) {
        let N = n;
        let V = v;
        let ior = u.params.x;
        let chroma = 1.0;
        let L = normalize(vec3(0.4, 0.6, 0.7));
        let NdotL = max(dot(N, L), 0.0);
        let H = normalize(L + V);
        let spec = pow(max(dot(N, H), 0.0), 48.0) * 1.3;
        let pv = u.c0.xyz - i.w;
        let pd = length(pv);
        let pL = pv / max(pd, 1e-4);
        let pat = 1.0 / (1.0 + (pd / u.c1.w) * (pd / u.c1.w));
        let pDiff = max(dot(N, pL), 0.0) * u.c0.w * pat;
        let pSpec = pow(max(dot(N, normalize(pL + V)), 0.0), 48.0) * u.c0.w * pat;
        let fresnel = pow(1.0 - ndv, max(u.params.z, 0.001));
        let suv = i.pos.xy * u.c3.xy;
        let I = -V;
        let rR = refract(I, N, 1.0 / (ior - chroma * 0.04));
        let rG = refract(I, N, 1.0 / ior);
        let rB = refract(I, N, 1.0 / (ior + chroma * 0.04));
        let os = u.params.w * (0.35 + chroma * 0.25);
        let bg = vec3(
            textureSampleLevel(tex, samp, clamp(suv + vec2(rR.x, -rR.y) * os, vec2(0.0), vec2(1.0)), 0.0).r,
            textureSampleLevel(tex, samp, clamp(suv + vec2(rG.x, -rG.y) * os, vec2(0.0), vec2(1.0)), 0.0).g,
            textureSampleLevel(tex, samp, clamp(suv + vec2(rB.x, -rB.y) * os, vec2(0.0), vec2(1.0)), 0.0).b);
        let it = dot(N, V) * 2.0 + (rR.x - rB.x) * 4.0;
        let rainbow = 0.5 + 0.5 * sin(vec3(it * 2.5, it * 2.5 + 2.094, it * 2.5 + 4.188));
        let irid = rainbow * fresnel * (0.4 + chroma * 0.6);
        let rim = pow(1.0 - ndv, 3.0);
        let amb = vec3(0.235, 0.314, 0.47) * 0.35;
        let lightC = vec3(1.0) * 0.9 * NdotL + u.c1.rgb * pDiff;
        // dark smoked glass: the refracted scene is dimmed and cooled, so the
        // light lives in edges, highlights and dispersion (as in the reference)
        var c = mix(bg, bg * tint, 0.35) * (0.32 + (amb + lightC) * 0.3);
        c = c + irid * 0.55;
        c = c + (vec3(1.0) * spec + u.c1.rgb * pSpec) * 2.2;
        c = c + rim * (vec3(0.9) + u.c1.rgb * u.c0.w * pat) * 0.5;
        // crisp bevel edges: the rounded bevel strips have normals that swing
        // fast across the face -> a thin line of light along every edge
        let fw = length(fwidth(N));
        let bevel = smoothstep(0.02, 0.18, fw);
        c = c + (vec3(1.0, 0.96, 0.9) * (0.35 + NdotL * 1.2) + u.c1.rgb * pDiff * 1.5) * bevel * 1.4;
        let glowE = rim * 0.6 * 1.5 + (spec + pSpec) * 0.8 * 3.0 + dot(irid, vec3(0.333)) * 0.45 * 1.8;
        c = c + u.c2.rgb * glowE * u.c2.w * 0.2;
        var a = clamp(mix(u.params.y, 1.0, fresnel) + (spec + pSpec) * 0.6 + bevel, 0.0, 1.0);
        return finish(c * a * op, a * op, i.w);
    }
    // ------------------------------------------------------------ prism glass body
    // Refracts THIS frame's opaque scene (tex = snapshot taken between the
    // opaque and glass passes). The refracted ray is pushed `th` units through
    // the solid in local space and re-projected with the object's own mvp, so
    // the image behind bends with the facet angles. Three IORs = dispersion.
    // params: x ior, y thickness, z dispersion, w reflection
    if (mode > 12.5) {
        if (!ff) { discard; }
        let I = -v;
        let m0 = u.model[0].xyz;
        let m1 = u.model[1].xyz;
        let m2 = u.model[2].xyz;
        let s2 = max(dot(m0, m0), 1e-6);
        let ior = u.params.x;
        let disp = u.params.z;
        var refr = vec3(0.0);
        for (var ch = 0; ch < 3; ch++) {
            let eta = 1.0 / (ior + (f32(ch) - 1.0) * disp);
            var rw = refract(I, n, eta);
            if (dot(rw, rw) < 1e-4) { rw = reflect(I, n); }
            // bend further toward the inside so the effect reads at small sizes
            let bend = normalize(rw - I * 0.35);
            let dl = vec3(dot(m0, bend), dot(m1, bend), dot(m2, bend)) / s2;
            let cp = u.mvp * vec4(i.lp + dl * u.params.y, 1.0);
            let ruv = clamp(vec2(cp.x / cp.w * 0.5 + 0.5, 0.5 - cp.y / cp.w * 0.5), vec2(0.0), vec2(1.0));
            let smpc = textureSampleLevel(tex, samp, ruv, 0.0);
            refr[ch] = smpc[ch];
        }
        // glass absorbs a little and is tinted by the layer colour
        let fr = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
        let env = mix(vec3(0.05, 0.04, 0.03), vec3(1.0, 0.82, 0.55), smoothstep(-0.2, 0.9, reflect(I, n).y)) * u.params.w;
        let L = normalize(vec3(-0.4, 0.8, 0.5));
        let spec = pow(max(dot(n, normalize(L + v)), 0.0), 90.0) * 1.6;
        let trans = mix(vec3(1.0), tint, 0.35) * 0.92;
        let c = refr * trans * (1.0 - fr) + env * fr + vec3(spec) * fr * 4.0;
        return finish(c * op, op, i.w);
    }
    // ------------------------------------------------------------ Bit facets
    // translucent faceted shell: fresnel glass body, crisp glowing facet edges,
    // per-facet shimmer hashed from the flat normal, a scan band sweeping up.
    // params.x edge width, params.y body, params.z edge glow, mode.y energy,
    // mode.z hue mix toward white-hot, mode.w per-facet flicker
    if (mode > 10.5) {
        let bc = vec3(i.uv.x, i.uv.y, 1.0 - i.uv.x - i.uv.y);
        let de = min(bc.x, min(bc.y, bc.z));
        let fwe = clamp(fwidth(de), 1e-4, 0.5);
        // screen-space cap: edge + halo widths are facet-relative, so as the
        // camera closes in they grew into wide white bands that stacked across
        // the nested layers and blew out. Relative to the hub framing
        // (~1/150 barycentric per pixel) they now grow only ~mag^0.15.
        let mag = max((1.0 / 150.0) / fwe, 1.0);
        let wk = pow(mag, -0.85);
        let ew = u.params.x * 0.5 * wk;
        // anti-aliased line: at least ~1.5 px wide (0.75 px per facet side), a 1 px box
        // filter across its edge, and thinner lines get dimmer instead of breaking
        // into stair steps and beads (same light per unit length at any size)
        let ewMin = fwe * 0.75;
        let ewD = max(ew, ewMin);
        let edge = (1.0 - smoothstep(ewD - fwe * 0.5, ewD + fwe * 0.5, de)) * min(1.0, ew / ewMin);
        // the halo gets the same treatment: never narrower than ~1.5 px
        let hw = u.params.x * 2.5 * wk;
        let hwD = max(hw, fwe * 1.5);
        let halo = exp(-de / max(hwD, 1e-4)) * 0.35 * min(1.0, hw / (fwe * 1.5));
        let fid = hash3(floor(n * 41.0 + 0.5));
        let pulse = 0.5 + 0.5 * sin(t * (1.3 + fid * 2.0) + fid * 40.0);
        let flick = 1.0 - u.mode.w * step(0.93, hash2(vec2(floor(t * 12.0), fid * 97.0)));
        let ly = normalize(i.lp).y;
        let scan = smoothstep(0.12, 0.0, abs(ly - (fract(t * 0.23) * 2.4 - 1.2))) * 0.8;
        let body = (u.params.y * (0.22 + 0.78 * fres) * (0.55 + 0.45 * pulse) + scan * 0.25) * flick;
        // proximity calm-down: when the camera grazes the core (flights pass
        // ~2.6 units from its centre) the edges fill the frame and DoF smears
        // them into white bars. Fade their energy and the push to white-hot
        // as it gets close; untouched at hub distance (~11).
        let cd = length(u.cam.xyz - u.model[3].xyz);
        let prox = smoothstep(3.0, 10.8, cd);
        let ek = mix(0.25, 1.0, prox * prox * (3.0 - 2.0 * prox));
        let hot = mix(tint, vec3(1.0, 0.86, 0.62) * length(tint), u.mode.z * prox);
        var c = tint * body + hot * (edge * u.params.z + halo * u.params.z * 0.4) * (0.8 + u.mode.y) * flick * ek;
        // rear faces dimmer so the layers read as nested translucent volumes
        if (!ff) { c = c * 0.35; }
        return finish(c * op, 0.0, i.w);
    }
    // ------------------------------------------------------------ cable
    if (mode > 9.5) {
        let along = i.uv.x * u.params.w;
        let isWire = step(1.5, i.uv.y);
        // armoured segments: grooves every ~0.5 units darken + break the highlight
        let seg = fract(along * 2.0);
        let groove = (smoothstep(0.0, 0.06, seg) * smoothstep(0.34, 0.26, seg)) * (1.0 - isWire);
        let rib = 1.0 - groove * 0.85;
        let toL = u.c0.xyz - i.w;
        let dl = length(toL);
        let L = toL / max(dl, 1e-3);
        let att = 1.0 / (1.0 + dl * dl * 0.01);
        let diff = max(dot(n, L), 0.0) * att;
        let spec = pow(max(dot(reflect(-L, n), v), 0.0), 40.0) * att;
        let rimL = pow(1.0 - ndv, 4.0) * max(dot(n, L) * 0.5 + 0.5, 0.0);
        let key = pow(max(dot(n, normalize(vec3(-0.3, 1.0, 0.4))), 0.0), 3.0) * 0.02;
        let base = vec3(0.006, 0.0055, 0.005);
        let lightC = mix(tint, u.c2.rgb, 0.6);
        var c = base + lightC * (diff * 0.12 + spec * 1.6) * rib + vec3(key) * rib + tint * rimL * 0.3 * att * 4.0;
        // faint amber edge light everywhere, so far cables read against the haze
        c = c + lightC * pow(1.0 - ndv, 3.0) * 0.035 * rib;
        // rare slow energy packets travelling toward the core along the wires
        let pk = pow(0.5 + 0.5 * sin(along * 0.35 + t * 1.2 + u.mode.z * 3.0), 60.0);
        // energy packets are the one warm accent on the cables
        c = c + u.c2.rgb * pk * (0.15 + isWire * 1.2) * (0.4 + u.mode.y);
        c = c + tint * isWire * 0.015;
        let fog = fogK(i.w);
        if (u.fx.w > 0.0) {
            let f = exp(-max(FLOOR_Y - i.w.y, 0.0) * 0.55) * u.fx.w * fog;
            return vec4(c * f * op, f * op);
        }
        return vec4(c * fog * op, op);
    }
    // ------------------------------------------------------------ far hex wall
    if (mode > 8.5 && u.mode.y > 0.5) {
        // smoked-glass body of the hex sphere, only near the camera during
        // the dive fly-through (dims what's behind it so it reads as a shell)
        let hf = geoField(i.uv, i.lp);
        let dCam = length(u.cam.xyz - i.w);
        let near = smoothstep(0.5, 5.0, dCam) * (1.0 - smoothstep(14.0, 60.0, dCam));
        let fade = smoothstep(FLOOR_Y - 0.5, FLOOR_Y + 2.0, i.w.y);
        let sheen = 0.5 + 0.5 * hash3(hf.yzw);
        let a = 0.55 * near * fade * u.mode.z;
        return vec4(tint * (0.01 + sheen * 0.02) * a, a);
    }
    if (mode > 8.5) {
        let hf = geoField(i.uv, i.lp);
        let e = hf.x;
        let px = max(fwidth(e), 1e-4);
        // sphere sits on the floor: fade where it meets it
        let fade = smoothstep(FLOOR_Y - 0.5, FLOOR_Y + 2.0, i.w.y);
        let dCam = length(u.cam.xyz - i.w);
        let near = smoothstep(18.0, 2.0, dCam) * mix(1.0, smoothstep(0.3, 3.5, dCam), u.mode.z)
            + u.mode.z * smoothstep(0.3, 3.5, dCam) * (1.0 - smoothstep(14.0, 70.0, dCam)) * 0.9;
        let lw = max(HEX_LINE, px * 1.3);
        let thin = HEX_LINE / lw;
        let line = (1.0 - smoothstep(lw - px, lw + px, e)) * mix(1.0, sqrt(thin), 0.6);
        let inset = 1.0 - smoothstep(0.0, px * 1.5, abs(e - HEX_LINE * 5.0) - HEX_LINE * 0.35);
        let hc = hash3(hf.yzw);
        // slow scan: latitude bands sweeping up the sphere, with longitude twist
        let nrm = normalize(i.lp);
        let scan = pow(0.5 + 0.5 * sin(nrm.y * 9.0 - t * 0.7 + atan2(nrm.z, nrm.x) * 3.0), 10.0);
        let lit = step(0.93, hash3(hf.yzw + floor(t * 0.6 + hc * 7.0)));
        let fill = (0.012 + hc * 0.02) * (0.4 + near) + lit * 0.06;
        let halo = exp(-max(e - lw, 0.0) / (lw * 3.0 + px)) * 0.25;
        let k = line * (0.10 + scan * 0.45 + near * 1.3) + halo * (0.06 + near * 0.6)
            + inset * (0.03 + near * 0.25) + fill;
        let fogLift = mix(1.0, 1.0 / max(fogK(i.w), 0.18), u.mode.z * 0.55);
        let c = tint * k * fade * op * fogLift;
        return finish(c, 0.0, i.w);
    }
    // ------------------------------------------------------------ haze dome
    if (mode > 7.5) {
        let d = normalize(i.w - u.cam.xyz);
        let c = normalize(u.c0.xyz - u.cam.xyz);
        let k = max(dot(d, c), 0.0);
        let core = pow(k, 22.0) * 0.55 + pow(k, 5.0) * 0.12;
        let shafts = 0.75 + 0.25 * noise3(vec3(d.x * 7.0, d.y * 2.0 + t * 0.05, d.z * 7.0));
        let low = smoothstep(0.25, -0.35, d.y) * 0.05;
        let col = tint * (core * shafts + low) * op;
        return vec4(col, 0.0);
    }
    // ------------------------------------------------------------ gyroscope ring
    if (mode > 6.5) {
        let seg = fract(i.uv.x * 64.0);
        let dash = smoothstep(0.0, 0.04, seg) * smoothstep(0.42, 0.38, seg);
        let gaps = step(0.04, fract(i.uv.x * 3.0 + 0.02));
        let run = pow(0.5 + 0.5 * cos((i.uv.x - t * 0.18 * u.mode.z) * TAU), 24.0);
        let lip = pow(abs(sin(i.uv.y * TAU)), 12.0);
        let k = (0.18 + dash * 0.55 + lip * 0.8) * gaps + run * 4.0 * (0.4 + u.mode.y) + fres * 0.9;
        return finish(tint * k * u.params.y * op, 0.0, i.w);
    }
    // ------------------------------------------------------------ plasma core
    if (mode > 5.5) {
        let q = normalize(i.lp) * 2.4;
        let n1 = fbm(q + vec3(0.0, t * 0.55, t * 0.2));
        let n2 = fbm(q * 2.1 + vec3(n1 * 2.4, -t * 0.35, n1));
        let veins = pow(1.0 - abs(n2 * 2.0 - 1.0), 6.0);
        let heat = (0.25 + 0.75 * n2) * (1.0 + u.mode.y * 1.5);
        var c = mix(tint * 0.35, tint * 1.6, heat) + vec3(1.0, 0.85, 0.6) * veins * (0.6 + u.mode.y * 1.2);
        c = c * (0.35 + 0.65 * pow(ndv, 0.7)) + tint * fres * 2.5;
        return finish(c * u.params.y * op, op, i.w);
    }
    // ------------------------------------------------------------ light volume
    if (mode > 4.5) {
        let along = i.uv.y;
        let dust = 0.55 + 0.45 * noise3(vec3(i.w.x * 3.0, i.w.y * 3.0 - t * 1.2, i.w.z * 3.0));
        let streaks = 0.7 + 0.3 * sin(i.uv.x * 90.0 + t * 0.7);
        let soft = pow(ndv, 1.2);
        let k = mix(1.0, along, u.params.x) * soft * dust * streaks;
        let c = tint * k * u.params.y * op;
        return finish(c, 0.0, i.w);
    }
    // ------------------------------------------------------------ neon frame
    if (mode > 3.5) {
        let run = pow(0.5 + 0.5 * cos((i.uv.x - t * 0.35) * TAU), 40.0);
        let corner = i.uv.y;
        let k = 0.35 + corner * 1.6 + run * 6.0 * u.mode.y;
        let flick = 1.0 - 0.15 * step(0.97, hash2(vec2(floor(t * 20.0), u.mode.z)));
        return finish(tint * k * u.params.y * op * flick, 0.0, i.w);
    }
    // ------------------------------------------------------------ floor
    if (mode > 2.5) {
        let p = i.w.xz;
        let g1 = abs(fract(p - 0.5) - 0.5) / max(fw, vec2(1e-4));
        let l1 = 1.0 - min(min(g1.x, g1.y), 1.0);
        let p4 = p * 0.25;
        let g4 = abs(fract(p4 - 0.5) - 0.5) / max(fw * 0.25, vec2(1e-4));
        let l4 = 1.0 - min(min(g4.x, g4.y) * 0.5, 1.0);
        let dc = length(p - u.c0.xz);
        let fade = exp(-length(p - vec2(0.8, -1.0)) * 0.085);
        // ripples from the core on every kick + a slow idle ring
        let rip = smoothstep(0.35, 0.0, abs(dc - u.c1.x)) * u.c1.y;
        let idle = smoothstep(0.08, 0.0, abs(dc - fract(t * 0.12) * 18.0)) * 0.25 * (1.0 - fract(t * 0.12));
        // radar sweep around the core
        let ang = atan2(p.y - u.c0.z, p.x - u.c0.x);
        let sweep = pow(fract((ang / TAU) - t * 0.08), 14.0) * exp(-dc * 0.12);
        let pool = exp(-dc * dc * 0.18) * u.c0.w;
        let df = length(p - u.c2.xz);
        let pool2 = exp(-df * df * 0.5) * u.c2.w;
        let grid = (l1 * 0.05 + l4 * 0.16) * fade;
        let c = tint * (grid * (1.0 + rip * 3.0 + idle * 2.0) + sweep * 0.0 + pool * 0.5) + u.c3.rgb * (pool2 * 0.45 + rip * 0.15 * fade);
        return vec4(c * op * fogK(i.w), 0.0);
    }
    // ------------------------------------------------------------ holo shell
    if (mode > 1.5) {
        let q = normalize(i.lp);
        let rot = vec3(q.x * cos(t * 0.07) - q.z * sin(t * 0.07), q.y, q.x * sin(t * 0.07) + q.z * cos(t * 0.07));
        let g = abs(fract(rot * 7.0) - 0.5);
        let lat = smoothstep(0.44, 0.5, max(g.x, max(g.y, g.z)));
        let sweep = smoothstep(0.22, 0.0, abs(q.y - sin(t * 0.6) * 0.95));
        let film = irid(ndv * 1.6 + q.y * 0.35 + t * 0.04);
        let c = (mix(tint, film, 0.12) * fres * u.params.x + tint * lat * (0.08 + sweep * 1.2) * (0.3 + fres)) * op;
        return finish(c, 0.0, i.w);
    }
    // ------------------------------------------------------------ energy tube
    if (mode > 0.5) {
        let along = i.uv.x;
        let speed = 3.5 + u.mode.y * 9.0;
        let packets = pow(0.5 + 0.5 * sin(along * 30.0 - t * speed), 10.0);
        let core = pow(ndv, 2.5);
        let pulse = 0.2 + u.mode.y * 1.3;
        let ends = smoothstep(0.0, 0.06, along) * smoothstep(1.0, 0.92, along);
        let k = (packets * 3.0 * pulse + 0.12 + core * 0.9 * pulse) * ends;
        let c = mix(tint, vec3(1.0), core * 0.55 * pulse) * k * op;
        return finish(c, 0.0, i.w);
    }

    // ------------------------------------------------------------ holo panel
    let reveal = u.fx.x;
    let gl = u.fx.z;
    let row = floor(i.uv.y * 48.0);
    let tear = (hash2(vec2(row, floor(t * 24.0))) - 0.5) * (gl * 0.05 + (1.0 - reveal) * 0.03) * step(0.6, hash2(vec2(row * 0.37, floor(t * 12.0))));
    let uv = vec2(fract(max(i.uv.x, 0.0) + u.params.w + tear), i.uv.y);
    let ch = u.fx.y + gl * 0.006;
    let base = u.uvr.xy + uv * u.uvr.zw;
    let off = vec2(ch * u.uvr.z, 0.0);
    let cr = textureSample(tex, samp, base + off);
    let cg = textureSample(tex, samp, base);
    let cb = textureSample(tex, samp, base - off);
    // glass body of a game case (non-front faces carry u = -1)
    if (i.uv.x < -0.5) {
        let c = tint * (fres * 1.3 + 0.03) * op;
        return finish(c, 0.0, i.w);
    }
    let ca = max(cg.a, max(cr.a, cb.a));
    var lin = toLinear(vec3(cr.r, cg.g, cb.b));
    // build-in: content materialises top to bottom behind a bright scan line
    let edgeY = reveal * 1.2 - 0.1;
    let dv = i.uv.y - edgeY;
    let shown = smoothstep(0.02, -0.02, dv);
    let lead = smoothstep(0.035, 0.0, abs(dv)) * step(reveal, 0.999);
    let scan = 1.0 - u.params.z * (0.5 + 0.5 * sin(i.uv.y * 700.0));
    let band = 1.0 + u.params.z * 1.2 * pow(0.5 + 0.5 * sin(i.uv.y * 3.0 - t * 0.7), 16.0);
    let flick = 1.0 - (u.mode.y * 0.08 + gl * 0.3) * step(0.96, hash2(vec2(floor(t * 30.0), row)));
    lin = lin * u.params.y * scan * band * flick * (1.0 - u.mode.w);
    // projected light: dark artboard areas go see-through, bright UI stays solid
    let lum = max(lin.r, max(lin.g, lin.b));
    let solid = 0.42 + 0.58 * smoothstep(0.004, 0.12, lum);
    // neon border + inner glow measured in panel-height units
    let asp = max(u.mode.z, 0.01);
    let de = min(min(uv.x, 1.0 - uv.x) * asp, min(i.uv.y, 1.0 - i.uv.y));
    let border = (smoothstep(0.01, 0.0, de) * 1.4 + exp(-de * 22.0) * 0.14) * u.params.x;
    let rim = fres * u.params.x * 0.6;
    let haze = tint * 0.025 * ca;
    var rgb = (lin + haze) * shown + tint * (border + rim) * (0.3 + 0.7 * shown) + tint * lead * 1.4;
    var a = clamp((ca * solid * 0.92 + border * 0.3) * shown + lead * 0.5, 0.0, 1.0);
    rgb = rgb * op;
    a = a * op;
    return finish(rgb, a, i.w);
}
