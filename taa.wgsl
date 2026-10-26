// Temporal resolve for depth of field. The DoF gather is rotated every frame;
// this pass reprojects last frame's result through the depth buffer and
// accumulates it, so out-of-focus areas converge to smooth, stable bokeh
// instead of boiling, while in-focus pixels pass straight through (no lag,
// no ghosting on the UI). History is clipped to the current 3x3 colour
// neighbourhood (variance box) so moving edges never smear.
struct M { ivp: mat4x4<f32>, pvp: mat4x4<f32>, eye: vec4<f32>, k: vec4<f32> };
// eye.w = 1 resets history; k.zw = texel size
@group(0) @binding(0) var<uniform> m: M;
@group(0) @binding(1) var cur: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
@group(0) @binding(3) var dist: texture_2d<f32>;
@group(0) @binding(4) var hist: texture_2d<f32>;

struct V { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };

@vertex fn vs_full(@builtin(vertex_index) i: u32) -> V {
    var o: V;
    let x = f32((i << 1u) & 2u);
    let y = f32(i & 2u);
    o.pos = vec4(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    o.uv = vec2(x, y);
    return o;
}

fn prevUv(uv: vec2<f32>) -> vec3<f32> {
    let dd = textureSampleLevel(dist, smp, uv, 0.0);
    let d = mix(150.0, dd.r / max(dd.a, 1e-4), smoothstep(0.0, 0.05, dd.a));
    let ndc = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let fp = m.ivp * vec4(ndc, 1.0, 1.0);
    let dir = normalize(fp.xyz / fp.w - m.eye.xyz);
    let wp = m.eye.xyz + dir * d;
    let pc = m.pvp * vec4(wp, 1.0);
    if (pc.w <= 0.01) {
        return vec3(0.0, 0.0, 0.0);
    }
    return vec3(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5, 1.0);
}

@fragment fn fs_taa(i: V) -> @location(0) vec4<f32> {
    let uv = i.uv;
    let c = textureSampleLevel(cur, smp, uv, 0.0);
    var m1 = vec3(0.0);
    var m2 = vec3(0.0);
    var mn = c.rgb;
    var mx = c.rgb;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let s = textureSampleLevel(cur, smp, uv + vec2(f32(x), f32(y)) * m.k.zw, 0.0).rgb;
            m1 += s;
            m2 += s * s;
            mn = min(mn, s);
            mx = max(mx, s);
        }
    }
    let mean = m1 / 9.0;
    let sd = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
    let lo = max(mn, mean - sd * 2.0);
    let hi = min(mx, mean + sd * 2.0);
    let pu = prevUv(uv);
    // in focus -> current frame; defocused -> long accumulation (~10 frames)
    var a = mix(1.0, 0.07, c.a);
    let off = pu.z < 0.5 || pu.x < 0.0 || pu.y < 0.0 || pu.x > 1.0 || pu.y > 1.0;
    if (m.eye.w > 0.5 || off) {
        a = 1.0;
    }
    let h = textureSampleLevel(hist, smp, pu.xy, 0.0);
    // focus changed under this pixel (subject arrives / leaves): resolve fast
    a = max(a, clamp(abs(h.a - c.a) * 1.5, 0.0, 1.0));
    let hc = clamp(h.rgb, lo, hi);
    return vec4(mix(hc, c.rgb, a), c.a);
}
