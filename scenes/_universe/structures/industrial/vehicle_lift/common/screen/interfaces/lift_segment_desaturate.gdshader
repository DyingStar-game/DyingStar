shader_type canvas_item;


instance uniform float amount : hint_range(0.0, 1.0) = 0.0;


void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	float grayscale = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	vec3 mixed_rgb = mix(COLOR.rgb, vec3(grayscale), amount);
	float mixed_alpha = COLOR.a * (1.0 - amount);
	//COLOR.rgb = mix(COLOR.rgb, vec3(grayscale), amount);
	//COLOR.a = COLOR.a * (amount * 2.0);
	COLOR = vec4(mixed_rgb, mixed_alpha);
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
