extends RefCounted
## Authority-only sampling: fine crater rings, coarser rings over every flank.
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const SECTORS := 96
const RINGS := 96
const CRATER_RINGS := 24
## Share (per mille) of the peak rate fed once the crater has overflowed, for the rest of the eruption.
const TAIL_PERMILLE := 50
## Full peak rate until this tick after the start, then a linear fall to the tail until OPEN_END_TICKS.
const OPEN_FULL_TICKS := 1200
const OPEN_END_TICKS := 2400
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

## Whole build in one call (tests, offline preview). A server uses [method start_build] and steps it.
static func build(data: PlanetData, volcano: VolcanoRelief.Volcano) -> Dictionary:
	var job := start_build(data, volcano)
	if job == null:
		return {}
	while not job.step(1 << 40):
		pass
	return job.result


## A build split over frames: 9 312 height samples cost 0.3-0.8 s, too long for one server frame. Runs on the
## main thread (PlanetData's lazy caches are not thread-safe). null when the volcano or planet is unusable or
## its tiles are not resident yet ([method terrain_ready]).
static func start_build(data: PlanetData, volcano: VolcanoRelief.Volcano) -> BuildJob:
	if volcano == null or data == null or volcano.rc < 24.0 or data.radius < 1000.0: return null
	if not is_finite(data.surface_gravity) or data.surface_gravity < 0.001 or data.surface_gravity > 50.0: return null
	if not terrain_ready(data, volcano): return null
	return BuildJob.new(data, volcano, ring_edges(volcano))


class BuildJob:
	extends RefCounted
	## The patch description once [method step] has returned true; {} when the site was rejected.
	var result: Dictionary = {}
	var spent_usec := 0
	var _data: PlanetData
	var _volcano: VolcanoRelief.Volcano
	var _up: Vector3
	var _x_axis: Vector3
	var _z_axis: Vector3
	var _origin: Vector3
	var _base_height := 0.0
	var _edges: PackedInt64Array
	var _finest := 0
	var _contexts := {}
	var _samples := PackedInt64Array()
	var _rims := PackedInt64Array()
	var _low := 1 << 60
	var _high := -(1 << 60)
	var _row := 0

	func _init(data: PlanetData, volcano: VolcanoRelief.Volcano, edges: PackedInt64Array) -> void:
		_data = data
		_volcano = volcano
		_up = volcano.c.normalized()
		var ref := Vector3.UP if absf(_up.y) < 0.95 else Vector3.RIGHT
		_x_axis = _up.cross(ref).normalized()
		_z_axis = _x_axis.cross(_up).normalized()
		_base_height = data.sample_height_for_direction(_up)
		_origin = _up * (data.radius + _base_height)
		_edges = edges
		_finest = 1 << data.max_quadtree_depth

	## Samples rows until [param budget_usec] is spent; true once finished (see [member result]).
	func step(budget_usec: int) -> bool:
		var started := Time.get_ticks_usec()
		while _row < RINGS:
			var radius := (_edges[_row] + _edges[_row + 1]) / 2000.0
			for x in SECTORS:
				var mm := _sample(x, radius)
				_samples.append(mm)
				_low = mini(_low, mm); _high = maxi(_high, mm)
			_row += 1
			if Time.get_ticks_usec() - started >= budget_usec:
				spent_usec += Time.get_ticks_usec() - started
				return false
		for x in SECTORS:
			_rims.append(_sample(x, _volcano.rc))
		spent_usec += Time.get_ticks_usec() - started
		result = _finish()
		return true

	## Ground height (mm) along the patch's up axis, sector [param x] at [param radius] m from the summit.
	func _sample(x: int, radius: float) -> int:
		var a := (x + 0.5) * TAU / SECTORS
		var dir := (_up + (_x_axis * cos(a) + _z_axis * sin(a)) * (radius / _data.radius)).normalized()
		var ip := HEALPix.vec2pix_nest(_finest, dir)
		if not _contexts.has(ip): _contexts[ip] = GradeBed.make_ctx(_data, _finest, ip, 1.0)
		var h := _data.sample_height_for_direction(dir)
		if not (_contexts[ip] as Dictionary).is_empty(): h = GradeBed.apply(h, HEALPix.vec2lonlat(dir), _contexts[ip])
		return roundi((dir * (_data.radius + h) - _origin).dot(_up) * 1000.0)

	func _finish() -> Dictionary:
		var samples := _samples
		var rims := _rims
		var low := _low
		var high := _high
		if high - low > Core.MAX_TERRAIN_SPAN_MM: return {}
		for i in samples.size(): samples[i] -= low
		for x in rims.size(): rims[x] -= low
		var core := Core.new()
		core.gravity_milli = roundi(_data.surface_gravity * 1000.0)
		core.viscosity_q = VISCOSITY_PA_S
		core.yield_q = 30
		core.cleanup_enabled = true
		if not core.configure_polar_q(SECTORS, _edges, samples): return {}
		core.crater_rows = CRATER_RINGS
		core.rim_heights_q = rims
		core.eruption_head_mm = 64000
		var fill_q := 0
		var lowest := rims[0]
		for h in rims: lowest = mini(lowest, h)
		for i in CRATER_RINGS * SECTORS:
			fill_q += maxi(0, lowest - samples[i]) * core.areas_q[i] / 1000000
		var peak := clampi(fill_q / 900, 500000, 3000000)
		var key := VolcanoFeatures.key_of(_volcano)
		return {"key": _data.planet_name + "/" + key, "planet": _data.planet_name,
			"volcano_key": key, "volcano_seed": _volcano.seed,
			"frame": Transform3D(Basis(_x_axis, _up, _z_axis), _origin + _up * (low / 1000.0)),
			"source_x_mm": 0, "source_z_mm": 0, "source_radius_mm": roundi(_volcano.rc * 980.0),
			"source_rate_q": peak, "source_temperature_t": 12000,
			"source_radius_from_summit_m": 0.0, "source_height_m": _base_height,
			"crater_radius_m": _volcano.rc, "crater_rows": CRATER_RINGS,
			"field_radius_m": _edges[-1] / 1000.0, "fill_to_lowest_rim_m3": fill_q / float(Core.Q_PER_M3),
			"checkpoint": core.checkpoint(), "relief_mm": high - low, "build_ms": spent_usec / 1000.0}


## The integer eruption plan shared by every peer, from an eruption window of
## VolcanoActivityProfile.eruption_window (authority only: it reads floats once).
## Tick 1 of the patch is the first 100 ms after start_unix_ms.
static func eruption_plan(window: Dictionary, packet: Dictionary) -> Dictionary:
	var length := clampi(roundi(float(window.length_s) * 10.0), 1, 864000)
	return {"start_unix_ms": roundi(float(window.start_unix) * 10.0) * 100, "eruption_ticks": length,
		"strength_milli": clampi(roundi(float(window.strength) * 1000.0), 0, 4000),
		"ramp_up_ticks": clampi(roundi(float(window.get("ramp_up_s", 45.0)) * 10.0), 1, length),
		"ramp_down_ticks": clampi(roundi(float(window.get("ramp_down_s", 30.0)) * 10.0), 1, length),
		"source_rate_q": int(packet.source_rate_q), "tail_permille": TAIL_PERMILLE}


## Plan fields checked before a peer trusts a received plan.
static func valid_plan(plan: Dictionary) -> bool:
	for field in ["start_unix_ms", "eruption_ticks", "strength_milli", "ramp_up_ticks", "ramp_down_ticks",
			"source_rate_q", "tail_permille"]:
		if not plan.has(field) or typeof(plan[field]) not in [TYPE_INT, TYPE_FLOAT]:
			return false
	return (int(plan.eruption_ticks) >= 1 and int(plan.eruption_ticks) <= 864000
		and int(plan.strength_milli) >= 0 and int(plan.strength_milli) <= 4000
		and int(plan.ramp_up_ticks) >= 1 and int(plan.ramp_down_ticks) >= 1
		and int(plan.source_rate_q) >= 1 and int(plan.source_rate_q) <= 3000000
		and int(plan.tail_permille) >= 1 and int(plan.tail_permille) <= 1000)


## Litres fed by the crater during patch tick [param tick] (1-based): integers only, so every peer derives
## the same commands. Never 0 inside the eruption: a 2 s gap would start the end-of-eruption cleanup.
static func eruption_volume_q(tick: int, plan: Dictionary) -> int:
	var length := int(plan.eruption_ticks)
	var age := tick - 1
	if age < 0 or age >= length:
		return 0
	var up := clampi(int(plan.ramp_up_ticks), 1, maxi(1, length * 45 / 100))
	var down := clampi(int(plan.ramp_down_ticks), 1, maxi(1, length * 45 / 100))
	var envelope := mini(1000, mini((age + 1) * 1000 / up, (length - age) * 1000 / down))
	var tail := clampi(int(plan.tail_permille), 1, 1000)
	var opening := 1000
	if age >= OPEN_END_TICKS:
		opening = tail
	elif age > OPEN_FULL_TICKS:
		opening = 1000 - (1000 - tail) * (age - OPEN_FULL_TICKS) / (OPEN_END_TICKS - OPEN_FULL_TICKS)
	# <= 3e6 x 4000 x 1000 x 1000 = 1.2e16: far below int64.
	var volume := int(plan.source_rate_q) * int(plan.strength_milli) * envelope * opening / 1000000000
	return maxi(1, volume)


## Crater commands of patch tick [param tick], each share bounded by the room left in its cell: a full cell
## must not make inject_q refuse the whole tick. Reads the canonical state only, so peers agree.
static func eruption_commands(solver, packet: Dictionary, plan: Dictionary, tick: int) -> PackedInt64Array:
	var volume := eruption_volume_q(tick, plan)
	if volume <= 0:
		return PackedInt64Array()
	var commands: PackedInt64Array = solver.disc_commands(0, 0, int(packet.source_radius_mm), volume,
		int(packet.source_temperature_t))
	var at := 0
	for p in range(0, commands.size(), 3):
		var i := commands[p]
		var amount := mini(commands[p + 1], solver.capacities_q[i] - solver.volume_q[i])
		if amount > 0:
			commands[at] = i; commands[at + 1] = amount; commands[at + 2] = commands[p + 2]
			at += 3
	commands.resize(at)
	return commands
