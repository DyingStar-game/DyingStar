
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 paint_color : source_color;
uniform float paint_roughness: hint_range(0.0, 1.0, 0.01) = 0.34;
uniform float paint_metallic: hint_range(0.0, 1.0, 0.01) = 1.0;
uniform vec3 metal_color: source_color = vec3(0.7);
uniform float metal_roughness: hint_range(0.0, 1.0, 0.01) = 0.2;

uniform sampler2D scratch_texture: hint_default_black;
uniform float scratch_amount: hint_range(0.0, 2.0, 0.01) = 0.2;

uniform float uv1_blend_sharpness = 1.0;

varying vec3 uv1_power_normal;
varying vec3 uv1_triplanar_pos;

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
}

void vertex() {
	uv1_power_normal = pow(abs(NORMAL), vec3(uv1_blend_sharpness));
	uv1_triplanar_pos = VERTEX * 3.0;
	uv1_power_normal /= dot(uv1_power_normal, vec3(1.0));
	uv1_triplanar_pos *= vec3(1.0, -1.0, 1.0);
}

void fragment() {
	float scratch_value = triplanar_texture(scratch_texture, uv1_power_normal, uv1_triplanar_pos).r;

	float metal_blend = COLOR.r + scratch_value * scratch_amount;
	ALBEDO = mix(paint_color.rgb, metal_color, metal_blend);
	METALLIC = mix(paint_metallic, 1.0, metal_blend);
	ROUGHNESS = mix(paint_roughness, metal_roughness, metal_blend);
}
