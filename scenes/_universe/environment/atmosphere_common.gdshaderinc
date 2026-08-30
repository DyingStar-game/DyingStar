// Single-scattering atmosphere, shared by the sky dome and the aerial perspective pass.
//
// ALL the physics lives here and nowhere else: sky.gdshader draws the dome where there is no
// geometry, aerial_perspective.gdshader adds the air in front of the geometry, and both call the
// same scatter(). A formula duplicated between the two would drift and show up as a seam at the
// planet's limb, which is exactly the seam this model exists to remove.
//
// The constants come from an AtmosphereProfile resource, derived once at edit time from the system
// data (see addons/dyingstar/build_atmosphere_profiles.gd). Nothing here is tuned by eye.
//
// FRAME: everything is expressed RELATIVE TO THE CAMERA. World positions in this game reach ~3e10 m
// and shader floats are 32-bit, so a world-space planet centre would quantise to hundreds of metres
// and the atmosphere would visibly step. AtmosphereRenderer subtracts the camera position on the CPU
// in float64 and pushes the small result, so the camera sits at the origin and every length here
// stays within a few planetary radii.

// Planet centre, in camera-relative coordinates. The camera itself is at vec3(0).
uniform vec3 planet_center = vec3(0.0);
uniform float planet_radius = 0.0;
uniform float atmosphere_top = 0.0;

uniform vec3 rayleigh_beta = vec3(0.0);
uniform float rayleigh_scale_height = 1.0;

uniform vec3 mie_beta = vec3(0.0);
uniform float mie_g = 0.0;
// 1.0 = the haze only redistributes light, it cannot darken. Corundum (Al2O3) has k ~ 0 in the
// visible, so Sandbox's veil sits exactly at 1.0; a value below it means a genuinely absorbing dust.
uniform float mie_albedo = 1.0;
// haze_top > 0 selects a capped, well-mixed layer; 0 selects a plain exponential.
uniform float haze_top = 0.0;
uniform float haze_falloff = 1.0;
uniform float mie_scale_height = 1200.0;

uniform vec3 absorption_beta = vec3(0.0);
uniform float absorption_center = 25000.0;
uniform float absorption_width = 15000.0;

// Unit vector toward the star, world space (directions are safe in float32; positions are not).
uniform vec3 to_star = vec3(0.0, 1.0, 0.0);
// Irradiance at the top of this body's atmosphere, W/m2, and the star's linear colour normalised so
// its brightest channel is 1. Splitting them keeps the colour a property of the star's temperature
// and the magnitude a property of the orbit.
uniform float star_irradiance = 0.0;
uniform vec3 star_color = vec3(1.0);

// Sample counts, exposed so the graphics settings can trade quality for cost later.
uniform int view_steps = 32;
uniform int light_steps = 8;

// Physical radiance is in W/m2/sr and the engine's lights are in arbitrary units, so the two need a
// bridge. This is the ONLY non-physical number in the model: it scales, it never tints.
uniform float sky_exposure = 1.0;

const float PI_F = 3.14159265358979;


// Entry and exit distances of a ray through the sphere of radius [param radius] centred on
// planet_center, or vec2(-1.0) when it misses. Solved on the reduced quadratic, which keeps its
// precision when the origin sits far outside the sphere (a camera in orbit).
vec2 ray_sphere(vec3 origin, vec3 dir, float radius) {
	vec3 oc = origin - planet_center;
	float b = dot(oc, dir);
	float c = dot(oc, oc) - radius * radius;
	float d = b * b - c;
	if (d < 0.0) {
		return vec2(-1.0);
	}
	d = sqrt(d);
	return vec2(-b - d, -b + d);
}


// Height of [param p] above the reference surface, in metres.
float atmo_altitude(vec3 p) {
	return length(p - planet_center) - planet_radius;
}


// Density profiles, each normalised to 1.0 at ground level.

float rayleigh_density(float altitude) {
	return exp(-altitude / rayleigh_scale_height);
}


// Two regimes. A capped, well-mixed layer (haze_top > 0) is what a suspended dust storm looks like:
// uniform up to a ceiling, then a soft edge — which is why Sandbox's 4000 m plateaus stand clear of
// it. Otherwise a plain exponential, like terrestrial aerosol.
float mie_density(float altitude) {
	if (haze_top > 0.0) {
		return 1.0 - smoothstep(haze_top - haze_falloff, haze_top + haze_falloff, altitude);
	}
	return exp(-altitude / mie_scale_height);
}


// Tent profile, as Bruneton models ozone: a band at a given altitude rather than a scale height.
float absorption_density(float altitude) {
	return max(0.0, 1.0 - abs(altitude - absorption_center) / absorption_width);
}


// Total extinction coefficient at one point, per channel, 1/m.
vec3 atmo_extinction(float altitude) {
	return rayleigh_beta * rayleigh_density(altitude)
		+ mie_beta * mie_density(altitude)
		+ absorption_beta * absorption_density(altitude);
}


// 3 / (16 PI) * (1 + cos^2)
float rayleigh_phase(float cos_theta) {
	return 0.0596831 * (1.0 + cos_theta * cos_theta);
}


// Henyey-Greenstein, in the normalised form that keeps its integral at 1 over the sphere.
float mie_phase(float cos_theta, float g) {
	float g2 = g * g;
	float d = 1.0 + g2 - 2.0 * g * cos_theta;
	return 0.0795775 * (1.0 - g2) / (d * sqrt(d) * (2.0 + g2));
}


// Optical depth accumulated from [param origin] along [param dir] over [param max_distance].
vec3 optical_depth(vec3 origin, vec3 dir, float max_distance, int steps) {
	float ds = max_distance / float(steps);
	vec3 depth = vec3(0.0);
	for (int i = 0; i < steps; i++) {
		vec3 p = origin + dir * (ds * (float(i) + 0.5));
		depth += atmo_extinction(atmo_altitude(p)) * ds;
	}
	return depth;
}



// THE core function: single-scattered radiance reaching the camera along [param dir], integrated
// from the camera to [param max_distance] (or to whatever the planet and the atmosphere shell allow,
// whichever comes first).
//
// [param view_transmittance] comes back as an out parameter rather than being recomputed by the
// callers: the sky needs it to dim the star's disc and the stars behind it, and the aerial pass needs
// it to fade the geometry it covers. Integrating the same path twice would be both wasteful and a
// second place for the physics to drift.
vec3 scatter(
		vec3 origin,
		vec3 dir,
		float max_distance,
		int steps_view,
		int steps_light,
		out vec3 view_transmittance) {
	view_transmittance = vec3(1.0);

	vec2 shell = ray_sphere(origin, dir, planet_radius + atmosphere_top);
	if (shell.y < 0.0) {
		return vec3(0.0);  // the ray never meets the air at all
	}
	float t_enter = max(shell.x, 0.0);
	float t_exit = min(shell.y, max_distance);
	// The solid planet stops the view ray before the far side of the shell does.
	vec2 ground = ray_sphere(origin, dir, planet_radius);
	if (ground.x > 0.0) {
		t_exit = min(t_exit, ground.x);
	}
	if (t_exit <= t_enter) {
		return vec3(0.0);
	}

	float ds = (t_exit - t_enter) / float(steps_view);
	float cos_theta = dot(dir, to_star);
	float phase_r = rayleigh_phase(cos_theta);
	float phase_m = mie_phase(cos_theta, mie_g);

	vec3 depth_view = vec3(0.0);
	vec3 sum_rayleigh = vec3(0.0);
	vec3 sum_mie = vec3(0.0);

	for (int i = 0; i < steps_view; i++) {
		vec3 p = origin + dir * (t_enter + ds * (float(i) + 0.5));
		float h = atmo_altitude(p);
		float density_r = rayleigh_density(h);
		float density_m = mie_density(h);
		depth_view += atmo_extinction(h) * ds;

		// Is this sample in the planet's own shadow? A star ray that enters the ground never gets
		// here, and testing it is what draws the terminator and the shadow of the planet climbing
		// through the air at dusk.
		if (ray_sphere(p, to_star, planet_radius).x > 0.0) {
			continue;
		}
		float to_top = ray_sphere(p, to_star, planet_radius + atmosphere_top).y;
		vec3 depth_light = optical_depth(p, to_star, to_top, steps_light);

		vec3 transmittance = exp(-(depth_view + depth_light));
		sum_rayleigh += density_r * transmittance * ds;
		sum_mie += density_m * transmittance * ds;
	}

	view_transmittance = exp(-depth_view);
	return star_irradiance * star_color * (
		rayleigh_beta * phase_r * sum_rayleigh
		+ mie_beta * mie_albedo * phase_m * sum_mie
	) * sky_exposure;
}


// Convenience wrapper for callers that have no geometry in the way (the sky dome).
vec3 scatter_sky(vec3 dir, out vec3 view_transmittance) {
	return scatter(vec3(0.0), dir, 1.0e30, view_steps, light_steps, view_transmittance);
}
