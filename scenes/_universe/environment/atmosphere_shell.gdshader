shader_type spatial;
// The air of a FAR body, seen from outside it (AtmosphereLod, level SHELL): a sphere as big as the top
// of its air, around it, adding the light the air scatters toward the camera along every ray that
// grazes the body without meeting its ground — its limb. The disc itself is the terrain shader's
// (far_air: the column of air over the ground), so those rays are left to it.
//
// The same single scattering as the sky the player lives under: scatter() of atmosphere_common, fed
// with this body's profile by AtmosphereLod — right for the thin grazing paths of a limb. Its uniforms
// are this shell's own (one material per body): planet_center camera-relative, world-oriented,
// recomputed in float64 every frame on the CPU.
//
// Back faces only (cull_front): one surface per pixel, the far half of the shell, which stays
// behind anything in front of the body and needs no camera inside it — inside, the body's air is
// the player's own and AtmosphereRenderer draws it (level OWN). Added onto what is behind (space).
render_mode unshaded, blend_add, depth_draw_never, cull_front, fog_disabled, shadows_disabled;

#include "res://scenes/_universe/environment/atmosphere_common.gdshaderinc"

void fragment() {
	// World-oriented direction of this pixel's ray, the frame planet_center and to_star are in.
	vec3 dir = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	if (ray_sphere(vec3(0.0), dir, planet_radius).x > 0.0) {
		discard;  // the ray meets the ground: the disc is the terrain's
	}
	vec3 view_transmittance;
	ALBEDO = scatter(vec3(0.0), dir, 1.0e30, view_steps, light_steps, view_transmittance);
}
