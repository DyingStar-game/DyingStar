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
#include "res://scenes/_universe/environment/weather_common.gdshaderinc"
#include "res://scenes/_universe/environment/dust_layer.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

// The march of the air, precomputed for the frame in a grid on the camera (aerial_perspective_lut.gdshader,
// filled by AtmosphereRenderer): out to aerial_lut_distance a pixel reads it, past it the pixel marches as
// before. 0 = no table, every pixel marches (debug_no_aerial_lut). The grid's shape is the table's.
uniform sampler2D aerial_lut : filter_linear, repeat_disable;
uniform float aerial_lut_distance = 0.0;
uniform ivec2 lut_tiles = ivec2(32, 18);
uniform int lut_slices = 32;


// One band of the table (0 in-scattered light, 1 transmittance) at [slice], where the pixel is. The cell
// is clamped inside its slice: the filter must not reach into the next one, a whole other distance.
vec3 aerial_lut_read(vec2 screen_uv, int slice, int band) {
	vec2 cell = clamp(screen_uv * vec2(lut_tiles), vec2(0.5), vec2(lut_tiles) - 0.5);
	vec2 size = vec2(float(lut_tiles.x * lut_slices), float(lut_tiles.y * 2));
	vec2 at = vec2(float(slice * lut_tiles.x), float(band * lut_tiles.y)) + cell;
	return textureLod(aerial_lut, at / size, 0.0).rgb;
}


// The air between the eye and [distance] along the pixel's ray, from the table: between the two slices
// around it (slice s ends at aerial_lut_distance * ((s + 1) / lut_slices)^2), the eye before the first.
void aerial_lut_at(vec2 screen_uv, float distance, out vec3 air, out vec3 transmittance) {
	float f = sqrt(distance / aerial_lut_distance) * float(lut_slices) - 1.0;
	int s0 = int(floor(f));
	float w = f - floor(f);
	vec3 air0 = vec3(0.0);
	vec3 t0 = vec3(1.0);
	if (s0 >= 0) {
		air0 = aerial_lut_read(screen_uv, s0, 0);
		t0 = aerial_lut_read(screen_uv, s0, 1);
	}
	int s1 = min(s0 + 1, lut_slices - 1);
	air = mix(air0, aerial_lut_read(screen_uv, s1, 0), w);
	transmittance = mix(t0, aerial_lut_read(screen_uv, s1, 1), w);
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
		// The sky behind is already drawn; only the wind's dust goes over it (near and far: the horizon
		// sinks into the dust like the far plains).
		vec3 sky_dir = normalize((INV_VIEW_MATRIX * vec4((INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.0, 1.0)).xyz, 0.0)).xyz);
		float dust_t;
		vec3 dust = dust_march(sky_dir, max(dust_range, dust_far_range), FRAGCOORD.xy, dust_t);
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
		vec3 air;
		if (distance_to_surface < aerial_lut_distance) {
			aerial_lut_at(SCREEN_UV, distance_to_surface, air, transmittance);
		} else {
			air = scatter(vec3(0.0), world_dir, distance_to_surface, view_steps, light_steps, transmittance);
		}

		// What the surface sent us, dimmed by the air it crossed, plus what that air scattered in; the
		// wind's dust, nearest the eye, over all (dust_layer.gdshaderinc, WeatherSky).
		float dust_t;
		vec3 dust = dust_march(world_dir, distance_to_surface, FRAGCOORD.xy, dust_t);
		ALBEDO = (texture(screen_tex, SCREEN_UV).rgb * transmittance + air) * dust_t + dust;
		ALPHA = 1.0;
	}
}
