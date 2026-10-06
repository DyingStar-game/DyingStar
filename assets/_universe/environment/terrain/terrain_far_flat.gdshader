shader_type spatial;
// A ground surface seen from afar, for a material that cannot light itself there (a StandardMaterial3D —
// the grass, the leaf litter, the lunar regolith — or a shader without terrain_far_light): its
// colour from afar is the average of its texture, lit by the star like every other ground
// (terrain_far_light). FarGround builds one per such material and puts it on the chunk's surface while
// the chunk is far (the celestial layer), so no ground is ever black from afar.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://assets/_universe/environment/terrain/terrain_far_light.gdshaderinc"

// The ground's albedo from afar: the material's albedo colour times the average of its texture.
uniform vec3 far_albedo : source_color = vec3(0.4);

varying vec3 far_radial;
varying float far_cam_dist;

void vertex() {
	far_radial = far_light_radial(MODEL_MATRIX, VERTEX + CUSTOM0.xyz);
	far_cam_dist = far_light_cam_dist(MODELVIEW_MATRIX, VERTEX + CUSTOM0.xyz);
}

void fragment() {
	ALBEDO = far_albedo;
	ROUGHNESS = 1.0;
	EMISSION += far_light_emission(ALBEDO, far_radial, far_cam_dist, VIEW_MATRIX, VERTEX);
}
