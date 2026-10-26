// GPU-instanced holographic motes: camera-facing soft sparks in HDR so they
// bloom, stretched along their screen velocity during camera moves.
struct C { vp: mat4x4<f32>, right: vec4<f32>, up: vec4<f32>, misc: vec4<f32> };
@group(0) @binding(0) var<uniform> c: C;
struct V {
    @builtin(position) pos: vec4<f32>,
    @location(0) q: vec2<f32>,
    @location(1) col: vec4<f32>,
    @location(2) dist: f32,
};
struct FOut { @location(0) c: vec4<f32>, @location(1) d: vec4<f32> };
@vertex fn vs_part(@builtin(vertex_index) vi: u32, @location(0) ip: vec4<f32>, @location(1) ic: vec4<f32>) -> V {
    var corners = array<vec2<f32>, 6>(vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));
    let q = corners[vi];
    let stretch = 1.0 + c.misc.x;
    let wp = ip.xyz + c.right.xyz * q.x * ip.w * stretch + c.up.xyz * q.y * ip.w;
    var o: V;
    o.pos = c.vp * vec4(wp, 1.0);
    o.q = vec2(q.x, q.y * stretch);
    o.col = ic;
    o.dist = o.pos.w;
    return o;
}
@fragment fn fs_part(i: V) -> FOut {
    let d = length(vec2(i.q.x, i.q.y / (1.0 + c.misc.x)));
    let core = exp(-d * d * 9.0);
    let halo = exp(-d * 3.5) * 0.25;
    let k = (core * 2.4 + halo) * smoothstep(1.0, 0.7, d);
    var o: FOut;
    // same distance fog as the scene: from the start screen the dashboard's
    // sparks melt into the dark instead of stacking into one hot blob
    let fog = exp(-max(i.dist - 9.0, 0.0) * 0.075);
    o.c = vec4(i.col.rgb * k * i.col.a * fog, 0.0);
    // layer B: sparks carry their own depth (weighted by brightness), so each
    // one blurs into a bokeh disc at its own distance
    let wgt = clamp(k * i.col.a * fog * 0.6, 0.0, 1.0);
    o.d = vec4(i.dist * wgt, 0.0, 0.0, wgt);
    return o;
}
