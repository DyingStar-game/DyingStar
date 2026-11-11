shader_type spatial;
// Refracting clear crystal: composes what lies behind it from the screen texture, absorbed by its hue, so
// the order of the crystals inside one MultiMesh (never sorted) does not matter. See the include.
render_mode blend_mix, depth_draw_always, cull_back;

#include "res://scenes/planet/cave/cave_crystal.gdshaderinc"

void vertex() {
	v_inner_a = crystal_inner_facet(NORMAL, COLOR, INSTANCE_ID, 1.0, MODELVIEW_NORMAL_MATRIX);
	v_inner_b = crystal_inner_facet(NORMAL, COLOR, INSTANCE_ID, 2.0, MODELVIEW_NORMAL_MATRIX);
}

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
// Offset of the background seen through the crystal (fraction of the screen), the bend of its facets.
uniform float refraction : hint_range(0.0, 0.2, 0.001) = 0.04;

void fragment() {
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 4.0);
	// Grazing rays cross more crystal: deeper colour on the silhouettes.
	float thickness = mix(1.8, 0.6, ndv);
	vec3 behind = textureLod(screen_tex, SCREEN_UV - NORMAL.xy * refraction, 0.0).rgb;
	// A ruby passes only its red: absorbed by its hue taken twice, and a body that keeps some of the light.
	vec3 absorbed = behind * 0.6 * exp(-(vec3(1.0) - crystal_color * crystal_color) * density * thickness);
	v_hue = crystal_color;
	v_glow = crystal_glow_colour(COLOR);
	ALBEDO = crystal_color * 0.04;
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	// No reflection of the environment: in a cave it is the daytime sky (no probe stops it), a grey sheen
	// that hid the rock seen through the crystal. The glints on the facets come from light().
	SPECULAR = 0.0;
	// Underground: the sky's ambient light does not reach the crystals either.
	AO = 0.0;
	AO_LIGHT_AFFECT = 0.0;
	EMISSION = absorbed * (1.0 - fresnel * 0.6) + v_glow * ambient_glow + crystal_color * fresnel * rim_strength;
	ALPHA = 1.0;
}

void light() {
	crystal_light(v_hue, v_glow, ALBEDO, NORMAL, v_inner_a, v_inner_b, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION,
			SPECULAR_AMOUNT, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
