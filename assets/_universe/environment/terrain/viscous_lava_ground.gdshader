shader_type spatial;
render_mode cull_disabled, depth_draw_never;
#include "res://assets/_universe/environment/terrain/viscous_lava_field.gdshaderinc"
#include "res://assets/_universe/environment/terrain/viscous_lava_appearance.gdshaderinc"
uniform mat4 patch_from_view;
uniform bool debug_field = false;
void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.xyz += normalize(-view.xyz) * 0.02;
	POSITION = PROJECTION_MATRIX * view;
}
void fragment() {
	vec3 point = (patch_from_view * vec4(VERTEX, 1.0)).xyz;
	vec2 metres = point.xz;
	vec2 extent = (1.0 / grid_texel - vec2(1.0)) * cell_m;
	if (!debug_field) {
		if (polar_geometry) { if (length(metres) > field_radius) { discard; } }
		else if (any(lessThan(metres, vec2(0.0))) || any(greaterThan(metres, extent))) { discard; }
	}
	vec2 uv = field_coordinates(metres);
	vec4 state = state_at(uv);
	vec4 phase = phase_at(uv);
	if (!debug_field && (abs(point.y - state.a) > 8192.0 || state.r < 0.003 || hash21(floor(metres * 8.0)) >= phase.b)) { discard; }
	vec3 albedo;
	vec3 emission;
	float roughness;
	vec3 normal_map;
	lava_appearance(metres, phase.rg, state.g, state.b, albedo, emission, roughness, normal_map);
	ALBEDO = albedo; EMISSION = emission; ROUGHNESS = roughness; NORMAL_MAP = normal_map;
	if (debug_field) { ALBEDO = vec3(fract(metres.x / 512.0), fract(metres.y / 1024.0), 0.2); EMISSION = ALBEDO; }
}
