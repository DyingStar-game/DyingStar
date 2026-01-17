shader_type spatial;
render_mode cull_disabled, depth_draw_always, diffuse_burley;

// Ocean water shader — adapted from taillight-games pixelated water shader:
//   https://github.com/taillight-games/godot-4-pixelated-water-shader
// MIT License
//
// Adapted for spherical planet ocean surfaces:
//   - Vertex NORMAL = sphere direction (set by PlanetChunk mesh gen)
//   - UVs derived from spherical lon/lat instead of world XZ plane
//   - Isotropic two-direction wave animation (no directional flow)
//   - Wave-crest procedural foam (no SubViewport mask required)

// ── Wave parameters ───────────────────────────────────────────
group_uniforms Waves;
uniform float wave_speed : hint_range(0.0, 0.5, 0.001) = 0.08;
uniform float height_scale : hint_range(0.0, 20.0, 0.01) = 1.0;
uniform float amplitude1 : hint_range(0.0, 5.0, 0.1) = 2.0;
uniform float amplitude2 : hint_range(0.0, 5.0, 0.1) = 0.5;
uniform sampler2D vertex_noise_big : repeat_enable;
uniform sampler2D vertex_noise_big2 : repeat_enable;
uniform int v_noise_tile : hint_range(1, 300, 1) = 200;
uniform float v_normal_scale : hint_range(0.0, 5.0, 0.1) = 1.0;

// ── Surface colours ───────────────────────────────────────────
group_uniforms Surface;
uniform vec3 surface_albedo : source_color = vec3(0.04, 0.18, 0.38);
uniform vec3 high_color : source_color = vec3(0.20, 0.42, 0.60);
uniform vec3 low_color : source_color = vec3(0.01, 0.08, 0.20);
uniform float wave_color_range : hint_range(0.1, 5.0, 0.1) = 2.0;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.35;

// ── Depth fade / transparency ─────────────────────────────────
group_uniforms Depth;
uniform float opacity : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float edge_fade_power : hint_range(0.5, 10.0, 0.1) = 2.0;
uniform float depth_fade_distance : hint_range(0.1, 200.0, 0.1) = 12.0;
uniform float transmittence : hint_range(0.0, 0.5, 0.01) = 0.04;
uniform vec3 transmit_color : source_color = vec3(0.0, 0.05, 0.15);

// ── Foam ──────────────────────────────────────────────────────
group_uniforms Foam;
uniform vec3 foam_color : source_color = vec3(0.88, 0.93, 0.97);
// Threshold in wave_crest units (~[-0.5, 2.0] for default amplitude1=2.0, amplitude2=0.5).
uniform float foam_threshold : hint_range(-1.0, 3.0, 0.01) = 1.5;
uniform float foam_intensity : hint_range(0.0, 2.0, 0.01) = 1.0;

// ── Normal map ────────────────────────────────────────────────
group_uniforms Normals;
uniform sampler2D normal_noise : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_noise2 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_noise_size : hint_range(0.1, 20.0, 0.01) = 5.12;
uniform float normal_noise_speed : hint_range(0.0, 0.5, 0.001) = 0.05;

// ── Planet / projection ───────────────────────────────────────
group_uniforms Planet;
// Set by PlanetChunk at runtime to the average water radius.
uniform float planet_radius = 1000.0;
uniform float water_level_offset = 0.0;
// Controls the spatial density of wave tiling on the sphere surface.
uniform float uv_scale : hint_range(1.0, 500.0, 1.0) = 80.0;

// ── Screen textures (under-water refraction) ──────────────────
uniform sampler2D screen_texture : hint_screen_texture;
uniform sampler2D depth_texture : hint_depth_texture;
uniform sampler2D wobble_noise : filter_linear_mipmap, repeat_enable;
uniform float wobble_power : hint_range(0.0, 0.05, 0.001) = 0.008;

// ── Varyings ──────────────────────────────────────────────────
varying vec3 sphere_dir;
varying vec3 wave_color;
varying vec2 surface_uv;
// Raw wave function output (before height_scale), for foam threshold comparisons.
// With default amplitude1=2.0, amplitude2=0.5 this is in approximately [-0.5, 2.0].
varying float wave_crest;

// ── Helpers ───────────────────────────────────────────────────

float remap(float in_low, float in_high, float out_low, float out_high, float value) {
	return out_low + (value - in_low) * (out_high - out_low) / (in_high - in_low);
}

// Map a sphere direction to lon/lat UV tiled by uv_scale.
vec2 dir_to_uv(vec3 dir, float scale) {
	float lon = atan(dir.z, dir.x);
	float lat = asin(clamp(dir.y, -1.0, 1.0));
	return vec2(lon, lat) * scale;
}

// Scrolling UV for texture animation.
// Two orthogonal offsets so the ocean animates isotropically.
vec2 scrolled_uv(vec2 uv, float speed, bool flipped) {
	float t = TIME * speed;
	if (!flipped) {
		uv += vec2(t * 0.3, t * 0.3);
	} else {
		uv -= vec2(t * 0.2, 0.0);
	}
	return uv;
}

// Map tiled world coordinates to a [0,1] noise UV and advance by TIME.
// Two animations run in slightly orthogonal directions for natural ocean look.
vec2 g_v(vec2 v, bool flipped) {
	float f_v_n_t = float(v_noise_tile);
	v.x = mod(v.x, f_v_n_t);
	v.y = mod(v.y, f_v_n_t);
	vec2 mapped = vec2(remap(0.0, f_v_n_t, 0.0, 1.0, v.x),
	                    remap(0.0, f_v_n_t, 0.0, 1.0, v.y));
	if (flipped) {
		mapped.y -= TIME * wave_speed;
		mapped.x -= TIME * wave_speed * 0.3;
	} else {
		mapped.x += TIME * wave_speed;
		mapped.y += TIME * wave_speed * 0.3;
	}
	mapped.x = mod(mapped.x, 1.0);
	return mapped;
}

// Wave height from two noise textures.
// Returns s in approximately [-height_scale/2, amplitude1+amplitude2-height_scale/2].
// With defaults (amplitude1=2.0, amplitude2=0.5, height_scale=1.0): s ∈ [-0.5, 2.0].
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
	// NORMAL contains the sphere direction (outward unit vector at this vertex).
	sphere_dir = normalize(NORMAL);

	// Lon/lat UV for wave sampling — scale-independent of planet radius.
	vec2 base_uv = dir_to_uv(sphere_dir, uv_scale);
	surface_uv = base_uv;

	// Evaluate wave height.
	float s = wave(base_uv);
	wave_crest = s;              // raw, used by foam in fragment/light
	float h = s * height_scale;  // actual displacement (metres with height_scale=1.0)
	VERTEX += sphere_dir * h;

	// Wave colour gradient: high waves lighter, low waves darker.
	float color_mix = remap(-wave_color_range, wave_color_range, 0.0, 1.0, h);
	color_mix = clamp(color_mix, 0.0, 1.0);
	wave_color = mix(low_color, high_color, color_mix);

	// Vertex-displaced normal via finite differences.
	vec2 e = vec2(0.1, 0.0);
	float v_scale = height_scale * v_normal_scale;
	vec3 wave_normal = normalize(vec3(
		wave(base_uv - e) * v_scale - wave(base_uv + e) * v_scale,
		2.0 * e.x,
		wave(base_uv - e.yx) * v_scale - wave(base_uv + e.yx) * v_scale
	));
	// Blend displaced normal back onto the sphere surface normal.
	vec3 tangent_lon = normalize(vec3(-sphere_dir.z, 0.0, sphere_dir.x));
	vec3 tangent_lat = cross(sphere_dir, tangent_lon);
	NORMAL = normalize(
		sphere_dir + tangent_lon * wave_normal.x + tangent_lat * wave_normal.z
	);
}

// ── Fragment ──────────────────────────────────────────────────
void fragment() {
	ROUGHNESS = roughness;

	// Under-water screen refraction via wobble noise.
	vec2 wobble_uv = texture(wobble_noise,
		scrolled_uv(surface_uv * 0.1, normal_noise_speed, false)).xy * wobble_power;
	wobble_uv -= wobble_power * 0.86;

	vec3 under = texture(screen_texture, SCREEN_UV + wobble_uv).rgb;

	// Depth-based fade from depth buffer.
	float raw_depth = texture(depth_texture, SCREEN_UV + wobble_uv).x;
	vec3 ndc = vec3(SCREEN_UV + wobble_uv, raw_depth) * 2.0 - 1.0;
	vec4 world4 = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 world_pos = world4.xyz / world4.w;
	float vertex_y = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y;
	float dist = abs(world_pos.y - vertex_y);

	// Depth colour: deeper = surface_albedo, shallower = wave_color.
	float depth_blend = exp(-dist / depth_fade_distance);
	depth_blend = clamp(depth_blend, 0.0, 1.0);

	// Transparency increases with depth below surface.
	float alpha_blend = clamp(1.0 - exp(-dist * transmittence), 0.0, 1.0);

	vec3 deep = mix(wave_color, surface_albedo, depth_blend);

	// Dual scrolling normal maps for fine ripple detail.
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

	// Wave-crest foam: brightens the peaks of high waves.
	float foam_power = smoothstep(foam_threshold, foam_threshold + 0.2, wave_crest)
		* foam_intensity;
	foam_power = clamp(foam_power, 0.0, 1.0);
	albedo = mix(albedo, foam_color, foam_power);

	ALBEDO = albedo;
	ALPHA = opacity;
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

	// Suppress specular on foam and tint diffuse with foam colour.
	float foam_p = clamp(
		smoothstep(foam_threshold, foam_threshold + 0.2, wave_crest) * foam_intensity,
		0.0, 1.0);
	SPECULAR_LIGHT = mix(SPECULAR_LIGHT, vec3(0.0), foam_p);
	DIFFUSE_LIGHT = mix(DIFFUSE_LIGHT, foam_color * LIGHT_COLOR.rgb * ATTENUATION, foam_p);
}