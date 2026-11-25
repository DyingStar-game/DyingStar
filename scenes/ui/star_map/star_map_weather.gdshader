shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled;
// The star map's weather layer (star_map_weather.gd): isobars and wind arrows drawn OVER the ground,
// whatever the relief (a debug chart must not be hidden by a plateau), but only on the face of the body
// that looks at the camera. The node sits at the body's centre (NODE_POSITION_WORLD): a point is on the
// near face when the way out of the body there and the way to the camera agree.

uniform vec4 colour : source_color = vec4(1.0);

void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (dot(world - NODE_POSITION_WORLD, CAMERA_POSITION_WORLD - world) < 0.0) {
		discard;
	}
	ALBEDO = colour.rgb;
	ALPHA = colour.a;
}
