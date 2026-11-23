// The ground shader's body, compiled twice: terrain_biome.gdshader (every ground) and
// terrain_biome_nova.gdshader (a Nova body's ground: #define NOVA first). shader_type and render_mode are
// theirs.

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

// ── Nova (NovaBody sets these on the body's own copy of this material) ──
// A chunk baked for Nova carries a palette of 4 variant ids (nova_palette, one per chunk) and each vertex's
// weight on them (CUSTOM3): the weights, interpolated over the triangles, are the transition between
// variants. A mesh without them reads zero weights and keeps the look above, untouched.
group_uniforms nova;
// How much of the occlusion map darkens the ground, and the roughness setting at which the roughness map
// is taken as it is (the setting scales it from there).
const float NOVA_AO = 0.85;
const float NOVA_ROUGH_REF = 0.9;
// The fine tile of a ground (its close-up grain) shows whole up to this many of its own lengths from the
// camera, and is gone by that many: 10 m and 36 m for a 2 m tile.
const float NOVA_DETAIL_NEAR = 5.0;
const float NOVA_DETAIL_FAR = 18.0;
const float NOVA_TRIPLANAR_SHARPNESS = 32.0;
// Steep parallax: full strength up to NEAR metres from the camera, none past FAR; height steps a ray;
// how many depths the texture may slide at grazing angles.
const float NOVA_POM_NEAR = 12.0;
const float NOVA_POM_FAR = 30.0;
const int NOVA_POM_STEPS = 12;
const float NOVA_POM_MAX_SLIDE = 3.0;
// In a transition, each ground's weight is shifted by a noise of its own, in patches of this size (metres):
// two grounds meet in tongues and islands instead of along the zone's outline. Its two octaves, the least
// and most it multiplies a weight by, and where it fades out seen from afar (finer than a pixel there).
const float NOVA_EDGE_PATCH_M = 40.0;
const float NOVA_EDGE_LOW = 0.2;
const float NOVA_EDGE_HIGH = 1.8;
const float NOVA_EDGE_NEAR = 800.0;
const float NOVA_EDGE_FAR = 2500.0;
// A triplanar projection weighing less than this is not read (nova_tri_read).
const float NOVA_PLANE_MIN = 0.01;
// Nova's code is compiled in terrain_biome_nova.gdshader only (#define NOVA): a body without Nova draws
// its ground without it. Compiled in and switched off by a uniform, it cost such a ground 20 to 50 % more
// (RTX 2060, 2026-11-22: the shader's registers are reserved for its worst path, even when it never runs).
#ifdef NOVA
uniform bool nova_on = true;
#else
const bool nova_on = false;
#endif
// One row per variant id, NovaBody.PARAM_COLUMNS RGBA float texels (see NovaBody.refresh_ground):
// 0 = albedo layer, normal layer, tile (m), texture strength; 1 = gain, normal strength, roughness,
// blend sharpness; 2 = macro strength, macro size (m), anti-tiling, occlusion / roughness / height layer;
// 3-4 and 5-6 = the second and third materials (4.w = close-up tile, 6.w = hex tiling); 7 = parallax depth.
uniform sampler2D nova_params : filter_nearest, repeat_disable;
uniform sampler2DArray nova_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray nova_normal : filter_linear_mipmap_anisotropic, repeat_enable;
// Occlusion (R), roughness (G) and height (B) of the same grounds.
uniform sampler2DArray nova_orh : filter_linear_mipmap_anisotropic, repeat_enable;

// Far lighting (terrain_far_light.gdshaderinc) is included by terrain_biome.gdshader and
// terrain_biome_nova.gdshader themselves, before this body: FarGround.lights_itself looks for that
// include in the shader's own code.
// Must match `_wrap` in planet_terrain.gd.  Tiling scales are snapped to
// integer multiples of 1/WRAP so the pattern is seamless across the wrap
// (UV differs by scale×WRAP×integer between chunks → integer = no seam).
const float WRAP = 8192.0;
// Hex tiling: how fast one of the three reads takes over from the others (1 = a wide cross-fade).
const float NOVA_HEX_SHARPNESS = 7.0;
// Hex tiling: how much a read's height adds to its weight along a seam.
const float NOVA_HEX_HEIGHT = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;
// The same normal in the MODEL frame — the frame tri_pos is in. The triplanar weights and the
// detail normal must be in that frame: the planet spins on the client, so world axes and tri_pos
// axes differ, and weights taken from world_normal gave a steep slope's weight to a plane nearly
// edge-on to it in tri_pos — the detail smeared down building taluses (planet_surface.gdshader).
varying vec3 model_normal;
varying vec3 tri_pos;
varying flat float detail_layer;
varying float detail_scale;
varying float cam_dist;  // camera -> fragment distance (m), for the far-distance radial normal blend
varying vec3 planet_radial_world;  // true smooth sphere normal (world space): terminator + star NdotL
varying vec4 rock;  // CUSTOM1: rocky terrain intensity × envelope, small-block size (m), level + 8 × type, altitude (m)
varying vec4 nova_w;  // CUSTOM3: Nova weight of each palette slot
// The chunk's palette of variant ids (0 = empty slot), one for the whole chunk (PlanetTerrain sets it from
// the mesh). After the indices terrain_far_light fixes for every ground shader.
instance uniform vec4 nova_palette : instance_index(7);
varying vec3 nova_view;  // fragment -> camera, model space (steep parallax)

// Rocky terrain blocks below the mesh pitch (CUSTOM1) — rock_blocks().
#include "res://scenes/planet/rock_blocks.gdshaderinc"

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
// It takes the UV's screen derivatives (dFdx, dFdy), not the UV: they are taken once, in uniform flow, at
// the top of fragment(), and the detail may then be skipped per pixel (under Nova's ground).
float aniso_lod(vec2 uv_dx, vec2 uv_dy) {
	vec2 dx = uv_dx * DETAIL_TEX_SIZE;
	vec2 dy = uv_dy * DETAIL_TEX_SIZE;
	return 0.5 * log2(max(min(dot(dx, dx), dot(dy, dy)), 1.0));
}

// Per-plane min-axis LODs for one octave of scale s, from the screen derivatives of the texture position
// (tri_dx = dFdx(tri_pos), tri_dy = dFdy(tri_pos)). Safe anywhere: no derivative is taken here.
vec3 detail_lods(vec3 tri_dx, vec3 tri_dy, float s) {
	return vec3(aniso_lod(tri_dx.yz * s, tri_dy.yz * s), aniso_lod(tri_dx.xz * s, tri_dy.xz * s),
			aniso_lod(tri_dx.xy * s, tri_dy.xy * s));
}

// One detail octave, triplanar-blended.
// Returns: .xyz = world-space bump-normal contribution, .w = height (0–1).
// Forward differences: for each plane, offset the base sample by an EXACT
// world-space step (stable despite float32 world_pos at planetary scale)
// and use the raw height delta (NOT per-metre slope) so the tilt scales with k.
// Fetches are explicit-LOD (textureLod) with caller-supplied min-axis LODs so
// grazing ground keeps its texture and a live bump gradient — and so no
// derivative is taken under a branch (detail_lods takes the ones fragment() took first).
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

// ── Nova helpers ───────────────────────────────────────────────────
vec4 nova_param(int id, int col) {
	return texelFetch(nova_params, ivec2(col, id), 0);
}

#ifdef NOVA
// True where Nova's palette covers the place whole (weights [param w] of the chunk's palette [param ids])
// and every variant weighing there has its albedo and its normal map: the ground's own detail is not seen
// there (fragment() replaces it by Nova's, mix(.., st_sum = 1)). The same tests as Nova's loop in fragment().
bool nova_covers_whole(vec4 w, vec4 ids) {
	if (dot(w, vec4(1.0)) < 0.999) {
		return false;
	}
	float w_in[4] = float[](w.x, w.y, w.z, w.w);
	float id_in[4] = float[](ids.x, ids.y, ids.z, ids.w);
	for (int i = 0; i < 4; i++) {
		int id = int(id_in[i]);
		if (w_in[i] < 0.004 || id <= 0) {
			continue;
		}
		vec4 p0 = nova_param(id, 0);
		vec4 p1 = nova_param(id, 1);
		if (p0.x < 0.0 || p0.y < 0.0 || p1.y <= 0.0) {
			return false;
		}
	}
	return true;
}
#endif

float nova_hash(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// Value noise of period `period` cells: tri_pos wraps every WRAP metres, so the lattice must too.
float nova_noise(vec3 x, float period) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = nova_hash(mod(i, period));
	float n100 = nova_hash(mod(i + vec3(1, 0, 0), period));
	float n010 = nova_hash(mod(i + vec3(0, 1, 0), period));
	float n110 = nova_hash(mod(i + vec3(1, 1, 0), period));
	float n001 = nova_hash(mod(i + vec3(0, 0, 1), period));
	float n101 = nova_hash(mod(i + vec3(1, 0, 1), period));
	float n011 = nova_hash(mod(i + vec3(0, 1, 1), period));
	float n111 = nova_hash(mod(i + vec3(1, 1, 1), period));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
	           mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// Triplanar read of a Nova texture array at tiling s (planes: X → zy, Y → xz, Z → xy), each projection at
// its own position (the columns of pm: steep parallax), over the projections weighing more than
// NOVA_PLANE_MIN only (re-weighted over them): on the ground nearly all the weight is on one, and the two
// others were read for nothing (RTX 2060, 2026-11-22). Read with the screen derivatives of the texture
// position (dx, dy: tri_dx, tri_dy, taken in uniform flow), as nova_hex_tri does: a projection read in one
// pixel and skipped in the next leaves the implicit derivatives undefined.
vec3 nova_tri_read(sampler2DArray tex, float layer, mat3 pm, float s, vec3 w, vec3 dx, vec3 dy) {
	vec3 sum = vec3(0.0);
	float seen = 0.0;
	if (w.x > NOVA_PLANE_MIN) {
		sum += textureGrad(tex, vec3(pm[0].zy * s, layer), dx.zy * s, dy.zy * s).rgb * w.x;
		seen += w.x;
	}
	if (w.y > NOVA_PLANE_MIN) {
		sum += textureGrad(tex, vec3(pm[1].xz * s, layer), dx.xz * s, dy.xz * s).rgb * w.y;
		seen += w.y;
	}
	if (w.z > NOVA_PLANE_MIN) {
		sum += textureGrad(tex, vec3(pm[2].xy * s, layer), dx.xy * s, dy.xy * s).rgb * w.z;
		seen += w.z;
	}
	return sum / max(seen, 0.001);
}

// Triplanar albedo of `layer` (nova_tri_read).
vec3 nova_tri_albedo(float layer, mat3 pm, float s, vec3 w, vec3 dx, vec3 dy) {
	return nova_tri_read(nova_albedo, layer, pm, s, w, dx, dy);
}

// The same at one position for the three projections.
vec3 nova_tri_albedo(float layer, vec3 p, float s, vec3 w, vec3 dx, vec3 dy) {
	return nova_tri_albedo(layer, mat3(p, p, p), s, w, dx, dy);
}

vec3 nova_tri_orh(float layer, mat3 pm, float s, vec3 w, vec3 dx, vec3 dy) {
	return nova_tri_read(nova_orh, layer, pm, s, w, dx, dy);
}

// A random texture offset for corner c of the tiling lattice. The lattice is a sheared square grid; in
// the coordinates (2x + y, y) it wraps where the texture does (period cells), so chunks agree.
vec2 nova_hex_offset(vec2 c, float period) {
	vec2 q = vec2(mod(2.0 * c.x + c.y, 4.0 * period), mod(c.y, 2.0 * period));
	vec3 p3 = fract(vec3(q.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

// One projection of a ground's three images (layers: albedo, normal, orh; -1 = none) with hex tiling: the
// plane is paved with triangles, each corner shifts the texture by its own random offset, and the three
// reads are blended by their distance to the corners and by the texture's height, so one of them wins
// almost everywhere and the seams follow the grain. gx, gy: screen derivatives of uv (the offsets would
// break the automatic ones along the triangles' edges).
void nova_hex_plane(vec2 uv, vec2 gx, vec2 gy, float period, vec3 layers,
		out vec3 alb, out vec2 nrm, out vec3 orh) {
	vec2 sk = vec2(uv.x - 0.5 * uv.y, uv.y) * 2.0;
	vec2 base = floor(sk);
	vec2 f = sk - base;
	vec2 c1 = base + vec2(1.0, 0.0);
	vec2 c2 = base + vec2(0.0, 1.0);
	vec2 c0 = base;
	vec3 w = vec3(1.0 - f.x - f.y, f.x, f.y);
	if (f.x + f.y > 1.0) {
		c0 = base + vec2(1.0, 1.0);
		w = vec3(f.x + f.y - 1.0, 1.0 - f.y, 1.0 - f.x);
	}
	vec2 u0 = uv + nova_hex_offset(c0, period);
	vec2 u1 = uv + nova_hex_offset(c1, period);
	vec2 u2 = uv + nova_hex_offset(c2, period);
	vec3 o0 = vec3(1.0, 1.0, 0.5);
	vec3 o1 = o0;
	vec3 o2 = o0;
	if (layers.z >= 0.0) {
		o0 = textureGrad(nova_orh, vec3(u0, layers.z), gx, gy).rgb;
		o1 = textureGrad(nova_orh, vec3(u1, layers.z), gx, gy).rgb;
		o2 = textureGrad(nova_orh, vec3(u2, layers.z), gx, gy).rgb;
	}
	// The height only settles the seam between two reads: weighted more, the highest of the three would
	// win everywhere and the texture's hollows (its dark cracks) would vanish.
	vec3 ws = pow(w, vec3(NOVA_HEX_SHARPNESS)) * (vec3(o0.b, o1.b, o2.b) * NOVA_HEX_HEIGHT + 1.0);
	ws /= ws.x + ws.y + ws.z;
	orh = o0 * ws.x + o1 * ws.y + o2 * ws.z;
	alb = textureGrad(nova_albedo, vec3(u0, layers.x), gx, gy).rgb * ws.x
			+ textureGrad(nova_albedo, vec3(u1, layers.x), gx, gy).rgb * ws.y
			+ textureGrad(nova_albedo, vec3(u2, layers.x), gx, gy).rgb * ws.z;
	nrm = vec2(0.0);
	if (layers.y >= 0.0) {
		nrm = (textureGrad(nova_normal, vec3(u0, layers.y), gx, gy).rg * ws.x
				+ textureGrad(nova_normal, vec3(u1, layers.y), gx, gy).rg * ws.y
				+ textureGrad(nova_normal, vec3(u2, layers.y), gx, gy).rg * ws.z) * 2.0 - 1.0;
	}
}

// The texture offset of the hex-tiling corner that weighs most at uv (see nova_hex_plane).
vec2 nova_hex_top_offset(vec2 uv, float period) {
	vec2 sk = vec2(uv.x - 0.5 * uv.y, uv.y) * 2.0;
	vec2 base = floor(sk);
	vec2 f = sk - base;
	vec2 c0 = base;
	vec3 w = vec3(1.0 - f.x - f.y, f.x, f.y);
	if (f.x + f.y > 1.0) {
		c0 = base + vec2(1.0, 1.0);
		w = vec3(f.x + f.y - 1.0, 1.0 - f.y, 1.0 - f.x);
	}
	vec2 c = c0;
	if (w.y >= w.x && w.y >= w.z) {
		c = base + vec2(1.0, 0.0);
	} else if (w.z >= w.x && w.z >= w.y) {
		c = base + vec2(0.0, 1.0);
	}
	return nova_hex_offset(c, period);
}

// q on the projection plane of `axis` (a unit axis), as the triplanar reads take it.
vec2 nova_plane(vec3 q, vec3 axis) {
	return axis.x > 0.5 ? q.zy : (axis.y > 0.5 ? q.xz : q.xy);
}

// Steep parallax occlusion mapping on the projection of `axis`: p slid along the view ray (v: towards the
// camera, model space, unit) down to the height field of image `layer` (blue of nova_orh, 1 = top) at
// tiling s, depth_m metres deep along the axis. With hex tiling the heights are those of the read that
// weighs most at p.
vec3 nova_parallax_axis(vec3 p, vec3 dx, vec3 dy, vec3 v, vec3 axis, float layer, float s, bool hex,
		float depth_m) {
	float vn = dot(v, axis);
	// At grazing angles the slide is held to NOVA_POM_MAX_SLIDE depths: beyond, the steps show.
	vec3 slide = -(v - axis * vn) / max(abs(vn), 1.0 / NOVA_POM_MAX_SLIDE) * depth_m;
	vec2 gx = nova_plane(dx, axis) * s;
	vec2 gy = nova_plane(dy, axis) * s;
	vec2 off = hex ? nova_hex_top_offset(nova_plane(p, axis) * s, WRAP * s) : vec2(0.0);
	float step_t = 1.0 / float(NOVA_POM_STEPS);
	float t = 0.0;
	float ray = 1.0;
	float h = textureGrad(nova_orh, vec3(nova_plane(p, axis) * s + off, layer), gx, gy).b;
	float last_ray = ray;
	float last_h = h;
	for (int i = 0; i < NOVA_POM_STEPS; i++) {
		if (ray <= h) {
			break;
		}
		last_ray = ray;
		last_h = h;
		ray -= step_t;
		t += step_t;
		h = textureGrad(nova_orh, vec3(nova_plane(p + slide * t, axis) * s + off, layer), gx, gy).b;
	}
	// Between the last step above the surface and the first below it.
	float above = last_ray - last_h;
	float below = h - ray;
	t -= step_t * clamp(below / max(above + below, 0.0001), 0.0, 1.0);
	return p + slide * max(t, 0.0);
}

// The position each of the three projections is read at (columns: the X, Y and Z planes), each slid in
// its own plane. The planet's ground faces no axis over most of its surface, so the projections that
// share it each get their parallax; one that does not count (w) keeps p.
mat3 nova_parallax(vec3 p, vec3 dx, vec3 dy, vec3 view_m, vec3 w, float layer, float s, bool hex,
		float depth_m) {
	vec3 v = normalize(view_m);
	mat3 pm = mat3(p, p, p);
	if (w.x > 0.01) {
		pm[0] = nova_parallax_axis(p, dx, dy, v, vec3(1.0, 0.0, 0.0), layer, s, hex, depth_m);
	}
	if (w.y > 0.01) {
		pm[1] = nova_parallax_axis(p, dx, dy, v, vec3(0.0, 1.0, 0.0), layer, s, hex, depth_m);
	}
	if (w.z > 0.01) {
		pm[2] = nova_parallax_axis(p, dx, dy, v, vec3(0.0, 0.0, 1.0), layer, s, hex, depth_m);
	}
	return pm;
}

// The whiteout blend of three projected normal-map reads (tx, ty, tz) around the geometric normal n.
vec3 nova_whiteout(vec2 tx, vec2 ty, vec2 tz, vec3 w, vec3 n) {
	vec3 nx = vec3(tx + n.zy, abs(n.x));
	vec3 ny = vec3(ty + n.xz, abs(n.y));
	vec3 nz = vec3(tz + n.xy, abs(n.z));
	nx.z *= sign(n.x);
	ny.z *= sign(n.y);
	nz.z *= sign(n.z);
	return normalize(nx.zyx * w.x + ny.xzy * w.y + nz.xyz * w.z);
}

// A ground material's three images at p (derivatives dx, dy), tiling s, with hex tiling on the projections
// that count (w: the triplanar weights): its colour, its occlusion / roughness / height and its normal
// around n (strength k).
void nova_hex_tri(mat3 pm, vec3 dx, vec3 dy, float s, vec3 w, vec3 layers, float k, vec3 n,
		out vec3 alb, out vec3 orh, out vec3 nrm) {
	float period = WRAP * s;
	alb = vec3(0.0);
	orh = vec3(0.0);
	vec3 a;
	vec3 o;
	vec2 nx2 = vec2(0.0);
	vec2 ny2 = vec2(0.0);
	vec2 nz2 = vec2(0.0);
	float seen = 0.0;
	if (w.x > 0.01) {
		nova_hex_plane(pm[0].zy * s, dx.zy * s, dy.zy * s, period, layers, a, nx2, o);
		alb += a * w.x;
		orh += o * w.x;
		seen += w.x;
	}
	if (w.y > 0.01) {
		nova_hex_plane(pm[1].xz * s, dx.xz * s, dy.xz * s, period, layers, a, ny2, o);
		alb += a * w.y;
		orh += o * w.y;
		seen += w.y;
	}
	if (w.z > 0.01) {
		nova_hex_plane(pm[2].xy * s, dx.xy * s, dy.xy * s, period, layers, a, nz2, o);
		alb += a * w.z;
		orh += o * w.z;
		seen += w.z;
	}
	alb /= max(seen, 0.001);
	orh /= max(seen, 0.001);
	nrm = nova_whiteout(nx2 * k, ny2 * k, nz2 * k, w, n);
}

// Triplanar normal map (whiteout blend around the geometric normal n), model space: the projections
// weighing more than NOVA_PLANE_MIN only, read as nova_tri_read does.
vec3 nova_tri_normal(float layer, mat3 pm, float s, vec3 w, vec3 n, float k, vec3 dx, vec3 dy) {
	vec3 wk = w * step(vec3(NOVA_PLANE_MIN), w);
	vec2 tx = vec2(0.0);
	vec2 ty = vec2(0.0);
	vec2 tz = vec2(0.0);
	if (wk.x > 0.0) {
		tx = (textureGrad(nova_normal, vec3(pm[0].zy * s, layer), dx.zy * s, dy.zy * s).rg * 2.0 - 1.0) * k;
	}
	if (wk.y > 0.0) {
		ty = (textureGrad(nova_normal, vec3(pm[1].xz * s, layer), dx.xz * s, dy.xz * s).rg * 2.0 - 1.0) * k;
	}
	if (wk.z > 0.0) {
		tz = (textureGrad(nova_normal, vec3(pm[2].xy * s, layer), dx.xy * s, dy.xy * s).rg * 2.0 - 1.0) * k;
	}
	return nova_whiteout(tx, ty, tz, wk, n);
}

void vertex() {
	VERTEX += lod_morph_step(CUSTOM2);  // LOD morph, see terrain_far_light
	// Recover the surface position for triplanar UV.
	// For terrain vertices CUSTOM0 is zero so VERTEX + CUSTOM0 == VERTEX.
	// For skirt vertices VERTEX is at the dropped position and CUSTOM0
	// holds the inverse offset back to the surface — keeping triplanar
	// texture continuous across the terrain-to-skirt boundary.
	world_pos    = (MODEL_MATRIX * vec4(VERTEX + CUSTOM0.xyz, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	model_normal = NORMAL;
	// High-precision triplanar position: chunk-local vertex + wrapped chunk
	// origin.  Both terms are small (≤ ~8300 m), so float32 keeps
	// sub-millimetre precision — unlike world_pos (~4.5e6 m → 0.5 m steps).
	tri_pos      = chunk_origin_mod + VERTEX + CUSTOM0.xyz;
	rock         = CUSTOM1;
	// Camera->fragment distance for the far-distance radial normal blend (view space is camera-relative,
	// so this stays float32-precise regardless of the astronomic world position).
	cam_dist     = far_light_cam_dist(MODELVIEW_MATRIX, VERTEX + CUSTOM0.xyz);
#ifdef NOVA
	nova_view    = (inverse(MODELVIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz - VERTEX;
#endif
	// TRUE radial 'up' as a world-space direction: the planet-local vertex (chunk_center_local + VERTEX,
	// precise) rotated by the model's linear part (the planet's world rotation; w=0 drops the ~3e10
	// translation, so no float32 blow-up). Smooth sphere normal for the far terminator + star lighting.
	planet_radial_world = far_light_radial(MODEL_MATRIX, VERTEX + CUSTOM0.xyz);
	detail_layer = UV2.x;    // integer layer index (0 = blank)
	detail_scale = UV2.y;    // per-biome tiling scale (world-space)
	nova_w     = CUSTOM3;
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
	// not a per-fragment branch — blends the cliff result (the detail's LODs come from
	// tri_dx / tri_dy, taken in uniform flow before any branch).
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
	// Model frame (tri_pos's) <-> world. The chunk's basis is the planet's rotation, no scale.
	mat3 m2w = mat3(MODEL_MATRIX);
	mat3 w2m = transpose(m2w);
	vec3 nrm_m = normalize(model_normal);

	// Screen derivatives of the texture position, taken here in uniform flow: the detail's LODs and Nova's
	// hex tiling read with them under branches that differ from pixel to pixel.
	vec3 tri_dx = dFdx(tri_pos);
	vec3 tri_dy = dFdy(tri_pos);
	// Under Nova's ground the detail octaves are not read where Nova's look is the whole look (27 to 45
	// texture reads a pixel, all thrown away by the mix with st_sum = 1).
	bool nova_owns = false;
#ifdef NOVA
	nova_owns = nova_on && nova_covers_whole(nova_w, nova_palette);
#endif

	if (detail_scale > 0.0 && !nova_owns) {
		vec3 n = abs(nrm_m);
		n = pow(n, vec3(triplanar_sharpness));
		n /= (n.x + n.y + n.z);

		// Snap all octave scales to the seamless 1/WRAP grid (see tri_pos).
		float s = snap_scale(detail_scale);
		float layer = detail_layer;
		vec3 sgn = sign(nrm_m);

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
				detail_bump_strength, detail_lods(tri_dx, tri_dy, s));
		detail = base_o.w;
		vec3 bn = base_o.xyz;
		// Count the base terms accumulated in bn: every octave carries one
		// sgn*n (the triplanar reconstruction of world_normal).  They are
		// subtracted below so only the gradient perturbation survives.
		float oct = 1.0;

		if (detail_fine_strength > 0.0) {
			vec4 fine_o = detail_octave_sample(tri_pos, sf, layer, n, sgn,
					detail_bump_strength * detail_fine_strength, detail_lods(tri_dx, tri_dy, sf));
			// Add the fine grain to the albedo modifier around neutral 0.5.
			detail = clamp(detail + (fine_o.w - 0.5) * detail_fine_strength, 0.0, 1.0);
			bn += fine_o.xyz;
			oct += 1.0;
		}

		if (detail_macro_strength > 0.0) {
			bn += detail_octave_sample(tri_pos, sm, layer, n, sgn,
					detail_bump_strength * detail_macro_strength, detail_lods(tri_dx, tri_dy, sm)).xyz;
			oct += 1.0;
		}

		// ── Cliff detail swap ────────────────────────────────────────
		// Steep faces blend in the cliff detail LAYER (e.g. rock on a sand
		// biome).  Skipped when the cliff layer+scale already equal the base
		// (true for whole-rock biomes like corundum) — a UNIFORM condition
		// (all inputs are per-draw constants).
		float cs = snap_scale(cliff_tiling_scale);
		float cl = cliff_detail_layer_index;
		if (abs(cl - layer) > 0.5 || abs(cs - s) > 1e-9) {
			float csf = snap_scale(cs * detail_fine_ratio);
			vec4 cbase = detail_octave_sample(tri_pos, cs, cl, n, sgn,
					detail_bump_strength, detail_lods(tri_dx, tri_dy, cs));
			float cliff_detail = cbase.w;
			vec3 cbn = cbase.xyz;
			float coct = 1.0;  // the cliff path has no macro octave
			if (detail_fine_strength > 0.0) {
				vec4 cfine = detail_octave_sample(tri_pos, csf, cl, n, sgn,
						detail_bump_strength * detail_fine_strength, detail_lods(tri_dx, tri_dy, csf));
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
			// which then rides on world_normal — brought from tri_pos's frame, which
			// bn is in, to world space.
			shaded_normal = normalize(world_normal + m2w * (bn - sgn * n * oct));
		}
	}

	// Cliff face tint (applied regardless of layer swap — greys/roughens steep rock).
	biome_color = mix(biome_color, cliff_tint.rgb, cliff_factor * cliff_tint_strength);

	// Blend: detail 0.5 = no change, <0.5 darkens, >0.5 brightens.
	// Using overlay-style blending for natural look.
	float mod = mix(1.0, detail * 2.0, detail_strength);
	vec3 sn_m = w2m * shaded_normal;

	// ── Nova: each palette variant's texture, relief and roughness, blended by the vertex
	// weights sharpened against the texture's own brightness (a height blend: the transition follows
	// the grain of the ground instead of the triangles).
	// A variant with no texture keeps this shader's own detail (mod, sn_m) under its other settings.
	float st_sum = nova_on ? dot(nova_w, vec4(1.0)) : 0.0;
	vec3 st_col = vec3(1.0);
	float st_rough = roughness;
	float mod_detail = mod;
	vec3 sn_detail = sn_m;
	if (st_sum > 0.004) {
		// A sharp choice between the three projections: the planet's ground faces no axis over most of its
		// surface, and a wide blend lays two stretched copies of every stone over each other.
		vec3 tw = pow(abs(nrm_m), vec3(max(triplanar_sharpness, NOVA_TRIPLANAR_SHARPNESS)));
		tw /= (tw.x + tw.y + tw.z);
		vec3 cols[4];
		vec3 nrms[4];
		float wts[4];
		float rgh[4];
		float wsum = 0.0;
		// Plain arrays: indexing a vector with a loop variable is not portable to every backend.
		float w_in[4] = float[](nova_w.x, nova_w.y, nova_w.z, nova_w.w);
		float id_in[4] = float[](nova_palette.x, nova_palette.y, nova_palette.z, nova_palette.w);
		for (int i = 0; i < 4; i++) {
			cols[i] = vec3(1.0);
			nrms[i] = sn_detail;
			rgh[i] = roughness;
			wts[i] = 0.0;
			float wi = w_in[i];
			int id = int(id_in[i]);
			if (wi < 0.004 || id <= 0) {
				continue;
			}
			vec4 p0 = nova_param(id, 0);
			vec4 p1 = nova_param(id, 1);
			vec4 p2 = nova_param(id, 2);
			float s = snap_scale(1.0 / max(p0.z, 0.01));
			// Close to the camera the same textures are read again at a finer tile: the large tile, which
			// does not repeat seen from afar, is a few dozen texels a metre underfoot.
			float fine_tile = nova_param(id, 4).w;
			float sd = snap_scale(1.0 / max(fine_tile, 0.05));
			float fine = fine_tile > 0.0
					? 1.0 - smoothstep(fine_tile * NOVA_DETAIL_NEAR, fine_tile * NOVA_DETAIL_FAR, cam_dist) : 0.0;
			// Steep parallax, close to the camera: the position every texture is read at slides along the
			// view ray to where it meets the height of the material lying there (its own image's blue),
			// so stones and cracks hide and uncover each other as the camera moves.
			vec3 pp = tri_pos;
			mat3 pm = mat3(tri_pos, tri_pos, tri_pos);
			// The overlays' patch noise, read here for the parallax and kept for the overlays below (-1: not read).
			float where_kept[2] = float[](-1.0, -1.0);
			float pom_m = nova_param(id, 7).x;
			float pom_k = pom_m > 0.0 ? 1.0 - smoothstep(NOVA_POM_NEAR, NOVA_POM_FAR, cam_dist) : 0.0;
			if (pom_k > 0.0) {
				float pom_layer = p2.w;
				float pom_s = fine > 0.5 ? sd : s;
				for (int k = 0; k < 2; k++) {
					vec4 pa = nova_param(id, 3 + k * 2);
					if (pa.w <= 0.0 || pa.x < 0.0) {
						continue;
					}
					vec4 pb = nova_param(id, 4 + k * 2);
					float sp = snap_scale(1.0 / max(pb.x, 1.0));
					vec3 off = vec3(17.0, 31.0, 5.0) * float(k);
					float where = nova_noise(tri_pos * sp + off, WRAP * sp) * 0.65
							+ nova_noise(tri_pos * sp * 2.0 + off, WRAP * sp * 2.0) * 0.35;
					where_kept[k] = where;
					if (clamp((where - 0.5) * 1.8 + 0.5, 0.0, 1.0) > 1.0 - pa.w) {
						pom_layer = pb.z;
						pom_s = snap_scale(1.0 / max(pa.z, 0.01));
					}
				}
				if (pom_layer >= 0.0) {
					pm = nova_parallax(tri_pos, tri_dx, tri_dy, nova_view, tw, pom_layer, pom_s,
							nova_param(id, 6).w > 0.5, pom_m * pom_k);
				}
			}
			vec3 tex = vec3(0.5);
			// Hex tiling of the ground's materials: no repetition, so no anti-tiling read. The first
			// material keeps its close-up tile, hex-tiled too.
			bool hex = p0.x >= 0.0 && nova_param(id, 6).w > 0.5;
			vec3 hex_orh = vec3(1.0, 1.0, 0.5);
			vec3 hex_nrm = nrm_m;
			if (hex) {
				nova_hex_tri(pm, tri_dx, tri_dy, s, tw, vec3(p0.x, p0.y, p2.w), p1.y, nrm_m,
						tex, hex_orh, hex_nrm);
				if (fine > 0.0) {
					vec3 tex_f;
					vec3 orh_f;
					vec3 nrm_f;
					nova_hex_tri(pm, tri_dx, tri_dy, sd, tw, vec3(p0.x, p0.y, p2.w), p1.y, nrm_m,
							tex_f, orh_f, nrm_f);
					tex = mix(tex, tex_f, fine);
					hex_orh = mix(hex_orh, orh_f, fine);
					hex_nrm = normalize(mix(hex_nrm, nrm_f, fine));
				}
			} else if (p0.x >= 0.0) {
				tex = nova_tri_albedo(p0.x, pm, s, tw, tri_dx, tri_dy);
				if (p2.z > 0.0) {
					// Anti-tiling: a second, coarser read with swapped axes, mixed by a slow noise.
					float s2 = snap_scale(s * 0.43);
					vec3 tex2 = nova_tri_albedo(p0.x, pp.yzx, s2, tw.yzx, tri_dx.yzx, tri_dy.yzx);
					float sa = snap_scale(s * 0.11);
					float k = nova_noise(pp * sa, WRAP * sa);
					tex = mix(tex, tex2, smoothstep(0.3, 0.7, k) * p2.z);
				}
				if (fine > 0.0) {
					vec3 tex_f = nova_tri_albedo(p0.x, pm, sd, tw, tri_dx, tri_dy);
					if (p2.z > 0.0) {
						// The same anti-tiling as the large tile: a small tile repeats within sight.
						float sf2 = snap_scale(sd * 0.57);
						float sfa = snap_scale(sd * 0.17);
						float kf = nova_noise(pp * sfa, WRAP * sfa);
						tex_f = mix(tex_f, nova_tri_albedo(p0.x, pp.yzx, sf2, tw.yzx, tri_dx.yzx, tri_dy.yzx),
								smoothstep(0.35, 0.65, kf) * p2.z);
					}
					tex = mix(tex, tex_f, fine);
				}
			}
			cols[i] = p0.x >= 0.0 ? mix(vec3(1.0), tex * p1.x, p0.w) : vec3(mod_detail);
			// Occlusion, roughness and height of the ground, when it has the image for them: the hollows
			// darken, the surface shines or not point by point, and "low" is a real height instead of a
			// dark texel. Without the image: no occlusion, the one roughness, the texel's brightness.
			vec3 orh = vec3(1.0, 1.0, dot(tex, vec3(0.333)));
			float rough_i = p1.z;
			if (p2.w >= 0.0) {
				orh = hex ? hex_orh : nova_tri_orh(p2.w, pm, s, tw, tri_dx, tri_dy);
				if (fine > 0.0 && !hex) {
					orh = mix(orh, nova_tri_orh(p2.w, pm, sd, tw, tri_dx, tri_dy), fine);
				}
				cols[i] *= mix(1.0, orh.r, NOVA_AO);
				rough_i = clamp(orh.g * p1.z / NOVA_ROUGH_REF, 0.04, 1.0);
			}
			// The second and third materials (sand, gravel, dust…), in patches, one over the other: a slow
			// noise of its own says where each lies, and it takes the hollows of the first material first
			// — its dark texels — so the rim of a patch follows the rock's own grain instead of a flat
			// cross-fade. Columns 3-4 of the parameters hold the second, 5-6 the third, laid out alike.
			float over[2] = float[](0.0, 0.0);
			vec4 over_a[2];
			vec3 over_n[2];
			for (int k = 0; k < 2; k++) {
				vec4 pa = nova_param(id, 3 + k * 2);
				over_a[k] = pa;
				if (pa.w <= 0.0 || pa.x < 0.0) {
					continue;
				}
				vec4 pb = nova_param(id, 4 + k * 2);
				float sp = snap_scale(1.0 / max(pb.x, 1.0));
				// A whole number of lattice cells apart, so each material has its own patches and the
				// noise still wraps.
				vec3 off = vec3(17.0, 31.0, 5.0) * float(k);
				float where = where_kept[k] >= 0.0 ? where_kept[k] : nova_noise(pp * sp + off, WRAP * sp) * 0.65
						+ nova_noise(pp * sp * 2.0 + off, WRAP * sp * 2.0) * 0.35;
				// A blend of noises gathers around 0.5: stretched so pa.w is about the share it covers.
				where = clamp((where - 0.5) * 1.8 + 0.5, 0.0, 1.0) + (0.5 - orh.b) * 0.35;
				over[k] = smoothstep(1.0 - pa.w - 0.07, 1.0 - pa.w + 0.07, where);
				if (over[k] > 0.0) {
					float sb = snap_scale(1.0 / max(pa.z, 0.01));
					vec3 tex_b;
					vec3 orh_b = vec3(1.0, 1.0, 0.5);
					if (hex) {
						nova_hex_tri(pm, tri_dx, tri_dy, sb, tw, vec3(pa.x, pa.y, pb.z), p1.y, nrm_m,
								tex_b, orh_b, over_n[k]);
					} else {
						tex_b = nova_tri_albedo(pa.x, pm, sb, tw, tri_dx, tri_dy);
						if (pb.z >= 0.0) {
							orh_b = nova_tri_orh(pb.z, pm, sb, tw, tri_dx, tri_dy);
						}
					}
					vec3 col_b = mix(vec3(1.0), tex_b * pb.y, p0.w);
					if (pb.z >= 0.0) {
						col_b *= mix(1.0, orh_b.r, NOVA_AO);
						rough_i = mix(rough_i, clamp(orh_b.g * p1.z / NOVA_ROUGH_REF, 0.04, 1.0), over[k]);
					}
					cols[i] = mix(cols[i], col_b, over[k]);
				}
			}
			if (p2.x > 0.0) {
				float sm = snap_scale(1.0 / max(p2.y, 1.0));
				float m = nova_noise(pp * sm, WRAP * sm) * 0.65
						+ nova_noise(pp * sm * 2.0, WRAP * sm * 2.0) * 0.35;
				cols[i] *= 1.0 + (m - 0.5) * 2.0 * p2.x;
			}
			if (p0.y >= 0.0 && p1.y > 0.0) {
				nrms[i] = hex ? hex_nrm : nova_tri_normal(p0.y, pm, s, tw, nrm_m, p1.y, tri_dx, tri_dy);
				if (fine > 0.0 && !hex) {
					nrms[i] = normalize(mix(nrms[i], nova_tri_normal(p0.y, pm, sd, tw, nrm_m, p1.y, tri_dx, tri_dy), fine));
				}
			}
			for (int k = 0; k < 2; k++) {
				if (over[k] > 0.0 && over_a[k].y >= 0.0 && p1.y > 0.0) {
					float sb = snap_scale(1.0 / max(over_a[k].z, 0.01));
					nrms[i] = normalize(mix(nrms[i], hex ? over_n[k]
							: nova_tri_normal(over_a[k].y, pm, sb, tw, nrm_m, p1.y, tri_dx, tri_dy), over[k]));
				}
			}
			rgh[i] = rough_i;
			float h = orh.b;
			float edge = 1.0;
			if (wi < 0.996 && cam_dist < NOVA_EDGE_FAR) {
				float se = snap_scale(1.0 / NOVA_EDGE_PATCH_M);
				vec3 oe = vec3(41.0, 13.0, 29.0) * float(id);
				float ne = nova_noise(tri_pos * se + oe, WRAP * se) * 0.65
						+ nova_noise(tri_pos * se * 3.0 + oe, WRAP * se * 3.0) * 0.35;
				edge = mix(mix(NOVA_EDGE_LOW, NOVA_EDGE_HIGH, ne), 1.0,
						smoothstep(NOVA_EDGE_NEAR, NOVA_EDGE_FAR, cam_dist));
			}
			wts[i] = pow(max(wi * edge * (0.5 + h), 1e-4), p1.w);
			wsum += wts[i];
		}
		if (wsum > 0.0) {
			vec3 c = vec3(0.0);
			vec3 nn = vec3(0.0);
			float r = 0.0;
			for (int i = 0; i < 4; i++) {
				float k = wts[i] / wsum;
				c += cols[i] * k;
				nn += nrms[i] * k;
				r += rgh[i] * k;
			}
			st_sum = clamp(st_sum, 0.0, 1.0);
			st_col = mix(vec3(1.0), c, st_sum);
			st_rough = r;
			mod = mix(mod_detail, 1.0, st_sum);
			sn_m = normalize(mix(sn_detail, normalize(nn), st_sum));
		} else {
			st_sum = 0.0;
		}
	} else {
		st_sum = 0.0;
	}

	// Rock blocks of a rocky_terrain field (CUSTOM1), faded with the distance.
	// In tri_pos's frame, like the planes; its shading normal comes back to world space.
	mod *= rock_blocks(rock, tri_pos, nrm_m, w2m * planet_up, cam_dist, sn_m);
	shaded_normal = normalize(m2w * sn_m);
	ALBEDO = clamp(biome_color * st_col * mod * albedo_multiplier, vec3(0.0), vec3(1.0));

	// Increase roughness on steep cliff faces for a more matte rock look.
	ROUGHNESS = mix(mix(roughness, st_rough, st_sum), min(roughness + 0.1, 1.0), cliff_factor);
	METALLIC  = metallic;

	// Far terrain: shade on the TRUE smooth planet radial (world space) so distant coarse chunks light on
	// a clean sphere normal (crisp great-circle terminator) instead of their wandering vertex normals (the
	// 'yin-yang'). Near terrain (blend 0) keeps its full detail relief.
	float radial_blend = far_light_blend(cam_dist);
	shaded_normal = normalize(mix(shaded_normal, planet_radial_world, radial_blend));
	// Distant chunks live on the celestial layer where NO Godot light reaches them: they emit the star's
	// light themselves (terrain_far_light), faded in so near terrain keeps the per-player sun.
	EMISSION += far_light_emission(ALBEDO, planet_radial_world, cam_dist, VIEW_MATRIX, VERTEX);

	// Output the detail-derived surface normal (converted to view space).
	// Replaces the old equirectangular normal_map lookup, which spanned the
	// whole planet and so resolved to ~1 texel per chunk — effectively flat.
	NORMAL = normalize((VIEW_MATRIX * vec4(shaded_normal, 0.0)).xyz);
}
