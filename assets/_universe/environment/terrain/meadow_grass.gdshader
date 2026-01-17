shader_type spatial;
render_mode cull_disabled;

uniform float size_small = 0.2;
uniform float size_large = 0.6;

uniform float blade_bend = 0.5;

uniform vec3 color_small: source_color = vec3(0.3, 0.6, 0.1);
uniform vec3 color_large: source_color = vec3(0.9, 0.9, 0.2);

uniform sampler2D patch_noise;
uniform float patch_scale = 5.0;
varying float patch_factor;

varying float bottom_to_top;

void vertex() {
	bottom_to_top = 1.0 - UV.y;
	
	VERTEX.z += blade_bend * pow(bottom_to_top, 2.0);

	patch_factor = texture(patch_noise, NODE_POSITION_WORLD.xz / patch_scale).r;
	VERTEX *= mix(size_small, size_large, patch_factor);

	NORMAL = mix(NORMAL, vec3(0.0, 1.0, 0.0), bottom_to_top);
}

void fragment() {
	AO = bottom_to_top;
	AO_LIGHT_AFFECT = 1.0;

	ALBEDO = mix(color_small, color_large, patch_factor);
	BACKLIGHT = vec3(0.2);

	ROUGHNESS = 0.4;
	SPECULAR = 0.2;
}
