@tool
class_name BiomeRelief
## A light, deterministic undulation added to the heightmap on the zones of a
## biome that asks for one (BiomeDefinition.relief_*): outcrop plateaus would
## otherwise read as a perfect plane at eye level.
##
## Same contract as the corundum cracks: [method offset] is a PURE function of
## the surface direction and the biome's constants — no height, no time, no
## RNG — so PlanetChunk.generate_mesh (client) and generate_collision_shape
## (server) get bit-identical values for the same vertex, and the normal probes
## can evaluate it at their own directions.
##
## LOD: like the cracks, the noise is dropped entirely (never faded) once the
## grid's vertex spacing reaches half its wavelength — a feature the grid
## cannot represent must not exist in either geometry.
##
## Roads flatten it: [method road_weight] is 0 within half-width + a flat
## margin of any road centreline and ramps to 1 past a blend margin, so a
## ribbon or a bed (both sit on the raw heightmap) is never pierced by the
## ground and its surroundings join the relief without a step. The margins
## scale with the grid: the relief lives on VERTICES and the surface between
## them is interpolated, so every vertex of every triangle that touches the
## road must be flat — one and a half vertex pitches (~20 m at the finest
## LOD) past the road edge, not two metres.

## Weight of the finer octave (wavelength / 3).
const DETAIL_OCTAVE_W := 0.25
## Flat band past the road's half-width, and where the relief is back to
## full — floors; the vertex pitch widens them (see road_weight).
const FLAT_MARGIN_M := 2.0
const BLEND_MARGIN_M := 10.0
## Flat band in vertex pitches (the triangle diagonal is 1.41 pitch), and the
## blend reach.
const FLAT_PITCHES := 1.5
const BLEND_PITCHES := 3.0


## Relief in metres at [param dir] for [param bd], 0 when the biome has none
## or the grid ([param vtx_spacing_m], 0 = no gate) is too coarse for it.
static func offset(dir: Vector3, radius: float, bd: BiomeDefinition,
		vtx_spacing_m: float = 0.0) -> float:
	if bd == null or not bd.has_relief():
		return 0.0
	var wl: float = bd.relief_wavelength_m
	if vtx_spacing_m > 0.0 and vtx_spacing_m >= wl * 0.5:
		return 0.0
	var n := SurfaceNoise.vnoise(dir * (radius / wl))
	var wl2 := wl / 3.0
	if vtx_spacing_m <= 0.0 or vtx_spacing_m < wl2 * 0.5:
		n = (1.0 - DETAIL_OCTAVE_W) * n + DETAIL_OCTAVE_W * SurfaceNoise.vnoise(dir * (radius / wl2))
	return lerpf(bd.relief_min_m, bd.relief_max_m, clampf(n, 0.0, 1.0))


## 0 on and around a road, 1 away from every road, smooth in between.
## [param roads] are decoded road records (centerline in lon/lat degrees);
## [param lonlat] the vertex, [param m_per_deg] the planet's metres per degree,
## [param vtx_spacing_m] the grid's vertex pitch (0 = the metre floors only).
static func road_weight(lonlat: Vector2, roads: Array, m_per_deg: float,
		vtx_spacing_m: float = 0.0) -> float:
	if roads.is_empty():
		return 1.0
	var flat_margin := maxf(FLAT_MARGIN_M, FLAT_PITCHES * vtx_spacing_m)
	var full_margin := maxf(BLEND_MARGIN_M, BLEND_PITCHES * vtx_spacing_m)
	var lat_scale := cos(deg_to_rad(clampf(lonlat.y, -89.5, 89.5)))
	if lat_scale < 1e-6:
		lat_scale = 1e-6
	var w := 1.0
	for r in roads:
		var cl: PackedVector2Array = r.get("centerline", PackedVector2Array())
		if cl.size() < 2:
			continue
		var flat_m: float = RoadTerrain.get_half_width_m(r) + flat_margin
		var full_m: float = RoadTerrain.get_half_width_m(r) + full_margin
		var full_deg := full_m / m_per_deg
		var best_sq := INF
		for i in cl.size() - 1:
			best_sq = minf(best_sq, RoadTerrain._dist_sq_to_segment(lonlat, cl[i], cl[i + 1], lat_scale))
			if best_sq <= 0.0:
				break
		if best_sq >= full_deg * full_deg:
			continue
		var d_m := sqrt(best_sq) * m_per_deg
		if d_m <= flat_m:
			return 0.0
		w = minf(w, smoothstep(flat_m, full_m, d_m))
	return w


## The road pieces a chunk's relief must respect: its own and its eight
## neighbours' (a vertex at the pixel edge sees the road just across it),
## deduplicated on feature + piece start.
static func gather_roads(data: PlanetData, hp_nside: int, hp_ipix: int) -> Array:
	var out: Array = []
	if hp_nside <= 0 or hp_ipix < 0:
		return out
	var seen := {}
	var pix: Array = [hp_ipix]
	for nb in HEALPix.get_neighbors_nest(hp_nside, hp_ipix).values():
		if int(nb) >= 0:
			pix.append(int(nb))
	for ip in pix:
		for r in data.get_roads_for_chunk(hp_nside, int(ip)):
			var cum: PackedFloat64Array = r.get("_cum_lengths", PackedFloat64Array())
			var key := "%d_%.3f" % [int(r.get("feature_id", -1)), cum[0] if not cum.is_empty() else 0.0]
			if seen.has(key):
				continue
			seen[key] = true
			out.append(r)
	return out
