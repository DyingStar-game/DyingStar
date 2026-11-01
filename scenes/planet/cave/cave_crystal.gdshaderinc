// Clear corundum crystal of the caves (CaveMineral), shared by cave_crystal.gdshader (refracting, reads the
// screen) and cave_crystal_opaque.gdshader (medium quality). Everything is in view space: no world
// coordinate, so no precision loss at planetary distances.
//
// Per instance (CaveMineral.dress_crystals): the hue the crystal lets through and its fluorescence.
// Mesh (CaveCrystalMesh): COLOR.r = height along the crystal (0 root .. 1 tip), COLOR.g = random per crystal.
//
// UV: the players' UV torch is a NEGATIVE SpotLight3D masked to the fluorescent render layer alone
// (Globals.RENDER_MASK_FLUORESCENT). light() sees it as LIGHT_COLOR < 0 and turns it into fluorescence
// instead of light; no other surface is on that layer, so it darkens nothing.

instance uniform vec3 crystal_color = vec3(1.0, 0.4, 0.31);
instance uniform vec4 glow = vec4(1.0, 0.1, 0.1, 0.5);

// Strength of the fluorescence glowing with no UV at all (HDR emission, x the rock's strength).
uniform float ambient_glow : hint_range(0.0, 4.0, 0.01) = 0.12;
// Gain of the fluorescence under the UV torch (x the rock's strength and the beam's falloff).
uniform float uv_glow : hint_range(0.0, 40.0, 0.1) = 1.5;
// How strongly the crystal's hue absorbs what is seen through it: higher = deeper, darker colour.
uniform float density : hint_range(0.0, 8.0, 0.01) = 1.6;
// Sharpness of the light glinting on the facets, and its strength.
uniform float glint_power : hint_range(8.0, 1024.0, 1.0) = 256.0;
uniform float glint_strength : hint_range(0.0, 20.0, 0.1) = 4.0;
// Light scattered inside the crystal toward the viewer, tinted by its hue (lamp facing the crystal).
uniform float inner_scatter : hint_range(0.0, 2.0, 0.01) = 0.05;
// Light from behind passing through the crystal, tinted by its hue.
uniform float transmission : hint_range(0.0, 4.0, 0.01) = 0.8;
// Bright rim at grazing angles (Fresnel reflection of the cave).
uniform float rim_strength : hint_range(0.0, 2.0, 0.01) = 0.25;

varying vec3 v_hue;
varying vec3 v_glow;

vec3 crystal_glow_colour(vec4 vertex_colour) {
	// Brighter toward the tips, a little different from one crystal to the next.
	return glow.rgb * glow.a * mix(0.35, 1.0, vertex_colour.r) * mix(0.8, 1.2, vertex_colour.g);
}

void crystal_light(vec3 hue, vec3 glow_colour, vec3 albedo, vec3 normal, vec3 view, vec3 light, vec3 light_colour,
		float attenuation, inout vec3 diffuse_light, inout vec3 specular_light) {
	float ndl = dot(normal, light);
	if (light_colour.r < 0.0) {
		// The UV torch: no visible light, it excites the fluorescence. The crystal is translucent, so the
		// back faces fluoresce too, a little less.
		float uv = dot(-light_colour, vec3(1.0 / 3.0));
		specular_light += glow_colour * uv * uv_glow * attenuation * (0.4 + 0.6 * max(ndl, 0.0));
		return;
	}
	// A custom light() gets no albedo applied: the (faint) body colour is ours to multiply.
	diffuse_light += albedo * max(ndl, 0.0) * attenuation * light_colour / PI;
	vec3 half_vector = normalize(view + light);
	float glint = pow(max(dot(normal, half_vector), 0.0), glint_power) * glint_strength;
	specular_light += glint * attenuation * light_colour;
	float through = max(-ndl, 0.0) * 0.5 + pow(max(dot(view, -light), 0.0), 4.0);
	specular_light += hue * attenuation * light_colour / PI
			* (inner_scatter * max(ndl, 0.0) + transmission * through);
}
