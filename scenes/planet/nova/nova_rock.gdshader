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

void vertex() {
	l_pos = VERTEX * length(MODEL_MATRIX[0].xyz);
	if (fade_end_m > 0.0) {
		float away = length((fade_cell - nova_cam_cell) + (fade_rest - nova_cam_rest) + INSTANCE_CUSTOM.xyz);
		VERTEX *= 1.0 - smoothstep(fade_end_m * (1.0 - FADE_BAND), fade_end_m, away);
	}
	l_nrm = NORMAL;
	axis_x = normalize(MODELVIEW_MATRIX[0].xyz);
	axis_y = normalize(MODELVIEW_MATRIX[1].xyz);
	axis_z = normalize(MODELVIEW_MATRIX[2].xyz);
}

void fragment() {
	vec3 w = pow(abs(normalize(l_nrm)), vec3(SHARPNESS));
	w /= w.x + w.y + w.z;
	float s = 1.0 / max(detail_tile_m, 0.05);
	vec3 grain = texture(detail_albedo, l_pos.zy * s).rgb * w.x
			+ texture(detail_albedo, l_pos.xz * s).rgb * w.y
			+ texture(detail_albedo, l_pos.xy * s).rgb * w.z;
	vec3 own = texture(own_albedo, UV).rgb;
	vec3 orm = texture(own_orm, UV).rgb;
	ALBEDO = tint * grain * mix(vec3(1.0), own / OWN_MEAN, own_share);
	AO = orm.r;
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
