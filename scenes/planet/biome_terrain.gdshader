// Water based planet shader
// 1st layer: sand near water and based on humidity, rock (based on normal), soil based on temperature
// 2nd layer: grass (color based on biome)
// 3rd layer: snow based on temp




shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;


uniform sampler2D base_normal: hint_normal, filter_linear_mipmap;


uniform sampler2D terrain_map: source_color, filter_linear_mipmap;
uniform sampler2D biome_map: source_color, filter_linear_mipmap;
uniform highp sampler2DArray ground_textures: filter_linear_mipmap, repeat_enable;

uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;
uniform float uv1_blend_sharpness : hint_range(0.0, 150.0, 0.001);

uniform vec3 uv1_scale;
uniform vec3 uv1_offset;

uniform float blend_start = 10.0;
uniform float blend_end  = 30.0;

uniform sampler2D noise: source_color, filter_linear_mipmap, repeat_enable;
uniform float notile_offset = 1.0;

uniform float terrain_normal_blend_offset = 0.9;
uniform float terrain_normal_blend_fade = 0.1;

uniform vec4 sand_color: source_color = vec4(0.8, 0.7, 0.4, 1.0);
uniform vec4 rock_color: source_color = vec4(0.4, 0.4, 0.4, 1.0);
uniform vec4 soil_color: source_color = vec4(0.35, 0.2, 0.1, 1.0);

uniform sampler2D distant_normal: hint_normal;

uniform float snow_temp_threshold = 0.3;
uniform float sand_elev_threshold = 0.05;
uniform float soil_humid_blend = 0.05;

instance uniform vec3 offset_pos;

varying vec3 uv1_triplanar_pos;
varying vec3 uv1_power_normal;

varying float terrain_slope;

void vertex() {
	vec3 normal = NORMAL;
	terrain_slope = dot(normalize(offset_pos + VERTEX), NORMAL);

	//TANGENT = vec3(0.0, 0.0, -1.0) * abs(normal.x);
	//TANGENT += vec3(1.0, 0.0, 0.0) * abs(normal.y);
	//TANGENT += vec3(1.0, 0.0, 0.0) * abs(normal.z);
	//TANGENT = normalize(TANGENT);
//
	//BINORMAL = vec3(0.0, 1.0, 0.0) * abs(normal.x);
	//BINORMAL += vec3(0.0, 0.0, -1.0) * abs(normal.y);
	//BINORMAL += vec3(0.0, 1.0, 0.0) * abs(normal.z);
	//BINORMAL = normalize(BINORMAL);

	// UV1 Triplanar: Enabled
	uv1_power_normal = pow(abs(NORMAL), vec3(uv1_blend_sharpness));
	uv1_triplanar_pos = (VERTEX + offset_pos) * uv1_scale + uv1_offset;
	uv1_power_normal /= dot(uv1_power_normal, vec3(1.0));
	uv1_triplanar_pos *= vec3(1.0, -1.0, 1.0);


}

vec4 triplanar_texture(sampler2DArray p_sampler, vec3 p_weights, vec3 p_triplanar_pos, float layer) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, vec3(p_triplanar_pos.xy, layer)) * p_weights.z;
	samp += texture(p_sampler, vec3(p_triplanar_pos.xz, layer)) * p_weights.y;
	samp += texture(p_sampler, vec3(p_triplanar_pos.zy * vec2(-1.0, 1.0), layer)) * p_weights.x;
	return samp;
}


float sum( vec4 v ) { return v.x+v.y+v.z+v.w; }

// From: https://www.shadertoy.com/view/Xtl3zf

vec4 textureNoTile(sampler2DArray tex, in vec2 x, float layer, float v) {
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

    vec4 cola = textureGrad(tex, vec3(x + v*offa, layer), duvdx, duvdy);
    vec4 colb = textureGrad(tex, vec3(x + v*offb, layer), duvdx, duvdy);

    return mix( cola, colb, smoothstep(0.2,0.8,f-0.1*sum(cola-colb)) );
}


vec4 triplanar_texture_notile(sampler2DArray p_sampler, vec3 p_weights, vec3 p_triplanar_pos, float layer) {
	vec4 samp = vec4(0.0);
	samp += textureNoTile(p_sampler, p_triplanar_pos.xy, layer, notile_offset) * p_weights.z;
	samp += textureNoTile(p_sampler, p_triplanar_pos.xz, layer, notile_offset) * p_weights.y;
	samp += textureNoTile(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0), layer, notile_offset) * p_weights.x;
	return samp;
}

vec3 blend_normals(vec3 a, vec3 b) {
	return vec3(a.xy + b.xy - 0.5, a.z);
}

vec3 normal_from_packed_tex(vec4 packed_tex) {
	vec2 normal_xy  = packed_tex.rg * 2.0 - 1.0;
    float normal_z  = sqrt(max(0.0, 1.0 - dot(normal_xy, normal_xy)));
    vec3 normal_map = vec3(normal_xy, normal_z) + 1.0 / 2.0;
	return normal_map;
}

vec3 get_biome_color(float temp, float humid) {
    // lookup texture with humidity (x) and temp (y)
    return texture(biome_map, vec2(humid, temp)).rgb;
}

void fragment() {

	vec3 planet_tex = texture(terrain_map, UV + vec2(0.0, 10.0)).rgb;
	float elev = planet_tex.r;
	float temp = planet_tex.g;
	float humid = planet_tex.b;

	//vec3 up_dir_chunk = normalize(offset_pos + VERTEX);
	//vec3 up_vector_viewspace = up_dir_chunk; //mat3(VIEW_MATRIX) * vert_normal;
	//float dot_product = dot(up_vector_viewspace, mat3(VIEW_MATRIX) * NORMAL);
	float slope = smoothstep(terrain_normal_blend_offset - terrain_normal_blend_fade, terrain_normal_blend_offset + terrain_normal_blend_fade, terrain_slope);


	vec3 distant_n = texture(distant_normal, UV * 100.0).rgb;

	// Layer masks
    float sand_mask = slope * clamp((smoothstep(0.04, 0.035, elev) + smoothstep(sand_elev_threshold, 0.8, temp)), 0.0, 1.0);
    float rock_mask = 1.0 - slope;
    float soil_mask = slope * smoothstep(0.7, 0.6, temp);
    float grass_mask = soil_mask * smoothstep(soil_humid_blend, 0.2, humid);
    float snow_mask = clamp(smoothstep(snow_temp_threshold, 0.01, temp) + smoothstep(0.7, 0.75, elev), 0.0, 1.0);

	// Normalize masks
    float sum_mask = sand_mask + rock_mask + soil_mask + grass_mask + snow_mask + 0.0001;
    sand_mask /= sum_mask;
    rock_mask /= sum_mask;
    soil_mask /= sum_mask;
    grass_mask /= sum_mask;
    snow_mask /= sum_mask;

	vec2 fuv = UV * 1000.0;

	// Textures sampling
	//vec4 sand_tex = triplanar_texture(ground_textures, uv1_power_normal, uv1_triplanar_pos , 1.0);
	vec4 sand_tex = texture(ground_textures,vec3(fuv, 1.0)); // triplanar_texture_notile(ground_textures, uv1_power_normal, uv1_triplanar_pos / 100000.0, 1.0);
	vec4 rock_tex = triplanar_texture(ground_textures, uv1_power_normal, uv1_triplanar_pos, 0.0); // texture(ground_textures,vec3(fuv * 3000.0, 0.0));
	vec4 soil_tex = triplanar_texture(ground_textures, uv1_power_normal, uv1_triplanar_pos, 2.0); //texture(ground_textures,vec3(fuv * 3000.0, 2.0));

	// Colors
    vec3 sand_col = sand_tex.b * sand_color.rgb;
    vec3 rock_col = rock_tex.b * rock_color.rgb;
    vec3 soil_col = soil_tex.b * soil_color.rgb;
    vec3 grass_col = get_biome_color(temp, humid);
    vec3 snow_col = vec3(1.0);

	// Final color blend
	vec3 col = sand_col * sand_mask +
               rock_col * rock_mask +
               soil_col * soil_mask +
               grass_col * grass_mask +
               snow_col * snow_mask;

	ALBEDO = sand_col; //vec3(fuv.xy / 2.0, 1.0); //col;

	// Final normal blend
	vec3 sand_normal = normal_from_packed_tex(sand_tex);
	vec3 rock_normal = normal_from_packed_tex(rock_tex);
	vec3 soil_normal = normal_from_packed_tex(soil_tex);
	vec3 b_normal = texture(base_normal, fuv).rgb;

	vec3 normal = normalize(sand_normal * sand_mask +
               rock_normal * rock_mask +
               soil_normal * soil_mask +
               b_normal * grass_mask +
               b_normal * snow_mask
	);

	 // World-space position of the fragment
    vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    // Distance from camera
    float dist = distance(CAMERA_POSITION_WORLD, world_pos);
	// Blend factor between 0 (near) and 1 (far)
    float blend = smoothstep(blend_start, blend_end, dist);


	ROUGHNESS = 1.0;

	NORMAL_MAP = normal;

	//ALBEDO = vec3(blend);

	NORMAL_MAP_DEPTH = normal_scale;
}
