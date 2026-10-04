shader_type spatial;
// 原版 nuke_clouds_002 天空球云层复刻 (UnlitTwoTexture 双层滚动云)
// 天空球网格来自真实地图数据 (material nuke_clouds_002), 位于 3D 天空盒坐标
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform vec3 top_color : source_color = vec4(0.62, 0.71, 0.85);
uniform vec3 horizon_color : source_color = vec4(0.83, 0.85, 0.88);
uniform vec3 cloud_color : source_color = vec4(1.0, 1.0, 1.0);
uniform float cloud_speed = 0.004;
uniform float cloud_coverage = 0.45;
uniform float fog_scale = 16.0;
uniform float fog_start = -0.2286;
uniform float fog_end = 228.6;
uniform float fog_max_density = 0.6;
uniform vec3 fog_color : source_color = vec4(0.75, 0.79, 0.85);
uniform vec3 sky_origin = vec3(-0.69, -209.07, -12.14);

varying vec3 world_pos_v;

void vertex() {
        world_pos_v = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash12(vec2 p) {
        vec3 p3 = fract(vec3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
        vec2 i = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x),
                   mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) {
        float v = 0.0;
        float a = 0.5;
        for (int i = 0; i < 4; i++) {
                v += a * vnoise(p);
                p = p * 2.13 + vec2(17.3, 9.1);
                a *= 0.5;
        }
        return v;
}

void fragment() {
        vec3 wpos = world_pos_v;
        vec3 dir = normalize(wpos);
        // 高度渐变天空
        float h = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
        vec3 sky = mix(horizon_color, top_color, pow(h, 0.75));
        // 双层滚动云 (投影到 XZ)
        vec2 uv1 = dir.xz / max(0.08, abs(dir.y) + 0.35) * 2.0 + vec2(TIME * cloud_speed, TIME * cloud_speed * 0.6);
        vec2 uv2 = dir.xz / max(0.08, abs(dir.y) + 0.35) * 5.3 - vec2(TIME * cloud_speed * 1.7, 0.0);
        float c1 = smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + 0.35, fbm(uv1));
        float c2 = smoothstep(1.0 - cloud_coverage * 0.8, 1.0 - cloud_coverage * 0.8 + 0.4, fbm(uv2));
        float cloud = clamp(c1 * 0.75 + c2 * 0.45, 0.0, 1.0) * smoothstep(0.02, 0.16, dir.y);
        vec3 col = mix(sky, cloud_color, cloud * 0.85);
        // 与原版一致的距离雾
        vec3 sky_pos = sky_origin + wpos / fog_scale;
        float dist = length(sky_pos);
        float fog = clamp((dist - fog_start) / max(0.01, fog_end - fog_start), 0.0, 1.0) * fog_max_density;
        ALBEDO = mix(col, fog_color, fog);
}
