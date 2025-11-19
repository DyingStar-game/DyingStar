shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;


uniform int layer_count = 2;
uniform sampler2D color_map: source_color;
uniform sampler2DArray biome_color: source_color, filter_linear_mipmap;
uniform sampler2DArray biome_normal: filter_linear_mipmap;
uniform sampler2D terrain_normal: hint_normal, filter_linear_mipmap;

uniform sampler2D rock_albedo: source_color, filter_linear_mipmap;
uniform sampler2D rock_normal: hint_normal, filter_linear_mipmap;

uniform sampler2D ground_albedo: source_color, filter_linear_mipmap;
uniform sampler2D ground_normal: hint_normal, filter_linear_mipmap;


uniform sampler2D noise: source_color, filter_linear_mipmap, repeat_enable;
uniform float notile_offset;

uniform float uv1_blend_sharpness = 8.0;
uniform float uv1_scale = 1.0;
uniform float uv_distance_scale = 1.0;
uniform float surface_uv_scale = 100.0;

uniform float terrain_normal_blend_offset = 0.9;
uniform float terrain_normal_blend_fade = 0.1;


instance uniform vec3 offset_pos;

varying vec3 uv1_triplanar_pos;
varying vec3 uv1_triplanar_pos_loc;

varying vec3 uv1_power_normal;

varying float terrain_slope;

varying vec2 _uv;

void vertex() {
	vec3 normal = NORMAL;
	terrain_slope = dot(normalize(offset_pos + VERTEX), NORMAL);

	TANGENT = vec3(0.0,0.0,-1.0) * abs(normal.x);
	TANGENT+= vec3(1.0,0.0,0.0) * abs(normal.y);
	TANGENT+= vec3(1.0,0.0,0.0) * abs(normal.z);
	TANGENT = normalize(TANGENT);
	BINORMAL = vec3(0.0,1.0,0.0) * abs(normal.x);
	BINORMAL+= vec3(0.0,0.0,-1.0) * abs(normal.y);
	BINORMAL+= vec3(0.0,1.0,0.0) * abs(normal.z);
	BINORMAL = normalize(BINORMAL);


	_uv = UV * uv1_scale;
	
	// UV1 Triplanar: Enabled
	uv1_power_normal = pow(abs(NORMAL), vec3(uv1_blend_sharpness));
	
	uv1_triplanar_pos = (VERTEX + offset_pos) * uv1_scale / 1000.0;
	uv1_triplanar_pos_loc = VERTEX * uv1_scale / 1000.0;
	uv1_triplanar_pos_loc *= vec3(1.0, -1.0, 1.0);
	
	uv1_power_normal /= dot(uv1_power_normal, vec3(1.0));
	uv1_triplanar_pos *= vec3(1.0, -1.0, 1.0);
}
float sum( vec3 v ) { return v.x+v.y+v.z; }

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

vec4 triplanar_texture_arr(sampler2DArray p_sampler, vec3 p_weights, vec3 p_triplanar_pos, float layer) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, vec3(p_triplanar_pos.xy, layer)) * p_weights.z;
	samp += texture(p_sampler, vec3(p_triplanar_pos.xz, layer)) * p_weights.y;
	samp += texture(p_sampler, vec3(p_triplanar_pos.zy, layer) * vec3(-1.0, 1.0, 1.0)) * p_weights.x;
	return samp;
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
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

vec3 sample_layers(sampler2DArray tex, vec2 uv, ivec2 layer_bounds, float local_blend) {
	vec4 tex_lower = texture(tex, vec3(uv, float(layer_bounds.x)));
    vec4 tex_upper = texture(tex, vec3(uv, float(layer_bounds.y)));

	return mix(tex_lower, tex_upper, local_blend).rgb;
}

void fragment() {

	//vec2 uv = UV * uv1_scale;

	//vec3 up_dir_chunk = normalize(offset_pos + VERTEX);
	//vec3 up_vector_viewspace = up_dir_chunk; //mat3(VIEW_MATRIX) * vert_normal;
	//float dot_product = dot(up_vector_viewspace, mat3(VIEW_MATRIX) * NORMAL);
	float slope = smoothstep(terrain_normal_blend_offset - terrain_normal_blend_fade, terrain_normal_blend_offset + terrain_normal_blend_fade, terrain_slope);


	//ALBEDO = COLOR.r * vec3(0.6, 0.2, 0.0);
	//ALBEDO = vec3(COLOR.r, 0.0, 0.0);
	//ALBEDO = triplanar_texture_arr(biome_color, uv1_power_normal, uv1_triplanar_pos, COLOR.r).rgb;
	ROUGHNESS = 1.0;

	SPECULAR = 0.2;


	vec3 terrain_n = triplanar_texture(terrain_normal, uv1_power_normal, uv1_triplanar_pos_loc * uv_distance_scale).rgb;

	//NORMAL_MAP = blend_normals(triplanar_texture_arr(biome_normal, uv1_power_normal * vec3(1, 1, 1), uv1_triplanar_pos, COLOR.r).rgb, terrain_n);

	float scaled = COLOR.r * float(layer_count - 1);
    int lower_layer = int(floor(scaled));
    int upper_layer = lower_layer + 1;
    float local_blend = fract(scaled);

    vec3 albedo = sample_layers(biome_color, _uv, ivec2(lower_layer, upper_layer), local_blend);

	vec3 color_variation = texture(color_map, vec2(COLOR.r, 0.0)).rgb;
	vec3 biome_albedo = mix(albedo, color_variation, 0.2);

	vec3 ground_a = triplanar_texture_notile(ground_albedo, uv1_power_normal, uv1_triplanar_pos_loc * surface_uv_scale).rgb;
	vec3 rock_a = triplanar_texture_notile(rock_albedo, uv1_power_normal, uv1_triplanar_pos_loc * surface_uv_scale).rgb;
	vec3 surface_a = mix(rock_a, ground_a, slope);

	ALBEDO = mix(biome_albedo, surface_a, 0.5);
	//ALBEDO = vec3(_uv.xy, 0.0);
	//ALBEDO = COLOR.rrr;

	vec3 normal = sample_layers(biome_normal, _uv, ivec2(lower_layer, upper_layer), local_blend);
	//vec3 biome_n = blend_normals(normal, terrain_n);
	vec3 biome_n = terrain_n * smoothstep(0.0, 1.0, length(VERTEX) / 1000.0);
	
	vec3 ground_n = triplanar_texture_notile(ground_normal, uv1_power_normal, uv1_triplanar_pos_loc * surface_uv_scale).rgb;
	vec3 rock_n = triplanar_texture_notile(rock_normal, uv1_power_normal, uv1_triplanar_pos_loc * surface_uv_scale).rgb;
	vec3 surface_n = mix(rock_n, ground_n, slope);

	NORMAL_MAP = mix(surface_n, biome_n, 0.2);
	NORMAL_MAP.x = clamp(NORMAL_MAP.x, 0.0, 1.0);
	NORMAL_MAP.y = clamp(NORMAL_MAP.y, 0.0, 1.0);
	NORMAL_MAP.z = clamp(NORMAL_MAP.z, 0.0, 1.0);
	NORMAL_MAP_DEPTH = 1.5;
}
