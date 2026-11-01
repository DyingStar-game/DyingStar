shader_type spatial;
// Opaque stand-in of cave_crystal.gdshader for the medium ground quality: no screen copy, the crystal's
// depth is faked by its dark hue, a Fresnel rim and the light scattered inside it. See the include.
render_mode blend_mix, cull_back;

#include "res://scenes/planet/cave/cave_crystal.gdshaderinc"

void fragment() {
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 4.0);
	v_hue = crystal_color;
	v_glow = crystal_glow_colour(COLOR);
	// A dense gem rather than a matte stone: a dark body in the crystal's hue, bright facet edges.
	ALBEDO = crystal_color * 0.05;
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	// No reflection of the environment: in a cave it is the daytime sky (no probe stops it), a grey sheen
	// that hid the rock seen through the crystal. The glints on the facets come from light().
	SPECULAR = 0.0;
	EMISSION = v_glow * ambient_glow + crystal_color * (fresnel * rim_strength * 2.0 + 0.03 * (1.0 - ndv));
}

void light() {
	crystal_light(v_hue, v_glow, ALBEDO, NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
