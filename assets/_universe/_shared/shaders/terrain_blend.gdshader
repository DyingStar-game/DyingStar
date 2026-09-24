shader_type spatial;

// GROUND FRINGE -- the bottom of a placed object takes on the colour of the ground it stands on, so
// the meeting line stops reading as a cut.
//
// Worn as a material_overlay, never as a replacement: the object keeps the material it already had
// (on GLB buildings that slot is re-assigned at every reimport by shared_material_resolver.gd, so
// anything written there would be silently lost), and the fringe is one extra pass on top.
//
// WHY NOT the published "mesh-terrain blending" shader this is modelled on: it measures height as
// the world-space Y of the vertex, which assumes a flat terrain sitting at the origin. Our planets
// are spheres whose client-side transform carries their Kepler position -- tarsis_4 orbits at
// 0.63-0.67 AU, i.e. ~1e11 m -- so a world position here is a float32 with kilometre-wide steps,
// and "up" is not Y but the local radial. Nothing below is ever a world position.
// terrain_biome.gdshader:229-241 spells out what happens when that rule is broken: a
// normalize(world_pos) there once classified 50.6 % of the terrain as cliff.
//
// specular_disabled: without it the overlay ADDS a second specular lobe on top of the base
// surface's own, which reads as a glossy ring around the foot of every object.
//
// NOT depth_test_disabled -- that is the full-screen-quad mode, and here it would show the fringe
// through walls and through the terrain. depth_draw_never plus the engine's _OR_EQUAL depth
// comparison is what lets a coplanar overlay pass, and it is why material_overlay works at all.
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_disabled;

// ── Shared across every object ──────────────────────────────────────────────────────────────────
// Per-instance uniforms cannot hold a texture, and one shared material is a hard requirement
// anyway: rock_debug.gd measured 23-30 fps between a material per rock and a single shared one, on
// forty rocks. Mining_Zone asks for three hundred.
group_uniforms fringe;
uniform sampler2D blend_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float blend_noise_scale = 0.4;
uniform float blend_noise_strength : hint_range(0.0, 1.0) = 0.55;
// How fast the band gives way as it climbs. 1.0 is linear; above that it stays full at the contact
// and thins out sooner, which is how windblown sand actually sits against a wall.
uniform float blend_curve : hint_range(0.5, 4.0, 0.1) = 1.6;
// Second, finer noise octave. With one octave the limit still reads as a regular wave; several
// scales breaking at once is what makes it read as drift rather than as a torn edge.
uniform float blend_noise_detail : hint_range(1.0, 12.0, 0.1) = 4.7;
// The LOW octave, and the one that matters most to the eye: it makes the whole band rise and fall
// over metres, so the sand piles deep in places and thins to nothing in others. Without it the
// limit is ragged but its AVERAGE height is dead constant along a wall, which still reads as a
// band of uniform thickness -- a ruled line with a torn edge is still a ruled line.
uniform float blend_noise_swell : hint_range(0.02, 1.0, 0.01) = 0.22;
// How much a surface's ORIENTATION suppresses the band. A fringe is sand driven AGAINST a face:
// on a horizontal surface sitting at ground level there is no contact line to hide, only a floor,
// and painting it reads as an apron buried in sand rather than bordered by it. 1.0 = horizontal
// faces get nothing, 0.0 = orientation ignored (the old behaviour).
uniform float blend_face_weight : hint_range(0.0, 1.0, 0.01) = 1.0;
// How much an INWARD-facing wall loses the band. Windblown sand reaches the outside of a building,
// not the inside of its rooms, and nothing in the mesh says which is which -- but the geometry
// does: an outer wall's normal points AWAY from the building's centre, an inner wall's points
// TOWARD it.
//
// It was briefly lowered to 0.7 because a row of habitations lost its sand across the alley
// between them -- but that was the NaN above, not this test: each habitation is its OWN object, so
// its outer walls point away from its OWN centre and were never penalised. Full strength restored.
//
// The limit is real though: the test is geometric, not spatial, so it cannot tell a room from a
// street between two halves of the SAME object. Set it lower on an asset shaped like that; 0.0
// ignores orientation entirely.
uniform float blend_inward_weight : hint_range(0.0, 1.0, 0.01) = 1.0;
// How far the band's normal is turned toward the planetary up AT THE CONTACT.
//
// The band represents ground, but it is painted on a wall, so it is lit with the WALL's normal:
// on a shaded face it stays dark while the sand a centimetre away is in full sun, and the cut line
// comes back as a step in brightness even though the texture matches. Turning the normal upward
// where the band is thickest lights it like the ground it is pretending to be. It fades back to
// the wall's own normal as the band thins out, so nothing looks detached higher up.
uniform float blend_normal_lift : hint_range(0.0, 1.0, 0.01) = 0.85;
// Ceiling on the band's opacity. Below 1.0 the wall keeps showing through even at the very
// bottom, which is what stops the contact line reading as a painted skirting board: real windblown
// sand thins out over a surface, it does not coat it.
uniform float blend_opacity : hint_range(0.0, 1.0) = 0.85;
uniform float blend_roughness : hint_range(0.0, 1.0) = 0.85;
// The ground's OWN detail array, handed over by TerrainBlend from the live terrain material rather
// than copied: one texture, one source of truth, and the band cannot drift from the ground when an
// artist retunes the terrain. Each layer is a greyscale modifier centred on 0.5, exactly as
// terrain_biome.gdshader treats it.
uniform sampler2DArray blend_detail : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float blend_detail_strength : hint_range(0.0, 1.0) = 0.75;
// The terrain stacks three octaves on its detail layer; the one that carries VISIBLE grain is the
// fine one, at detail_fine_ratio times the base scale. The base scale alone is ~0.001, i.e. one
// texture stretched over a kilometre -- which on a 45 cm band is a flat wash, and is exactly why
// the first attempt came out as a plain stripe. Read off the live terrain material, like the array.
uniform float blend_detail_fine = 128.0;
// THE ground's own albedo, for the biomes whose terrain_material_override runs them on
// planet_surface.gdshader instead of terrain_biome.gdshader -- the outcrops, and Tarsis 3's whole
// surface. There the colour IS a texture, not a vertex colour modulated by a grey detail layer, so
// a band built the other way matches nothing. Left unassigned, blend_use_albedo stays false and the
// flat-colour path below is used, which is what the biomes without a texture yet still need.
uniform sampler2D blend_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool blend_use_albedo = false;
// tile_scale of that material: 0.1 means one tile per 10 m, the size of the marbling one sees.
uniform float blend_albedo_scale = 0.1;
uniform float blend_fade_start = 100.0;
// The fringe is drawn AFTER the aerial-perspective quad and so carries no atmospheric veil: that
// quad reads a screen copy taken once, before the whole alpha list, and overwrites every pixel it
// covers, so no render_priority can feed a transparent into it (atmosphere_renderer.gd:180-192
// records the measurement that proves the copy is taken early). The answer is to stop before the
// veil is legible rather than to fight the ordering: with tarsis_3's rayleigh_beta, 150 m of air
// transmits 0.995 in blue -- under the 8-bit quantisation step. Well below visible.
uniform float blend_far = 150.0;
// Insurance against a depth test that rejects the coplanar overlay. Two millimetres is invisible,
// and a fringe that never draws would be read as "the feature does not work".
uniform float blend_surface_offset = 0.002;

// ── Per instance ────────────────────────────────────────────────────────────────────────────────
// instance_index is given EXPLICITLY. animated_panel_trim.gdshader:17 already declares an
// `instance uniform float animation_speed` with no index, and it runs on crates: the instance
// uniform buffer is shared by every material on the instance, so two indexless uniforms collide
// and the first material found silently wins.
//
// blend_plane holds the ground plane in MODEL space:
//   .xyz = transpose(model_basis) * up_world   -- the TRANSPOSE, not the normalised inverse. The
//          derivative of up·(B·v) with respect to v IS Bᵀ·up, and that is the only form that stays
//          exact under a NON-UNIFORM scale. With B = diag(1,2,1) and up = (1,1,0)/sqrt(2) the
//          "normalised inverse times length" form is off by 2.5x on one component -- which is
//          exactly a rock stretched for variety.
//   .w   = -dot(base_local, .xyz)
// so dot(VERTEX, .xyz) + .w is the height above the ground IN WORLD METRES already: the basis
// carries the scale, so there is no factor left to apply, and MODEL_MATRIX is never needed here.
instance uniform vec4 blend_plane : instance_index(13);
instance uniform vec3 blend_ground_color : instance_index(14);
instance uniform float blend_height : instance_index(15);
// (layer, tiling scale) of the ground's own detail texture under this object, straight from
// PlanetData.ground_detail_at -- the same pair PlanetChunk writes into UV2. y == 0 means this
// biome has no detail texture, and the band falls back to flat colour, as the terrain does.
instance uniform vec2 blend_detail_uv : instance_index(12);
// Centre of the WHOLE object (not of this mesh), in this mesh's model space. Lets a face tell
// outward from inward: a mesh's own centre would say nothing, since an inner wall is perfectly
// centred on itself.
instance uniform vec3 blend_center : instance_index(11);

// Affine in VERTEX, so the interpolation across a triangle is exact.
varying float blend_h;
// The noise coordinates MUST be carried from vertex(): in fragment(), VERTEX is the position in
// VIEW space and NORMAL the view-space normal, so sampling there would anchor the pattern to the
// camera and the fringe would visibly slide as the player turns. Model space is also what keeps
// the numbers small enough for float32.
varying vec3 tri_pos;
varying vec3 tri_w;
// Cosine between this surface's normal and the planetary up: 1 on a floor or a roof, 0 on a wall.
// Computed in MODEL space -- dot(n, transpose(B)*up) == dot(B*n, up), so the transposed plane
// normal we already carry gives the world-space answer with no extra data.
varying float face_up;
// >0 when this face looks away from the object's centre (an outer wall), <0 when it looks inward.
varying float face_out;
// The planetary up in VIEW space, which is the space fragment() writes NORMAL in.
varying vec3 up_view;

void vertex() {
	blend_h = dot(VERTEX, blend_plane.xyz) + blend_plane.w;

	// Raw model coordinates, i.e. metres for any object at scale 1 -- which is nearly all of them.
	// The noise and the ground's detail texture each apply their own tiling on top.
	tri_pos = VERTEX;
	vec3 tn = abs(NORMAL);
	tri_w = tn / max(tn.x + tn.y + tn.z, 0.001);
	// Guarded: an unset plane is all zeroes, and normalize(vec3(0)) is a NaN that would propagate
	// into the alpha and make the geometry vanish -- a spectacular failure for a missing parameter.
	float pl = length(blend_plane.xyz);
	face_up = pl > 1e-6 ? dot(normalize(NORMAL), blend_plane.xyz / pl) : 0.0;
	// Horizontal only: the vertical component is already handled by face_up, and keeping it here
	// would make a roof read as "outward" simply because it is above the centre.
	vec3 up_m = pl > 1e-6 ? blend_plane.xyz / pl : vec3(0.0, 1.0, 0.0);
	// w = 0 -- a direction, so the model matrix's astronomic translation never enters.
	up_view = normalize((MODELVIEW_MATRIX * vec4(up_m, 0.0)).xyz);
	vec3 from_c = VERTEX - blend_center;
	vec3 radial = from_c - up_m * dot(from_c, up_m);
	// BOTH vectors need guarding, not just the radial. A vertical normal -- a floor, a roof, the
	// top of a wall -- flattens to the zero vector here, and normalize(vec3(0)) is a NaN that
	// propagates straight into ALPHA. The result is a fringe that vanishes in patches, with
	// nothing in any log to say why.
	vec3 n_h = NORMAL - up_m * dot(NORMAL, up_m);
	float nh = length(n_h);
	float rl = length(radial);
	// 1.0 == "treat as outward", the neutral answer: a face we cannot classify keeps its sand
	// rather than losing it on a technicality.
	face_out = (nh > 1e-4 && rl > 1e-4) ? dot(n_h / nh, radial / rl) : 1.0;

	VERTEX += NORMAL * blend_surface_offset;

	// Nothing to paint this far out: collapse the triangle to a point so the rasteriser emits no
	// fragment at all. That is the whole cost story -- a distant building pays a vertex, not a
	// screenful of blended pixels.
	//
	// MODELVIEW_MATRIX[3].xyz is the model ORIGIN in view space, the SAME value for every vertex of
	// this draw. A per-vertex test would tear an object straddling the threshold into shards, one
	// vertex collapsed and two not. The slack covers a large building whose origin is far while a
	// corner is still near; the visible edge is the fragment fade below, which is exact.
	if (blend_height <= 0.0 || length(MODELVIEW_MATRIX[3].xyz) > blend_far + 256.0) {
		VERTEX = vec3(0.0);
	}
}

// w passed in rather than read from the varying: a function reaching for a varying compiles on
// some backends and not others, and a shader that fails to compile is replaced in SILENCE by
// Godot's fallback material.
float tri_noise(vec3 p, vec3 w) {
	return texture(blend_noise, p.yz).r * w.x
			+ texture(blend_noise, p.xz).r * w.y
			+ texture(blend_noise, p.xy).r * w.z;
}


void fragment() {
	// An unconfigured plane is all zeroes, which would make blend_h zero EVERYWHERE and repaint the
	// whole object in ground colour -- a wall of sand instead of a fringe. Uniform across the draw,
	// so it costs nothing, and it fails visibly quiet rather than spectacularly wrong.
	if (dot(blend_plane.xyz, blend_plane.xyz) < 1e-12) {
		discard;
	}


	// Two octaves, from the varying (MODEL space -- fragment's own VERTEX is in VIEW space and would
	// make the pattern swim with the camera).
	// Three octaves, weighted so the LOWEST dominates: half the displacement comes from the swell
	// that spans metres, the rest sharpens it. Weights sum to 1 so blend_noise_strength alone
	// controls the overall amplitude.
	float s = blend_noise_scale;
	float mask = tri_noise(tri_pos * s * blend_noise_swell, tri_w) * 0.5
			+ tri_noise(tri_pos * s, tri_w) * 0.32
			+ tri_noise(tri_pos * s * blend_noise_detail, tri_w) * 0.18;

	// The noise scales the band's HEIGHT -- never its opacity. This is the difference between "how
	// far up does the sand reach here" and "how see-through is it here", and only the first is a
	// real description of drifted sand.
	//
	// It also fixes the flaw the opacity form had, which no amount of tuning could: with the noise
	// on alpha, a trough left the band translucent AT THE CONTACT ITSELF -- at strength 0.6 and
	// curve 3.5, pow(0.4, 3.5) is 0.04 -- so the bare cut line showed through exactly where the
	// fringe exists to hide it. Here blend_h = 0 gives t = 1 whatever the noise says, so the
	// junction is full ground colour EVERYWHERE, and the noise only decides where it stops.
	float h_eff = max(blend_height * (1.0 + (mask * 2.0 - 1.0) * blend_noise_strength), 0.001);
	float t = clamp(1.0 - blend_h / h_eff, 0.0, 1.0);

	// Full ground at the contact, thinning as it climbs -- rather than one uniformly translucent
	// band, which reads as a painted skirting.
	float a = pow(t, blend_curve) * blend_opacity;
	// Upright faces keep the full band; flat ones lose it. The smoothstep leaves a gentle slope
	// (a shallow roof, a ramp) mostly unfringed while a wall is untouched.
	float upright = 1.0 - abs(face_up);
	a *= mix(1.0, smoothstep(0.0, 0.45, upright), blend_face_weight);
	// Inward-facing walls -- the inside of a building -- keep no sand.
	a *= mix(1.0, smoothstep(-0.25, 0.15, face_out), blend_inward_weight);
	// In fragment(), VERTEX is the view-space position the engine computed on its emulated
	// double-precision path, so this distance is exact at 1e11 m -- unlike anything reconstructed
	// from MODEL_MATRIX, whose translation is truncated to float32.
	a *= 1.0 - smoothstep(blend_fade_start, blend_far, length(VERTEX));

	// Above the band -- roofs, upper floors, glazing -- leave BEFORE the lighting loop. This discard
	// is what makes the overlay affordable on a building that fills the screen.
	if (a <= 0.004) {  // below 1/255: the blend would be a no-op anyway
		discard;
	}

	// Borrow the ground's OWN grain, so the band reads as ground rather than as paint. One octave
	// where terrain_biome.gdshader runs three (base, macro, fine): the band is a few dozen
	// centimetres tall and mostly seen at a glancing angle, so the other two would not survive the
	// mip chain. The combination is the terrain's own -- colour * mix(1, detail*2, strength) --
	// because a detail layer is a greyscale modifier centred on 0.5, not a colour.
	if (blend_use_albedo) {
		// Sample the ground's real texture, triplanar on model coordinates. No hex-tiling here,
		// unlike planet_surface.gdshader: its stochastic tiling exists to hide repetition across
		// hundreds of metres of open ground, and 499 lines of it would buy nothing on a band a few
		// dozen centimetres tall where a single tile barely fits.
		vec3 ap = tri_pos * blend_albedo_scale;
		ALBEDO = texture(blend_albedo_tex, ap.yz).rgb * tri_w.x
				+ texture(blend_albedo_tex, ap.xz).rgb * tri_w.y
				+ texture(blend_albedo_tex, ap.xy).rgb * tri_w.z;
	} else {
		float detail = 0.5;  // neutral: no detail texture for this biome
		if (blend_detail_uv.y > 0.0) {
			vec3 dp = tri_pos * (blend_detail_uv.y * blend_detail_fine);
			float layer = blend_detail_uv.x;
			detail = texture(blend_detail, vec3(dp.yz, layer)).r * tri_w.x
					+ texture(blend_detail, vec3(dp.xz, layer)).r * tri_w.y
					+ texture(blend_detail, vec3(dp.xy, layer)).r * tri_w.z;
		}
		ALBEDO = blend_ground_color * mix(1.0, detail * 2.0, blend_detail_strength);
	}
	// Lit as ground where it IS ground. `t` is 1 at the contact and 0 at the top of the band, so
	// the lift is strongest exactly where the mismatch shows.
	vec3 lifted = mix(NORMAL, up_view, t * blend_normal_lift);
	// A wall facing straight down would make these two opposite and the mix vanish; keep the
	// surface's own normal rather than emit a zero vector.
	NORMAL = length(lifted) > 1e-4 ? normalize(lifted) : NORMAL;
	ROUGHNESS = blend_roughness;
	METALLIC = 0.0;
	ALPHA = a;
}
