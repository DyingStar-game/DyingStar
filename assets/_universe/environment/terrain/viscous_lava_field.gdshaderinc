uniform sampler2D state_previous : filter_linear, repeat_enable;
uniform sampler2D state_current : filter_linear, repeat_enable;
uniform sampler2D phase_previous : filter_linear, repeat_enable;
uniform sampler2D phase_current : filter_linear, repeat_enable;
uniform vec2 grid_texel;
uniform float cell_m = 1.5;
uniform float interpolation_alpha = 1.0;
uniform bool thermal_view = false;
uniform bool polar_geometry = false;
uniform int radial_count = 0;
uniform float radial_centres[256];
uniform float field_radius = 0.0;

vec2 bounded_uv(vec2 uv) {
	uv.x = polar_geometry ? fract(uv.x) : clamp(uv.x, grid_texel.x * 0.5, 1.0 - grid_texel.x * 0.5);
	uv.y = clamp(uv.y, grid_texel.y * 0.5, 1.0 - grid_texel.y * 0.5);
	return uv;
}
vec4 state_at(vec2 uv) {
	uv = bounded_uv(uv);
	return mix(textureLod(state_previous, uv, 0.0), textureLod(state_current, uv, 0.0), interpolation_alpha);
}
vec4 phase_at(vec2 uv) {
	uv = bounded_uv(uv);
	return mix(textureLod(phase_previous, uv, 0.0), textureLod(phase_current, uv, 0.0), interpolation_alpha);
}
float surface_at(vec2 uv) { vec4 s = state_at(uv); return s.a + s.r; }
vec2 field_coordinates(vec2 metres) {
	if (!polar_geometry) { return (metres / cell_m + vec2(0.5)) * grid_texel; }
	float radius = length(metres);
	int lo = 0;
	int hi = radial_count - 1;
	for (int n = 0; n < 8; n++) {
		if (lo < hi) {
			int mid = (lo + hi) / 2;
			if (radial_centres[mid] < radius) { lo = mid + 1; } else { hi = mid; }
		}
	}
	int lower = max(0, lo - 1);
	float f = clamp((radius - radial_centres[lower]) / max(0.001, radial_centres[lo] - radial_centres[lower]), 0.0, 1.0);
	return vec2(fract(atan(metres.y, metres.x) / 6.28318530718 + 1.0), (float(lower) + 0.5 + f) * grid_texel.y);
}
