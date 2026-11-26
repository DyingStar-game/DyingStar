// The corundum dust sea (Sandbox), marched by aerial_perspective.gdshader between the eye and whatever
// was drawn: ONE medium seen from below, from inside, from above and from orbit by the same march. White
// and opaque from above (the 1-2 um grains scatter nearly all the light, Mie), a heavy overcast from
// inside, its dust reaching down to the ground in the basins. Ported from the October cloud layer
// (wip/weather, cloud_layer.gdshaderinc), the sea only: no storm grid, no tears.
//
// The numbers come from the atmosphere model (services weather, Nova-Atmo): visibility ~1 km inside, the
// top near 3 300 m, the base at 500 m with a tenth of the dust under it. DustSea (GDScript) pushes them; the
// extinction is uniform from the base to a billowed top (and from the ground to the base), so the light under
// it follows the two-stream estimate DustLight uses for the near dust (1 / (1 + 3/4 (1 - g) tau)).
//
// Frame: the planet's, relative to an anchor on the reference sphere under the eye (DustSea, re-laid as
// the eye travels): sea_frame takes a world direction there, sea_cam is the camera. No astronomic
// coordinate reaches float32. Needs atmosphere_common.gdshaderinc and weather_common.gdshaderinc first.

// 0 = nothing drawn and no cost.
uniform int sea_on = 0;
uniform mat3 sea_frame = mat3(1.0);
uniform vec3 sea_cam = vec3(0.0);
uniform vec3 sea_up = vec3(0.0, 1.0, 0.0);
// The anchor sphere's radius (m): the planet's reference radius, so every height below is an altitude.
uniform float sea_radius = 6356000.0;
// The mean top (m), the lowest ground the march goes down to (m), the extinction inside (1/m, weather
// included), and the ground the multiple scattering bounces on (m, the eye's basin).
uniform float sea_top = 3300.0;
uniform float sea_floor = -3000.0;
uniform float sea_beta = 0.0039;
uniform float sea_ground = -500.0;
// The sea's base (m over the reference sphere): under it the dust is sea_below_share of the sea's (the model
// holds the base, services weather sandbox.toml [sea] below_share), the change sea_base_edge m soft.
uniform float sea_base = 500.0;
uniform float sea_below_share = 1.0;
uniform float sea_base_edge = 150.0;
// The top denser than the inside (an IMAGE choice: the domes read as shapes, not as a soft fog): the
// extinction rises by sea_top_boost over the last sea_top_scale metres under the billowed top.
uniform float sea_top_boost = 2.0;
uniform float sea_top_scale = 150.0;
// The billowed top: it rises and sinks by up to sea_billow_m on four scales (swells of the smooth noise,
// domes, puffs and a cauliflower grain of the cellular one), each anchored on the planet by its offset
// (in periods, wrapped on the CPU). sea_edge_m: half the thickness of the top's edge, the finest step.
uniform float sea_billow_m = 250.0;
uniform float sea_billow_a_m = 40000.0;
uniform float sea_billow_b_m = 12000.0;
uniform float sea_billow_c_m = 3500.0;
uniform float sea_billow_d_m = 900.0;
uniform vec3 sea_billow_offset_a = vec3(0.0);
uniform vec3 sea_billow_offset_b = vec3(0.0);
uniform vec3 sea_billow_offset_c = vec3(0.0);
uniform vec3 sea_billow_offset_d = vec3(0.0);
uniform float sea_edge_m = 30.0;
// The sea's own noises (DustSea): smooth (three octaves) and cellular (distance to the nearest cell).
uniform sampler3D sea_noise : filter_linear_mipmap, repeat_enable;
uniform sampler3D sea_worley : filter_linear_mipmap, repeat_enable;
// The colour: white grains (sea_white), tinted by the rock they were lifted from (the planet map,
// DustSeaMap: the ground's dust albedo, equirectangular in the planet frame) by sea_rock_tint inside and
// sea_edge_tint at its top (what is seen from above: the white sea, barely tinted); brighter and darker patches on sea_colour_noise_m.
uniform sampler2D sea_map : filter_linear, repeat_enable;
uniform int sea_map_on = 0;
uniform vec3 sea_white = vec3(0.96, 0.95, 0.93);
uniform float sea_rock_tint = 0.3;
uniform float sea_edge_tint = 0.12;
uniform float sea_colour_noise_m = 9000.0;
uniform vec3 sea_noise_offset = vec3(0.0);
// The light BEFORE the air (the star's colour at the sun's energy at the top of the air): the air over
// each sample is read there (sea_air), the sun rises and sets along the planet, not with the eye. The
// ambient term: the sky's own glow over the sea.
uniform vec3 sea_sun = vec3(1.0);
uniform vec3 sea_ambient = vec3(0.02);
// The multiply scattered light's weight (1 = the two-stream radiance) and the direct beam's.
uniform float sea_ms_gain = 0.85;
// The eye's adaptation under the sea (DustSea.UNDER_GAIN): all the sea's light scaled, the land in it too.
uniform float sea_eye_gain = 1.0;
// The direct beam's weight over the dust's phase, and the light the hollows between the domes keep (0..1):
// the domes' relief, read at grazing angles from a plateau's edge (an IMAGE choice).
uniform float sea_direct_gain = 1.5;
uniform float sea_crease_floor = 0.4;
// The share of the air's own tint the eye discounts on the sea (DustSea.NEUTRAL_LIGHT): the sea reads white,
// not in the colour of the sunlight that crossed the air.
uniform float sea_neutral = 0.0;
// The colours of the grains' own scattering on the direct beam (dust_sea_mie.gdshaderinc, DustSeaMie): the
// glory around the eye's shadow on the sunlit top, the iridescence of the thin edges near the sun. 0 = white.
uniform float sea_mie_fore_strength = 0.5;
uniform float sea_mie_back_strength = 1.0;
// Quality: the most steps a ray takes, how far it looks inside the shell (m), the angle one pixel spans
// (rad), and the rays averaged per pixel (more from high up, where the jitter alone left a grain).
uniform int sea_steps = 48;
uniform float sea_far = 300000.0;
uniform float sea_pixel_rad = 0.0005;
uniform int sea_rays = 1;

// The billow scales' weights and the shadow taps toward the sun, in billow heights.
const float SEA_W_A = 0.45;
const float SEA_W_B = 0.35;
const float SEA_W_C = 0.2;
const float SEA_W_D = 0.1;
const vec2 SEA_SHADOW_REACH = vec2(0.67, 2.33);
// The two-stream factor 3/4 (1 - g) for corundum's g = 0.7 (DustLight.G).
const float SEA_TWO_STREAM = 0.225;
// The most fine steps a coarse one is walked again in.
const int SEA_FINE_RUN_MAX = 8;
// Over this height over the shell (m) the ray's crossings come from the exact sphere, not the parabola.
const float SEA_EXACT_SPAN_M = 50000.0;


// The height (m) of [param q] (planet frame, relative to the anchor) over the anchor's sphere, without
// subtracting two radii of millions of metres in float32.
float sea_altitude(vec3 q) {
	float w = dot(q, sea_up);
	float s2 = max(dot(q, q) - w * w, 0.0);
	return (2.0 * sea_radius * w + w * w + s2) / (sqrt((sea_radius + w) * (sea_radius + w) + s2) + sea_radius);
}


// The air's transmittance toward the sun over [param q] ([param sun_q] in the planet frame), [param mu]
// the sun's height there. The planet's bulk is the terminator, sharp, as in scatter().
vec3 sea_air(vec3 q, vec3 sun_q, out float mu) {
	vec3 n = normalize(q + sea_up * sea_radius);
	mu = dot(n, sun_q);
	float r = planet_radius + clamp(sea_altitude(q), 0.0, atmosphere_top);
	float horizon = -sqrt(max(r * r - planet_radius * planet_radius, 0.0)) / r;
	if (mu < horizon) {
		return vec3(0.0);
	}
	if (use_transmittance_lut) {
		return texture(transmittance_lut, transmittance_lut_uv(r, mu)).rgb;
	}
	vec3 p = planet_center + (n * sea_frame) * r;  // n back in the world: the frame is a rotation
	float to_top = ray_sphere(p, to_star, planet_radius + atmosphere_top).y;
	return exp(-optical_depth(p, to_star, max(to_top, 0.0), light_steps));
}


// The planet map's coordinates of [param q] (PlanetData.direction_to_uv).
vec2 sea_map_uv(vec3 q) {
	vec3 d = normalize(q + sea_up * sea_radius);
	return vec2(0.5 + atan(-d.z, d.x) / (2.0 * PI_F), 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI_F);
}


// One billow scale: the cellular noise's rounded puffs (1 - d²), or the smooth noise's swells
// (|2n - 1|) when [param smooth_noise]; a feature under [param blur] fades to its mean, 0.5.
float sea_octave(vec3 q, float period, vec3 offset, float blur, bool smooth_noise) {
	float fade = 1.0 - smoothstep(smooth_noise ? 0.05 : 0.02, smooth_noise ? 0.2 : 0.08, blur / period);
	if (fade <= 0.0) {
		return 0.5;
	}
	float v;
	if (smooth_noise) {
		v = abs(2.0 * texture(sea_noise, q / period + offset).r - 1.0);
	} else {
		float n = texture(sea_worley, q / period + offset).r;
		v = 1.0 - n * n;
	}
	return mix(0.5, v, fade);
}


// The billows' height offset (m) at [param q]: [param octaves] of the four scales read.
float sea_billow(vec3 q, int octaves, float blur) {
	float sum = sea_octave(q, sea_billow_a_m, sea_billow_offset_a, blur, true) * SEA_W_A;
	sum += (octaves > 1 ? sea_octave(q, sea_billow_b_m, sea_billow_offset_b, blur, false) : 0.5) * SEA_W_B;
	sum += (octaves > 2 ? sea_octave(q, sea_billow_c_m, sea_billow_offset_c, blur, false) : 0.5) * SEA_W_C;
	sum += (octaves > 3 ? sea_octave(q, sea_billow_d_m, sea_billow_offset_d, blur, false) : 0.5) * SEA_W_D;
	return (sum / (SEA_W_A + SEA_W_B + SEA_W_C + SEA_W_D) - 0.5) * 2.0 * sea_billow_m;
}


// The sea's optical depth per unit of extinction between heights [param lo] and [param hi] (m): full over
// the base, sea_below_share under it (DustSea.depth_between).
float sea_depth_between(float lo, float hi) {
	float over_base = max(hi - max(lo, sea_base), 0.0);
	float under_base = max(min(hi, sea_base) - lo, 0.0);
	return over_base + sea_below_share * under_base;
}


// The share of the sea's extinction at height [param alt] (m): 1 over the base, sea_below_share under it.
float sea_base_share(float alt) {
	return mix(sea_below_share, 1.0, smoothstep(sea_base - sea_base_edge, sea_base + sea_base_edge, alt));
}


// The MEAN of that share between heights [param a] and [param b] (a step of the march): read at one point, a
// step crossing the base took all of it or a tenth, and looking up from a basin the base drew rings around the
// zenith where the steps' count across it changed (2026-11-26).
float sea_base_mean(float a, float b) {
	float lo = min(a, b);
	float hi = max(a, b);
	return hi - lo > 1.0 ? sea_depth_between(lo, hi) / (hi - lo) : sea_base_share(lo);
}


// The sea's extinction (1/m) at [param q] with [param octaves] of billows ([param shallow] of their height),
// a top [param edge] m soft; out: how far q stands over the billowed top (< 0 inside).
float sea_medium(vec3 q, int octaves, float edge, float blur, float shallow, out float over_top) {
	float alt = sea_altitude(q);
	over_top = alt - sea_top - sea_billow(q, octaves, blur) * shallow;
	float layer = 1.0 - smoothstep(-edge, edge, over_top);
	return sea_beta * sea_base_share(alt) * layer * (1.0 + sea_top_boost * exp(min(over_top, 0.0) / sea_top_scale));
}


// A lobe's table at [param u] (0..1 across it): the sample index and the blend to the next, linear, faded to
// white at the lobe's far end so nothing shows a seam.
vec2 sea_mie_index(float u) {
	float f = clamp(u * float(SEA_MIE_SAMPLES) - 0.5, 0.0, float(SEA_MIE_SAMPLES - 1));
	float i = min(floor(f), float(SEA_MIE_SAMPLES - 2));
	return vec2(i, f - i);
}


// The colour of the light the grains scatter toward the eye at [param cos_sun] from the sun (DustSeaMie.tint):
// the forward lobe's iridescence near the sun, the glory around the antisolar point, white between.
vec3 sea_mie_tint(float cos_sun) {
	float angle = degrees(acos(clamp(cos_sun, -1.0, 1.0)));
	vec3 c = vec3(1.0);
	if (angle < SEA_MIE_FORE_DEG) {
		float u = angle / SEA_MIE_FORE_DEG;
		vec2 k = sea_mie_index(u);
		c = mix(mix(SEA_MIE_FORE[int(k.x)], SEA_MIE_FORE[int(k.x) + 1], k.y), vec3(1.0), smoothstep(SEA_MIE_FORE_FADE, 1.0, u));
		c = mix(vec3(1.0), c, sea_mie_fore_strength);
	} else if (180.0 - angle < SEA_MIE_BACK_DEG) {
		float u = (180.0 - angle) / SEA_MIE_BACK_DEG;
		vec2 k = sea_mie_index(u);
		c = mix(mix(SEA_MIE_BACK[int(k.x)], SEA_MIE_BACK[int(k.x) + 1], k.y), vec3(1.0), smoothstep(SEA_MIE_BACK_FADE, 1.0, u));
		c = mix(vec3(1.0), c, sea_mie_back_strength);
	}
	return c;
}


// The stretch of the ray along which alt(t) = c + rise t + k t² is under zero: [t1, t2], or (-1, -1).
// Solved on the stable form (the small root as c / q): k is 1e-7.
vec2 sea_span_below(float c, float rise, float k) {
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
// sphere of radius [param r_s], for an eye far from the shell.
vec2 sea_sphere_span(vec3 o, vec3 d, float r_s) {
	float b = dot(o, d);
	float c = dot(o, o) - r_s * r_s;
	float disc = b * b - c;
	if (disc < 0.0) {
		return vec2(-1.0);
	}
	float sq = sqrt(disc);
	return vec2(-b - sq, -b + sq);
}


// The direct beam left at [param q]: [param taps] taps over the billowed top toward the sun (a dome
// shades its lee), faded by [param shade] far away, and the column over the point ([param column],
// optical depth) under a sun [param sun_up] high, the larger.
float sea_direct(vec3 q, vec3 sun_q, float column, float sun_up, int taps, int octaves, float shade, float shallow) {
	float shadow = 0.0;
	float walked = 0.0;
	for (int i = 0; i < taps; i++) {
		float reach = SEA_SHADOW_REACH[i] * sea_billow_m;
		float over;
		float s = sea_medium(q + sun_q * reach, octaves, sea_edge_m, sea_edge_m, shallow, over);
		shadow += s * (reach - walked);
		walked = reach;
	}
	return exp(-max(shadow * shade, column / sun_up));
}


// The dust's colour at [param q], [param over] metres over the top: white grains tinted by the rock
// they came from, more at the top's edge (the thin dust over the plateaus' feet), varied in patches
// where the eye can see them ([param blur]).
vec3 sea_albedo(vec3 q, float over, float blur) {
	vec3 rock = sea_map_on == 1 ? texture(sea_map, sea_map_uv(q)).rgb : sea_white;
	float tint = mix(sea_rock_tint, sea_edge_tint, smoothstep(-400.0, 0.0, over));
	vec3 base = mix(sea_white, rock, tint);
	float w = 1.0 - smoothstep(250.0, 700.0, blur);
	if (w <= 0.0) {
		return base;
	}
	vec3 nq = q / sea_colour_noise_m + sea_noise_offset;
	float shade = 1.0 + (texture(sea_noise, nq * 2.3 + vec3(0.71, 0.29, 0.13)).r - 0.5) * 0.3 * w;
	vec3 hue = mix(vec3(1.0), mix(vec3(0.94, 0.97, 1.05), vec3(1.05, 1.0, 0.93),
			texture(sea_noise, nq * 0.7 + vec3(0.19, 0.83, 0.41)).r), w);
	return base * shade * hue;
}


// The sea between the camera and [param limit] metres along [param dir] (world): the light it scatters
// toward the eye (returned), its transmittance in [param trans]. Only the stretch of the ray inside the
// shell (the floor to the highest billowed top, the planet curving away included) is marched, coarse
// steps finding the medium and fine ones drawing it; detail follows the step and the pixel. Lit by the
// direct beam left (the column over the sample, the domes' shade) and by the multiply scattered light:
// the two-stream radiance, E mu0 (1 + 3/4 (1-g) tau_below) / (1 + 3/4 (1-g) tau_total), white at the
// top, a quarter of it at the bottom of a basin (the Eddington profile of a conservative layer).
vec3 sea_march_ray(vec3 dir, float limit, float jitter, out float trans) {
	trans = 1.0;
	vec3 light = vec3(0.0);
	vec3 d = sea_frame * dir;
	float rise = dot(d, sea_up);
	float k = max((1.0 - rise * rise) / (2.0 * sea_radius), 1e-12);
	float c0 = sea_altitude(sea_cam);
	float top = sea_top + sea_billow_m + sea_edge_m;
	vec2 under_top;
	vec2 under_floor;
	if (c0 > SEA_EXACT_SPAN_M) {
		vec3 o = sea_up * sea_radius + sea_cam;
		under_top = sea_sphere_span(o, d, sea_radius + top);
		under_floor = sea_sphere_span(o, d, sea_radius + sea_floor);
	} else {
		under_top = sea_span_below(c0 - top, rise, k);
		under_floor = sea_span_below(c0 - sea_floor, rise, k);
	}
	if (under_top.y <= 0.0) {
		return light;
	}
	float t_a = max(under_top.x, 0.0);
	float t_b = under_top.y;
	if (under_floor.y > t_a && under_floor.x < t_b) {
		if (under_floor.x <= t_a) {
			t_a = max(t_a, under_floor.y);
		} else {
			t_b = min(t_b, under_floor.x);
		}
	}
	t_b = min(t_b, min(limit, t_a + sea_far));
	if (t_b <= t_a) {
		return light;
	}
	// Grazing rays (the horizon from a plateau's edge) cross kilometres of tops and take more steps: run out
	// before the end of their stretch, they left bands of see-through sea along the horizon.
	int budget = max(sea_steps, 8) + int(float(sea_steps) * 1.5 * pow(1.0 - abs(rise), 16.0));
	// Where the ray meets the drawn ground (a terrain pixel): the billows shrink where that ground stands near
	// or over the top, so a plateau is not painted with flat white patches of sea (October's "shallow").
	float shallow = 1.0;
	if (limit < 1e11) {
		shallow = smoothstep(0.0, 3.0 * sea_billow_m, sea_top - sea_altitude(sea_cam + d * limit));
	}
	float phase = dust_phase(dot(dir, to_star));
	vec3 mie = sea_mie_tint(dot(dir, to_star));
	vec3 sun_q = sea_frame * to_star;
	float tau_one_m = 1.0 / max(sea_beta, 1e-6);  // one optical depth inside (m)
	float tau_top_m = 1.0 / max(sea_beta * (1.0 + sea_top_boost), 1e-6);  // and at the top
	vec3 albedo = vec3(-1.0);
	// The steps' boundaries are moved per pixel (the first step is 0.5 to 1.5 long) and the sample inside a step
	// by a second, independent number: the same boundaries for every pixel at one height drew horizontal strata
	// along the horizon (2026-11-25).
	float first = 0.5 + jitter;
	bool shifted = false;
	float inside = fract(jitter * 1.6180339 + 0.3819660);
	float tau_sum = 0.0;
	vec3 lit_last = vec3(-1.0);
	float t = t_a;
	int fine_left = 0;
	float fine = sea_edge_m;
	float coarse = 4.0 * fine;
	bool was_thin = false;
	for (int i = 0; i < budget; i++) {
		if (t >= t_b) {
			break;
		}
		// Under the base the dust is thin and even: steps of a quarter of ITS optical depth, up to the base. At
		// the sea's 30-60 m a ray up from a basin spent its budget under the base and stopped short of the top,
		// by more steps the more slanted: rings around the zenith (2026-11-26). No step, the jittered first one
		// included, goes past the base; out of the thin dust the steps are worked out again for the sea.
		bool thin = false;
		float to_base = 1e9;
		if (sea_below_share < 1.0) {
			float alt_t = sea_altitude(sea_cam + d * t);
			thin = alt_t < sea_base - sea_base_edge;
			to_base = rise > 0.05 ? max((sea_base - sea_base_edge - alt_t) / rise, sea_edge_m) : 1e9;
			if (was_thin && !thin) {
				fine_left = 0;
			}
			was_thin = thin;
		}
		if (fine_left == 0) {
			// Crisp near the eye (2 % of the distance), never under a pixel, at most half an optical depth.
			fine = max(clamp(t * 0.02, sea_edge_m, max(sea_edge_m, tau_one_m * 0.25)), min(t * sea_pixel_rad, tau_one_m * 0.5));
			if (thin) {
				fine = max(fine, min(0.25 * tau_one_m / sea_below_share, to_base));
			}
			coarse = max(4.0 * fine, (t_b - t) / float(budget - i) * 1.5);
			if (thin) {
				// Never a coarse step across the base either: the fine run it starts would go on into the sea.
				coarse = max(min(coarse, to_base), fine);
			}
			fine = coarse / float(min(int(ceil(coarse / fine)), SEA_FINE_RUN_MAX));
		}
		float dt = min((fine_left > 0 ? fine : coarse) * (shifted ? 1.0 : first), t_b - t);
		if (thin) {
			dt = min(dt, to_base);
		}
		float ts = t + dt * inside;
		vec3 q = sea_cam + d * ts;
		float blur = max(dt, ts * sea_pixel_rad);
		int octaves = blur < 72.0 ? 4 : (blur < 280.0 ? 3 : (blur < 960.0 ? 2 : 1));
		float over;
		float sigma = sea_medium(q, octaves, max(sea_edge_m, blur), blur, shallow, over);
		// The base over the whole step, not at its sample (sea_base_mean).
		if (sea_below_share < 1.0 && sigma > 0.0) {
			float alt_q = sea_altitude(q);
			if (alt_q - dt < sea_base + sea_base_edge) {
				float mean = sea_base_mean(sea_altitude(sea_cam + d * t), sea_altitude(sea_cam + d * (t + dt)));
				sigma *= mean / max(sea_base_share(alt_q), 1e-3);
			}
		}
		if (sigma <= 1e-9) {
			if (fine_left > 0) {
				fine_left--;
			}
			t += dt;
			shifted = true;
			continue;
		}
		if (fine_left == 0 && dt > fine * 1.01) {
			fine_left = int(ceil(dt / fine));  // found by a coarse step: over it again, finely
			continue;
		}
		fine_left = max(fine_left, 1);
		// A thick step looking down on the top is seen about one optical depth in, whatever the jitter
		// put the sample at: lit where the jitter fell, the sea from afar was a checkerboard (2026-10-09).
		vec3 n = normalize(q + sea_up * sea_radius);
		float rise_q = dot(d, n);
		if (sigma * dt > 1.0 && rise_q < -0.02 && c0 - sea_altitude(q) > -over) {
			vec3 q_lit = q + d * clamp((over + tau_top_m * -rise_q) / (-rise_q), -dt, dt);
			sea_medium(q_lit, octaves, max(sea_edge_m, blur), blur, shallow, over);
			q = q_lit;
		}
		if (albedo.x < 0.0) {
			albedo = sea_albedo(q, over, blur);
		}
		// An opaque step looked down on from over the top is seen about one optical depth in, whatever the
		// jitter put its sample at: its light is read there (at a grazing angle a few metres under the top).
		// Read where the jitter fell, the far sea was speckled bright and dark (2026-11-25). Only from over
		// the top: for an eye inside the sea, every sample was lit as the top, a bright band at eye level.
		float over_l = over;
		if (sigma * dt > 1.0 && rise_q < 0.0 && c0 > sea_altitude(q) - over) {
			over_l = max(over, -tau_top_m * max(-rise_q, 0.05));
		}
		float alt = sea_altitude(q) + (over_l - over);
		// Over the sample to the top (the base's thinner dust taken off under it), and from the ground up to it.
		float column = sea_beta * (max(-over_l, 0.0) - (1.0 - sea_below_share) * max(sea_base - alt, 0.0))
				+ sea_beta * sea_top_boost * sea_top_scale * (1.0 - exp(min(over_l, 0.0) / sea_top_scale));
		float below = sea_beta * sea_depth_between(sea_ground, alt);
		float shade = 1.0 - smoothstep(400.0, 900.0, blur);
		int taps = blur < 100.0 ? 2 : (shade > 0.0 ? 1 : 0);
		float mu;
		vec3 air = sea_air(q, sun_q, mu);
		air = mix(air, vec3(dot(air, vec3(0.2126, 0.7152, 0.0722))), sea_neutral);
		float beam_t = sea_direct(q, sun_q, column, max(mu, 0.05), taps, blur < 60.0 ? 2 : 1, shade, shallow);
		float multi = max(mu, 0.0) * (1.0 + SEA_TWO_STREAM * below) / (1.0 + SEA_TWO_STREAM * (below + column));
		// The hollows between the domes see less of the sky: near the top only. Deeper the light is the
		// overcast's whatever the domes (the probe, 2026-11-25: every sample under the top took the hollows'
		// 0.4, the fog of a basin two and a half times too dark).
		float crease = mix(sea_crease_floor, 1.0, smoothstep(-0.7 * sea_billow_m, 0.0, over));
		crease = mix(crease, 1.0, 1.0 - smoothstep(-2.8 * sea_billow_m, -1.4 * sea_billow_m, over));
		vec3 lit = sea_eye_gain * albedo * (sea_sun * air * (sea_direct_gain * phase * beam_t * mie + sea_ms_gain * multi * crease)
				+ sea_ambient * crease * smoothstep(-0.25, 0.05, mu));
		float step_t = exp(-sigma * dt);
		light += trans * (1.0 - step_t) * lit;
		trans *= step_t;
		tau_sum += sigma * dt;
		lit_last = lit;
		t += dt;
		shifted = true;
		if (trans < 0.03) {
			trans = 0.0;
			break;
		}
	}
	// Steps run out before the end of the stretch: the rest is taken as the dust met so far, lit as the last.
	if (trans > 0.0 && t < t_b && lit_last.x >= 0.0) {
		float rest = exp(-tau_sum / max(t - t_a, 1.0) * (t_b - t));
		light += trans * (1.0 - rest) * lit_last;
		trans *= rest;
	}
	return light;
}


// The sea for one pixel: sea_rays rays, each with its own jitter (stratified), averaged.
vec3 sea_march(vec3 dir, float limit, vec2 pixel, out float trans) {
	trans = 1.0;
	if (sea_on == 0 || sea_beta <= 0.0) {
		return vec3(0.0);
	}
	int rays = clamp(sea_rays, 1, 4);
	float jitter = dust_jitter(pixel);
	vec3 light = vec3(0.0);
	float sum_t = 0.0;
	for (int i = 0; i < rays; i++) {
		float tr;
		light += sea_march_ray(dir, limit, fract(jitter + float(i) / float(rays)), tr);
		sum_t += tr;
	}
	trans = sum_t / float(rays);
	return light / float(rays);
}
