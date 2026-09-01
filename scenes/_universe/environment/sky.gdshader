shader_type sky;

// Physical sky dome. Replaces local_sky.gdshader, whose gradient was marked TEMPORARY in its own
// comments, and the extremely_fast_atmosphere addon that drew the halo from hand-painted gradient
// LUTs. Both are gone: ground and orbit are now one model with one set of constants.
//
// Nothing here decides what the sky looks like — atmosphere_common.gdshaderinc integrates it from
// the body's AtmosphereProfile. This file only says where the ray starts, adds the star's own disc,
// and lets the stars through.
#include "res://scenes/_universe/environment/atmosphere_common.gdshaderinc"

// The same starfield the system chart (F2) draws, so a constellation learnt on the chart is the one
// overhead. It is a pure function of a direction, which is why one file serves a quad and a dome.
#include "res://assets/shaders/starfield.gdshaderinc"

// Angular DIAMETER of the star's disc, degrees, as seen from this body.
uniform float star_angular_diameter = 0.5;
// Softness of the disc edge, as a fraction of its radius.
//
// The star's limb really is sharp, but 0.6734 degrees lands on about ten pixels at a 75 degree field
// of view — near the resolution limit, where a hard edge is the WRONG answer: it aliases into a
// visible polygon, and reads as a second, separate disc sitting inside the glow. Same trap the
// starfield include documents for stars, from the other side. At 0.5 the fade spans half the radius,
// roughly two pixels, and the core merges into its halo instead of fighting it.
uniform float star_limb_softness : hint_range(0.0, 1.0) = 0.5;

// Brightness of the starfield, driven by AtmosphereRenderer.
//
// This is the one value in the whole model that CANNOT be derived, and the reason is worth
// stating: a star is a point source far below one pixel, so what a shader draws for it has no
// physical radiance to match. Worse, dark adaptation NORMALISES the frame — at night the stars are
// most of what is in it, so scaling them physically does not dim them, it just moves the exposure
// until they come back. Setting this from the physics was tried and put the sky below the point
// where the eye stops opening, which erased the stars entirely. It is calibrated by eye instead.
uniform float star_brightness : hint_range(0.0, 4.0) = 0.05;
// How strongly a lit sky drowns the stars. This is eye adaptation, not radiometry: the stars really
// are still there at noon, which is why they are attenuated by the physical transmittance FIRST and
// only then washed out by the sky's own brightness.
uniform float star_wash : hint_range(0.0, 2000.0) = 200.0;

// The radiance cubemap that feeds ambient light and reflections is rendered over six faces every
// time the sky changes, so it gets a cheaper integration. Its job is an average, not a horizon.
uniform int cubemap_view_steps = 12;
uniform int cubemap_light_steps = 4;


void sky() {
	vec3 transmittance;
	int steps_v = AT_CUBEMAP_PASS ? cubemap_view_steps : view_steps;
	int steps_l = AT_CUBEMAP_PASS ? cubemap_light_steps : light_steps;
	// The camera is the origin of the frame: AtmosphereRenderer already subtracted its world position
	// in double precision, so planet_center carries the offset and no ~3e10 coordinate reaches here.
	vec3 air = scatter(vec3(0.0), EYEDIR, 1.0e30, steps_v, steps_l, transmittance);

	// The star's disc, seen through whatever air lies in front of it. Its radiance is its irradiance
	// spread over its solid angle, so a distant dim star and a close bright one both come out right.
	float radius = radians(star_angular_diameter) * 0.5;
	float angle = acos(clamp(dot(EYEDIR, to_star), -1.0, 1.0));
	float disc = 1.0 - smoothstep(radius * (1.0 - star_limb_softness), radius, angle);
	// Never in the ambient cubemap, for two independent reasons.
	//
	// DOUBLE COUNTING: the disc's radiance is star_irradiance / solid_angle, so integrating it over
	// the sky gives back the star's FULL irradiance -- which PlayerSunLight's DirectionalLight
	// already delivers. Letting both through lights everything twice.
	//
	// AND THE CUBEMAP HAS NO TERRAIN: it is rendered over six faces including the one pointing
	// down, and nothing there knows the planet is in the way. At night the star sits in that face,
	// attenuated only by the short path to the ground, so the world ends up lit from below by a
	// star that has set. That is the light that survived turning the moons off.
	if (disc > 0.0 && !AT_CUBEMAP_PASS) {
		float solid_angle = max(2.0 * PI_F * (1.0 - cos(radius)), 1.0e-12);
		air += star_irradiance / solid_angle * star_color * disc * transmittance * sky_exposure;
	}

	// Stars sit outside the atmosphere, so the same transmittance dims them — that is why they fade
	// out through dusk instead of snapping on at sunset, and why they burn at full strength in space
	// where the integral returns nothing and the transmittance is 1.
	float sky_luminance = dot(air, vec3(0.2126, 0.7152, 0.0722));
	vec3 stars = sf_starfield(EYEDIR) * star_brightness * transmittance;

	// The stars are drawn for the EYE, never for the light. This same function also renders the
	// radiance cubemap that feeds ambient light and reflections, and star_brightness is explicitly
	// NOT radiometric -- it is calibrated against eye adaptation, as the uniform above says. Letting
	// it through made the whole night sky an ambient source: at night `air` is nearly zero, so the
	// wash-out term vanishes and the starfield arrives at full strength, lighting the terrain and
	// the buildings from every direction at once. That is what read as everything being backlit.
	//
	// Real starlight is around 1e-4 lux against 0.25 for a full moon: it lights nothing. The moons
	// do the lighting, through MoonLights, where it can be reasoned about.
	if (AT_CUBEMAP_PASS) {
		stars = vec3(0.0);
	}

	COLOR = air + stars / (1.0 + sky_luminance * star_wash);
}
