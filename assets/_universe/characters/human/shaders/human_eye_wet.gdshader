// The wet shine of an eye: the tear film over the cornea and the sclera, and the tear line along the lower
// lid. Black and additive -- it adds its highlight and its reflections to what is behind, nothing else --
// so the cornea can stay a hole in the sclera with the iris seen through it.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_back, specular_schlick_ggx, shadows_disabled;

// Roughness of the tear film: lower = sharper catch-light.
uniform float film_roughness : hint_range(0.0, 1.0) = 0.04;
// Strength of the film's reflection, 0..1: 0.35 is water's (2 % head-on; the engine's F0 = 0.16 x this squared).
uniform float film_specular : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	ALBEDO = vec3(0.0);
	ROUGHNESS = film_roughness;
	SPECULAR = film_specular;
}
