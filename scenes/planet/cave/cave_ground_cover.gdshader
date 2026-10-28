shader_type spatial;

// GROUND COVER on a cave's open-air surfaces (approach hollow, doline and light-shaft rims, exit bowl): the
// planet's own ground look (GroundLook: its texture and tint, or its flat biome colour) painted over the
// cave's rock where the build baked coverage into COLOR.r, full at the relief's level and fading with depth,
// slower on flat faces where drift settles. The rim stops reading as a seam between two materials.
//
// Worn as a material_overlay, like the ground fringe (terrain_blend.gdshader): the cave keeps its own
// materials. Coordinates are the mesh's own (the site frame, in metres), never world positions.
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_disabled;

uniform sampler2D ground_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool ground_textured = false;
// Tiling of the ground texture (per metre), as the ground shader's own tile_scale.
uniform float ground_scale = 0.1;
// How much the ground shader tints its texture by the biome colour (its vertex_color_strength).
uniform float ground_tint_strength = 0.0;
uniform sampler2D cover_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
// Per site: the colour the ground shows there (flat ground) or the tint it applies (textured ground).
instance uniform vec3 ground_tint = vec3(0.6, 0.55, 0.5);

varying vec3 local_pos;
varying vec3 local_normal;
varying float cover;

void vertex() {
	local_pos = VERTEX;
	local_normal = NORMAL;
	cover = COLOR.r;
}

void fragment() {
	vec3 albedo = ground_tint;
	if (ground_textured) {
		vec3 w = pow(abs(normalize(local_normal)), vec3(4.0));
		w /= max(w.x + w.y + w.z, 1e-4);
		vec3 tex = texture(ground_albedo, local_pos.zy * ground_scale).rgb * w.x
			+ texture(ground_albedo, local_pos.xz * ground_scale).rgb * w.y
			+ texture(ground_albedo, local_pos.xy * ground_scale).rgb * w.z;
		albedo = tex * mix(vec3(1.0), ground_tint, ground_tint_strength);
	} else {
		// Flat ground: a gentle mottle so the cover is not a painted plane.
		albedo *= 0.88 + 0.24 * texture(cover_noise, local_pos.xz * 0.21).r;
	}
	// A ragged edge on two scales, where the rock shows through the drift.
	float n = texture(cover_noise, local_pos.xz * 0.11).r * 0.65
		+ texture(cover_noise, local_pos.xz * 0.53 + vec2(local_pos.y * 0.3)).r * 0.35;
	ALBEDO = albedo;
	ROUGHNESS = 0.9;
	ALPHA = smoothstep(0.35, 0.65, cover + (n - 0.5) * 0.8);
}
