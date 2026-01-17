shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Rocky ground terrain shader — triplanar object-space mapping.
// Uses VERTEX (chunk-local coordinates) for UV tiling so that textures
// are stable at planet scale.  In double-precision Godot,
// MODEL_MATRIX gives camera-relative positions that drift each frame;
// VERTEX is chunk-local and bounded, giving clean float32 UVs.
//
// cull_disabled: skirt geometry shares vertex normals with terrain edge
// vertices.  At planet scale, some skirt triangles have winding that
// appears backfacing from the camera; culling them creates black holes
// at the horizon.  Since vertex normals control shading (not face
// winding), cull_disabled is visually correct.

group_uniforms terrain;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_texture : filter_linear_mipmap, repeat_enable;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float metallic  : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float normal_strength : hint_range(0.0, 2.0, 0.01) = 1.0;

group_uniforms tiling;
// Object-space tiling: texture repeats every (1.0 / tile_scale) metres.
// 0.125 → one repeat every 8 m.
uniform float tile_scale : hint_range(0.001, 1.0, 0.001) = 0.125;
// Triplanar blending sharpness (higher = sharper axis selection).
uniform float triplanar_sharpness : hint_range(1.0, 16.0, 0.1) = 4.0;

// Per-chunk planet-space origin (modularly wrapped for float32 precision).
// Set via MeshInstance3D.set_instance_shader_parameter() so that
// adjacent chunks compute the same planet-space position at shared edges,
// eliminating triplanar texture seams.
instance uniform vec3 chunk_origin_mod;

varying vec3 local_pos;
varying vec3 obj_normal;

void vertex() {
	// Recover the surface position for triplanar UV.  For terrain vertices
	// CUSTOM0 is zero so VERTEX + CUSTOM0 == VERTEX.
	// For skirt vertices VERTEX is at the dropped position and CUSTOM0
	// holds the inverse offset back to the surface.
	local_pos  = chunk_origin_mod + VERTEX + CUSTOM0.xyz;
	// Pass object-space normal for triplanar axis blending.
	// NORMAL in vertex() is object-space; in fragment() it's view-space.
	// Triplanar needs a stable frame independent of camera orientation.
	obj_normal = NORMAL;
	// VERTEX already stores the final geometry position (dropped for
	// skirt vertices, surface for terrain) — no displacement needed.
}

void fragment() {
	// Triplanar blend weights from object-space normal (stable).
	vec3 n = abs(obj_normal);
	n = pow(n, vec3(triplanar_sharpness));
	n /= (n.x + n.y + n.z);

	float s = tile_scale;

	// ── Albedo ──────────────────────────────────────────────────────
	vec3 a_x = texture(albedo_texture, local_pos.yz * s).rgb;
	vec3 a_y = texture(albedo_texture, local_pos.xz * s).rgb;
	vec3 a_z = texture(albedo_texture, local_pos.xy * s).rgb;
	ALBEDO = a_x * n.x + a_y * n.y + a_z * n.z;

	// ── ORM (AO in R, Roughness in G, Metallic in B) ────────────────
	vec3 o_x = texture(orm_texture, local_pos.yz * s).rgb;
	vec3 o_y = texture(orm_texture, local_pos.xz * s).rgb;
	vec3 o_z = texture(orm_texture, local_pos.xy * s).rgb;
	vec3 orm = o_x * n.x + o_y * n.y + o_z * n.z;
	AO        = orm.r;
	ROUGHNESS = orm.g * roughness;
	METALLIC  = orm.b * metallic;

	// Normal mapping disabled — the mesh lacks tangent data, so
	// NORMAL_MAP produces incorrect lighting on skirt geometry
	// (vertical faces with horizontal tangent frames).
	// The analytical heightmap-gradient vertex normals are sufficient.
}
