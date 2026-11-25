shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled, fog_disabled;

// Halo of an erupting vent (VolcanoVentGlow): a sphere that glows towards its centre as seen from the
// eye, so it needs no billboard (no world matrix maths, safe at astronomic coordinates). Additive and
// depth tested: the crater rim hides its lower part, as it hides the vent. This is the only "bloom" of
// the eruption: the rest of the frame keeps its own brightness.

uniform float intensity = 1.0;
uniform vec3 core_color = vec3(2.6, 1.15, 0.35);
uniform vec3 halo_color = vec3(1.0, 0.33, 0.07);

void fragment() {
	// 1 where the ray passes through the centre, 0 on the silhouette.
	float c = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float core = pow(c, 10.0);
	float halo = pow(c, 2.2) * (1.0 - c * 0.5);
	ALBEDO = (core_color * core + halo_color * halo * 0.35) * intensity;
}
