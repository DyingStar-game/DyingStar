// The canyons of the star map (StarMapCanyons), drawn like every line of the chart (StarMapTileLines):
// unshaded, blended after the ground, seen from either side — and painted ONCE a pixel. See-through, the
// stretches overlap at every joint and every fork, and each overlap came out darker. The stencil remembers
// what is painted already this frame in the chart's viewport; it must be read AND written in the same pass,
// which StandardMaterial3D will not take together (its flags are one or the other).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
stencil_mode read, write, compare_not_equal, 1;

// How much of the network shows, 0 to 1: its fade with the zoom times StarMapCanyons.OPACITY.
uniform float opacity = 1.0;

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * opacity;
}
