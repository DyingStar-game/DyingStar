shader_type spatial;
// cull_disabled (matches rocky_ground.gdshader): HEALPix terrain + skirt geometry
// can appear back-facing to the camera, so cull_back would punch black holes in the
// surface and leave only skirts visible. Double-sided rendering avoids that.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Terrain biome shader — uses vertex COLOR as base albedo.
// Supports:
//  - Normal mapping (UV-based)
//  - Roughness / metallic
//  - Triplanar detail texture from a Texture2DArray (layer index in UV2.x)

group_uniforms terrain;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float metallic  : hint_range(0.0, 1.0, 0.01) = 0.0;

// How much vertex color influences the final albedo (1.0 = full, 0.0 = flat).
group_uniforms blending;
uniform float vertex_color_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
// Scales the final albedo. A knob on the BIOME PALETTE, not a lighting correction.
//
// iron_tint() produces vertex colours around 0.82-0.90, which is the reflectance of fresh snow.
// Light sand sits near 0.35 and powdered corundum near 0.25, so the ground was returning about 2.4x
// the light it should. Until the cliff bug above was fixed this went unnoticed, because cliff_tint
// was darkening the entire day side by 30 % and hiding it.
//
// Measured at noon on Sandbox, ground against the sky directly above it:
//   before  ratio 7.78, 64 % of the ground's pixels clipped to white
//   at 0.40 ratio 3.53, no clipping at all   (light sand is physically 3.2)
//
// Lowering EXPOSURE instead would look similar and be wrong: it would darken the sky too, and the
// sky is correct. That is precisely what the cliff bug was doing by accident.
//
// This is a STOPGAP. The real fix belongs in iron_tint(), and the value needs a decision: the
// atmosphere profile of Sandbox declares ground_albedo = 0.15, which is what pins the planet's
// published 0.32 albedo and the calibration of mie_beta. 0.15, 0.40 and the 0.64 of KiFouine's
// corundum material cannot all be right.
uniform float albedo_multiplier : hint_range(0.05, 1.5, 0.01) = 1.0;
// A fallback base color used when vertex_color_strength < 1.0.
uniform vec4 base_color : source_color = vec4(0.45, 0.35, 0.25, 1.0);

// Detail texture array — each layer is a grayscale modifier (0.5 = neutral).
// Layer index comes from UV2.x; tiling scale comes from UV2.y.
group_uniforms detail;
// Anisotropic filtering is essential here: the ground is viewed at grazing
// angles, where plain trilinear picks the mip from the most-compressed screen
// axis and blurs the detail (and its bump) away — walls stayed sharp while
// floors went smooth.  Aniso keeps the along-view axis sharp.
uniform sampler2DArray detail_textures : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_strength : hint_range(0.0, 1.0, 0.01) = 0.6;
// Triplanar blending sharpness (higher = sharper axis selection).
uniform float triplanar_sharpness : hint_range(1.0, 16.0, 0.1) = 4.0;
// How strongly the grayscale detail height perturbs the surface normal.
// This is what gives the terrain its lit "rock imperfections and bumps"
// at every LOD — the mesh geometry is smoothed away by distance-LOD, but
// this bump is a per-fragment effect that survives.  0 = flat (old look).
uniform float detail_bump_strength : hint_range(0.0, 16.0, 0.1) = 4.0;
// Coarse (macro) bump octave — a lower-frequency copy of the detail height.
// Its screen-space derivatives are much smaller, so it survives the
// grazing-angle mip blur that flattens the fine octave — this is what makes
// flat ground (e.g. the corundum plateau top) show rolling rock relief
// instead of reading as a smooth plane.
uniform float detail_macro_ratio : hint_range(0.02, 1.0, 0.01) = 0.15;   // macro tiling = ratio × fine
uniform float detail_macro_strength : hint_range(0.0, 4.0, 0.1) = 3.0;   // 0 = disable macro octave
// Fine (near) octave — close-range grain.  The per-biome detail scale tiles
// about once per KILOMETRE (one texel ≈ 2 m), so standing on the surface you
// only ever see a smooth filtered gradient — the ground looks untextured up
// close while distant terrain shows the full pattern.  This octave re-tiles
// the same texture N× finer to give metre-scale grain underfoot; mip
// filtering fades it to neutral with distance automatically (no horizon noise).
// ~16 → base×16 = 0.016 (≈62 m repeat, ~12 cm texels): the "rock grain"
// frequency — fine enough to read as texture, coarse enough to stay resolvable
// at grazing distances (128 made 1.5 cm texels that are sub-pixel past ~2 m).
uniform float detail_fine_ratio : hint_range(1.0, 1024.0, 1.0) = 16.0;   // fine tiling = ratio × base
uniform float detail_fine_strength : hint_range(0.0, 4.0, 0.1) = 1.2;    // 0 = disable fine octave

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

// Far-distance shading-normal correction.
// Distant coarse-LOD chunks light on their GEOMETRIC vertex normals, which wander (heightmap finite
// differences over huge quads) and warp the day/night terminator into a wavy 'yin-yang'. Past
// radial_blend_far the shading normal is fully the smooth planet radial (planet_up) — a clean
// great-circle terminator; below radial_blend_near it is the full detail relief (no regression up
// close). Blended by CAMERA distance, so it only kicks in when the planet is a distant disc.
group_uniforms lighting;
uniform float radial_blend_near : hint_range(0.0, 10000000.0, 10000.0) = 100000.0;
uniform float radial_blend_far : hint_range(0.0, 40000000.0, 10000.0) = 250000.0;
// Per-fragment STAR lighting for distant chunks. On the celestial layer no Godot light reaches them
// (the per-player sun is masked off, the star OmniLight is ineffective at astronomic range), so we
// light them here: EMISSION = albedo * max(dot(radial, star_dir), 0) * energy, faded in with distance.
// star_dir_world is the world-space direction from THIS planet to the star, set per-chunk (computed in
// double precision on the CPU, so it is exact at ~3e10 where a float32 world_pos would not be).
uniform float star_light_energy : hint_range(0.0, 8.0, 0.1) = 2.0;
uniform vec3 star_light_color : source_color = vec3(1.0, 0.95, 0.85);
instance uniform vec3 star_dir_world;

// Chunk origin wrapped to WRAP metres, set per-chunk by planet_terrain.gd
// (fposmod(chunk_center, 8192)).  Triplanar coordinates are built from
// chunk-LOCAL vertex positions plus this small offset instead of the raw
// world position: at ~4.5e6 m from the planet origin a float32 world_pos
// has ~0.5 m precision steps, which shreds any detail octave whose texel
// is smaller than that (everything finer than the 1 km base octave).
// tri_pos stays < ~8300 m → sub-millimetre precision at every octave.
instance uniform vec3 chunk_origin_mod;
// Full (NON-wrapped) planet-LOCAL chunk centre, set per-chunk by planet_terrain.gd (= the chunk's
// position under the planet). chunk_center_local + VERTEX is the planet-local vertex (~4.5e6 m ->
// float32-precise, unlike the ~3e10 world position), so normalize() of it is the TRUE radial 'up';
// rotated to world by MODEL_MATRIX it becomes the smooth sphere normal used to de-warp the far
// terminator (see planet_radial_world). Zero disables the correction (radial == geometric normal).
instance uniform vec3 chunk_center_local;
// Must match `_wrap` in planet_terrain.gd.  Tiling scales are snapped to
// integer multiples of 1/WRAP so the pattern is seamless across the wrap
// (UV differs by scale×WRAP×integer between chunks → integer = no seam).
const float WRAP = 8192.0;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 tri_pos;
varying flat float detail_layer;
varying float detail_scale;
varying float cam_dist;  // camera -> fragment distance (m), for the far-distance radial normal blend
varying vec3 planet_radial_world;  // true smooth sphere normal (world space): terminator + star NdotL

// Snap a tiling scale to the seamless 1/WRAP grid (minimum one repeat/WRAP).
float snap_scale(float raw) {
	return max(round(raw * WRAP), 1.0) / WRAP;
}

// Detail texture side length (px) — used for manual LOD selection.
const float DETAIL_TEX_SIZE = 512.0;

// Manual "min-axis" mip LOD for one triplanar UV.  Hardware aniso is capped at
// 16x, so ground viewed at a grazing angle (>16:1 compression) drops to a
// blurred mip and the detail — and its bump gradient — collapse to a constant.
// Selecting the LOD from the LESS-compressed screen axis (min of the two
// derivative lengths) keeps grazing surfaces sharp with no 16:1 ceiling.
// Derivatives are on the tiled UV (from tri_pos → small, float32-precise).
float aniso_lod(vec2 uv) {
	vec2 dx = dFdx(uv) * DETAIL_TEX_SIZE;
	vec2 dy = dFdy(uv) * DETAIL_TEX_SIZE;
	return 0.5 * log2(max(min(dot(dx, dx), dot(dy, dy)), 1.0));
}

// Per-plane min-axis LODs for one octave.  MUST be called in uniform control
// flow (it uses dFdx/dFdy).  Returned LODs are then safe to use anywhere.
vec3 detail_lods(vec3 wp, float s) {
	return vec3(aniso_lod(wp.yz * s), aniso_lod(wp.xz * s), aniso_lod(wp.xy * s));
}

// One detail octave, triplanar-blended.
// Returns: .xyz = world-space bump-normal contribution, .w = height (0–1).
// Forward differences: for each plane, offset the base sample by an EXACT
// world-space step (stable despite float32 world_pos at planetary scale)
// and use the raw height delta (NOT per-metre slope) so the tilt scales with k.
// Fetches are explicit-LOD (textureLod) with caller-supplied min-axis LODs so
// grazing ground keeps its texture and a live bump gradient — and so the
// derivative calls stay in uniform flow even when this is used for cliffs.
vec4 detail_octave_sample(vec3 wp, float s, float layer, vec3 w, vec3 sgn, float k, vec3 lods) {
	float e = (1.0 / 256.0) / s;               // ~2-texel world step
	vec2 uyz = wp.yz * s;
	vec2 uxz = wp.xz * s;
	vec2 uxy = wp.xy * s;
	float lyz = lods.x;
	float lxz = lods.y;
	float lxy = lods.z;
	float bx = textureLod(detail_textures, vec3(uyz, layer), lyz).r;
	float by = textureLod(detail_textures, vec3(uxz, layer), lxz).r;
	float bz = textureLod(detail_textures, vec3(uxy, layer), lxy).r;
	vec2 gx = vec2(textureLod(detail_textures, vec3(uyz + vec2(e, 0.0) * s, layer), lyz).r - bx,
	               textureLod(detail_textures, vec3(uyz + vec2(0.0, e) * s, layer), lyz).r - bx);
	vec2 gy = vec2(textureLod(detail_textures, vec3(uxz + vec2(e, 0.0) * s, layer), lxz).r - by,
	               textureLod(detail_textures, vec3(uxz + vec2(0.0, e) * s, layer), lxz).r - by);
	vec2 gz = vec2(textureLod(detail_textures, vec3(uxy + vec2(e, 0.0) * s, layer), lxy).r - bz,
	               textureLod(detail_textures, vec3(uxy + vec2(0.0, e) * s, layer), lxy).r - bz);
	vec3 pnx = vec3(sgn.x, -gx * k);              // plane X (yz), base along X
	vec3 pny = vec3(-gy.x * k, sgn.y, -gy.y * k); // plane Y (xz), base along Y
	vec3 pnz = vec3(-gz * k, sgn.z);              // plane Z (xy), base along Z
	return vec4(pnx * w.x + pny * w.y + pnz * w.z,
	            bx * w.x + by * w.y + bz * w.z);
}

void vertex() {
	// Recover the surface position for triplanar UV.
	// For terrain vertices CUSTOM0 is zero so VERTEX + CUSTOM0 == VERTEX.
	// For skirt vertices VERTEX is at the dropped position and CUSTOM0
	// holds the inverse offset back to the surface — keeping triplanar
	// texture continuous across the terrain-to-skirt boundary.
	world_pos    = (MODEL_MATRIX * vec4(VERTEX + CUSTOM0.xyz, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// High-precision triplanar position: chunk-local vertex + wrapped chunk
	// origin.  Both terms are small (≤ ~8300 m), so float32 keeps
	// sub-millimetre precision — unlike world_pos (~4.5e6 m → 0.5 m steps).
	tri_pos      = chunk_origin_mod + VERTEX + CUSTOM0.xyz;
	// Camera->fragment distance for the far-distance radial normal blend (view space is camera-relative,
	// so this stays float32-precise regardless of the astronomic world position).
	cam_dist     = length((MODELVIEW_MATRIX * vec4(VERTEX + CUSTOM0.xyz, 1.0)).xyz);
	// TRUE radial 'up' as a world-space direction: the planet-local vertex (chunk_center_local + VERTEX,
	// precise) rotated by the model's linear part (the planet's world rotation; w=0 drops the ~3e10
	// translation, so no float32 blow-up). Smooth sphere normal for the far terminator + star lighting.
	planet_radial_world = normalize((MODEL_MATRIX * vec4(chunk_center_local + VERTEX + CUSTOM0.xyz, 0.0)).xyz);
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
	// ── Cliff factor (computed early) ───────────────────────────────
	// From the GEOMETRIC normal — never the bump-perturbed one, whose tilt
	// swings by tens of degrees and would flip surfaces in/out of the cliff
	// path per-fragment.  Computed here (before any texturing) so its VALUE —
	// not a per-fragment branch — blends the cliff result, keeping the
	// derivative-based LOD (dFdx in detail_lods) in uniform control flow.
	// The radial computed in vertex(), NOT normalize(world_pos). The comment on planet_radial_world
	// above already spells out why: w = 0 drops the model matrix's translation. world_pos keeps it,
	// and on the CLIENT that translation is the planet's Kepler position -- tarsis_4 orbits at
	// 0.63-0.67 AU, i.e. ~1e11 m from the universe root, against a 6.36e6 m radius. normalize() of
	// that returns the star-to-planet direction, which varies by 0.004 degrees across the whole
	// globe: `slope` was therefore not the local slope at all, but the dot of the surface normal
	// with a planet-wide constant. Every face on the star-facing hemisphere fell under
	// cliff_slope_threshold and rendered as cliff -- albedo pulled 30 % toward cliff_tint and
	// ROUGHNESS forced up -- while genuinely vertical faces elsewhere were missed.
	//
	// It only shows on the client: planet_body.gd returns early from _place_at_time() under
	// Engine.is_editor_hint() or dedicated_server, so in the editor and on the server the planet
	// sits at the origin and normalize(world_pos) happens to be right. That is why it survived.
	vec3 planet_up = planet_radial_world;
	float slope = dot(world_normal, planet_up);  // 1.0 = flat, 0.0 = vertical
	float cliff_lo = cliff_slope_threshold - cliff_blend_range;
	float cliff_hi = cliff_slope_threshold + cliff_blend_range;
	float cliff_factor = 1.0 - smoothstep(cliff_lo, cliff_hi, slope);

	float detail = 0.5;  // neutral (no modification)
	// Surface normal used for shading — starts as the geometric normal and is
	// perturbed by the detail height below so the rock micro-relief is lit.
	vec3 shaded_normal = world_normal;

	if (detail_scale > 0.0) {
		vec3 n = abs(world_normal);
		n = pow(n, vec3(triplanar_sharpness));
		n /= (n.x + n.y + n.z);

		// Snap all octave scales to the seamless 1/WRAP grid (see tri_pos).
		float s = snap_scale(detail_scale);
		float layer = detail_layer;
		vec3 sgn = sign(world_normal);

		// ── Three detail octaves ─────────────────────────────────────
		// Each octave contributes to BOTH the albedo modifier (height) and
		// the lit bump normal.  The mesh geometry is smoothed by distance-
		// LOD, but these per-fragment octaves are not:
		//   base  — the per-biome scale (~1 repeat/km for rock): the broad
		//           pattern you see on distant terrain.
		//   fine  — base × detail_fine_ratio: cm-scale grain underfoot.
		//   macro — base × detail_macro_ratio: broad swells.
		float sf = snap_scale(s * detail_fine_ratio);
		float sm = snap_scale(s * detail_macro_ratio);

		vec4 base_o = detail_octave_sample(tri_pos, s, layer, n, sgn,
				detail_bump_strength, detail_lods(tri_pos, s));
		detail = base_o.w;
		vec3 bn = base_o.xyz;
		// Count the base terms accumulated in bn: every octave carries one
		// sgn*n (the triplanar reconstruction of world_normal).  They are
		// subtracted below so only the gradient perturbation survives.
		float oct = 1.0;

		if (detail_fine_strength > 0.0) {
			vec4 fine_o = detail_octave_sample(tri_pos, sf, layer, n, sgn,
					detail_bump_strength * detail_fine_strength, detail_lods(tri_pos, sf));
			// Add the fine grain to the albedo modifier around neutral 0.5.
			detail = clamp(detail + (fine_o.w - 0.5) * detail_fine_strength, 0.0, 1.0);
			bn += fine_o.xyz;
			oct += 1.0;
		}

		if (detail_macro_strength > 0.0) {
			bn += detail_octave_sample(tri_pos, sm, layer, n, sgn,
					detail_bump_strength * detail_macro_strength, detail_lods(tri_pos, sm)).xyz;
			oct += 1.0;
		}

		// ── Cliff detail swap ────────────────────────────────────────
		// Steep faces blend in the cliff detail LAYER (e.g. rock on a sand
		// biome).  Skipped when the cliff layer+scale already equal the base
		// (true for whole-rock biomes like corundum) — a UNIFORM condition
		// (all inputs are per-draw constants), so dFdx stays in uniform flow.
		float cs = snap_scale(cliff_tiling_scale);
		float cl = cliff_detail_layer_index;
		if (abs(cl - layer) > 0.5 || abs(cs - s) > 1e-9) {
			float csf = snap_scale(cs * detail_fine_ratio);
			vec4 cbase = detail_octave_sample(tri_pos, cs, cl, n, sgn,
					detail_bump_strength, detail_lods(tri_pos, cs));
			float cliff_detail = cbase.w;
			vec3 cbn = cbase.xyz;
			float coct = 1.0;  // the cliff path has no macro octave
			if (detail_fine_strength > 0.0) {
				vec4 cfine = detail_octave_sample(tri_pos, csf, cl, n, sgn,
						detail_bump_strength * detail_fine_strength, detail_lods(tri_pos, csf));
				cliff_detail = clamp(cliff_detail + (cfine.w - 0.5) * detail_fine_strength, 0.0, 1.0);
				cbn += cfine.xyz;
				coct += 1.0;
			}
			detail = mix(detail, cliff_detail, cliff_factor);
			bn = mix(bn, cbn, cliff_factor);
			oct = mix(oct, coct, cliff_factor);  // bn's base count follows the same blend
		}

		if (detail_bump_strength > 0.0) {
			// Perturb the TRUE geometric normal — never replace it with bn.
			// Each octave's base term in bn is sgn*n, the triplanar reconstruction
			// of world_normal, which sharpness-warps it toward the dominant
			// coordinate axis (~23 deg of tilt on ground whose radial has no
			// dominant axis).  A fixed world-space tilt is invisible under the
			// high sun but flips N.L sign under a grazing local light (the torch
			// lighting the ground from one azimuth and not from the opposite one).
			// Subtracting one base per contributing octave (oct, counted above
			// and cliff-blended with bn) leaves the pure gradient perturbation,
			// which then rides on world_normal.
			shaded_normal = normalize(world_normal + (bn - sgn * n * oct));
		}
	}

	// Cliff face tint (applied regardless of layer swap — greys/roughens steep rock).
	biome_color = mix(biome_color, cliff_tint.rgb, cliff_factor * cliff_tint_strength);

	// Blend: detail 0.5 = no change, <0.5 darkens, >0.5 brightens.
	// Using overlay-style blending for natural look.
	float mod = mix(1.0, detail * 2.0, detail_strength);
	ALBEDO = clamp(biome_color * mod * albedo_multiplier, vec3(0.0), vec3(1.0));

	// Increase roughness on steep cliff faces for a more matte rock look.
	ROUGHNESS = mix(roughness, min(roughness + 0.1, 1.0), cliff_factor);
	METALLIC  = metallic;

	// Far terrain: shade on the TRUE smooth planet radial (world space) so distant coarse chunks light on
	// a clean sphere normal (crisp great-circle terminator) instead of their wandering vertex normals (the
	// 'yin-yang'). Near terrain (blend 0) keeps its full detail relief.
	float radial_blend = smoothstep(radial_blend_near, radial_blend_far, cam_dist);
	shaded_normal = normalize(mix(shaded_normal, planet_radial_world, radial_blend));
	// Distant chunks live on the celestial layer where NO Godot light reaches them (per-player sun masked
	// off, star OmniLight ineffective at ~3e10). Light them per-fragment from the REAL star direction and
	// EMIT it, faded in with distance so near terrain (blend 0) still uses the Godot per-player sun.
	EMISSION += ALBEDO * star_light_color
			* (max(dot(planet_radial_world, star_dir_world), 0.0) * star_light_energy * radial_blend);

	// Output the detail-derived surface normal (converted to view space).
	// Replaces the old equirectangular normal_map lookup, which spanned the
	// whole planet and so resolved to ~1 texel per chunk — effectively flat.
	NORMAL = normalize((VIEW_MATRIX * vec4(shaded_normal, 0.0)).xyz);
}
