shader_type spatial;

uniform vec4 albedo : source_color;
uniform float roughness : hint_range(0.0, 1.0);
uniform float specular : hint_range(0.0, 1.0, 0.01);
uniform float metallic : hint_range(0.0, 1.0, 0.01);

uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale : hint_range(-16.0, 16.0);

uniform sampler2D texture_heightmap : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float heightmap_scale : hint_range(-16.0, 16.0, 0.001);
uniform int heightmap_min_layers : hint_range(1, 64);
uniform int heightmap_max_layers : hint_range(1, 64);
uniform vec2 heightmap_flip;

instance uniform float animation_speed = 1.0;

uniform bool parralax = false;

void fragment() {
	vec2 base_uv = UV;

	base_uv += vec2(TIME * 0.2 * animation_speed, 0.0);



	if (parralax) {
		// Height: Enabled
		vec3 view_dir = normalize(normalize(-VERTEX + EYE_OFFSET) * mat3(TANGENT * heightmap_flip.x, -BINORMAL * heightmap_flip.y, NORMAL));

		// Height Deep Parallax: Enabled
		float num_layers = mix(float(heightmap_max_layers), float(heightmap_min_layers), abs(dot(vec3(0.0, 0.0, 1.0), view_dir)));
		float layer_depth = 1.0 / num_layers;
		float current_layer_depth = 0.0;
		vec2 p = view_dir.xy * heightmap_scale * 0.01;
		vec2 delta = p / num_layers;
		vec2 ofs = base_uv;
		float depth = 1.0 - texture(texture_heightmap, ofs).r;

		float current_depth = 0.0;
		while (current_depth < depth) {
			ofs -= delta;
			depth = 1.0 - texture(texture_heightmap, ofs).r;

			current_depth += layer_depth;
		}

		vec2 prev_ofs = ofs + delta;
		float after_depth = depth - current_depth;
		float before_depth = (1.0 - texture(texture_heightmap, prev_ofs).r) - current_depth + layer_depth;

		float weight = after_depth / (after_depth - before_depth);
		ofs = mix(ofs, prev_ofs, weight);
		base_uv = ofs;
	}
//
	//{
		//// Height: Enabled
		//vec3 view_dir = normalize(normalize(-VERTEX + EYE_OFFSET) * mat3(TANGENT * heightmap_flip.x, -BINORMAL * heightmap_flip.y, NORMAL));
//
		//// Height Deep Parallax: Enabled
		//float num_layers = mix(float(heightmap_max_layers), float(heightmap_min_layers), abs(dot(vec3(0.0, 0.0, 1.0), view_dir)));
		//float layer_depth = 1.0 / num_layers;
		//float current_layer_depth = 0.0;
		//vec2 p = view_dir.xy * heightmap_scale * 0.01;
		//vec2 delta = p / num_layers;
		//vec2 ofs = base_uv;
		//float depth = 1.0 - texture(texture_heightmap, ofs).r;
//
		//float current_depth = 0.0;
		//while (current_depth < depth) {
			//ofs -= delta;
			//depth = 1.0 - texture(texture_heightmap, ofs).r;
//
			//current_depth += layer_depth;
		//}
//
		//vec2 prev_ofs = ofs + delta;
		//float after_depth = depth - current_depth;
		//float before_depth = (1.0 - texture(texture_heightmap, prev_ofs).r) - current_depth + layer_depth;
//
		//float weight = after_depth / (after_depth - before_depth);
		//ofs = mix(ofs, prev_ofs, weight);
		//base_uv = ofs;
	//}

	ALBEDO = albedo.rgb;
	METALLIC = metallic;
	SPECULAR = specular;
	ROUGHNESS = roughness;

	// Normal Map: Enabled
	NORMAL_MAP = texture(texture_normal, base_uv).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
}
