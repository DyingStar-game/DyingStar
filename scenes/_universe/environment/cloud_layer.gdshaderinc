// The planetary cloud layer, marched by aerial_perspective.gdshader between the eye and whatever was
// drawn: ONE medium — on Sandbox the corundum dust, lifted by the storms and lying as a sea over the
// lowlands; on a wetter world, droplets — seen from below, from inside, from above and from orbit by the
// same march (a painted stand-in for the far sea had its own light and never matched the volume's).
//
// Its parts:
//   - a regional grid (StormField: cloud_grid, cloud_ground): the storms' extinction and the sea's
//     thickness from the weather, the real ground and the storms' lid ground, 512 km around the eye;
//   - a planet map (CloudPlanetMap: cloud_planet): the dust's colour (the ground's) over the whole
//     planet, for the colour of every billow, past the grid and from orbit;
//   - the sea: between cloud_bottom and cloud_top, its dust packed under a billowed top;
//   - the storms: cloud_storm_depth of dust over their lid ground, under the same billowed top.
//
// Frame: the planet's, relative to the grid's anchor (a ground point under the eye): cloud_frame takes a
// world direction there, cloud_cam is the camera. No astronomic coordinate reaches float32.
// Needs atmosphere_common.gdshaderinc (PI_F) and weather_common.gdshaderinc before it.

// The whole layer (0 = nothing drawn and no cost); its storms and its sea (dev switches, WeatherPanel).
uniform int cloud_on = 0;
uniform int cloud_storms_on = 1;
uniform int cloud_deck_on = 1;
// The grid: R the storms' extinction (1/m), G the sea's thickness factor (1 = the calibrated veil). The
// ground: R the real ground, G the storms' lid ground (m over the anchor's sphere). Both on the tangent
// frame at the anchor (cloud_east, cloud_north, cloud_up), cloud_half metres each way.
uniform sampler2D cloud_grid : filter_linear, repeat_disable;
uniform sampler2D cloud_ground : filter_linear, repeat_disable;
uniform mat3 cloud_frame = mat3(1.0);
uniform vec3 cloud_cam = vec3(0.0);
uniform vec3 cloud_east = vec3(1.0, 0.0, 0.0);
uniform vec3 cloud_north = vec3(0.0, 0.0, 1.0);
uniform vec3 cloud_up = vec3(0.0, 1.0, 0.0);
uniform float cloud_half = 256000.0;
// The anchor sphere's radius (m); the grid's highest lid ground and lowest ground (m over that sphere);
// the strongest storm extinction in it (0 = no storm).
uniform float cloud_radius = 6356000.0;
uniform float cloud_ground_top = 0.0;
uniform float cloud_ground_low = 0.0;
uniform float cloud_storm_max = 0.0;
// The planet map: the dust's colour, equirectangular in the planet frame (PlanetData.direction_to_uv).
uniform sampler2D cloud_planet : filter_linear, repeat_enable;
uniform int cloud_planet_on = 0;
// The sea: its bottom and top (m over the anchor's sphere), its extinction AT the top (1/m: the
// profile's optical depth over the packing) and the packing: divided by e every cloud_scale_m under the
// billowed top, a dense, billowy top over a lighter haze. The storms' depth of dust over their lid
// ground (m, WeatherSampler.DUST_LAYER_M).
uniform float cloud_bottom = 0.0;
uniform float cloud_top = 0.0;
uniform float cloud_beta = 0.0;
uniform float cloud_scale_m = 400.0;
uniform float cloud_storm_depth = 1000.0;
// The billowed top: it rises and sinks by up to cloud_billow_m on four scales of the shared noises
// (swells, domes on them, puffs on those, the cauliflower grain), each anchored on the planet by its
// offset (in periods, wrapped on the CPU). cloud_edge_m: half the thickness over which the dust goes
// from full to none at the top (crisp, so the domes read as shapes), and the finest step near the eye.
uniform float cloud_billow_m = 300.0;
uniform float cloud_billow_a_m = 40000.0;
uniform float cloud_billow_b_m = 12000.0;
uniform float cloud_billow_c_m = 3500.0;
uniform float cloud_billow_d_m = 900.0;
uniform vec3 cloud_billow_offset_a = vec3(0.0);
uniform vec3 cloud_billow_offset_b = vec3(0.0);
uniform vec3 cloud_billow_offset_c = vec3(0.0);
uniform vec3 cloud_billow_offset_d = vec3(0.0);
uniform float cloud_edge_m = 30.0;
// The sea torn where the weather thins it: a large noise (cloud_cover_m) over the grid's factor.
uniform float cloud_cover_m = 200000.0;
uniform vec3 cloud_cover_offset = vec3(0.0);
// The colour varied within the cloud (brighter and darker patches, a cooler and a warmer tint: the
// dust of several grounds, not one flat paint) on cloud_colour_noise_m.
uniform float cloud_colour_noise_m = 9000.0;
uniform vec3 cloud_noise_offset = vec3(0.0);
// The light BEFORE the air (DustLight.push): the star's beam through the dust over the eye, that beam
// before the dust took its share, and the ambient term; the air is read per sample (cloud_air) and the
// night's floor added after it. Lit by the beam at the eye, the sea seen from 2000 km was in full sun
// over the whole planet, night side included (2026-10-09): the sun rises and sets along the planet,
// not with the eye.
uniform vec3 cloud_sun_beam = vec3(1.0);
uniform vec3 cloud_sun_free = vec3(1.0);
uniform vec3 cloud_ambient = vec3(0.2);
uniform vec3 cloud_ambient_floor = vec3(0.03, 0.035, 0.045);
// Quality: the most steps a ray takes, how far it looks INSIDE the shell (m: from the eye the shell may
// be 400 km away), and the angle one pixel spans (rad): a feature under a pixel is faded instead of
// sparkling.
uniform int cloud_steps = 48;
uniform float cloud_far = 300000.0;
uniform float cloud_pixel_rad = 0.0005;
// Rays averaged per pixel (DustVolume.rays_for): one near the ground, more with the altitude, where a
// step is a pixel wide and the jitter alone left a fine grain over the whole planet (2026-10-09).
uniform int cloud_rays = 1;
// How much of the grid still counts (DustVolume.grid_fade): 1 near the ground, 0 high up, where its
// 512 km disc (the local sea and storms against the calibrated sea past it) was a stamp on the planet.
uniform float cloud_grid_fade = 1.0;

// The billow scales' weights (they sum to 1.1) and the shadow taps toward the sun, in billow heights.
const float CLOUD_W_A = 0.45;
const float CLOUD_W_B = 0.35;
const float CLOUD_W_C = 0.2;
const float CLOUD_W_D = 0.1;
const vec2 CLOUD_SHADOW_REACH = vec2(0.67, 2.33);
// The most fine steps a coarse one is walked again in (a coarse step that lands in the cloud).
const int CLOUD_FINE_RUN_MAX = 8;
// Over this height over the shell (m) the ray's crossings come from the exact sphere, not the parabola.
const float CLOUD_EXACT_SPAN_M = 50000.0;


// The height (m) of [param q] (planet frame, relative to the anchor) over the sphere through the
// anchor, without subtracting two radii of millions of metres in float32.
float cloud_altitude(vec3 q) {
	float w = dot(q, cloud_up);
	float s2 = max(dot(q, q) - w * w, 0.0);
	return (2.0 * cloud_radius * w + w * w + s2) / (sqrt((cloud_radius + w) * (cloud_radius + w) + s2) + cloud_radius);
}


// The air's transmittance toward the sun over [param q], with [param mu] the sun's height there (the
// cosine of its zenith angle). The planet's bulk is the terminator, sharp, as in scatter(); past it the
// table, or the integral when the table is off (client.ini debug_atmo_no_lut).
vec3 cloud_air(vec3 q, vec3 sun_q, out float mu) {
	vec3 n = normalize(q + cloud_up * cloud_radius);
	mu = dot(n, sun_q);
	float r = planet_radius + clamp(cloud_altitude(q), 0.0, atmosphere_top);
	float horizon = -sqrt(max(r * r - planet_radius * planet_radius, 0.0)) / r;
	if (mu < horizon) {
		return vec3(0.0);
	}
	if (use_transmittance_lut) {
		return texture(transmittance_lut, transmittance_lut_uv(r, mu)).rgb;
	}
	vec3 p = planet_center + (n * cloud_frame) * r;  // n back in the world: the frame is a rotation
	float to_top = ray_sphere(p, to_star, planet_radius + atmosphere_top).y;
	return exp(-optical_depth(p, to_star, max(to_top, 0.0), light_steps));
}


// The grid's coordinates of [param q], in [-1, 1] each way.
vec2 cloud_grid_uv(vec3 q) {
	return vec2(dot(q, cloud_east), dot(q, cloud_north)) / cloud_half;
}


// How far inside the grid [param uv] stands (1 inside, 0 past its edge): past it the clamped texels
// would carry the last storm on forever.
float cloud_inside(vec2 uv) {
	return (1.0 - smoothstep(0.9, 1.0, max(abs(uv.x), abs(uv.y)))) * cloud_grid_fade;
}


// The planet map's coordinates of [param q] (PlanetData.direction_to_uv: u the longitude from -180,
// running from +X toward -Z, v the latitude from the north pole).
vec2 cloud_planet_uv(vec3 q) {
	vec3 d = normalize(q + cloud_up * cloud_radius);
	return vec2(0.5 + atan(-d.z, d.x) / (2.0 * PI_F), 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI_F);
}


// One billow scale: the rounded puffs of the cellular noise (1 - d², a dome over each cell with a
// crease between) at [param period], or the smooth noise's swells (|2n - 1|) when [param smooth]; a
// feature under [param blur] fades to its mean, 0.5 (the cellular texture, mipmap-less, drew a moire
// of fine hatching along the far cloud's edge).
float cloud_octave(vec3 q, float period, vec3 offset, float blur, bool smooth_noise) {
	float fade = 1.0 - smoothstep(smooth_noise ? 0.05 : 0.02, smooth_noise ? 0.2 : 0.08, blur / period);
	if (fade <= 0.0) {
		return 0.5;
	}
	float v;
	if (smooth_noise) {
		v = abs(2.0 * texture(dust_noise, q / period + offset).r - 1.0);
	} else {
		float n = texture(dust_worley, q / period + offset).r;
		v = 1.0 - n * n;
	}
	return mix(0.5, v, fade);
}


// The billows' height offset (m) at [param q]: [param octaves] of the four scales read (the others at
// their mean), features under [param blur] m faded.
float cloud_billow(vec3 q, int octaves, float blur) {
	float sum = cloud_octave(q, cloud_billow_a_m, cloud_billow_offset_a, blur, true) * CLOUD_W_A;
	sum += (octaves > 1 ? cloud_octave(q, cloud_billow_b_m, cloud_billow_offset_b, blur, false) : 0.5) * CLOUD_W_B;
	sum += (octaves > 2 ? cloud_octave(q, cloud_billow_c_m, cloud_billow_offset_c, blur, false) : 0.5) * CLOUD_W_C;
	sum += (octaves > 3 ? cloud_octave(q, cloud_billow_d_m, cloud_billow_offset_d, blur, false) : 0.5) * CLOUD_W_D;
	return (sum / (CLOUD_W_A + CLOUD_W_B + CLOUD_W_C + CLOUD_W_D) - 0.5) * 2.0 * cloud_billow_m;
}


// The medium at [param q]: its extinction (1/m, returned) with [param octaves] of billows, a top
// [param edge] m soft, features under [param blur] faded, the sea's tears read once per ray
// ([param cover_noise]: the cover noise is 200 km wide). Out: how far q stands over the storms'
// billowed top and over the sea's (< 0 inside), and the two extinctions before the vertical profile
// (the column over q is worked out from them). One billow serves both tops: the medium is one dust.
// The sea stops at the real ground where the grid knows it: it fills the lowlands, it is not a shell
// through the mountains (past the grid the drawn terrain alone stops the ray).
float cloud_medium(vec3 q, int octaves, float edge, float blur, float cover_noise, out float over_storm,
		out float over_deck, out float beta_storm, out float beta_deck) {
	vec2 uv = cloud_grid_uv(q);
	float inside = cloud_inside(uv);
	vec2 st = uv * 0.5 + 0.5;
	vec2 grid = texture(cloud_grid, st).rg;
	vec2 ground = texture(cloud_ground, st).rg;
	float alt = cloud_altitude(q);
	float billow = cloud_billow(q, octaves, blur);
	float real_ground = mix(-1.0e9, ground.r, inside);
	float over_ground = smoothstep(real_ground - 50.0, real_ground + 50.0, alt);
	beta_storm = grid.r * inside * float(cloud_storms_on);
	over_storm = alt - ground.g - cloud_storm_depth - billow;
	float sigma = beta_storm * (1.0 - smoothstep(-edge, edge, over_storm)) * over_ground;
	// The sea's billows grow with its depth: a shallow sea over ground near its top is a thin, flat
	// sheet, and a plateau 100 m over the top is clear (the billows stood on it and the eye there was in
	// a grey fog, 2026-10-08). Full billows where the sea is three billow heights deep.
	float shallow = mix(1.0, smoothstep(0.0, 3.0 * cloud_billow_m, cloud_top - ground.r), inside);
	over_deck = alt - cloud_top - billow * shallow;
	beta_deck = 0.0;
	if (cloud_deck_on == 1 && cloud_beta > 0.0) {
		// Past the grid the calibrated sea, with the same tears.
		float factor = mix(1.0, grid.g, inside);
		float cover = factor + cover_noise;
		beta_deck = cloud_beta * clamp(cover, 0.0, 2.5) * smoothstep(0.15, 0.35, cover);
		float layer = smoothstep(cloud_bottom - 150.0, cloud_bottom + 150.0, alt)
				* (1.0 - smoothstep(-edge, edge, over_deck));
		sigma += beta_deck * layer * exp(min(over_deck, 0.0) / cloud_scale_m) * over_ground;
	}
	return sigma;
}


// The stretch of the ray along which alt(t) = c + rise t + k t² is under zero: [t1, t2], or (-1, -1)
// when it never is. Solved on the stable form (the small root as c / q): k is 1e-7 and the plain
// formula cancelled the near crossing away. For an eye near the shell: the parabola is the sphere's
// first terms, and from 2 000 km it put the crossings 6 km off, past the whole shell (no sea drawn).
vec2 cloud_span_below(float c, float rise, float k) {
	float disc = rise * rise - 4.0 * k * c;
	if (disc < 0.0) {
		return vec2(-1.0);
	}
	float sq = sqrt(disc);
	float q = -0.5 * (rise + (rise >= 0.0 ? sq : -sq));
	if (abs(q) < 1e-9) {
		return vec2(-1.0);
	}
	float t1 = q / k;
	float t2 = c / q;
	return vec2(min(t1, t2), max(t1, t2));
}


// The stretch of the ray from [param o] (planet frame, from the CENTRE) along [param d] inside the
// sphere of radius [param r_s]: [t1, t2], or (-1, -1). For an eye far from the shell, where the
// cancellation in o·o - r² (a few m at 400 km) is nothing against the shell's crossing; near it the
// parabola above is the precise one.
vec2 cloud_sphere_span(vec3 o, vec3 d, float r_s) {
	float b = dot(o, d);
	float c = dot(o, o) - r_s * r_s;
	float disc = b * b - c;
	if (disc < 0.0) {
		return vec2(-1.0);
	}
	float sq = sqrt(disc);
	return vec2(-b - sq, -b + sq);
}


// The sun's beam at [param q]: [param taps] taps over the billowed tops toward the sun (a dome shades
// its lee and its neighbours; fewer from afar, where the domes are under a pixel, with [param octaves]
// of billows each, their shade faded by [param shade] so it does not switch off at a distance) and the
// column of dust over the point for what lies deeper, the larger. [param column] is that column's
// optical depth.
float cloud_sun(vec3 q, vec3 sun_q, float column, float sun_up, int taps, int octaves, float cover_noise,
		float shade) {
	float shadow = 0.0;
	float walked = 0.0;
	for (int i = 0; i < taps; i++) {
		float reach = CLOUD_SHADOW_REACH[i] * cloud_billow_m;
		float os;
		float od;
		float bs;
		float bd;
		float s = cloud_medium(q + sun_q * reach, octaves, cloud_edge_m, cloud_edge_m, cover_noise, os, od, bs, bd);
		shadow += s * (reach - walked);
		walked = reach;
	}
	float tau = max(shadow * shade, column / sun_up);
	// The beam and what bounces its way down after it (Hillaire's octaves: each one through a quarter
	// of the dust at half the weight), normalised: lit by the direct beam alone the inside of a cloud
	// read dark grey, where a real one is a bright fog.
	return (exp(-tau) + 0.5 * exp(-0.25 * tau) + 0.25 * exp(-0.0625 * tau)) / 1.75;
}


// The dust's colour at [param q]: the planet map's (the ground's dust), varied within the cloud where
// the eye can see it ([param blur]): brighter and darker patches, and a slow drift between a cooler and
// a warmer tint.
vec3 cloud_albedo(vec3 q, float blur) {
	vec3 base = cloud_planet_on == 1 ? texture(cloud_planet, cloud_planet_uv(q)).rgb : vec3(0.86, 0.74, 0.56);
	// The patches are a few km: under a pixel from afar. They fade out with the pixel instead of
	// switching off at 600 m, and around a mean of 1: cut at a threshold, with their mean 0.9, they
	// drew a darker disc under the eye from 400 km (2026-10-09).
	float w = 1.0 - smoothstep(250.0, 700.0, blur);
	if (w <= 0.0) {
		return base;
	}
	vec3 nq = q / cloud_colour_noise_m + cloud_noise_offset;
	float shade = 1.0 + (texture(dust_noise, nq * 2.3 + vec3(0.71, 0.29, 0.13)).r - 0.5) * 0.53 * w;
	vec3 tint = mix(vec3(1.0), mix(vec3(0.85, 0.92, 1.12), vec3(1.14, 1.0, 0.8),
			texture(dust_noise, nq * 0.7 + vec3(0.19, 0.83, 0.41)).r), w);
	return base * shade * tint;
}


// The cloud layer between the camera and [param limit] metres along [param dir] (world): what it
// scatters toward the eye (returned), its transmittance in [param trans]. Only the stretch of the ray
// inside the layer's shell (its lowest ground to its highest billowed top, the planet curving away
// included) is marched, in steps that tighten toward the eye and as many as the stretch asks for:
// inside the sea the first metres decide what you see; from orbit the shell is a few km thick under
// the ray and a dozen steps cross it. Detail follows the step and the pixel: fewer billow scales, fewer
// shadow taps, no colour patches far away. Dithered per pixel ([param pixel]).
vec3 cloud_march_ray(vec3 dir, float limit, float jitter, out float trans) {
	trans = 1.0;
	vec3 light = vec3(0.0);
	vec3 d = cloud_frame * dir;
	float rise = dot(d, cloud_up);
	// Altitude along the ray over the anchor's sphere: cam + rise t + k t².
	float k = max((1.0 - rise * rise) / (2.0 * cloud_radius), 1e-12);
	float c0 = cloud_altitude(cloud_cam);
	float top = max(cloud_top, cloud_ground_top + cloud_storm_depth) + cloud_billow_m + cloud_edge_m;
	float bottom = min(cloud_bottom - 150.0, cloud_ground_low);
	vec2 under_top;
	vec2 under_bottom;
	if (c0 > CLOUD_EXACT_SPAN_M) {
		vec3 o = cloud_up * cloud_radius + cloud_cam;
		under_top = cloud_sphere_span(o, d, cloud_radius + top);
		under_bottom = cloud_sphere_span(o, d, cloud_radius + bottom);
	} else {
		under_top = cloud_span_below(c0 - top, rise, k);
		under_bottom = cloud_span_below(c0 - bottom, rise, k);
	}
	if (under_top.y <= 0.0) {
		return light;
	}
	float t_a = max(under_top.x, 0.0);
	float t_b = under_top.y;
	// The ray's dip under the layer's bottom: the march stops there, or starts past it for an eye in
	// a valley under the sea (then the far side of the planet, past the ground, is never reached).
	if (under_bottom.y > t_a && under_bottom.x < t_b) {
		if (under_bottom.x <= t_a) {
			t_a = max(t_a, under_bottom.y);
		} else {
			t_b = min(t_b, under_bottom.x);
		}
	}
	t_b = min(t_b, min(limit, t_a + cloud_far));
	if (t_b <= t_a) {
		return light;
	}
	int budget = max(cloud_steps, 8);
	float phase = dust_phase(dot(dir, dust_sun_dir));
	vec3 sun_q = cloud_frame * dust_sun_dir;
	float depth = cloud_top - cloud_bottom;
	// The sea's tears (200 km wide) and the dust's colour (patches of a few km) are read once per ray,
	// at its entry into the shell: they do not change along the few km a ray crosses of it.
	vec3 q_a = cloud_cam + d * t_a;
	// +-0.3 over the deck factor (0.5 to 2.5): thin wisps where the noise is low under a high, never a
	// hole to the ground (+-0.4 over a floor of 0.1 tore the sea open, 2026-10-09).
	float cover_noise = (texture(dust_noise, q_a / cloud_cover_m + cloud_cover_offset).r - 0.5) * 0.6;
	vec3 albedo = vec3(-1.0);
	// Coarse steps find the cloud, fine steps draw it: the detail is at its top, a few hundred metres
	// thick, under a ray that may cross kilometres of empty shell. The fine step grows with the distance
	// (crisp near the eye: 2 % of it, from the edge's width to a quarter of the packing scale) and never
	// under a pixel (from orbit a 30 m step would be sixty samples a pixel for nothing) up to half the
	// packing scale: the step runs ALONG the ray, through a top 400 m thick, and a pixel-wide 3 km step
	// from orbit left each pixel opaque or see-through at the whim of where its sample fell, a grain
	// over the whole planet that averaging rays did not remove (2026-10-09); the coarse step
	// follows the stretch left and the samples left for it, so a long grazing ray still reaches the far
	// sea. A coarse step that lands in the cloud is walked again from its start in as many fine steps as
	// cover it (eight 30 m steps under a 500 m coarse one left the sea unfound past a few km: a ring of
	// sea round the eye); the march goes coarse again after a coarse step's worth of empty fine ones.
	// Every sample is jittered within its step: a fine grid laid the same on neighbouring pixels drew
	// contour lines over the sea.
	float t = t_a;
	int fine_left = 0;
	float fine = cloud_edge_m;
	float coarse = 4.0 * fine;
	for (int i = 0; i < budget; i++) {
		if (t >= t_b) {
			break;
		}
		if (fine_left == 0) {
			fine = max(clamp(t * 0.02, cloud_edge_m, cloud_scale_m * 0.25), min(t * cloud_pixel_rad, cloud_scale_m * 0.5));
			coarse = max(4.0 * fine, (t_b - t) / float(budget - i) * 1.5);
			fine = coarse / float(min(int(ceil(coarse / fine)), CLOUD_FINE_RUN_MAX));
		}
		float dt = min(fine_left > 0 ? fine : coarse, t_b - t);
		float ts = t + dt * jitter;
		vec3 q = cloud_cam + d * ts;
		// The top's edge never sharper than the step can see (crisp near the eye, softer far away: a
		// 60 m edge under steps hundreds of metres apart left each pixel in or out of the dust at the
		// whim of its jitter, a black speckle over the whole storm), nor than the pixel.
		float blur = max(dt, ts * cloud_pixel_rad);
		int octaves = blur < 72.0 ? 4 : (blur < 280.0 ? 3 : (blur < 960.0 ? 2 : 1));
		float over_storm;
		float over_deck;
		float beta_storm;
		float beta_deck;
		float sigma = cloud_medium(q, octaves, max(cloud_edge_m, blur), blur, cover_noise, over_storm, over_deck,
				beta_storm, beta_deck);
		if (sigma <= 1e-9) {
			if (fine_left > 0) {
				fine_left--;
			}
			t += dt;
			continue;
		}
		if (fine_left == 0 && dt > fine * 1.01) {
			fine_left = int(ceil(dt / fine));  // found by a coarse step: over it again, finely
			continue;
		}
		fine_left = max(fine_left, 1);
		if (albedo.x < 0.0) {
			albedo = cloud_albedo(q, blur);
		}
		// Where the light is read. A thick step (opaque over its own length) is seen about one
		// optical depth in, from the side the eye looks from: looking down on the sea, that is the
		// hundred metres under its top (one e-fold of the packing, less at a slant), whatever the
		// jitter put the sample at. Lit where the jitter fell, a sample 1 km under the top read twelve
		// times darker than one at the top, and the sea from orbit was a checkerboard of bright and
		// dark pixels, one per jitter (2026-10-09). The medium's own density keeps the jittered sample:
		// that is what the step's extinction is for.
		vec3 n = normalize(q + cloud_up * cloud_radius);
		float rise_q = dot(d, n);
		float over = (beta_storm > beta_deck) ? over_storm : over_deck;
		if (sigma * dt > 1.0 && rise_q < -0.02 && c0 - cloud_altitude(q) > -over) {
			float z_lit;
			if (beta_storm > beta_deck) {
				z_lit = min(-rise_q / max(beta_storm, 1e-9), 0.5 * cloud_storm_depth);
			} else {
				float tau_sea = max(beta_deck * cloud_scale_m, 1e-6);
				z_lit = -cloud_scale_m * log(1.0 - min(-rise_q, 0.9 * tau_sea) / tau_sea);
			}
			vec3 q_lit = q + d * clamp((over + z_lit) / (-rise_q), -dt, dt);
			cloud_medium(q_lit, octaves, max(cloud_edge_m, blur), blur, cover_noise, over_storm, over_deck,
					beta_storm, beta_deck);
			q = q_lit;
		}
		float column = beta_storm * max(-over_storm, 0.0)
				+ beta_deck * cloud_scale_m * (1.0 - exp(-clamp(-over_deck, 0.0, depth) / cloud_scale_m));
		float shade = 1.0 - smoothstep(400.0, 900.0, blur);
		int taps = blur < 100.0 ? 2 : (shade > 0.0 ? 1 : 0);
		// The sun's height and the air over THIS point: from orbit the eye's are another place's.
		float mu;
		vec3 air = cloud_air(q, sun_q, mu);
		float sun_up = max(mu, 0.05);
		float sun_t = cloud_sun(q, sun_q, column, sun_up, taps, blur < 60.0 ? 2 : 1, cover_noise, shade);
		// The creases between the domes see less sky, weighed by which part of the medium is here.
		float deep = -0.7 * cloud_billow_m;
		float over_lit = (beta_storm > beta_deck) ? over_storm : over_deck;
		float crease = mix(0.15, 1.0, smoothstep(deep, 0.0, over_lit));
		// Multiple scattering: what the column over this point lets through diffuse (two-stream,
		// 1 / (1 + 3/4 (1 - g) tau)) beyond the direct beam. Beyond the column's own beam, not the
		// shadowed one: the shade a dome casts on its neighbour is not filled back in (it was, and
		// the whole sea read one flat white).
		float diffuse = max(1.0 / (1.0 + 0.225 * column) - exp(-column / sun_up), 0.0);
		// The night's floor is the twilight sky's glow: gone with the sun 15 deg under, like the
		// ground (from orbit the night side's sea read grey over a black planet).
		vec3 floor = cloud_ambient_floor * smoothstep(-0.25, 0.05, mu);
		vec3 lit = dust_lit_with(albedo, phase, sun_t, diffuse, crease, cloud_sun_beam * air,
				cloud_sun_free * air, cloud_ambient * air + floor);
		float step_t = exp(-sigma * dt);
		light += trans * (1.0 - step_t) * lit;
		trans *= step_t;
		t += dt;
		// Nothing behind shows any more: the rest of the march would be wasted.
		if (trans < 0.03) {
			trans = 0.0;
			break;
		}
	}
	return light;
}


// The cloud layer for one pixel: cloud_rays rays, each with its own jitter (stratified: the pixel's,
// shifted a share of the step each), averaged. Near the ground one ray; high up the grain of the
// jitter is averaged away instead of spread over a planet.
vec3 cloud_march(vec3 dir, float limit, vec2 pixel, out float trans) {
	trans = 1.0;
	if (cloud_on == 0 || (cloud_storm_max <= 1e-7 && (cloud_deck_on == 0 || cloud_beta <= 0.0))) {
		return vec3(0.0);
	}
	int rays = clamp(cloud_rays, 1, 8);
	float jitter = dust_jitter(pixel);
	vec3 light = vec3(0.0);
	float sum_t = 0.0;
	for (int i = 0; i < rays; i++) {
		float t;
		light += cloud_march_ray(dir, limit, fract(jitter + float(i) / float(rays)), t);
		sum_t += t;
	}
	trans = sum_t / float(rays);
	return light / float(rays);
}
