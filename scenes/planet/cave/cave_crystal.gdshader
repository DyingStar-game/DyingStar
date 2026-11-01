shader_type spatial;
// Refracting clear crystal: composes what lies behind it from the screen texture, absorbed by its hue, so
// the order of the crystals inside one MultiMesh (never sorted) does not matter. See the include.
render_mode blend_mix, depth_draw_always, cull_back;

#include "res://scenes/planet/cave/cave_crystal.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
// Offset of the background seen through the crystal (fraction of the screen), the bend of its facets.
uniform float refraction : hint_range(0.0, 0.2, 0.001) = 0.04;

void fragment() {
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 4.0);
	// Grazing rays cross more crystal: deeper colour on the silhouettes.
	float thickness = mix(1.8, 0.6, ndv);
	vec3 behind = textureLod(screen_tex, SCREEN_UV - NORMAL.xy * refraction, 0.0).rgb;
	vec3 absorbed = behind * exp(-(vec3(1.0) - crystal_color) * density * thickness);
	v_hue = crystal_color;
	v_glow = crystal_glow_colour(COLOR);
	ALBEDO = crystal_color * 0.04;
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	// No reflection of the environment: in a cave it is the daytime sky (no probe stops it), a grey sheen
	// that hid the rock seen through the crystal. The glints on the facets come from light().
	SPECULAR = 0.0;
	EMISSION = absorbed * (1.0 - fresnel * 0.6) + v_glow * ambient_glow + crystal_color * fresnel * rim_strength;
	ALPHA = 1.0;
}

void light() {
	crystal_light(v_hue, v_glow, ALBEDO, NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
