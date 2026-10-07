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
	float top = dust_height * 6.0;
	float rise = dot(dir, dust_up);
	float t0 = 0.0;
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
	for (int i = 0; i < steps; i++) {
		float t = t0 + (float(i) + jitter) * dt;
		vec3 p = dir * t;
		float h = dust_cam_height + dot(p, dust_up);
		vec3 rel = dust_frame * p;
		vec3 air = rel + dust_offset;
		vec3 q = air - w * dot(air, w) * squeeze;
		vec3 air2 = rel + dust_offset_fine;
		vec3 q2 = air2 - w * dot(air2, w) * squeeze;
		float n1 = texture(dust_noise, q / dust_noise_scale).r;
		float n2 = texture(dust_noise, q2 / (dust_noise_scale * 0.413) + vec3(0.31, 0.17, 0.73)).r;
		float n = n1 * 0.68 + n2 * 0.32;
		float body = mix(1.0, smoothstep(0.3, 0.72, n), dust_breakup);
		float profile = exp(-max(h, 0.0) / max(dust_height, 0.1));
		// Fades in from the camera (no wall of dust in the lens) and out toward the range's end.
		float fade = smoothstep(0.0, 6.0, t) * (1.0 - smoothstep(range * 0.7, range, t));
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
		float dust_t;
		vec3 dust = march_dust(normalize((INV_VIEW_MATRIX * vec4((INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.0, 1.0)).xyz, 0.0)).xyz),
				dust_range, FRAGCOORD.xy, dust_t);
		ALPHA = 1.0 - dust_t;
		ALBEDO = ALPHA > 1e-4 ? dust / ALPHA : vec3(0.0);
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
		float dust_t;
		vec3 dust = march_dust(world_dir, distance_to_surface, FRAGCOORD.xy, dust_t);
		ALBEDO = (texture(screen_tex, SCREEN_UV).rgb * transmittance + air) * dust_t + dust;
		ALPHA = 1.0;
	}
}
