shader_type spatial;
render_mode unshaded, blend_add, fog_disabled;

uniform float sun_size = 2.0;
uniform float sun_brightness = 1.0;
uniform vec4 sun_color: source_color;
uniform float sun_fade: hint_range(0.0, 1.0, 0.01) = 0.2;


void vertex() {
	// Billboard Mode: Enabled
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			MAIN_CAM_INV_VIEW_MATRIX[0],
			MAIN_CAM_INV_VIEW_MATRIX[1],
			MAIN_CAM_INV_VIEW_MATRIX[2],
			MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);

	// Fixed Size: Enabled
	if (PROJECTION_MATRIX[3][3] != 0.0) {
		// Orthogonal matrix; try to do about the same with viewport size.
		float h = abs(1.0 / (2.0 * PROJECTION_MATRIX[1][1]));
		// Consistent with vertical FOV (Keep Height).
		float sc = (h * 2.0);
		MODELVIEW_MATRIX[0] *= sc;
		MODELVIEW_MATRIX[1] *= sc;
		MODELVIEW_MATRIX[2] *= sc;
	} else {
		// Scale by depth.
		float sc = -(MODELVIEW_MATRIX)[3].z;
		MODELVIEW_MATRIX[0] *= sc;
		MODELVIEW_MATRIX[1] *= sc;
		MODELVIEW_MATRIX[2] *= sc;
	}
}

float circle(vec2 uv, float radius, float fade) {
	vec2 dist = uv - vec2(0.5);
	return 1.0 - smoothstep(radius - fade, radius + fade, dot(dist, dist) * 4.0);
}

void fragment() {
	vec2 uv = UV;

	ALBEDO = vec3(circle(uv, sun_size * 0.01, sun_fade) * sun_color.rgb * sun_brightness);
}
