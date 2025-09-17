shader_type spatial;

uniform sampler2D map: source_color, filter_linear_mipmap;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	ALBEDO.rgb = texture(map, UV).rgb;
	//ALBEDO.rgb = vec3(UV, 0.0);
}