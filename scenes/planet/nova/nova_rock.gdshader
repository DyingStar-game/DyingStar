shader_type spatial;
// A textured rock of Nova's scatter (scanned or sculpted model).
//
// A model's own textures are stretched over its whole surface: one or two thousand texels for a block of
// several metres is a smear at arm's length. So the fine grain does not come from the model: the ground's
// rock texture is laid over it by position (three projections, in the model's own space, in metres), sharp
// at any size, and the model's textures give what only they know — its large light and dark (own_share),
// its baked relief (normal map) and its hollows (occlusion).

uniform sampler2D own_albedo : source_color, hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D own_normal : hint_normal, filter_linear_mipmap_anisotropic;
// Occlusion (red), roughness (green).
uniform sampler2D own_orm : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D detail_albedo : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// The rock's colour × the ground's gain.
uniform vec3 tint : source_color = vec3(1.0);
// How much of the model's own base colour modulates the grain: 1 = all of it (a scan), 0 = none.
uniform float own_share = 1.0;
uniform float detail_tile_m = 3.0;
uniform float detail_normal_strength = 1.0;
uniform float roughness_scale = 1.0;

// Mean of a model's grey base colour (linear): dividing by it makes the base colour a modulation around 1.
const float OWN_MEAN = 0.45;
const float SHARPNESS = 8.0;

varying vec3 l_pos;
varying vec3 l_nrm;
varying vec3 axis_x;
varying vec3 axis_y;
varying vec3 axis_z;

// Fade in: a rock grows out of the ground over the last FADE_BAND of the distance it is drawn to, instead of
// being there at once. Growing costs nothing (no transparency, no dither) and its shadow grows with it.
// The distance is taken in the planet's frame, never from world coordinates (single floats in a shader: a
// planet far from the origin would round them by tens of metres). Positions are split in whole cells of
// NovaScatter.FADE_CELL_M and a rest, so the differences are exact: the camera (PlanetTerrain, each frame),
// the chunk's centre (per node), and the rock's place in its chunk (INSTANCE_CUSTOM).
global uniform vec3 nova_cam_cell;
global uniform vec3 nova_cam_rest;
instance uniform vec3 fade_cell;
instance uniform vec3 fade_rest;
// How far the node's objects are drawn, 0 = no fade.
instance uniform float fade_end_m = 0.0;
const float FADE_BAND = 0.2;

// Ground fringe: the foot of the rock takes on the look of the ground it rests on, so the meeting line stops
// reading as a cut (TerrainBlend does the same for placed objects, with a node each; a rock has none). Set per
// material by NovaScatter.rock_material from NovaBody.ground_look: the same textures, tiles, gains, strength,
// contrast and occlusion as the ground shader's Nova loop for this variant. The band climbs from the ground
// (model height fringe_ground_y) over fringe_ratio of the rock's height above it, at most fringe_max_m metres.
uniform bool fringe_on = false;
uniform float fringe_ground_y = 0.0;
uniform float fringe_top_y = 1.0;
uniform float fringe_ratio = 0.3;
uniform float fringe_max_m = 0.9;
// Past fringe_far metres from the camera the band is gone (faded from 2/3 of it): nothing to see at that size.
uniform float fringe_far = 150.0;
uniform float fringe_opacity = 0.85;
uniform float fringe_curve = 1.6;
// The ground's materials: its first, its second and third (the patches of gravel, regolith...) where it has them.
uniform sampler2D ground_albedo_0 : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_albedo_1 : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_albedo_2 : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Per material: tiling (per metre, snapped like the ground's), gain, share of the ground and size of its patches
// (per metre), the noise offset of its patches (the shader's k), occlusion's mean darkening, mean colour (linear).
uniform vec3 ground_scale = vec3(0.1);
uniform vec3 ground_gain = vec3(1.0);
uniform vec3 ground_share = vec3(1.0, 0.0, 0.0);
uniform vec3 ground_patch_scale = vec3(0.0);
uniform vec3 ground_offset_k = vec3(0.0, 0.0, 1.0);
uniform vec3 ground_ao = vec3(1.0);
uniform vec3 ground_mean_0 = vec3(0.5);
uniform vec3 ground_mean_1 = vec3(0.5);
uniform vec3 ground_mean_2 = vec3(0.5);
// The first material's close-up tile (per metre, 0 = none), whole up to .x metres from the camera, gone by .y.
uniform float ground_fine_scale = 0.0;
uniform vec2 ground_fine_range = vec2(15.0, 54.0);
uniform float ground_strength = 1.0;
uniform float ground_contrast = 1.0;
// Large-scale light and dark: strength, scale (per metre).
uniform vec2 ground_macro = vec2(0.0, 0.0025);
// The colour the ground shader starts from (biome colour x albedo multiplier), raw numbers like a vertex colour.
uniform vec3 ground_tint = vec3(0.3);
// The ground shader's tiling grid (WRAP in terrain_biome.gdshaderinc): its patterns repeat on that period.
const float WRAP = 8192.0;

// Ground fringe: height over the ground (m), the band's height (m, 0 = none), and the share of each of the
// ground's materials at the rock's place (xyz) with its large-scale light and dark (w). One rock, one answer.
varying float fringe_h;
varying flat float fringe_band;
varying flat vec4 fringe_w;

// The ground shader's nova_hash and nova_noise (terrain_biome.gdshaderinc): the same patches at the same place.
float g_hash(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float g_noise(vec3 x, float period) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(g_hash(mod(i, period)), g_hash(mod(i + vec3(1, 0, 0), period)), f.x),
			mix(g_hash(mod(i + vec3(0, 1, 0), period)), g_hash(mod(i + vec3(1, 1, 0), period)), f.x), f.y),
			mix(mix(g_hash(mod(i + vec3(0, 0, 1), period)), g_hash(mod(i + vec3(1, 0, 1), period)), f.x),
			mix(g_hash(mod(i + vec3(0, 1, 1), period)), g_hash(mod(i + vec3(1, 1, 1), period)), f.x), f.y), f.z);
}

// How much of the patches of a material (share sh, patch scale sp, offset k) covers point p: the ground shader's
// rule without the ground's own heights.
float g_over(vec3 p, float sh, float sp, float k) {
	if (sh <= 0.0) {
		return 0.0;
	}
	vec3 off = vec3(17.0, 31.0, 5.0) * k;
	float where = g_noise(p * sp + off, WRAP * sp) * 0.65 + g_noise(p * sp * 2.0 + off, WRAP * sp * 2.0) * 0.35;
	where = clamp((where - 0.5) * 1.8 + 0.5, 0.0, 1.0);
	return smoothstep(1.0 - sh - 0.07, 1.0 - sh + 0.07, where);
}

void vertex() {
	float sc = length(MODEL_MATRIX[0].xyz);
	l_pos = VERTEX * sc;
	float away = length((fade_cell - nova_cam_cell) + (fade_rest - nova_cam_rest) + INSTANCE_CUSTOM.xyz);
	fringe_h = 0.0;
	fringe_band = 0.0;
	fringe_w = vec4(1.0, 0.0, 0.0, 1.0);
	if (fringe_on && away < fringe_far + 50.0) {
		fringe_h = (VERTEX.y - fringe_ground_y) * sc;
		fringe_band = min(fringe_max_m, fringe_ratio * max(fringe_top_y - fringe_ground_y, 0.0) * sc);
		// The rock's place where the ground reads its patterns: the chunk's centre (whole cells, wrapped exactly,
		// and a rest) and the rock's place in the chunk -- the ground's own chunk_origin_mod + vertex.
		vec3 at = mod(fade_cell, WRAP) + fade_rest + INSTANCE_CUSTOM.xyz;
		float o1 = g_over(at, ground_share.y, ground_patch_scale.y, ground_offset_k.y);
		float o2 = g_over(at, ground_share.z, ground_patch_scale.z, ground_offset_k.z);
		vec3 w = vec3(1.0 - o1, o1, 0.0);
		w = vec3(w.xy * (1.0 - o2), o2);
		float m = 1.0;
		if (ground_macro.x > 0.0) {
			float sm = ground_macro.y;
			m = 1.0 + (g_noise(at * sm, WRAP * sm) * 0.65 + g_noise(at * sm * 2.0, WRAP * sm * 2.0) * 0.35 - 0.5)
					* 2.0 * ground_macro.x;
		}
		fringe_w = vec4(w, m);
	}
	if (fade_end_m > 0.0) {
		VERTEX *= 1.0 - smoothstep(fade_end_m * (1.0 - FADE_BAND), fade_end_m, away);
	}
	l_nrm = NORMAL;
	axis_x = normalize(MODELVIEW_MATRIX[0].xyz);
	axis_y = normalize(MODELVIEW_MATRIX[1].xyz);
	axis_z = normalize(MODELVIEW_MATRIX[2].xyz);
}

vec3 tri_read(sampler2D tex, vec3 p, vec3 w, float s) {
	return texture(tex, p.zy * s).rgb * w.x + texture(tex, p.xz * s).rgb * w.y + texture(tex, p.xy * s).rgb * w.z;
}

// One of the ground's materials as the ground shader colours it: contrast round its mean, then
// mix(1, texture × gain, strength), times its occlusion's mean darkening.
vec3 ground_layer(vec3 tex, vec3 mean, float gain, float ao) {
	if (abs(ground_contrast - 1.0) > 0.001) {
		tex = max(mean + (tex - mean) * ground_contrast, vec3(0.0));
	}
	return mix(vec3(1.0), tex * gain, ground_strength) * ao;
}

void fragment() {
	vec3 w = pow(abs(normalize(l_nrm)), vec3(SHARPNESS));
	w /= w.x + w.y + w.z;
	float s = 1.0 / max(detail_tile_m, 0.05);
	vec3 grain = tri_read(detail_albedo, l_pos, w, s);
	vec3 own = texture(own_albedo, UV).rgb;
	vec3 orm = texture(own_orm, UV).rgb;
	ALBEDO = tint * grain * mix(vec3(1.0), own / OWN_MEAN, own_share);
	AO = orm.r;
	// The foot of the rock in the ground's look. The conditions hold for a whole rock (a uniform and a flat
	// varying): the reads below keep their implicit derivatives.
	if (fringe_on && fringe_band > 0.0) {
		// The band rises and falls along the rock (a slow noise over its surface, ±35 %) instead of a ruled line.
		float n = g_noise(l_pos * 1.3, 4096.0);
		float h_eff = max(fringe_band * (0.65 + 0.7 * n), 0.001);
		float t = clamp(1.0 - fringe_h / h_eff, 0.0, 1.0);
		float a = pow(t, fringe_curve) * fringe_opacity
				* (1.0 - smoothstep(fringe_far * 0.67, fringe_far, length(VERTEX)));
		vec3 g = vec3(0.0);
		if (fringe_w.x > 0.01) {
			vec3 t0 = tri_read(ground_albedo_0, l_pos, w, ground_scale.x);
			if (ground_fine_scale > 0.0) {
				float fine = 1.0 - smoothstep(ground_fine_range.x, ground_fine_range.y, length(VERTEX));
				t0 = mix(t0, tri_read(ground_albedo_0, l_pos, w, ground_fine_scale), fine);
			}
			g += ground_layer(t0, ground_mean_0, ground_gain.x, ground_ao.x) * fringe_w.x;
		}
		if (fringe_w.y > 0.01) {
			g += ground_layer(tri_read(ground_albedo_1, l_pos, w, ground_scale.y), ground_mean_1, ground_gain.y,
					ground_ao.y) * fringe_w.y;
		}
		if (fringe_w.z > 0.01) {
			g += ground_layer(tri_read(ground_albedo_2, l_pos, w, ground_scale.z), ground_mean_2, ground_gain.z,
					ground_ao.z) * fringe_w.z;
		}
		ALBEDO = mix(ALBEDO, clamp(ground_tint * fringe_w.w * g, vec3(0.0), vec3(1.0)), a);
		AO = mix(AO, 1.0, a);  // the ground's own occlusion is in g
	}
	AO_LIGHT_AFFECT = 0.5;
	ROUGHNESS = clamp(orm.g * roughness_scale, 0.04, 1.0);
	METALLIC = 0.0;
	// The model's baked relief, then the grain's relief over it (its three projections, turned from the
	// model's axes to the view's).
	vec2 nm = texture(own_normal, UV).rg * 2.0 - 1.0;
	vec3 n = normalize(TANGENT * nm.x + BINORMAL * nm.y + NORMAL * sqrt(max(1.0 - dot(nm, nm), 0.0)));
	vec2 dx = texture(detail_normal, l_pos.zy * s).rg * 2.0 - 1.0;
	vec2 dy = texture(detail_normal, l_pos.xz * s).rg * 2.0 - 1.0;
	vec2 dz = texture(detail_normal, l_pos.xy * s).rg * 2.0 - 1.0;
	vec3 d = vec3(0.0, dx.y, dx.x) * w.x + vec3(dy.x, 0.0, dy.y) * w.y + vec3(dz.x, dz.y, 0.0) * w.z;
	NORMAL = normalize(n + (axis_x * d.x + axis_y * d.y + axis_z * d.z) * detail_normal_strength);
}
