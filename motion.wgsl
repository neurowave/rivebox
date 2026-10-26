// Camera motion blur (180-degree shutter). Each pixel's world position is
// rebuilt from the MSAA-resolved distance target, re-projected with last
// frame's view-projection, and the HDR frame is sampled along that screen
// velocity. Runs before bloom and DoF so highlights streak like real footage.
struct M { ivp: mat4x4<f32>, pvp: mat4x4<f32>, eye: vec4<f32>, k: vec4<f32> };
// k.x shutter fraction, k.y max blur length (uv), k.zw texel size
// eye.w zoom-blur strength: extra radial velocity out from the screen centre
@group(0) @binding(0) var<uniform> m: M;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
@group(0) @binding(3) var dist: texture_2d<f32>;

struct V { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };

@vertex fn vs_full(@builtin(vertex_index) i: u32) -> V {
    var o: V;
    let x = f32((i << 1u) & 2u);
    let y = f32(i & 2u);
    o.pos = vec4(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    o.uv = vec2(x, y);
    return o;
}

fn velAt(uv: vec2<f32>) -> vec2<f32> {
    let dd = textureSampleLevel(dist, smp, uv, 0.0);
    let d = mix(150.0, dd.r / max(dd.a, 1e-4), smoothstep(0.0, 0.05, dd.a));
    let ndc = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let fp = m.ivp * vec4(ndc, 1.0, 1.0);
    let far = fp.xyz / fp.w;
    let dir = normalize(far - m.eye.xyz);
    let wp = m.eye.xyz + dir * d;
    let pc = m.pvp * vec4(wp, 1.0);
    if (pc.w <= 0.01) {
        let rc0 = uv - vec2(0.5);
        return rc0 * m.eye.w * (0.35 + length(rc0) * 1.6);
    }
    let puv = vec2(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);
    var v = (uv - puv) * m.k.x;
    // zoom blur: radial, growing toward the edges (centre stays readable)
    let rc = uv - vec2(0.5);
    v = v + rc * m.eye.w * (0.35 + length(rc) * 1.6);
    let l = length(v);
    if (l > m.k.y) {
        v = v * (m.k.y / l);
    }
    return v;
}

@fragment fn fs_motion(i: V) -> @location(0) vec4<f32> {
    let uv = i.uv;
    let c0 = textureSampleLevel(src, smp, uv, 0.0);
    let vel = velAt(uv);
    let px = length(vel / m.k.zw);
    if (px < 0.75) {
        return c0;
    }
    // interleaved-gradient jitter hides the tap pattern; grain covers the rest
    let jit = fract(52.9829189 * fract(dot(i.pos.xy, vec2(0.06711056, 0.00583715))));
    let n = clamp(i32(px * 0.5) + 6, 6, 48);
    // zoom-only tuning (0 for ordinary camera moves): tiny white-hot features
    // (wire vertices, rings) each streak into a crisp white bar that pops as
    // they move. Luma-weighted averaging tames those fireflies, and a tapered
    // kernel softens streak ends so bars fade in and out instead of popping.
    let zf = clamp(m.eye.w / 0.12, 0.0, 1.0);
    var acc = vec3(0.0);
    var ws = 0.0;
    for (var k = 0; k < 48; k++) {
        if (k >= n) {
            break;
        }
        let t = (f32(k) + jit) / f32(n) - 0.5;
        let suv = uv + vel * t;
        // samples whose own motion is much smaller (a static thing in front)
        // contribute less, so sharp foreground edges don't smear backwards
        let sv = length(velAt(suv) / m.k.zw);
        var w = clamp(sv / max(px, 1e-3) * 1.5, 0.25, 1.0);
        let cs = textureSampleLevel(src, smp, suv, 0.0).rgb;
        let lum = dot(cs, vec3(0.2126, 0.7152, 0.0722));
        w = w * mix(1.0, (1.0 - abs(t) * 1.3) / (1.0 + lum * 1.6), zf);
        acc += cs * w;
        ws += w;
    }
    return vec4(acc / ws, c0.a);
}

// Pass 2 (gap fill): pass 1 lands its taps up to several pixels apart on
// long zoom streaks, so thin bright edges show as discrete copies that crawl
// from frame to frame. This short blur along the same velocity spans exactly
// one pass-1 tap gap, turning N taps into N x 8 (the "blur the blur" trick).
@fragment fn fs_motion2(i: V) -> @location(0) vec4<f32> {
    let uv = i.uv;
    let c0 = textureSampleLevel(src, smp, uv, 0.0);
    let vel = velAt(uv);
    let px = length(vel / m.k.zw);
    if (px < 0.75) {
        return c0;
    }
    let n1 = f32(clamp(i32(px * 0.5) + 6, 6, 48));
    let gap = vel / n1;
    if (length(gap / m.k.zw) < 1.0) {
        return c0;
    }
    let jit = fract(52.9829189 * fract(dot(i.pos.xy + vec2(17.0, 31.0), vec2(0.06711056, 0.00583715))));
    var acc = vec3(0.0);
    var ws = 0.0;
    for (var k = 0; k < 8; k++) {
        let t = (f32(k) + jit) / 8.0 - 0.5;
        let w = 1.0 - abs(t) * 1.2;
        acc += textureSampleLevel(src, smp, uv + gap * t, 0.0).rgb * w;
        ws += w;
    }
    return vec4(acc / ws, c0.a);
}

@fragment fn fs_copy(i: V) -> @location(0) vec4<f32> {
    let _k = m.k.x;
    let _d = textureSampleLevel(dist, smp, i.uv, 0.0).a;
    return textureSampleLevel(src, smp, i.uv, 0.0) + vec4(0.0 * _k * _d);
}
