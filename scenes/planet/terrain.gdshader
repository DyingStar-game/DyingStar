// NOTE: Shader automatically converted from Godot Engine 4.4.1.stable.mono's StandardMaterial3D.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;

uniform float roughness : hint_range(0.0, 1.0);

uniform sampler2D texture_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;

uniform float specular : hint_range(0.0, 1.0, 0.01);

uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;
varying vec3 uv1_triplanar_pos;
varying vec3 uv2_triplanar_pos;
uniform sampler2D sand_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;

uniform float uv1_blend_sharpness : hint_range(0.0, 150.0, 0.001);
varying vec3 uv1_power_normal;

uniform vec3 uv1_scale;
uniform vec3 uv1_offset;
uniform vec3 uv2_scale;
uniform vec3 uv2_offset;

uniform sampler2D noise: source_color, filter_linear_mipmap, repeat_enable;
uniform float notile_offset;

uniform vec3 albedo_var: source_color;

uniform sampler2D noise_c_variation: source_color, filter_linear_mipmap, repeat_enable;
uniform float noise_c_scale = 10.0;

instance uniform vec3 offset_pos;



void vertex() {
	vec3 normal = NORMAL;


	TANGENT = vec3(0.0, 0.0, -1.0) * abs(normal.x);
	TANGENT += vec3(1.0, 0.0, 0.0) * abs(normal.y);
	TANGENT += vec3(1.0, 0.0, 0.0) * abs(normal.z);
	TANGENT = normalize(TANGENT);

	BINORMAL = vec3(0.0, 1.0, 0.0) * abs(normal.x);
	BINORMAL += vec3(0.0, 0.0, -1.0) * abs(normal.y);
	BINORMAL += vec3(0.0, 1.0, 0.0) * abs(normal.z);
	BINORMAL = normalize(BINORMAL);

	// UV1 Triplanar: Enabled
	uv1_power_normal = pow(abs(NORMAL), vec3(uv1_blend_sharpness));
	uv1_triplanar_pos = (VERTEX + offset_pos) * uv1_scale + uv1_offset;
	uv1_power_normal /= dot(uv1_power_normal, vec3(1.0));
	uv1_triplanar_pos *= vec3(1.0, -1.0, 1.0);

	uv2_triplanar_pos = VERTEX * uv1_scale + uv1_offset;
	uv2_triplanar_pos *= vec3(1.0, -1.0, 1.0);

}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
}


float sum( vec3 v ) { return v.x+v.y+v.z; }

// From: https://www.shadertoy.com/view/Xtl3zf

vec3 textureNoTile(sampler2D tex, in vec2 x, float v ) {
    float k = texture( noise, 0.005*x ).x; // cheap (cache friendly) lookup

    vec2 duvdx = dFdx( x );
    vec2 duvdy = dFdy( x );

    float l = k*8.0;
    float f = fract(l);

//#if 1
    //float ia = floor(l); // my method
    //float ib = ia + 1.0;
//#else
    float ia = floor(l+0.5); // suslik's method (see comments)
    float ib = floor(l);
    f = min(f, 1.0-f)*2.0;
//#endif

    vec2 offa = sin(vec2(3.0,7.0)*ia); // can replace with any other hash
    vec2 offb = sin(vec2(3.0,7.0)*ib); // can replace with any other hash

    vec3 cola = textureGrad(tex, x + v*offa, duvdx, duvdy ).xyz;
    vec3 colb = textureGrad(tex, x + v*offb, duvdx, duvdy ).xyz;

    return mix( cola, colb, smoothstep(0.2,0.8,f-0.1*sum(cola-colb)) );
}


vec3 triplanar_texture_notile(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec3 samp = vec3(0.0);
	samp += textureNoTile(p_sampler, p_triplanar_pos.xy, notile_offset).rgb * p_weights.z;
	samp += textureNoTile(p_sampler, p_triplanar_pos.xz, notile_offset).rgb * p_weights.y;
	samp += textureNoTile(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0), notile_offset).rgb * p_weights.x;
	return samp;
}

vec3 blend_normals(vec3 a, vec3 b) {
	return vec3(a.xy + b.xy - 0.5, a.z);
}

void fragment() {
	vec3 albedo = triplanar_texture(noise_c_variation, uv1_power_normal, uv1_triplanar_pos * noise_c_scale / 10000.0).rgb;

	vec3 rock_normal_tex = triplanar_texture_notile(texture_normal, uv1_power_normal, uv1_triplanar_pos).rgb;
	vec3 sand_normal_tex = triplanar_texture_notile(sand_normal, uv1_power_normal, uv1_triplanar_pos * 0.05).rgb;

	float offset = 0.9;
	float fade = 0.1;

	//vec3 rock_normal = rock_normal_tex * 2.0 - 1.0;
	//rock_normal.z = sqrt(1.0 - rock_normal.x * rock_normal.x - rock_normal.y * rock_normal.y);
	//vec3 normal_applied = rock_normal.x * TANGENT + rock_normal.y * BINORMAL + rock_normal.z * NORMAL;

	vec3 up_vector_viewspace = mat3(VIEW_MATRIX) * normalize(offset_pos);
	float dot_product = dot(up_vector_viewspace, NORMAL);
	float mask = smoothstep(offset - fade, offset + fade, dot_product);


	//float mask_var = mask * (1.0 - pow(triplanar_texture(noise, uv1_power_normal, uv1_triplanar_pos * 0.0002).x, 0.5));

	vec3 roughness_texture_channel = vec3(1.0, 0.0, 0.0);
	float roughness_tex = triplanar_texture_notile(texture_roughness, uv1_power_normal, uv1_triplanar_pos).r;
	float sand_roughness_tex = triplanar_texture_notile(sand_roughness, uv1_power_normal, uv1_triplanar_pos).r * 1.5;


	ALBEDO = albedo.rgb;
	SPECULAR = specular;
	ROUGHNESS = mix(roughness_tex * roughness, sand_roughness_tex, mask);
	NORMAL_MAP = mix(rock_normal_tex, sand_normal_tex, mask);
	NORMAL_MAP_DEPTH = normal_scale;
}
