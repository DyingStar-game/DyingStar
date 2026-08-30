shader_type sky;

// Bare starfield, no atmosphere: the sky of somewhere with no air. Used as the system chart's
// background, where a Sky beats a full-screen quad — the renderer already knows which way the camera
// is looking, so the stars sit in space for free instead of having the basis copied over by hand each
// frame. The in-game sky (scenes/_universe/environment/sky.gdshader) draws the same stars behind its air.

#include "res://assets/shaders/starfield.gdshaderinc"

// Not pure black: deep space keeps a trace of blue, and it stops the view reading as a hole punched
// through the interface.
uniform vec3 space_color : source_color = vec3(0.004, 0.005, 0.011);
uniform float star_brightness : hint_range(0.0, 4.0) = 1.0;

void sky() {
	COLOR = space_color + sf_starfield(EYEDIR) * star_brightness;
}
