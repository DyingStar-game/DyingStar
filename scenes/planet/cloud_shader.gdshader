// NOTE: Shader automatically converted from Godot Engine 4.5.1.stable.mono.double's StandardMaterial3D.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_disabled, shadows_disabled;

uniform vec4 albedo : source_color;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform ivec2 albedo_texture_size;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform float proximity_fade_distance : hint_range(0.0, 4096.0, 0.01);

uniform float distance_fade_min = 1.0;
uniform float distance_fade_max = 1.0;

varying vec3 uv1_triplanar_pos;
uniform float uv1_blend_sharpness : hint_range(0.0, 150.0, 0.001);
varying vec3 uv1_power_normal;
uniform float uv1_scale;

void vertex() {
	vec3 normal = NORMAL;

	TANGENT = vec3(0.0, 0.0, -1.0) * abs(normal.x);
	TANGENT += vec3(1.0, 0.0, 0.0) * abs(normal.y);
	TANGENT += vec3(1.0, 0.0, 0.0) * abs(normal.z);
	TANGENT = normalize(TANGENT);

	BINORMAL = vec3(0.0, 1.0, 0.0) * abs(normal.x);
	BINORMAL += vec3(0.0, 0.0, -1.0) * abs(normal.y);
	BINORMAL += vec3(0.0, 1.0, 0.0) * abs(normal.z);
	BINORMAL = normalize(BINORMAL);

	vec3 up = NORMAL;
	// UV1 Triplanar: Enabled
	uv1_power_normal = pow(abs(NORMAL), vec3(uv1_blend_sharpness));
	uv1_triplanar_pos = VERTEX * uv1_scale + TIME * 0.5;
	uv1_power_normal /= dot(uv1_power_normal, vec3(1.0));
	uv1_triplanar_pos *= vec3(1.0, -1.0, 1.0);
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
}

void fragment() {
	vec4 albedo_tex = texture(texture_albedo, UV * 10.0 + vec2(TIME * 0.005, 0.0)); //triplanar_texture(texture_albedo, uv1_power_normal, uv1_triplanar_pos * 0.01);
	ALBEDO = albedo.rgb * albedo_tex.rgb;

	ALPHA *= albedo_tex.a * 1.5;

	// Proximity Fade: Enabled
	float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 proximity_view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
	proximity_view_pos.xyz /= proximity_view_pos.w;


	ALPHA *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	ALPHA *= clamp(smoothstep(distance_fade_min, distance_fade_max, length(VERTEX) / 1000.0), 0.0, 1.0);

	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
