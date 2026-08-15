shader_type sky;

// The stars, shared with the system chart (F2) so both show the SAME sky — a constellation learnt on
// the chart is the one overhead. It is a function of direction, which is why one file serves a
// full-screen quad and a sky dome alike.
#include "res://assets/shaders/starfield.gdshaderinc"

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
// Overall star brightness, so the field can be tuned without touching the shared generator.
uniform float star_brightness : hint_range(0.0, 4.0) = 1.0;
// How far BELOW the local horizon the star can be and still light the sky, as a sine of elevation.
// 0.31 = 18 deg, the end of astronomical twilight on Earth. Thicker air holds the glow longer, so this
// is the knob a denser world would raise.
uniform float dusk_depth : hint_range(0.0, 0.6) = 0.31;
// Dusk and dawn are red because low light crosses far more air, and only the long wavelengths survive.
uniform vec3 dusk_tint : source_color = vec3(1.0, 0.42, 0.20);
uniform float dusk_strength : hint_range(0.0, 3.0) = 1.0;

// Above this elevation the star lights the air fully and there is nothing left to call twilight.
// 0.10 = 6 deg, the end of civil twilight.
const float DUSK_FULL = 0.10;

void sky() {
	float elev = dot(EYEDIR, local_up);        // 1 = zenith, 0 = local horizon, -1 = straight down
	float star_elev = dot(to_star, local_up);  // star height above the local horizon

	// Two questions that only look alike, and whose answers diverge for hours around sunset:
	//   `day`     — is the star lighting YOU? It fades across the star's own disc (~3 deg), which is
	//               right for the ground, for the sun's disc, and for the surface terminator. It is
	//               shared (Globals.TERMINATOR_SOFTNESS), so it must not be stretched.
	//   `sky_lit` — is the star still lighting the AIR ABOVE you? That outlasts sunset by however long
	//               the planet's shadow takes to climb through the atmosphere — ~18 deg of stellar
	//               depression on Earth. This is what makes dusk and dawn last, and it is the SKY's
	//               business alone: widening `day` instead would keep the terrain lit half the night.
	float sky_lit = smoothstep(-dusk_depth, DUSK_FULL, star_elev);
	// The afterglow itself: rises as the air catches the light, dies once the star is properly up.
	float dusk = sky_lit * (1.0 - smoothstep(0.0, DUSK_FULL, star_elev));

	// Dome gradient above the horizon: warm-ish horizon -> blue zenith.
	float above = clamp(elev, 0.0, 1.0);
	vec3 dome = mix(horizon_day, zenith_day, pow(above, 0.5));

	// The broad scattered halo follows the LIT AIR, so it lingers after sunset; the tight disc glow
	// follows the STAR, so it sets with it instead of burning through the planet at midnight.
	float sd = max(dot(EYEDIR, to_star), 0.0);
	dome += sun_tint * (pow(sd, 5.0) * 0.35 * sky_lit + pow(sd, 250.0) * 2.5 * day);

	// ONE continuous sky, no separate 'ground': horizon -> zenith above, and the same sky simply CONTINUING
	// below the local horizon, dimming gently toward the nadir (atmosphere haze). The real terrain draws in
	// front, so there is never a distinct band — from altitude the strip below the horizon is just hazy
	// sky. The dimmed lower hemisphere still gives a sane sky-sourced down-ambient. `ground_col` sets how
	// dark the nadir gets (a floor colour), not a hard band.
	vec3 col = mix(dome, dome * ground_col, pow(clamp(-elev, 0.0, 1.0), 0.7));
	vec3 sky = mix(night_col, col, sky_lit);

	// The band of fire over the horizon, and it sits WHERE THE STAR SET rather than all the way round —
	// which is what tells you at a glance which way west is. Flattening both directions against the
	// local up compares them by bearing alone, ignoring how high each one is.
	vec3 star_flat = to_star - local_up * star_elev;
	vec3 eye_flat = EYEDIR - local_up * elev;
	float bearing = clamp(
		dot(star_flat, eye_flat) / max(length(star_flat) * length(eye_flat), 0.0001), 0.0, 1.0
	);
	float horizon_band = exp(-abs(elev) * 4.0);
	sky += dusk_tint * dusk * dusk_strength * horizon_band * (0.15 + 0.85 * bearing);

	// Altitude last: fade the whole atmospheric sky (blue, halo, dusk, and the ambient + reflections it
	// sources) toward black space as the air thins. High up the star reads as a sharp point on black.
	COLOR = sky * atmosphere;

	// Stars are always THERE; what hides them is LIT AIR — so they are drowned by exactly the quantity
	// that lights the sky, and they come out through dusk as it fades rather than snapping on at sunset.
	// In space (atmosphere -> 0) they burn at full strength whatever the local hour. Added after the
	// atmosphere multiply, or thinning the air would erase the very sky it is meant to reveal.
	COLOR += sf_starfield(EYEDIR) * star_brightness * (1.0 - sky_lit * atmosphere);
}
