
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 paint_color : source_color;
uniform float paint_roughness: hint_range(0.0, 1.0, 0.01) = 0.34;
uniform float paint_metallic: hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float metal_roughness: hint_range(0.0, 1.0, 0.01) = 0.2;


void fragment() {
	
	float edge = COLOR.r;
	
	ALBEDO = mix(paint_color.rgb, vec3(0.7), edge);
	METALLIC = mix(paint_metallic, 1.0, edge);
	ROUGHNESS = mix(paint_roughness, metal_roughness, edge);
}
