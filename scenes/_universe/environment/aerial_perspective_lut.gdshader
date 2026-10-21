// The aerial perspective of the frame, in a grid aligned on the camera (Hillaire, "A Scalable and
// Production Ready Sky and Atmosphere Rendering Technique", EGSR 2020): lut_tiles cells of the screen,
// by lut_slices distances, quadratic (fine near the eye) out to aerial_lut_distance. Each texel is ONE
// scatter() — the march aerial_perspective.gdshader ran for every pixel of the ground, 32 view samples
// each: 36 864 marches a frame instead of two million at 1080p. The light changes smoothly across the
// screen and along the ray, so the aerial pass reads it between the cells and the slices.
//
// Texel (x, y): slice x / lut_tiles.x, cell (x % lut_tiles.x, y % lut_tiles.y); the rows of band 0
// (y < lut_tiles.y) hold the in-scattered light, those of band 1 the transmittance. Filled every frame
// by AtmosphereRenderer (the camera turns), with the same constants as the aerial pass.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://scenes/_universe/environment/atmosphere_common.gdshaderinc"

uniform ivec2 lut_tiles = ivec2(32, 18);
uniform int lut_slices = 32;
uniform float aerial_lut_distance = 50000.0;
// The camera: tangents of its half field of view (across, up), and its basis (camera -> world).
uniform vec2 lut_tan = vec2(1.0);
uniform mat3 lut_view_basis = mat3(1.0);


void fragment() {
	ivec2 size = ivec2(lut_tiles.x * lut_slices, lut_tiles.y * 2);
	ivec2 texel = min(ivec2(floor(UV * vec2(size))), size - 1);
	int slice = texel.x / lut_tiles.x;
	vec2 screen_uv = (vec2(ivec2(texel.x % lut_tiles.x, texel.y % lut_tiles.y)) + 0.5) / vec2(lut_tiles);
	// Camera space: x right, y up, -z ahead; the screen's v runs down.
	vec3 dir_view = vec3((screen_uv.x * 2.0 - 1.0) * lut_tan.x, (1.0 - screen_uv.y * 2.0) * lut_tan.y, -1.0);
	vec3 dir = normalize(lut_view_basis * dir_view);
	float s = float(slice + 1) / float(lut_slices);
	vec3 transmittance;
	vec3 air = scatter(vec3(0.0), dir, aerial_lut_distance * s * s, view_steps, light_steps, transmittance);
	COLOR = vec4(texel.y < lut_tiles.y ? air : transmittance, 1.0);
}
