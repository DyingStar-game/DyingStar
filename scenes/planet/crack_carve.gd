class_name CrackCarve
## The corundum crack network as the height sampler adds it — the procedural
## canyons, seen by every caller of PlanetData.sample_height_for_direction the
## way the mountains are, instead of being re-added by hand where needed.
##
## [param cracks] of the sampler says what the caller wants:
## - [constant NONE]: the relief alone. For what bridges a chasm rather than
##   diving into it (grade profiles, bridges, road slabs and their colour, pads
##   and the editor snap that must agree with them), and for the chunk builders'
##   vertex, which carve the crack themselves right after the rim snap
##   (ArideDesertCorundumPlateauTerrain.crack_rim_snap) from the edge distance it
##   returns — one Voronoi per vertex. PlanetData.crack_aware_surface_dist and
##   RoadBridge.chasm_depth_at call [method offset] at pitch 0 themselves: the
##   full-depth crack, whatever pitch their mountains are sampled at.
## - [constant AUTO]: the ground as it stands — carved wherever the zone rule
##   (PlanetData.cracks_apply_at) says the ground is corundum. The default.
## - [constant CARVE]: the caller has already decided the ground is carved here
##   (a chunk's normal probes, from their vertex's zone): no zone lookup.
##
## The carve is PlanetData.crack_factor × crack_offset at the sampler's pitch —
## skipped past half the crack width, full depth wherever drawn — the same
## arithmetic, in the same order, as the chunk builders; TileFrameNative.Crack
## is its C# twin, held equal bit for bit by test_tile_frame_native.gd.

const NONE := 0
const AUTO := 1
const CARVE := 2


## The offset (≤ 0, m) the network carves at [param dir] for a grid of pitch
## [param vtx_spacing_m] (0 = full detail). The caller has checked that the
## planet has the network (corundum_default_biome) and that [param cracks] is
## not NONE.
static func offset(data: PlanetData, dir: Vector3, frame: PlanetData.TileFrame,
		vtx_spacing_m: float, cracks: int) -> float:
	var off := ArideDesertCorundumPlateauTerrain.crack_offset(dir, data.radius,
			data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, vtx_spacing_m, data.crack_noise())
	# Most of the ground is solid block: decided by the Voronoi alone, before
	# any zone or POI lookup.
	if off == 0.0:
		return 0.0
	if cracks == AUTO and not _applies(data, dir, frame):
		return 0.0
	var pois: Array = frame.crack_pois if frame != null and frame.crack_ready else data.crack_pois()
	return off * data.crack_factor(dir, pois, frame)


## How much of the network's depth the ground keeps at [param dir], in [0, 1],
## whatever the network does there: 0 where the ground is not corundum, inside a
## POI's sphere and on a massif, 1 on the open plateau. The "where" of
## [method offset] without its Voronoi, for whoever already knows a crack runs
## through [param dir] and asks only whether the game carves it (the star chart's
## lines).
static func depth_factor(data: PlanetData, dir: Vector3, frame: PlanetData.TileFrame) -> float:
	if not _applies(data, dir, frame):
		return 0.0
	var pois: Array = frame.crack_pois if frame != null and frame.crack_ready else data.crack_pois()
	return data.crack_factor(dir, pois, frame)


## PlanetData.cracks_apply_at, answered from the frame when its export tile
## holds no populate zone (the whole tile is the corundum default).
static func _applies(data: PlanetData, dir: Vector3, frame: PlanetData.TileFrame) -> bool:
	if frame != null and frame.crack_ready and frame.crack_zone >= 0 \
			and HEALPix.vec2pix_nest(frame.crack_zone_nside, dir) == frame.crack_zone_ipix:
		return frame.crack_zone == 1
	return data.cracks_apply_at(dir)


## Give [param frame] what the carve of chunk (hp_nside, hp_ipix) reads per
## sample: the POI spheres it can meet (the builders' crack_pois_near subset)
## and the zone rule over its export tile. Called by the chunk builders right
## after prepare_mountain_frame, and by whoever samples a patch through a frame.
static func prepare_frame(data: PlanetData, frame: PlanetData.TileFrame,
		hp_nside: int, hp_ipix: int) -> void:
	if frame == null or not data.corundum_default_biome or hp_nside <= 0 or hp_ipix < 0:
		return
	frame.crack_pois = data.crack_pois_near(HEALPix.pix2vec_nest(hp_nside, hp_ipix),
			HEALPix.pixel_side_length(hp_nside, 1.0) * data.radius * 0.8)
	frame.crack_zone = -1
	var zones: Array = []
	if hp_nside >= data.export_nside:
		var eipix := hp_ipix
		var ns := hp_nside
		while ns > data.export_nside:
			eipix >>= 2
			ns >>= 1
		frame.crack_zone_ipix = eipix
		frame.crack_zone_nside = data.export_nside
		zones = data.get_chunk_populate_zones(eipix)
		# No zone at all: first_zone_at is empty over the whole tile, and
		# cracks_apply_to_zone({}) is the corundum default — carved.
		if zones.is_empty():
			frame.crack_zone = 1
	frame.crack_ready = true
	if frame.native != null:
		var dirs := PackedVector3Array()
		var radii := PackedFloat64Array()
		for p: Dictionary in frame.crack_pois:
			dirs.append(p["dir"])
			radii.append(float(p["radius"]))
		frame.native.SetCrackFrame(dirs, radii, data.crack_poi_margin_m, frame.crack_zone,
				frame.crack_zone_ipix, frame.crack_zone_nside)
		if not zones.is_empty():
			_send_zones(data, frame, zones)


## The tile's zones to the C# half, so that it decides the zone rule per direction as
## PlanetData.cracks_apply_at does (first_zone_at, then cracks_apply_to_zone) instead of
## leaving every crack sample of a zoned tile to GDScript — 77 µs a sample against 8 on
## tarsis_3, where a refined cell re-reads 64 sub-vertices. The verdict of each zone is
## decided here, once; the C# only finds which zone holds the direction
## (PlanetChunk._dir_in_populate_zone). A "point" zone, or an outline of fewer than three
## vertices, never holds one and is left out; past a "full" zone none is reached.
static func _send_zones(data: PlanetData, frame: PlanetData.TileFrame, zones: Array) -> void:
	var full := PackedInt32Array()
	var carves := PackedInt32Array()
	var starts := PackedInt32Array([0])
	var verts := PackedFloat64Array()
	for z: Dictionary in zones:
		var coverage: String = z.get("coverage", "")
		if coverage == "point":
			continue
		var outline: Array = z.get("vertices", [])
		if coverage != "full" and outline.size() < 3:
			continue
		full.append(1 if coverage == "full" else 0)
		carves.append(1 if data.cracks_apply_to_zone(z) else 0)
		if coverage != "full":
			for v: Variant in outline:
				verts.append(float(v[0]))
				verts.append(float(v[1]))
		@warning_ignore("integer_division")
		starts.append(verts.size() / 2)
		if coverage == "full":
			break
	frame.native.SetCrackZones(full, carves, starts, verts,
			1 if data.cracks_apply_to_zone({}) else 0)
