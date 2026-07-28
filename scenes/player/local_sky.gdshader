shader_type sky;

// LOCAL-frame sky. Godot's PhysicalSkyMaterial measures the horizon and the sun's day/night elevation
// against WORLD axes (+Y up, XZ horizon). On a planet at astronomic coordinates (~3e10) the player's
// LOCAL up (planet centre -> player) has no relation to world +Y, so that sky renders night even when
// the star is well above the LOCAL horizon (the "always black sky" bug). This shader instead computes
// everything from local_up and to_star, both pushed every frame by PlayerSunLight, so day/night, the
// horizon and the sun glow are correct wherever the planet sits. TEMPORARY — the real atmosphere shader
// replaces this, exactly like the PhysicalSkyMaterial it succeeds.

// planet centre -> player (unit, world space): the local "up".
uniform vec3 local_up = vec3(0.0, 1.0, 0.0);
// player -> star (unit, world space): the sun direction.
uniform vec3 to_star = vec3(0.0, 1.0, 0.0);
// 1 = full local day, 0 = local night. Already soft across the terminator (PlayerSunLight).
uniform float day : hint_range(0.0, 1.0) = 1.0;
// 1 at the surface, 0 at the top of the atmosphere / in space. The air (and thus the scattered blue
// sky + the sun's halo) thins with altitude, so the sky fades toward black space as this drops — the
// star then reads as a sharp point in a dark sky. Pushed from PlayerSunLight._atmosphere_factor().
uniform float atmosphere : hint_range(0.0, 1.0) = 1.0;

uniform vec3 zenith_day : source_color = vec3(0.18, 0.42, 0.85);
uniform vec3 horizon_day : source_color = vec3(0.75, 0.82, 0.92);
uniform vec3 ground_col : source_color = vec3(0.30, 0.33, 0.38);
uniform vec3 sun_tint : source_color = vec3(1.0, 0.85, 0.55);
uniform vec3 night_col : source_color = vec3(0.008, 0.010, 0.018);

void sky() {
	float elev = dot(EYEDIR, local_up);        // 1 = zenith, 0 = local horizon, -1 = straight down
	float star_elev = dot(to_star, local_up);  // star height above the local horizon

	// Dome gradient above the horizon: warm-ish horizon -> blue zenith.
	float above = clamp(elev, 0.0, 1.0);
	vec3 dome = mix(horizon_day, zenith_day, pow(above, 0.5));

	// Sun: broad warm halo + tight glow around the star direction.
	float sd = max(dot(EYEDIR, to_star), 0.0);
	dome += sun_tint * (pow(sd, 5.0) * 0.35 + pow(sd, 250.0) * 2.5);

	// Warm the horizon band when the sun is low (sunrise / sunset).
	float horizon_band = exp(-abs(elev) * 8.0);
	float low_sun = clamp(1.0 - abs(star_elev) * 3.0, 0.0, 1.0);
	dome = mix(dome, sun_tint, horizon_band * low_sun * 0.5);

	// ONE continuous sky, no separate 'ground': horizon -> zenith above, and the same sky simply CONTINUING
	// below the local horizon, dimming gently toward the nadir (atmosphere haze). The real terrain draws in
	// front, so there is never a distinct band — from altitude the strip below the horizon is just hazy
	// sky. The dimmed lower hemisphere still gives a sane sky-sourced down-ambient. `ground_col` sets how
	// dark the nadir gets (a floor colour), not a hard band.
	vec3 col = mix(dome, dome * ground_col, pow(clamp(-elev, 0.0, 1.0), 0.7));

	// Day/night, THEN altitude: fade the whole atmospheric sky (blue + sun halo, and the ambient +
	// reflections it sources) toward black at night AND toward black space as the air thins with altitude.
	// High up the sky darkens and the star reads as a sharp point against black.
	COLOR = mix(night_col, col, day) * atmosphere;
}
