shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Fills the transmittance table read by scatter() (atmosphere_common.gdshaderinc): for each texel, the
// fraction of the starlight that crosses the air from the top of the atmosphere down to a point at
// distance r from the centre, the star at cos(zenith) = mu. Rendered once per atmosphere by
// AtmosphereRenderer into a 256 x 64 half-float SubViewport, so it can afford far more samples than a
// per-pixel loop ever could.
//
// Same constants, same density profiles, same optical_depth() as the pixels that read it: the physics
// still lives in one place.
#include "res://scenes/_universe/environment/atmosphere_common.gdshaderinc"

// Samples along each ray. The per-pixel loop this replaces ran 4 to 12.
uniform int lut_steps = 64;


void fragment() {
	vec2 r_mu = transmittance_lut_r_mu(UV);
	// The point straight "up" the frame's Y axis at distance r; the ray toward a star at angle acos(mu)
	// from that zenith. Only lengths and the angle matter, the air being the same in every direction.
	vec3 origin = planet_center + vec3(0.0, r_mu.x, 0.0);
	vec3 dir = vec3(sqrt(max(1.0 - r_mu.y * r_mu.y, 0.0)), r_mu.y, 0.0);
	float to_top = max(ray_sphere(origin, dir, planet_radius + atmosphere_top).y, 0.0);
	COLOR = vec4(exp(-optical_depth(origin, dir, to_top, lut_steps)), 1.0);
}
