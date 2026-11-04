shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// A rock that has landed near the player (StoneField): one shared material, each rock's own heat and
// noise offset in instance uniforms, so a hundred rocks are one material and no per-frame write.

#include "res://assets/_universe/environment/terrain/volcano/rock_surface.gdshaderinc"

instance uniform float heat = 0.0;
instance uniform float rock_seed = 0.0;
instance uniform float rock_radius = 1.0;

varying vec3 v_q;

void vertex() {
	// Metres on the rock: a boulder carries more cracks than a pebble, not bigger ones.
	v_q = VERTEX * pow(rock_radius, 0.7) * 0.5 + vec3(rock_seed);
}

void fragment() {
	vec3 albedo;
	vec3 emission;
	vec3 normal;
	rock_shade(v_q, heat, NORMAL, VERTEX, albedo, emission, normal);
	ALBEDO = albedo;
	EMISSION = emission;
	NORMAL = normal;
	ROUGHNESS = 0.95;
}
