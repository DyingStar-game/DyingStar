shader_type spatial;
render_mode blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, unshaded;

// Aerial perspective: the air BETWEEN the camera and whatever was drawn.
//
// A shader_type sky only paints where there is no geometry, so it can give the dome and nothing
// else. From orbit the planet is drawn by the terrain and the far-LOD spheres, and the limb — the
// bright rim of air over the edge of the disc — is geometry-covered pixels. On the ground the same
// integral is what turns distant relief blue. One pass, reading depth, covers both.
//
// It shares scatter() with sky.gdshader, so the dome and the limb cannot disagree: that seam is
// exactly what the two disjoint systems this replaces could never close.
#include "res://scenes/_universe/environment/atmosphere_common.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

// The dust a wind blows off the ground, marched through the first dust_range metres of every pixel
// (WeatherSky): dense at the ground, thinning upward, in long streaks stretched along the wind that
// stream past. Here and not in Godot's volumetric fog: that one computes its froxels' positions in
// float32 and, ~8e10 m from the origin, never finds them inside any volume. Everything below is camera
// relative, the noise's frame is the planet's own (dust_frame + dust_offset, wrapped on the CPU in
// double precision), so the streaks stay on the ground and only the wind moves them.
// Extinction at the ground (1/m); 0 = no layer and no cost.
uniform float dust_density = 0.0;
// e-folding height (m) over the ground, the camera's height over it (m), and the local up (world).
uniform float dust_height = 6.0;
uniform float dust_cam_height = 1.7;
uniform vec3 dust_up = vec3(0.0, 1.0, 0.0);
// Where the march starts (m from the eye): 0 in the open; sheltered, past the room's walls, so a wall
// near the eye gets no dust (its depth is shorter) while a window or a door shows the dust outside.
uniform float dust_start = 0.0;
// The buildings around (WeatherMasks): inverse unit boxes in camera-relative world space; a step
// inside one adds no dust, so a building is clear inside, seen from outside or from within.
uniform mat4 dust_mask[16];
uniform int dust_mask_count = 0;
// How far the layer is marched (m) and in how many steps.
uniform float dust_range = 300.0;
uniform int dust_steps = 20;
// World to planet frame, the camera's position in that frame plus the air's travel (m, wrapped),
// the wind's direction in that frame, and how much longer the streaks run along it.
uniform mat3 dust_frame = mat3(1.0);
uniform vec3 dust_offset = vec3(0.0);
// The fine gusts' own travel (m), a little faster than the air: the two scales slide past each other,
// so the pattern evolves as it streams instead of looping with the texture's period.
uniform vec3 dust_offset_fine = vec3(0.0);
uniform vec3 dust_wind_dir = vec3(1.0, 0.0, 0.0);
uniform float dust_stretch = 3.5;
// Period of the noise texture (m): it repeats every this many metres, so it must be long (the streaks
// are a few metres; a short period showed as the same gust coming back every few seconds).
uniform float dust_noise_scale = 110.0;
uniform float dust_breakup = 0.75;
uniform sampler3D dust_noise : filter_linear_mipmap, repeat_enable;
// The dust's colour (the ground's), and the light on it in scene units: the sun (colour × energy)
// and the sky, plus the sun's direction (world) for the forward glow toward it.
uniform vec3 dust_albedo = vec3(0.86, 0.74, 0.56);
uniform vec3 dust_sun = vec3(1.0);
uniform vec3 dust_ambient = vec3(0.2);
uniform vec3 dust_sun_dir = vec3(0.0, 1.0, 0.0);
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

// The storms, near and far (StormField): a regional grid of the storm dust's extinction (1/m) and of
// the ground (m over the sphere through the grid's anchor), on the tangent frame at the anchor, all in
// the planet's frame. The dust fills DUST_LAYER_M (storm_depth) of air over the ground, the sampler's
// own convention, so the visibility inside is the one the weather debug prints. storm_cam: the camera
// relative to the anchor; storm_ground_top: the grid's highest ground; storm_far: how far a ray looks.
uniform int storm_on = 0;
uniform sampler2D storm_dust : filter_linear, repeat_disable;
uniform sampler2D storm_ground : filter_linear, repeat_disable;
uniform mat3 storm_frame = mat3(1.0);
uniform vec3 storm_cam = vec3(0.0);
uniform vec3 storm_east = vec3(1.0, 0.0, 0.0);
uniform vec3 storm_north = vec3(0.0, 0.0, 1.0);
uniform vec3 storm_up = vec3(0.0, 1.0, 0.0);
uniform float storm_half = 256000.0;
uniform float storm_radius = 6356000.0;
uniform float storm_ground_top = 0.0;
uniform float storm_beta_max = 0.0;
uniform float storm_depth = 1000.0;
uniform float storm_far = 120000.0;
uniform int storm_steps = 24;
// The storm dust's colour per cell (StormField: the ground it stands on, mixed over ~44 km), read
// through a turbulent warp of the shared dust noise at storm_colour_noise_m (a few km), so where an
// ochre storm meets a white one the line twists instead of following the grid. storm_noise_offset:
// the anchor in noise periods, wrapped on the CPU, so the pattern is the planet's and does not jump
// when the grid is laid again.
uniform sampler2D storm_albedo : filter_linear, repeat_disable;
uniform float storm_colour_noise_m = 9000.0;
uniform float storm_colour_warp_m = 6000.0;
uniform vec3 storm_noise_offset = vec3(0.0);

// The height (m) of [param q] (planet frame, relative to the anchor) over the sphere through the
// anchor, without subtracting two radii of millions of metres in float32.
float storm_altitude(vec3 q) {
	float w = dot(q, storm_up);
	float s2 = max(dot(q, q) - w * w, 0.0);
	return (2.0 * storm_radius * w + w * w + s2) / (sqrt((storm_radius + w) * (storm_radius + w) + s2) + storm_radius);
}

// The storm dust between the camera and [param limit] metres along [param dir] (world): what it
// scatters toward the eye, its transmittance in [param trans]. Only the part of the ray under the
// layer's top (the grid's highest ground plus storm_depth, the planet curving away included) is
// marched, in steps that tighten toward the eye: inside a storm the first metres decide what you see.
vec3 march_storm(vec3 dir, float limit, vec2 pixel, out float trans) {
	trans = 1.0;
	vec3 light = vec3(0.0);
	if (storm_on == 0 || storm_beta_max <= 0.0) {
		return light;
	}
	vec3 d = storm_frame * dir;
	float rise = dot(d, storm_up);
	// Altitude along the ray over the anchor's sphere: cam + rise t + k t². Where it crosses the top.
	float k = max((1.0 - rise * rise) / (2.0 * storm_radius), 1e-12);
	float c = storm_altitude(storm_cam) - (storm_ground_top + storm_depth * 1.3);
	float disc = rise * rise - 4.0 * k * c;
	float t_a = 0.0;
	float t_b = 0.0;
	if (c > 0.0) {
		// Over the layer: only a ray going down into it meets it, between its two crossings.
		if (rise < 0.0 && disc >= 0.0) {
			float qq = 0.5 * (sqrt(disc) - rise);
			t_a = c / qq;
			t_b = qq / k;
		}
	} else {
		float sq = sqrt(max(disc, 0.0));
		float qq = rise >= 0.0 ? -0.5 * (rise + sq) : 0.5 * (sq - rise);
		qq = abs(qq) < 1e-9 ? -1e-9 : qq;  // a level ray exactly at the top: 0/0 otherwise
		t_b = max(qq / k, c / qq);
	}
	t_b = min(t_b, min(limit, storm_far));
	if (t_b <= t_a) {
		return light;
	}
	float span = t_b - t_a;
	int steps = max(storm_steps, 4);
	float n = float(steps);
	float jitter = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))) + 0.5);
	float cos_sun = dot(dir, dust_sun_dir);
	float forward = 1.0 + 1.6 * pow(max(cos_sun, 0.0), 6.0);
	float sun_up = max(dot(dust_sun_dir, dust_up), 0.05);
	for (int i = 0; i < steps; i++) {
		float f = (float(i) + jitter) / n;
		float t = t_a + span * f * f;
		float dt = span * (2.0 * float(i) + 1.0) / (n * n);
		vec3 q = storm_cam + d * t;
		vec2 uv = vec2(dot(q, storm_east), dot(q, storm_north)) / storm_half;
		// Past the grid's edge the clamped texels would carry the last storm on forever: fade it.
		float inside = 1.0 - smoothstep(0.9, 1.0, max(abs(uv.x), abs(uv.y)));
		vec2 st = uv * 0.5 + 0.5;
		float beta = texture(storm_dust, st).r * inside;
		// The lid: storm_depth over the ground smoothed over tens of km (the stirred air's top is far
		// smoother than the relief): valleys fill deeper, hills drown, only real peaks rise out of it.
		float over_lid = storm_altitude(q) - texture(storm_ground, st).g;
		float sigma = beta * (1.0 - smoothstep(storm_depth * 0.7, storm_depth * 1.3, over_lid));
		if (sigma <= 0.0) {
			continue;
		}
		// The sun through the dust over this point: a storm's foot is dark, its top lit.
		float sun_t = exp(-beta * max(storm_depth - over_lid, 0.0) / sun_up);
		vec3 nq = q / storm_colour_noise_m + storm_noise_offset;
		vec2 warp = vec2(texture(dust_noise, nq).r, texture(dust_noise, nq + vec3(0.37, 0.11, 0.53)).r) - 0.5;
		vec2 st_c = st + warp * (storm_colour_warp_m / storm_half);
		float shade = mix(0.9, 1.08, texture(dust_noise, nq * 2.3 + vec3(0.71, 0.29, 0.13)).r);
		vec3 albedo = texture(storm_albedo, st_c).rgb * shade;
		vec3 lit = albedo * (dust_sun * 0.3 * forward * sun_t + dust_ambient);
		float step_t = exp(-sigma * dt);
		light += trans * (1.0 - step_t) * lit;
		trans *= step_t;
	}
	return light;
}

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


// The dust between the camera and [param limit] metres along [param dir]: its transmittance (out)
// and the light it scatters toward the eye (returned). Steps jittered per pixel, so their edges dither
// into grain instead of banding.
vec3 march_dust(vec3 dir, float limit, vec2 pixel, out float trans) {
	trans = 1.0;
	vec3 light = vec3(0.0);
	float range = min(limit, dust_range);
	// Only the part of the ray inside the layer (6 e-folding heights over the ground): looking up, the
	// ray leaves it within metres; above it looking down, it enters late. Rays that never meet it cost
	// nothing.
	// Over the flat plane through the ground under the camera: the grid's highest ground lifts it.
	float top = dust_height * 6.0 + (dust_ground_on == 1 ? dust_ground_lift : 0.0);
	float rise = dot(dir, dust_up);
	float t0 = dust_start;
	if (dust_cam_height > top) {
		t0 = rise < -1e-4 ? (top - dust_cam_height) / rise : range;
	} else if (rise > 1e-4) {
		range = min(range, (top - dust_cam_height) / rise);
	}
	if (dust_density <= 0.0 || range <= t0) {
		return light;
	}
	int steps = max(dust_steps, 4);
	float dt = (range - t0) / float(steps);
	float jitter = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
	float cos_sun = dot(dir, dust_sun_dir);
	float forward = 1.0 + 1.6 * pow(max(cos_sun, 0.0), 6.0);
	vec3 lit = dust_albedo * (dust_sun * 0.3 * forward + dust_ambient);
	vec3 w = normalize(dust_wind_dir);
	float squeeze = 1.0 - 1.0 / max(dust_stretch, 1.0);
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
		float t = t0 + (float(i) + jitter) * dt;
		vec3 p = dir * t;
		float h = dust_height_over_ground(p, dust_cam_height + dot(p, dust_up));
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
		// Only the camera-relative part is stretched here (a few hundred metres): the rest, the camera's
		// place and the air's travel, arrives already stretched and wrapped to the noise's period (the
		// CPU, in double precision). Stretching an absolute position thousands of km long made the
		// smallest turn of the wind's direction throw the whole pattern metres back: the "jumps".
		vec3 rel = dust_frame * p;
		vec3 sr = rel - w * dot(rel, w) * squeeze;
		vec3 q = sr + dust_offset;
		vec3 q2 = sr + dust_offset_fine;
		float n1 = texture(dust_noise, q / dust_noise_scale).r;
		float n2 = texture(dust_noise, q2 / (dust_noise_scale * 0.413) + vec3(0.31, 0.17, 0.73)).r;
		float n = n1 * 0.68 + n2 * 0.32;
		float body = mix(1.0, smoothstep(0.3, 0.72, n), dust_breakup);
		float profile = exp(-max(h, 0.0) / max(dust_height, 0.1));
		// Fades in from the camera (no wall of dust in the lens) and out toward the range's end.
		float fade = smoothstep(dust_start, dust_start + 6.0, t) * (1.0 - smoothstep(range * 0.7, range, t));
		float sigma = dust_density * body * profile * fade;
		float step_t = exp(-sigma * dt);
		light += trans * (1.0 - step_t) * lit;
		trans *= step_t;
	}
	return light;
}


// Full-screen triangle-of-a-quad: the mesh's own transform is ignored and the vertices are written
// straight in clip space, so this cannot be pushed off-screen or scaled wrong by its parent.
void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}


void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	// Reverse-Z: 0 means nothing was drawn here, so this pixel is pure sky and sky.gdshader has
	// already integrated it. Adding the air a second time would double the horizon.
	// (Godot forbids an early `return` in a processor function, hence the branch.)
	if (depth <= 0.0) {
		// The sky behind is already drawn; only the wind's dust in front of it is added here.
		// The storms in front of it too: a dust wall standing on the horizon is drawn over the sky.
		vec3 sky_dir = normalize((INV_VIEW_MATRIX * vec4((INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.0, 1.0)).xyz, 0.0)).xyz);
		float dust_t;
		vec3 dust = march_dust(sky_dir, dust_range, FRAGCOORD.xy, dust_t);
		float storm_t;
		vec3 storm = march_storm(sky_dir, storm_far, FRAGCOORD.xy, storm_t);
		vec3 front = dust + dust_t * storm;
		ALPHA = 1.0 - dust_t * storm_t;
		ALBEDO = ALPHA > 1e-4 ? front / ALPHA : vec3(0.0);
	} else {
		// View-space position of the drawn surface, then its distance and its world direction. The
		// camera is the origin of the atmosphere frame, so this direction and distance are all
		// scatter() needs — no world position, and therefore no ~3e10 coordinate, enters the shader.
		vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		view.xyz /= view.w;
		float distance_to_surface = length(view.xyz);
		vec3 world_dir = normalize((INV_VIEW_MATRIX * vec4(view.xyz, 0.0)).xyz);

		vec3 transmittance;
		vec3 air = scatter(
				vec3(0.0), world_dir, distance_to_surface, view_steps, light_steps, transmittance);

		// What the surface sent us, dimmed by the air it crossed, plus what that air scattered in.
		// The wind's dust, nearest the eye, over all of it.
		// The storms between the eye and the surface over that, and the wind's dust nearest the eye.
		float storm_t;
		vec3 storm = march_storm(world_dir, distance_to_surface, FRAGCOORD.xy, storm_t);
		float dust_t;
		vec3 dust = march_dust(world_dir, distance_to_surface, FRAGCOORD.xy, dust_t);
		ALBEDO = ((texture(screen_tex, SCREEN_UV).rgb * transmittance + air) * storm_t + storm) * dust_t + dust;
		ALPHA = 1.0;
	}
}
