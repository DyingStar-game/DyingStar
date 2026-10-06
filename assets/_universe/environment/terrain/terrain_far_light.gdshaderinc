// How a planet's ground lights itself from afar — shared by EVERY ground material of a chunk
// (terrain_biome, planet_surface, rocky_ground), so a far body is lit whole.
//
// Distant chunks live on the celestial layer, where NO Godot light reaches them (the per-player sun is
// masked off, the star's OmniLight is ineffective at ~3e10 m). So the ground lights ITSELF from the real
// star direction and EMITS it, faded in with distance so near ground (blend 0) keeps the Godot per-player
// sun and its shadows. Only terrain_biome used to: every other ground stayed black from afar —
// Sandbox's corundum outcrops (planet_surface) and the lunar ground (rocky_ground), whole regions of
// black squares where the stars did not show through (2026-10-06).
//
// The per-chunk values (planet_terrain.gd, _assemble_visual_chunk) are instance uniforms at FIXED
// indices. A chunk with several surfaces — sand and a corundum outcrop — has ONE instance buffer, laid
// out by its first material: with indices left to each shader's declaration order, the others read
// their values from the wrong slots ("More than one material in instance export the same instance
// shader uniform ... with different indices", in every client log).

// Chunk origin wrapped to WRAP metres (fposmod(chunk_center, 8192)): triplanar coordinates are built
// from chunk-LOCAL vertex positions plus this small offset, float32-precise at every octave.
instance uniform vec3 chunk_origin_mod : instance_index(0);
// World-space direction from THIS planet to the star, computed in double precision on the CPU (exact at
// ~3e10 m, where a float32 world position would not be).
instance uniform vec3 star_dir_world : instance_index(1);
// Full planet-LOCAL chunk centre (the chunk's position under the planet): chunk_center_local + VERTEX is
// the planet-local vertex, ~4.5e6 m and float32-precise, so its direction is the TRUE radial 'up'.
instance uniform vec3 chunk_center_local : instance_index(2);

group_uniforms far_lighting;
// Past radial_blend_far the shading is on the smooth planet radial — a clean great-circle terminator
// instead of the wandering vertex normals of coarse chunks; below radial_blend_near the ground is the
// Godot sun's. Blended by CAMERA distance, so it only kicks in when the planet is a distant disc.
uniform float radial_blend_near : hint_range(0.0, 10000000.0, 10000.0) = 100000.0;
uniform float radial_blend_far : hint_range(0.0, 40000000.0, 10000.0) = 250000.0;
uniform float star_light_energy : hint_range(0.0, 8.0, 0.1) = 2.0;
uniform vec3 star_light_color : source_color = vec3(1.0, 0.95, 0.85);
group_uniforms;


// Camera -> point distance (view space is camera-relative: float32-precise at any world position).
// [param surface] is the chunk-local surface point (VERTEX + CUSTOM0.xyz).
float far_light_cam_dist(mat4 modelview, vec3 surface) {
	return length((modelview * vec4(surface, 1.0)).xyz);
}


// The TRUE smooth sphere normal, world space: the planet-local point rotated by the model's linear part
// (w = 0 drops the ~3e10 translation, so no float32 blow-up).
vec3 far_light_radial(mat4 model, vec3 surface) {
	return normalize((model * vec4(chunk_center_local + surface, 0.0)).xyz);
}


// How far the far lighting has taken over, 0 near, 1 far.
float far_light_blend(float cam_dist) {
	return smoothstep(radial_blend_near, radial_blend_far, cam_dist);
}


// The light this ground EMITS from afar: [param albedo] lit by the star on the smooth [param radial]
// (world space), faded in by [param cam_dist]. [param view] is VIEW_MATRIX and [param vertex_view] the
// fragment's VERTEX (view space): unused here, they are what the ground's air will need.
vec3 far_light_emission(vec3 albedo, vec3 radial, float cam_dist, mat4 view, vec3 vertex_view) {
	float blend = far_light_blend(cam_dist);
	float mu_star = max(dot(radial, star_dir_world), 0.0);
	return albedo * star_light_color * (mu_star * star_light_energy * blend);
}
