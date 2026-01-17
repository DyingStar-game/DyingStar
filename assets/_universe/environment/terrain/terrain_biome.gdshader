shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Terrain biome shader — uses vertex COLOR as base albedo.
// Supports:
//  - Normal mapping (UV-based)
//  - Roughness / metallic
//  - Triplanar detail texture from a Texture2DArray (layer index in UV2.x)

group_uniforms terrain;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float metallic  : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float normal_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform sampler2D normal_map : hint_normal;

// How much vertex color influences the final albedo (1.0 = full, 0.0 = flat).
group_uniforms blending;
uniform float vertex_color_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
// A fallback base color used when vertex_color_strength < 1.0.
uniform vec4 base_color : source_color = vec4(0.45, 0.35, 0.25, 1.0);

// Detail texture array — each layer is a grayscale modifier (0.5 = neutral).
// Layer index comes from UV2.x; tiling scale comes from UV2.y.
group_uniforms detail;
uniform sampler2DArray detail_textures : filter_linear_mipmap, repeat_enable;
uniform float detail_strength : hint_range(0.0, 1.0, 0.01) = 0.6;
// Triplanar blending sharpness (higher = sharper axis selection).
uniform float triplanar_sharpness : hint_range(1.0, 16.0, 0.1) = 4.0;

// Slope-based cliff face detection.
// Steep surfaces (dot(normal, planet_up) < threshold) get the rock detail
// texture blended in, giving cliff faces proper vertical-rock appearance.
group_uniforms cliff;
uniform float cliff_slope_threshold : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float cliff_blend_range : hint_range(0.01, 0.5, 0.01) = 0.15;
uniform float cliff_detail_layer_index : hint_range(0.0, 11.0, 1.0) = 2.0;
uniform float cliff_tiling_scale : hint_range(0.0001, 0.01, 0.0001) = 0.001;
uniform vec4  cliff_tint : source_color = vec4(0.38, 0.36, 0.34, 1.0);
uniform float cliff_tint_strength : hint_range(0.0, 1.0, 0.01) = 0.3;

varying vec3 world_pos;
varying vec3 world_normal;
varying flat float detail_layer;
varying float detail_scale;

void vertex() {
	// Recover the surface position for triplanar UV.
	// For terrain vertices CUSTOM0 is zero so VERTEX + CUSTOM0 == VERTEX.
	// For skirt vertices VERTEX is at the dropped position and CUSTOM0
	// holds the inverse offset back to the surface — keeping triplanar
	// texture continuous across the terrain-to-skirt boundary.
	world_pos    = (MODEL_MATRIX * vec4(VERTEX + CUSTOM0.xyz, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	detail_layer = UV2.x;    // integer layer index (0 = blank)
	detail_scale = UV2.y;    // per-biome tiling scale (world-space)
	// VERTEX already stores the final geometry position (dropped for
	// skirt vertices, surface for terrain) — no displacement needed.
}

void fragment() {
	// ── Base biome colour from vertex color ─────────────────────────
	vec3 biome_color = mix(base_color.rgb, COLOR.rgb, vertex_color_strength);

	// ── Triplanar detail texture ────────────────────────────────────
	// Sample the detail texture array using world-space triplanar UVs.
	// Each detail layer is a grayscale modifier centred on 0.5.
	float detail = 0.5;  // neutral (no modification)

	if (detail_scale > 0.0) {
		vec3 n = abs(world_normal);
		n = pow(n, vec3(triplanar_sharpness));
		n /= (n.x + n.y + n.z);

		float s = detail_scale;
		float layer = detail_layer;

		float d_x = texture(detail_textures, vec3(world_pos.yz * s, layer)).r;
		float d_y = texture(detail_textures, vec3(world_pos.xz * s, layer)).r;
		float d_z = texture(detail_textures, vec3(world_pos.xy * s, layer)).r;

		detail = d_x * n.x + d_y * n.y + d_z * n.z;
	}

	// ── Slope-based cliff face blending ─────────────────────────────
	// Detect steep surfaces and blend in rock detail texture + tint so
	// cliff faces get proper vertical rock appearance automatically.
	vec3 planet_up = normalize(world_pos);
	float slope = dot(world_normal, planet_up);  // 1.0 = flat, 0.0 = vertical
	float cliff_lo = cliff_slope_threshold - cliff_blend_range;
	float cliff_hi = cliff_slope_threshold + cliff_blend_range;
	float cliff_factor = 1.0 - smoothstep(cliff_lo, cliff_hi, slope);

	if (cliff_factor > 0.01 && detail_scale > 0.0) {
		vec3 cn = abs(world_normal);
		cn = pow(cn, vec3(triplanar_sharpness));
		cn /= (cn.x + cn.y + cn.z);
		float cs = cliff_tiling_scale;
		float cl = cliff_detail_layer_index;
		float cd_x = texture(detail_textures, vec3(world_pos.yz * cs, cl)).r;
		float cd_y = texture(detail_textures, vec3(world_pos.xz * cs, cl)).r;
		float cd_z = texture(detail_textures, vec3(world_pos.xy * cs, cl)).r;
		float cliff_detail = cd_x * cn.x + cd_y * cn.y + cd_z * cn.z;
		detail = mix(detail, cliff_detail, cliff_factor);
		biome_color = mix(biome_color, cliff_tint.rgb, cliff_factor * cliff_tint_strength);
	}

	// Blend: detail 0.5 = no change, <0.5 darkens, >0.5 brightens.
	// Using overlay-style blending for natural look.
	float mod = mix(1.0, detail * 2.0, detail_strength);
	ALBEDO = clamp(biome_color * mod, vec3(0.0), vec3(1.0));

	// Increase roughness on steep cliff faces for a more matte rock look.
	ROUGHNESS = mix(roughness, min(roughness + 0.1, 1.0), cliff_factor);
	METALLIC  = metallic;

	// Normal map (UV-based — equirectangular UV from chunk mesh).
	vec3 nm = texture(normal_map, UV).xyz;
	nm = nm * 2.0 - 1.0;
	NORMAL_MAP = nm * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;
}
