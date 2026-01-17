shader_type spatial;
render_mode cull_disabled, depth_draw_always, diffuse_burley;

// River water shader — adapted from taillight-games pixelated water shader.
// MIT License — original: https://github.com/taillight-games/godot-4-pixelated-water-shader
//
// Adapted for spherical planet terrain:
//   - Vertex COLOR.r = cross_t (0 = center of river, 1 = edge)
//   - Vertex COLOR.g = along_t (0 = upstream / start, 1 = downstream / end)
//   - UVs derived from spherical direction instead of world XZ plane
//   - Procedural edge foam from cross_t instead of SubViewport mask

// ── Wave parameters ───────────────────────────────────────────
group_uniforms Waves;
uniform float wave_speed : hint_range(0.0, 0.5, 0.001) = 0.05;
uniform float height_scale : hint_range(0.0, 5.0, 0.01) = 0.6;
uniform float amplitude1 : hint_range(0.0, 5.0, 0.1) = 2.0;
uniform float amplitude2 : hint_range(0.0, 5.0, 0.1) = 0.5;
uniform sampler2D vertex_noise_big : repeat_enable;
uniform sampler2D vertex_noise_big2 : repeat_enable;
uniform int v_noise_tile : hint_range(1, 300, 1) = 200;
uniform float v_normal_scale : hint_range(0.0, 5.0, 0.1) = 1.0;

// ── Flow ──────────────────────────────────────────────────────
group_uniforms Flow;
uniform vec2 flow_dir = vec2(0.0, 0.0);
uniform float flow_speed : hint_range(0.0, 5.0, 0.01) = 1.0;

// ── Surface colours ──────────────────────────────────────────
group_uniforms Surface;
uniform vec3 surface_albedo : source_color = vec3(0.04, 0.18, 0.35);
uniform vec3 high_color : source_color = vec3(0.25, 0.45, 0.60);
uniform vec3 low_color : source_color = vec3(0.02, 0.10, 0.22);
uniform float wave_color_range : hint_range(0.1, 5.0, 0.1) = 2.0;
uniform vec3 sky_color : source_color = vec3(0.6, 0.7, 0.8);
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.35;

// ── Depth fade / transparency ─────────────────────────────────
group_uniforms Depth;
uniform float opacity : hint_range(0.0, 1.0, 0.01) = 0.65;
uniform float edge_fade_power : hint_range(0.5, 10.0, 0.1) = 2.0;
uniform float depth_fade_distance : hint_range(0.1, 100.0, 0.1) = 5.0;
uniform float transmittence : hint_range(0.0, 0.5, 0.01) = 0.04;
uniform vec3 transmit_color : source_color = vec3(0.0, 0.1, 0.15);

// ── Foam ──────────────────────────────────────────────────────
group_uniforms Foam;
uniform vec3 foam_color : source_color = vec3(0.92, 0.95, 1.0);
uniform float foam_edge_start : hint_range(0.3, 1.0, 0.01) = 0.85;
uniform float foam_intensity : hint_range(0.0, 2.0, 0.01) = 0.7;

// ── Normal map ────────────────────────────────────────────────
group_uniforms Normals;
uniform sampler2D normal_noise : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_noise2 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_noise_size : hint_range(0.1, 20.0, 0.01) = 5.12;
uniform float normal_noise_speed : hint_range(0.0, 0.5, 0.001) = 0.05;

// ── Planet / projection ───────────────────────────────────────
group_uniforms Planet;
uniform float planet_radius = 1000.0;
uniform float water_level_offset = 0.0;
uniform float uv_scale : hint_range(1.0, 500.0, 1.0) = 150.0;

// ── Screen textures (for under-water refraction) ──────────────
uniform sampler2D screen_texture : hint_screen_texture;
uniform sampler2D depth_texture : hint_depth_texture;
uniform sampler2D wobble_noise : filter_linear_mipmap, repeat_enable;
uniform float wobble_power : hint_range(0.0, 0.05, 0.001) = 0.008;

// ── Varyings ──────────────────────────────────────────────────
varying vec3 sphere_dir;
varying float cross_t;    // 0 = center, 1 = edge
varying float along_t;    // 0 = upstream, 1 = downstream
varying vec3 wave_color;
varying vec2 surface_uv;
varying float foam_wave;

// ── Helpers ───────────────────────────────────────────────────

float remap(float in_low, float in_high, float out_low, float out_high, float value) {
	return out_low + (value - in_low) * (out_high - out_low) / (in_high - in_low);
}

// Map a direction vector to lon/lat UV, then tile and scroll.
vec2 dir_to_uv(vec3 dir, float scale) {
	float lon = atan(dir.z, dir.x);
	float lat = asin(clamp(dir.y, -1.0, 1.0));
	return vec2(lon, lat) * scale;
}

vec2 scrolled_uv(vec2 uv, float speed, bool flipped) {
	float t = TIME * speed;
	vec2 fd = normalize(flow_dir + vec2(0.001)) * flow_speed;
	if (!flipped) {
		uv += fd * t * 0.15 + vec2(t * 0.3, t * 0.3);
	} else {
		uv -= fd * t * 0.1 + vec2(t * 0.2, 0.0);
	}
	return uv;
}

// Wave height from two noise textures (taillight-style).
vec2 g_v(vec2 v, bool flipped) {
	float f_v_n_t = float(v_noise_tile);
	v.x = mod(v.x, f_v_n_t);
	v.y = mod(v.y, f_v_n_t);
	vec2 mapped = vec2(remap(0.0, f_v_n_t, 0.0, 1.0, v.x),
	                    remap(0.0, f_v_n_t, 0.0, 1.0, v.y));
	vec2 fd = normalize(flow_dir + vec2(0.001)) * flow_speed;
	if (flipped) {
		mapped -= fd * TIME * wave_speed * 0.5;
		mapped.y -= TIME * wave_speed;
	} else {
		mapped += fd * TIME * wave_speed * 0.5;
		mapped.x += TIME * wave_speed;
	}
	mapped.x = mod(mapped.x, 1.0);
	return mapped;
}

float wave(vec2 pos) {
	vec2 y1 = g_v(pos, false);
	vec2 y2 = g_v(pos + vec2(0.3, 0.476), true);
	float s = 0.0;
	s += texture(vertex_noise_big, mod(y1, float(v_noise_tile))).r * amplitude1;
	s += texture(vertex_noise_big2, mod(y2, float(v_noise_tile))).r * amplitude2;
	s -= height_scale / 2.0;
	return s;
}

// ── Vertex ────────────────────────────────────────────────────
void vertex() {
	sphere_dir = normalize(NORMAL);
	cross_t = COLOR.r;
	along_t = COLOR.g;

	// Spherical UV for wave sampling.
	vec2 base_uv = dir_to_uv(sphere_dir, uv_scale);
	surface_uv = base_uv;

	// Vertex wave displacement along surface normal.
	float h = wave(base_uv) * height_scale;
	// Reduce wave height at river edges for smooth bank transition.
	float edge_atten = 1.0 - smoothstep(0.6, 1.0, cross_t);
	h *= edge_atten;
	VERTEX += sphere_dir * h;

	// Wave color gradient (taillight-style: low ↔ high based on wave height).
	float color_mix = remap(-wave_color_range, wave_color_range, 0.0, 1.0, h);
	color_mix = clamp(color_mix, 0.0, 1.0);
	wave_color = mix(low_color, high_color, color_mix);

	// Compute vertex-displaced normal via finite differences.
	vec2 e = vec2(0.1, 0.0);
	float v_scale = height_scale * v_normal_scale;
	vec3 wave_normal = normalize(vec3(
		wave(base_uv - e) * v_scale - wave(base_uv + e) * v_scale,
		2.0 * e.x,
		wave(base_uv - e.yx) * v_scale - wave(base_uv + e.yx) * v_scale
	));
	// Blend wave normal with sphere normal.
	vec3 tangent_lon = normalize(vec3(-sphere_dir.z, 0.0, sphere_dir.x));
	vec3 tangent_lat = cross(sphere_dir, tangent_lon);
	NORMAL = normalize(
		sphere_dir + tangent_lon * wave_normal.x + tangent_lat * wave_normal.z
	);

	// Pre-compute edge foam noise.
	foam_wave = wave(base_uv * 3.0 + vec2(TIME * 0.02)) * 0.5 + 0.5;
}

// ── Fragment ──────────────────────────────────────────────────
void fragment() {
	ROUGHNESS = roughness;

	// Under-water wobble (screen refraction).
	vec2 wobble_uv = texture(wobble_noise,
		scrolled_uv(surface_uv * 0.1, normal_noise_speed, false)).xy * wobble_power;
	wobble_uv -= wobble_power * 0.86;

	vec3 under = texture(screen_texture, SCREEN_UV + wobble_uv).rgb;

	// Depth from depth buffer.
	float raw_depth = texture(depth_texture, SCREEN_UV + wobble_uv).x;
	vec3 ndc = vec3(SCREEN_UV + wobble_uv, raw_depth) * 2.0 - 1.0;
	vec4 world4 = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 world_pos = world4.xyz / world4.w;
	float vertex_y = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y;
	float dist = abs(world_pos.y - vertex_y);

	// Depth fade: objects become less visible with depth.
	float depth_blend = exp(-dist / depth_fade_distance);
	depth_blend = clamp(depth_blend, 0.0, 1.0);

	// Alpha from depth.
	float alpha_blend = clamp(1.0 - exp(-dist * transmittence), 0.0, 1.0);

	// Base colour: blend wave_color → surface_albedo with depth.
	vec3 deep = mix(wave_color, surface_albedo, depth_blend);

	// Normal maps — two scrolling layers blended.
	vec2 rounded_uv = surface_uv * (1.0 / normal_noise_size) * 0.1;
	vec3 n_map1 = texture(normal_noise,
		scrolled_uv(rounded_uv, normal_noise_speed, false)).xyz;
	vec3 n_map2 = texture(normal_noise2,
		scrolled_uv(rounded_uv, normal_noise_speed, true)).xyz;
	NORMAL_MAP = mix(n_map1, n_map2, 0.5);

	vec3 albedo;
	if (FRONT_FACING) {
		albedo = mix(under + transmit_color, deep,
			remap(0.0, opacity, 0.1, 0.8, pow(alpha_blend, edge_fade_power)));
	} else {
		NORMAL = -NORMAL;
		albedo = mix(texture(screen_texture, SCREEN_UV + wobble_uv).rgb,
			surface_albedo, 0.5);
	}

	// Edge fade based on cross_t (river bank transparency).
	float edge_alpha = 1.0 - smoothstep(0.85, 1.0, cross_t);

	// Procedural edge foam where cross_t approaches the bank.
	float foam_t = smoothstep(foam_edge_start, 1.0, cross_t);
	foam_t *= foam_wave * foam_intensity;
	albedo = mix(albedo, foam_color, clamp(foam_t, 0.0, 1.0));

	ALBEDO = albedo;
	ALPHA = opacity * edge_alpha;
}

// ── Toon lighting (from taillight-games) ──────────────────────
group_uniforms Lighting;
uniform float shine_strength : hint_range(0.0, 1.0) = 0.17;
uniform float shine_shininess : hint_range(0.0, 32.0) = 18.0;
uniform float shadow_val : hint_range(0.0, 1.0) = 0.72;
uniform float shadow_width : hint_range(0.001, 0.5) = 0.18;
uniform vec4 shadow_color : source_color = vec4(0.705, 0.705, 0.705, 1.0);
uniform float specular_smoothness : hint_range(0.0, 0.5) = 0.199;
uniform float specular_strength : hint_range(0.0, 9.25) = 0.075;
uniform float glossiness : hint_range(0.0, 0.5) = 0.067;

void light() {
	vec3 H = normalize(VIEW + LIGHT);
	float NdotH = dot(NORMAL, H);
	float specular_amount = max(pow(NdotH, shine_shininess * shine_shininess), 0.0)
		* ATTENUATION;
	SPECULAR_LIGHT += shine_strength * specular_amount * LIGHT_COLOR;

	float NdotL = dot(NORMAL, LIGHT) * ATTENUATION;
	NdotL = smoothstep(shadow_val - shadow_width, shadow_val + shadow_width, NdotL);

	float specular_intensity = pow(NdotH, 1.0 / glossiness);
	vec3 specular = vec3(smoothstep(0.5 - specular_smoothness,
		0.5 + specular_smoothness, specular_intensity));

	DIFFUSE_LIGHT += ATTENUATION * mix(
		ALBEDO * shadow_color.rgb,
		(ALBEDO + specular * specular_strength) * LIGHT_COLOR.rgb * 0.33,
		NdotL + 0.33
	);
}

