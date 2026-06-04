shader_type spatial;
render_mode cull_back;
// Rock material: local-space triplanar albedo (matches the original rock material)
// + red veins where the SURFACE is near a predefined fault plane, so faults read
// as crack lines ON the mesh. Each fault plane is { normal, offset } in LOCAL space:
//   distance(fragment) = dot(normal, local_pos) - offset

uniform sampler2D albedo_tex : source_color;
uniform float tex_scale = 1.0;
uniform vec3 vein_color : source_color = vec3(1.0, 0.15, 0.12);
uniform float vein_width = 0.02;
uniform int plane_count = 0;
uniform vec3 plane_normals[8];
uniform float plane_offsets[8];

varying vec3 v_local;
varying vec3 v_normal;

void vertex() {
	v_local = VERTEX;
	v_normal = NORMAL;
}

void fragment() {
	// Local-space triplanar albedo (blend the 3 axis projections by the normal).
	vec3 bw = abs(normalize(v_normal));
	bw /= max(bw.x + bw.y + bw.z, 0.0001);
	vec3 p = v_local * tex_scale;
	vec3 col = texture(albedo_tex, p.zy).rgb * bw.x
	         + texture(albedo_tex, p.xz).rgb * bw.y
	         + texture(albedo_tex, p.xy).rgb * bw.z;

	// Red veins at the fault planes.
	float vein = 0.0;
	for (int i = 0; i < plane_count; i++) {
		float d = abs(dot(plane_normals[i], v_local) - plane_offsets[i]);
		vein = max(vein, 1.0 - smoothstep(vein_width * 0.4, vein_width, d));
	}

	ALBEDO = mix(col, vein_color, vein);
	EMISSION = vein_color * vein * 1.5;
	ROUGHNESS = 0.9;
}
