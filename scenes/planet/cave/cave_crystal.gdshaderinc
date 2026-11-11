// Clear corundum crystal of the caves (CaveMineral), shared by cave_crystal.gdshader (refracting, reads the
// screen) and cave_crystal_opaque.gdshader (medium quality). Everything is in view space: no world
// coordinate, so no precision loss at planetary distances.
//
// Per instance (CaveMineral.dress_crystals): the hue the crystal lets through and its fluorescence.
// Mesh (CaveCrystalMesh): flat facets; COLOR.r = height along the crystal (0 root .. 1 tip), COLOR.g = random per
// crystal.
//
// A lamp on a gem (the players' torch, held at the eye): a white glint where a facet mirrors it (Fresnel of
// corundum, n = 1.77), and the light that gets in, bounces off the facets inside the stone (total internal
// reflection) and comes back out in its deep hue: two "inner facets" per face, fixed in the crystal, light some
// faces up and make one flash, so the gem twinkles as the player or the lamp moves, never as the head turns.
//
// UV: the players' UV torch is a NEGATIVE SpotLight3D masked to the fluorescent render layer alone
// (Globals.RENDER_MASK_FLUORESCENT). light() sees it as LIGHT_COLOR < 0 and turns it into fluorescence
// instead of light; no other surface is on that layer, so it darkens nothing. The sun and moons do not reach
// that layer (RENDER_MASK_LOCAL_LIT): underground, no daylight on the crystals.

instance uniform vec3 crystal_color = vec3(1.0, 0.4, 0.31);
instance uniform vec4 glow = vec4(1.0, 0.1, 0.1, 0.5);

// Strength of the fluorescence glowing with no UV at all (HDR emission, x the rock's strength).
uniform float ambient_glow : hint_range(0.0, 4.0, 0.01) = 0.12;
// Gain of the fluorescence under the UV torch (x the rock's strength and the beam's falloff).
uniform float uv_glow : hint_range(0.0, 40.0, 0.1) = 1.5;
// How strongly the crystal's hue absorbs what is seen through it: higher = deeper, darker colour.
uniform float density : hint_range(0.0, 8.0, 0.01) = 4.0;
// White glint of a lamp mirrored by a facet: sharpness (higher = smaller) and strength (HDR, makes it bloom).
uniform float glint_power : hint_range(8.0, 2048.0, 1.0) = 384.0;
uniform float glint_strength : hint_range(0.0, 40.0, 0.1) = 8.0;
// Light bouncing off the facets inside the stone and coming back out, in its hue taken twice (in and out):
// how far the inner facets lean from the face (0 = like the face, 1 = any way); the broad glow that lights up
// the faces whose inner facets face the lamp (strength, then narrowness: higher = fewer faces lit); and the
// sharp flashes of the facets exactly in line (narrowness, strength).
uniform float sparkle_spread : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float brilliance : hint_range(0.0, 4.0, 0.01) = 0.6;
uniform float brilliance_focus : hint_range(1.0, 64.0, 0.5) = 6.0;
uniform float sparkle_power : hint_range(8.0, 2048.0, 1.0) = 90.0;
uniform float sparkle_strength : hint_range(0.0, 40.0, 0.1) = 5.0;
// Light scattered inside the crystal toward the viewer, tinted by its hue (lamp facing the crystal).
uniform float inner_scatter : hint_range(0.0, 2.0, 0.01) = 0.05;
// Light from behind passing through the crystal, tinted by its hue.
uniform float transmission : hint_range(0.0, 4.0, 0.01) = 0.8;
// Bright rim at grazing angles (Fresnel reflection of the cave).
uniform float rim_strength : hint_range(0.0, 2.0, 0.01) = 0.25;

// Reflectance of corundum at normal incidence: ((1.77 - 1) / (1.77 + 1))^2.
const float CRYSTAL_F0 = 0.077;

varying vec3 v_hue;
varying vec3 v_glow;
// The two inner facets of this face, in view space (crystal_inner_facet).
varying vec3 v_inner_a;
varying vec3 v_inner_b;

vec3 crystal_hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

// An inner facet of the flat face of mesh normal [normal] (one per [salt]), leaning from it at random: the same
// for every vertex of the face, different on every face, crystal and instance. Returned in view space.
vec3 crystal_inner_facet(vec3 normal, vec4 vertex_colour, int instance_id, float salt, mat3 modelview_normal) {
	vec3 seed = normal * 31.7 + vec3(vertex_colour.g * 53.1, float(instance_id) * 7.13, salt * 19.9);
	vec3 lean = (crystal_hash33(seed) - 0.5) * 2.0 * sparkle_spread;
	return normalize(modelview_normal * normalize(normal + lean));
}

vec3 crystal_glow_colour(vec4 vertex_colour) {
	// Brighter toward the tips, a little different from one crystal to the next.
	return glow.rgb * glow.a * mix(0.35, 1.0, vertex_colour.r) * mix(0.8, 1.2, vertex_colour.g);
}

void crystal_light(vec3 hue, vec3 glow_colour, vec3 albedo, vec3 normal, vec3 inner_a, vec3 inner_b, vec3 view,
		vec3 light, vec3 light_colour, float attenuation, float specular_amount, inout vec3 diffuse_light,
		inout vec3 specular_light) {
	float ndl = dot(normal, light);
	if (light_colour.r < 0.0) {
		// The UV torch: no visible light, it excites the fluorescence. The crystal is translucent, so the
		// back faces fluoresce too, a little less.
		float uv = dot(-light_colour, vec3(1.0 / 3.0));
		specular_light += glow_colour * uv * uv_glow * attenuation * (0.4 + 0.6 * max(ndl, 0.0));
		return;
	}
	vec3 lit = light_colour * attenuation;
	// A custom light() gets no albedo applied: the (faint) body colour is ours to multiply.
	diffuse_light += albedo * max(ndl, 0.0) * lit / PI;
	vec3 half_vector = normalize(view + light);
	float fresnel = CRYSTAL_F0 + (1.0 - CRYSTAL_F0) * pow(1.0 - max(dot(view, half_vector), 0.0), 5.0);
	// The lamp mirrored by the facet, white, energy-normalised so a sharper glint is a brighter one.
	float glint = pow(max(dot(normal, half_vector), 0.0), glint_power) * (glint_power + 8.0) / (8.0 * PI);
	specular_light += glint * glint_strength * fresnel * max(ndl, 0.0) * lit * specular_amount;
	// The light that got in (1 - fresnel), mirrored by an inner facet back out: twice through the stone, so twice
	// its hue. A face whose inner facets face the lamp lights up deep red, the others stay dark, and the one
	// exactly in line flashes: they change as the player or the lamp moves.
	float entered = (1.0 - fresnel) * smoothstep(0.0, 0.2, ndl);
	float inner_a_h = max(dot(inner_a, half_vector), 0.0);
	float inner_b_h = max(dot(inner_b, half_vector), 0.0);
	float returned = brilliance * (pow(inner_a_h, brilliance_focus) + pow(inner_b_h, brilliance_focus)) / PI
			+ sparkle_strength * (pow(inner_a_h, sparkle_power) + pow(inner_b_h, sparkle_power));
	specular_light += hue * hue * returned * entered * lit * specular_amount;
	float through = max(-ndl, 0.0) * 0.5 + pow(max(dot(view, -light), 0.0), 4.0);
	specular_light += hue * lit / PI * (inner_scatter * max(ndl, 0.0) + transmission * through);
}
