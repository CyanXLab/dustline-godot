shader_type spatial;
// SourceBaked 复刻 — 原版 "Dustline/SourceBaked" 着色器:
// albedo = base_map × base_color × 顶点色(混合材质按顶点色 alpha 与 second_map 插值)
// 光照 = light_map (uv2 采样, HDR RGBAHalf 烘焙)
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D second_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D light_map : filter_linear, repeat_disable;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float blend_second = 0.0;        // 1.0 = 启用顶点色 alpha 混合
uniform float cutoff : hint_range(0.0, 1.0) = 0.35;
uniform float smoothness = 0.23;
uniform float metallic = 0.0;
uniform float ambient_boost = 0.0;       // 额外环境补光(烘焙区域)
uniform bool has_normal_map = false;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

void fragment() {
	vec4 vc = COLOR;
	vec4 base = texture(base_map, UV) * base_color;
	if (blend_second > 0.5) {
		// Source WorldVertexTransition: 顶点色 alpha 作为第二层混合因子
		vec4 second = texture(second_map, UV) * base_color;
		base = mix(base, second, vc.a);
	}
	if (has_normal_map) {
		NORMAL_MAP = texture(normal_map, UV).rgb;
	}
	ALBEDO = base.rgb * vc.rgb;
	METALLIC = metallic;
	ROUGHNESS = 1.0 - smoothness;
	vec3 light = texture(light_map, UV2).rgb;
	ALBEDO *= light;
	ALBEDO += ALBEDO * ambient_boost * max(vec3(0.0), vec3(1.0) - light);
	// cutout alpha 裁剪 (原版 _Cutoff 0.35, 双面)
	if (base.a < cutoff) {
		discard;
	}
}
