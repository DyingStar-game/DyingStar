// The dust a wind blows off the ground, marched through the first dust_range metres of every pixel by
// aerial_perspective.gdshader (WeatherSky): dense at the ground, thinning upward, in long streaks
// stretched along the wind that stream past. Here and not in Godot's volumetric fog: that one computes
// its froxels' positions in float32 and, ~8e10 m from the origin, never finds them inside any volume.
// Everything below is camera relative; the noise's frame is the planet's own (dust_frame + dust_offset,
// wrapped on the CPU in double precision), so the streaks stay on the ground and only the wind moves
// them. Needs weather_common.gdshaderinc before it.

// Extinction at the ground (1/m); 0 = no layer and no cost. The layer's e-folding height (m) over the
// ground and the camera's height over it (m).
uniform float dust_density = 0.0;
uniform float dust_height = 25.0;
uniform float dust_cam_height = 1.7;
// Where the march starts (m from the eye): 0 in the open; sheltered, past the room's walls, so a wall
// near the eye gets no dust (its depth is shorter) while a window or a door shows the dust outside.
uniform float dust_start = 0.0;
// The buildings around (WeatherMasks): inverse unit boxes in camera-relative world space; a step
// inside one adds no dust, so a building is clear inside, seen from outside or from within.
uniform mat4 dust_mask[16];
uniform int dust_mask_count = 0;
// How far the layer is marched (m) and in how many steps.
uniform float dust_range = 1000.0;
uniform int dust_steps = 20;
// The far dust, out to dust_far_range (m): a layer dust_far_height (m) thick lying on the real ground
// (its own coarse, wide grid, dust_far_ground*), of extinction dust_far_density (1/m) at the ground
// whatever the eye's height, in banks (the noise at dust_far_noise_scale, its offset wrapped on the
// CPU). It veils the distant plains and valleys more than the slopes that rise out of it, so the relief
// stands in planes; seen from above (EVA) it lies on the land. It starts at dust_far_start (m) and
// fades in over dust_far_fade (m): past the near layer on the ground, from the eye once that is gone.
uniform float dust_far_density = 0.0;
uniform float dust_far_range = 6000.0;
uniform float dust_far_height = 60.0;
uniform float dust_far_start = 700.0;
uniform float dust_far_fade = 300.0;
uniform float dust_far_noise_scale = 20000.0;
uniform vec3 dust_far_noise_offset = vec3(0.0);
uniform sampler2D dust_far_ground : filter_linear, repeat_disable;
uniform int dust_far_ground_on = 0;
uniform vec3 dust_far_ground_cam = vec3(0.0);
uniform vec3 dust_far_ground_east = vec3(1.0, 0.0, 0.0);
uniform vec3 dust_far_ground_north = vec3(0.0, 0.0, 1.0);
uniform vec3 dust_far_ground_up = vec3(0.0, 1.0, 0.0);
uniform float dust_far_ground_half = 12288.0;
// Steps of the far dust (WeatherSky: fewer on the Low setting), and how far the far grid's highest
// ground stands over the ground under the camera (m): a ray climbing over that plus the layer's six
// e-folding heights meets no more far dust, so the sky costs nothing.
uniform int dust_far_steps = 10;
uniform float dust_far_ground_lift = 0.0;
// Once the dust lets less than this through, the rest of the ray is not marched: nothing behind shows.
const float DUST_OPAQUE = 0.01;
// World to planet frame, the camera's position in that frame plus the air's travel (m, wrapped), the
// fine gusts' own travel (a little faster than the air: the two scales slide past each other, so the
// pattern evolves as it streams instead of looping with the texture's period), the wind's direction in
// that frame, and how much longer the streaks run along it.
uniform mat3 dust_frame = mat3(1.0);
uniform vec3 dust_offset = vec3(0.0);
uniform vec3 dust_offset_fine = vec3(0.0);
uniform vec3 dust_wind_dir = vec3(1.0, 0.0, 0.0);
uniform float dust_stretch = 3.5;
// Period of the noise texture (m): it repeats every this many metres, so it must be long (the streaks
// are a few metres; a short period showed as the same gust coming back every few seconds).
uniform float dust_noise_scale = 110.0;
uniform float dust_breakup = 0.75;
// The dust's colour: the ground's.
uniform vec3 dust_albedo = vec3(0.86, 0.74, 0.56);
// The real ground around the camera (DustGround): a height grid over a tangent plane anchored near
// it, all in the planet's frame. dust_ground_cam is the camera relative to that anchor, the texels the
// ground's height over the plane. The grid reaches past the march's range; off it (a fast camera
// outrunning the next grid) the edge's ground carries on, clamped by the sampler. Never the flat plane
// once there is a grid: where the two met, a ring of dust stood at the grid's edge on any slope.
// Before the first grid only, the flat plane through the ground under the camera. dust_ground_lift:
// how far the grid's highest ground stands over the ground under the camera (the layer reaches that
// much higher).
uniform sampler2D dust_ground : filter_linear, repeat_disable;
uniform int dust_ground_on = 0;
uniform vec3 dust_ground_cam = vec3(0.0);
uniform vec3 dust_ground_east = vec3(1.0, 0.0, 0.0);
uniform vec3 dust_ground_north = vec3(0.0, 0.0, 1.0);
uniform vec3 dust_ground_up = vec3(0.0, 1.0, 0.0);
uniform float dust_ground_half = 352.0;
uniform float dust_ground_lift = 0.0;
// The lamps near the eye (DustLights), the dust lit in their beams: camera-relative position and reach
// (xyz, w, m), colour × energy and Godot's falloff exponent (rgb, a), and for a spot its direction and
// the cosine of its half-angle (xyz, w; -2 for an omni). dust_light_count of the 4 are used.
uniform int dust_light_count = 0;
uniform vec4 dust_light_pos[4];
uniform vec4 dust_light_col[4];
uniform vec4 dust_light_spot[4];
// How much brighter the dust glows in a lamp's beam than its density alone gives: an IMAGE choice
// (WeatherSky.LAMP_GAIN). At the plains' visibility a real beam is barely seen; the lit ground is.
uniform float dust_lamp_gain = 1.0;


// The height (m) over the real ground of the camera-relative point [param p] whose height over the
// flat plane through the ground under the camera is [param flat_h].
float dust_height_over_ground(vec3 p, float flat_h) {
	if (dust_ground_on == 0) {
		return flat_h;
	}
	vec3 q = dust_frame * p + dust_ground_cam;
	vec2 uv = vec2(dot(q, dust_ground_east), dot(q, dust_ground_north)) / dust_ground_half;
	float ground = texture(dust_ground, uv * 0.5 + 0.5).r;
	return dot(q, dust_ground_up) - ground;
}


// The near layer's extinction (1/m) at the camera-relative point [param p]: its density, in gusts
// stretched along the wind, thinning with the height over the real ground. Shared by the march and the
// lamps' beams, so the dust seen in a beam is the dust that streams past. Only the camera-relative part
// is stretched here (a few hundred metres): the rest, the camera's place and the air's travel, arrives
// already stretched and wrapped to the noise's period (the CPU, in double precision). Stretching an
// absolute position thousands of km long made the smallest turn of the wind throw the pattern metres back.
// [param fine] adds the fine gusts (a second texture read); the lamps' beams do without (GPU cost).
float dust_sigma_at(vec3 p, bool fine) {
	vec3 w = normalize(dust_wind_dir);
	float squeeze = 1.0 - 1.0 / max(dust_stretch, 1.0);
	vec3 rel = dust_frame * p;
	vec3 sr = rel - w * dot(rel, w) * squeeze;
	float n = texture(dust_noise, (sr + dust_offset) / dust_noise_scale).r;
	if (fine) {
		float n2 = texture(dust_noise, (sr + dust_offset_fine) / (dust_noise_scale * 0.413) + vec3(0.31, 0.17, 0.73)).r;
		n = n * 0.68 + n2 * 0.32;
	}
	float body = mix(1.0, smoothstep(0.3, 0.72, n), dust_breakup);
	float h = dust_height_over_ground(p, dust_cam_height + dot(p, dust_up));
	return dust_density * body * exp(-max(h, 0.0) / max(dust_height, 0.1));
}


// The light the lamps scatter toward the eye off the dust along [param dir], from the march's start to
// [param t_end] (m): the streaming dust (dust_sigma_at) lit in each beam. Not on the march's steps
// (tens of metres, dithered: a grain over every halo, 2026-10-10) but on the stretch of the ray inside
// each lamp's reach, DUST_LAMP_SAMPLES points at equal angles seen from the lamp (equiangular sampling:
// dense where the ray passes the lamp, where its light changes fastest), fixed, so no grain. Godot's
// falloff (a window to the reach over d^-decay), the spot's cone, the phase, the dust in between. The
// lamp's head is 1 m across (no glare point in its centre). No shadows.
const int DUST_LAMP_SAMPLES = 8;
vec3 dust_lamps(vec3 dir, float t_end) {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < dust_light_count; i++) {
		vec3 lamp = dust_light_pos[i].xyz;
		float reach = dust_light_pos[i].w;
		float b = dot(lamp, dir);
		float h = max(length(dir * b - lamp), 1.0);
		float half_chord = sqrt(max(reach * reach - h * h, 0.0));
		float ta = max(b - half_chord, dust_start);
		float tb = min(b + half_chord, t_end);
		if (tb <= ta) {
			continue;
		}
		float th_a = atan((ta - b) / h);
		float th_b = atan((tb - b) / h);
		float dth = (th_b - th_a) / float(DUST_LAMP_SAMPLES);
		float decay = dust_light_col[i].a;
		vec4 spot = dust_light_spot[i];
		float beam = 0.0;
		for (int k = 0; k < DUST_LAMP_SAMPLES; k++) {
			float th = th_a + (float(k) + 0.5) * dth;
			float t = b + h * tan(th);
			float dt = h * dth / (cos(th) * cos(th));
			vec3 p = dir * t;
			vec3 to_lamp = lamp - p;
			float d = max(length(to_lamp), 1.0);
			vec3 l = to_lamp / d;
			float r = d / reach;
			float window = pow(clamp(1.0 - r * r * r * r, 0.0, 1.0), 2.0);
			float cone = spot.w > -1.5 ? smoothstep(spot.w, mix(spot.w, 1.0, 0.2), dot(-l, spot.xyz)) : 1.0;
			if (window * cone <= 0.0) {
				continue;
			}
			float sigma = dust_sigma_at(p, false);
			beam += sigma * exp(-sigma * t) * window * cone * pow(d, -decay) * dust_phase(dot(dir, l)) * dt;
		}
		sum += dust_light_col[i].rgb * beam;
	}
	return sum * dust_albedo * dust_lamp_gain;
}


// The height (m) over the real ground under the camera-relative point [param p] (the far grid); before
// the first grid, over the flat plane through the ground under the camera.
float dust_far_height_over_ground(vec3 p) {
	if (dust_far_ground_on == 0) {
		return dust_cam_height + dot(p, dust_up);
	}
	vec3 q = dust_frame * p + dust_far_ground_cam;
	vec2 uv = vec2(dot(q, dust_far_ground_east), dot(q, dust_far_ground_north)) / dust_far_ground_half;
	return dot(q, dust_far_ground_up) - texture(dust_far_ground, uv * 0.5 + 0.5).r;
}


// The far dust along [param dir] to [param limit] (m), lit by [param lit]: added to [param light] and
// [param trans]. Steps spaced by i^2, denser near the eye where the dust is resolved best; no dither.
void dust_far(vec3 dir, float limit, vec2 pixel, vec3 lit, inout vec3 light, inout float trans) {
	float t1 = min(limit, dust_far_range);
	float rise = dot(dir, dust_up);
	if (rise > 1e-4) {
		t1 = min(t1, (dust_far_height * 6.0 + dust_far_ground_lift - dust_cam_height) / rise);
	}
	if (dust_far_density <= 0.0 || t1 <= dust_far_start || trans < DUST_OPAQUE) {
		return;
	}
	float t_prev = dust_far_start;
	int steps = max(dust_far_steps, 1);
	for (int i = 0; i < steps; i++) {
		float f = (float(i) + 1.0) / float(steps);
		float t_next = mix(dust_far_start, t1, f * f);
		float dt = t_next - t_prev;
		float t = t_prev + 0.5 * dt;  // the far dust is smooth: the midpoint, no dither (it showed as grain)
		t_prev = t_next;
		vec3 p = dir * t;
		float h = dust_far_height_over_ground(p);
		float bank = texture(dust_noise, (dust_frame * p + dust_far_noise_offset) / dust_far_noise_scale).r;
		float sigma = dust_far_density * exp(-max(h, 0.0) / max(dust_far_height, 0.1))
				* mix(0.25, 1.6, smoothstep(0.3, 0.7, bank))
				* smoothstep(dust_far_start, dust_far_start + max(dust_far_fade, 0.01), t);
		float step_t = exp(-sigma * dt);
		light += trans * (1.0 - step_t) * lit;
		trans *= step_t;
		if (trans < DUST_OPAQUE) {
			break;
		}
	}
}


// The dust between the camera and [param limit] metres along [param dir]: its transmittance (out)
// and the light it scatters toward the eye (returned). Steps jittered per pixel, so their edges dither
// into grain instead of banding.
vec3 dust_march(vec3 dir, float limit, vec2 pixel, out float trans) {
	trans = 1.0;
	vec3 light = vec3(0.0);
	float range = min(limit, dust_range);
	// Only the part of the ray inside the layer (6 e-folding heights over the ground): looking up, the
	// ray leaves it within metres; above it looking down, it enters late. Rays that never meet it cost
	// nothing. Over the flat plane through the ground under the camera: the grid's highest ground lifts it.
	float top = dust_height * 6.0 + (dust_ground_on == 1 ? dust_ground_lift : 0.0);
	float rise = dot(dir, dust_up);
	float t0 = dust_start;
	if (dust_cam_height > top) {
		t0 = rise < -1e-4 ? (top - dust_cam_height) / rise : range;
	} else if (rise > 1e-4) {
		range = min(range, (top - dust_cam_height) / rise);
	}
	if (dust_density <= 0.0 && dust_far_density <= 0.0) {
		return light;
	}
	vec3 lit = dust_lit(dust_albedo, dust_phase(dot(dir, dust_sun_dir)), 1.0, 0.0, 1.0);
	if (dust_density <= 0.0 || range <= t0) {
		// The ray never meets the near layer (it leaves it at once, or the eye is over it): the far
		// dust may still lie across its path.
		dust_far(dir, limit, pixel, lit, light, trans);
		return light;
	}
	int steps = max(dust_steps, 4);
	// A quarter step of dither, no more: a full step showed as grain without a temporal filter to
	// average it (2026-10-10). The steps are spaced by i^2: dense near the eye, where the gusts are big.
	float jitter = 0.5 + 0.25 * (dust_jitter(pixel) - 0.5);
	// The buildings this ray crosses, as [enter, leave] distances along it: the ray is a line from the
	// camera, so in a box's unit frame it is one too, and the slab test gives the interval once per
	// pixel. Each step then compares t with the few intervals kept, instead of transforming its point
	// by every box (14 boxes x 20 steps cost 1.3 ms of GPU on a 3090, the layer itself 0.3).
	vec2 crossed[16];
	int crossed_count = 0;
	for (int m = 0; m < dust_mask_count; m++) {
		vec3 o = (dust_mask[m] * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		vec3 d = (dust_mask[m] * vec4(dir, 0.0)).xyz;
		// 1/d without a division by zero: a ray parallel to a face gets a huge, signed inverse.
		vec3 s = vec3(greaterThanEqual(d, vec3(0.0))) * 2.0 - 1.0;
		vec3 inv = s / max(abs(d), vec3(1e-8));
		vec3 ta = (vec3(-0.5) - o) * inv;
		vec3 tb = (vec3(0.5) - o) * inv;
		vec3 near = min(ta, tb);
		vec3 far = max(ta, tb);
		float enter = max(max(near.x, near.y), near.z);
		float leave = min(min(far.x, far.y), far.z);
		if (leave > max(enter, t0) && enter < range) {
			crossed[crossed_count] = vec2(enter, leave);
			crossed_count++;
		}
	}
	for (int i = 0; i < steps; i++) {
		float fa = float(i) / float(steps);
		float fb = (float(i) + 1.0) / float(steps);
		float ta_i = mix(t0, range, fa * fa);
		float dt = mix(t0, range, fb * fb) - ta_i;
		float t = ta_i + jitter * dt;
		bool masked = false;
		for (int m = 0; m < crossed_count; m++) {
			if (t > crossed[m].x && t < crossed[m].y) {
				masked = true;
				break;
			}
		}
		if (masked) {
			continue;
		}
		// Fades in from the camera (no wall of dust in the lens) and out toward the range's end.
		float fade = smoothstep(dust_start, dust_start + 6.0, t) * (1.0 - smoothstep(range * 0.7, range, t));
		float sigma = dust_sigma_at(dir * t, true) * fade;
		float step_t = exp(-sigma * dt);
		light += trans * (1.0 - step_t) * lit;
		trans *= step_t;
		if (trans < DUST_OPAQUE) {
			break;
		}
	}
	if (dust_light_count > 0) {
		light += dust_lamps(dir, range);
	}
	dust_far(dir, limit, pixel, lit, light, trans);
	return light;
}

