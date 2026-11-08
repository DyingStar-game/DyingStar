extends RefCounted
## Authority-only sampling: fine crater rings, coarser rings over every flank.
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const SECTORS := 96
const RINGS := 96
const CRATER_RINGS := 24
const ERUPTION_TICKS := 6000
const VISCOSITY_PA_S := 400
static var _required_tiles := {}

static func ring_edges(volcano: VolcanoRelief.Volcano) -> PackedInt64Array:
	var crater := maxi(3000, roundi(volcano.rc * 1000.0))
	var reach := roundi(maxf(volcano.rb * (1.0 + volcano.irr) + 500.0, volcano.rc + 3000.0) * 1000.0)
	reach = mini(reach, crater + (RINGS - CRATER_RINGS) * 128000)
	var edges := PackedInt64Array()
	for r in CRATER_RINGS + 1: edges.append(r * crater / CRATER_RINGS)
	for r in range(1, RINGS - CRATER_RINGS + 1): edges.append(crater + r * (reach - crater) / (RINGS - CRATER_RINGS))
	return edges

static func terrain_ready(data: PlanetData, volcano: VolcanoRelief.Volcano) -> bool:
	if data.remote_source == null: return true
	var key := "%d/%s/%d" % [data.get_instance_id(), VolcanoFeatures.key_of(volcano), data.max_quadtree_depth]
	var finest := 1 << data.max_quadtree_depth
	if not _required_tiles.has(key):
		if _required_tiles.size() > 32: _required_tiles.clear()
		var tiles := {}
		var up := volcano.c.normalized()
		var ref := Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT
		var east := up.cross(ref).normalized()
		var north := up.cross(east).normalized()
		var edges := ring_edges(volcano)
		for r in RINGS:
			var radius := (edges[r] + edges[r + 1]) / 2000.0
			for x in SECTORS:
				var a := (x + 0.5) * TAU / SECTORS
				var dir := (up + (east * cos(a) + north * sin(a)) * (radius / data.radius)).normalized()
				tiles[HEALPix.vec2pix_nest(finest, dir)] = true
				if r == CRATER_RINGS:
					var rim_dir := (up + (east * cos(a) + north * sin(a)) * (volcano.rc / data.radius)).normalized()
					tiles[HEALPix.vec2pix_nest(finest, rim_dir)] = true
		_required_tiles[key] = tiles
	var ready := true
	for ip: int in _required_tiles[key]:
		if not TileResidency.request_chunk_tiles(data, finest, ip): ready = false
	return ready

static func build(data: PlanetData, volcano: VolcanoRelief.Volcano) -> Dictionary:
	if volcano == null or data == null or volcano.rc < 24.0 or data.radius < 1000.0: return {}
	if not is_finite(data.surface_gravity) or data.surface_gravity < 0.001 or data.surface_gravity > 50.0: return {}
	if not terrain_ready(data, volcano): return {}
	var started := Time.get_ticks_usec()
	var up := volcano.c.normalized()
	var ref := Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT
	var x_axis := up.cross(ref).normalized()
	var z_axis := x_axis.cross(up).normalized()
	var base_height := data.sample_height_for_direction(up)
	var origin := up * (data.radius + base_height)
	var edges := ring_edges(volcano)
	var finest := 1 << data.max_quadtree_depth
	var contexts := {}
	var samples := PackedInt64Array()
	var rims := PackedInt64Array()
	var low := 1 << 60
	var high := -(1 << 60)
	for r in RINGS:
		var radius := (edges[r] + edges[r + 1]) / 2000.0
		for x in SECTORS:
			var a := (x + 0.5) * TAU / SECTORS
			var dir := (up + (x_axis * cos(a) + z_axis * sin(a)) * (radius / data.radius)).normalized()
			var ip := HEALPix.vec2pix_nest(finest, dir)
			if not contexts.has(ip): contexts[ip] = GradeBed.make_ctx(data, finest, ip, 1.0)
			var h := data.sample_height_for_direction(dir)
			if not (contexts[ip] as Dictionary).is_empty(): h = GradeBed.apply(h, HEALPix.vec2lonlat(dir), contexts[ip])
			var mm := roundi((dir * (data.radius + h) - origin).dot(up) * 1000.0)
			samples.append(mm)
			low = mini(low, mm); high = maxi(high, mm)
	for x in SECTORS:
		var a := (x + 0.5) * TAU / SECTORS
		var dir := (up + (x_axis * cos(a) + z_axis * sin(a)) * (volcano.rc / data.radius)).normalized()
		rims.append(roundi((dir * (data.radius + data.sample_height_for_direction(dir)) - origin).dot(up) * 1000.0))
	if high - low > Core.MAX_TERRAIN_SPAN_MM: return {}
	for i in samples.size(): samples[i] -= low
	for x in rims.size(): rims[x] -= low
	var core := Core.new()
	core.gravity_milli = roundi(data.surface_gravity * 1000.0)
	core.viscosity_q = VISCOSITY_PA_S
	core.yield_q = 30
	core.cleanup_enabled = true
	if not core.configure_polar_q(SECTORS, edges, samples): return {}
	core.crater_rows = CRATER_RINGS
	core.rim_heights_q = rims
	core.eruption_head_mm = 64000
	var fill_q := 0
	var lowest := rims[0]
	for h in rims: lowest = mini(lowest, h)
	for i in CRATER_RINGS * SECTORS:
		fill_q += maxi(0, lowest - samples[i]) * core.areas_q[i] / 1000000
	var peak := clampi(fill_q / 900, 500000, 3000000)
	var key := VolcanoFeatures.key_of(volcano)
	return {"key": data.planet_name + "/" + key, "planet": data.planet_name,
		"volcano_key": key, "volcano_seed": volcano.seed,
		"frame": Transform3D(Basis(x_axis, up, z_axis), origin + up * (low / 1000.0)),
		"source_x_mm": 0, "source_z_mm": 0, "source_radius_mm": roundi(volcano.rc * 980.0),
		"source_rate_q": peak, "source_temperature_t": 12000, "eruption_ticks": ERUPTION_TICKS,
		"source_radius_from_summit_m": 0.0, "source_height_m": base_height,
		"crater_radius_m": volcano.rc, "crater_rows": CRATER_RINGS,
		"field_radius_m": edges[-1] / 1000.0, "fill_to_lowest_rim_m3": fill_q / float(Core.Q_PER_M3),
		"checkpoint": core.checkpoint(), "relief_mm": high - low,
		"build_ms": (Time.get_ticks_usec() - started) / 1000.0}

static func source_commands(solver, packet: Dictionary, elapsed_ticks: int, strength: float) -> PackedInt64Array:
	var opening := 1.0 - smoothstep(120.0, 240.0, elapsed_ticks / 10.0)
	var rate := lerpf(0.1, 1.0, opening)
	var volume := roundi(int(packet.source_rate_q) * clampf(strength, 0.0, 4.0) * rate)
	return solver.disc_commands(0, 0, packet.source_radius_mm, volume, packet.source_temperature_t) if volume > 0 else PackedInt64Array()
