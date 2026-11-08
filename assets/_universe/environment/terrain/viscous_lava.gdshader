shader_type spatial;
render_mode cull_disabled;
#include "res://assets/_universe/environment/terrain/viscous_lava_field.gdshaderinc"
#include "res://assets/_universe/environment/terrain/viscous_lava_appearance.gdshaderinc"
varying vec2 field_uv;
void vertex() {
	field_uv = UV2;
	VERTEX.y = surface_at(UV2) + 0.015;
	float dx = surface_at(UV2 + vec2(grid_texel.x, 0.0)) - surface_at(UV2 - vec2(grid_texel.x, 0.0));
	float dz = surface_at(UV2 + vec2(0.0, grid_texel.y)) - surface_at(UV2 - vec2(0.0, grid_texel.y));
	if (polar_geometry) {
		int row = clamp(int(round(UV2.y / grid_texel.y - 0.5)), 0, radial_count - 1);
		float radial_distance = max(1.0, radial_centres[min(row + 1, radial_count - 1)] - radial_centres[max(0, row - 1)]);
		float radius = max(length(UV), radial_centres[0]);
		vec2 radial = vec2(cos(UV2.x * 6.28318530718), sin(UV2.x * 6.28318530718));
		vec2 grad = radial * (dz / radial_distance) + vec2(-radial.y, radial.x) * (dx / max(1.0, 2.0 * radius * 6.28318530718 * grid_texel.x));
		NORMAL = normalize(vec3(-grad.x, 1.0, -grad.y));
	} else { NORMAL = normalize(vec3(-dx, 2.0 * cell_m, -dz)); }
}
void fragment() {
	vec4 state = state_at(field_uv);
	vec4 phase = phase_at(field_uv);
	if (state.r < 0.003 || hash21(floor(UV * 8.0)) >= phase.b) { discard; }
	vec3 albedo;
	vec3 emission;
	float roughness;
	vec3 normal_map;
	lava_appearance(UV, phase.rg, state.g, state.b, albedo, emission, roughness, normal_map);
	ALBEDO = albedo; EMISSION = emission; ROUGHNESS = roughness; NORMAL_MAP = normal_map;
}
