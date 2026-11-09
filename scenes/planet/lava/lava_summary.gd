extends RefCounted
## A compact picture of a lava patch for the network, instead of its ~260 KB checkpoint: the exact wet mask
## (1 bit per cell) and Voronoi seeds, cells of the field that carry the values the renderer needs (depth,
## temperature, surface age, fade, flow). A replica rebuilds every wet cell's values from its nearest seeds.
## Seeds are added as the lava spreads (on the flanks, a wet cell farther than [member spacing_m] from every
## seed; in the crater, one more than [member crater_sector_step] sectors from the seeds of its ring) and never
## move, so the picture does not jump from one summary to the next.
##
## Measured against the simulation by test/lava/lava_summary_probe.tscn (crater ~1 %, flanks 1-5 cm, 3-5 KB).

const VERSION := 1
const GRID_VERSION := 1
## Bytes before the wet mask in a summary.
const HEADER := 20
## Per seed: cell (u16), depth or level (u16), temperature, age, opacity (u8), flow x and z (s8).
const SEED_BYTES := 9
const MAX_SIDE := 256
## How often (ms) the authority publishes a patch's summary; a replica interpolates across it.
const INTERVAL_MS := 3000
## Seeds taken into each wet cell's interpolation.
const NEAREST := 4

## Seed spacing (m) on the flanks.
var spacing_m := 150.0
## Seed spacing inside the crater (its first crater_rows rings), in sectors along each ring. The crater is
## not round about its vent: early on, one ring can hold 0.3 m in a sector and 34 m in another, so the
## crater is sampled and interpolated on its polar grid, not in metres.
var crater_sector_step := 6
## Cell index of each seed, in creation order.
var seeds := PackedInt32Array()
var _positions := PackedVector2Array()
var _bins := {} # Vector3i(bin x, bin z, zone) -> PackedInt32Array of seed numbers (indices into seeds)
var _width := 1
var _crater_rows := 0
var _ring_seeds := {} # crater ring -> PackedInt32Array of its seeds' cells


func _init(spacing: float = 150.0, crater_step: int = 6) -> void:
	spacing_m = spacing
	crater_sector_step = maxi(1, crater_step)


## Centre of every cell of [param core] in the patch plane (m), as the presentation solver places them.
static func cell_positions(core) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(core.width * core.height)
	for i in out.size():
		if core.geometry_mode == 1:
			var z: int = i / core.width
			var radius: float = (core.radial_edges_mm[z] + core.radial_edges_mm[z + 1]) / 2000.0
			var angle: float = (i % core.width + 0.5) * TAU / core.width
			out[i] = Vector2(cos(angle), sin(angle)) * radius
		else:
			out[i] = Vector2(i % core.width, i / core.width) * (core.cell_mm / 1000.0)
	return out


## Adds a seed on every wet cell of [param core] farther than spacing_m from all the seeds; in the crater, on
## every wet cell more than crater_sector_step sectors from the seeds of its ring.
func grow(core) -> void:
	if _positions.is_empty():
		_positions = cell_positions(core)
		_width = core.width
		_crater_rows = core.crater_rows
	for i: int in core.wet_indices:
		if core.volume_q[i] <= 0:
			continue
		if i / _width < _crater_rows:
			var ring: int = i / _width
			if not _near_in_ring(i, _ring_seeds.get(ring, PackedInt32Array())):
				var cells: PackedInt32Array = _ring_seeds.get(ring, PackedInt32Array())
				cells.append(i)
				_ring_seeds[ring] = cells
				seeds.append(i)
			continue
		if not _near_seed(i):
			var key := _bin(i)
			_bins.get_or_add(key, PackedInt32Array())
			var bin: PackedInt32Array = _bins[key]
			bin.append(seeds.size())
			_bins[key] = bin
			seeds.append(i)


func _near_in_ring(i: int, cells: PackedInt32Array) -> bool:
	for j: int in cells:
		if sectors_apart(i, j, _width) < crater_sector_step:
			return true
	return false


## Sectors between the cells [param i] and [param j], around the ring.
static func sectors_apart(i: int, j: int, width: int) -> int:
	var steps := absi(i % width - j % width)
	return mini(steps, width - steps)


## 1 for a cell of the crater (its first crater rows), 0 on the flanks.
static func zone_of(i: int, width: int, crater_rows: int) -> int:
	return 1 if i / width < crater_rows else 0


func _spacing(_zone: int) -> float:
	return spacing_m


func _bin(i: int) -> Vector3i:
	var zone := zone_of(i, _width, _crater_rows)
	var p := _positions[i]
	return Vector3i(floori(p.x / _spacing(zone)), floori(p.y / _spacing(zone)), zone)


func _near_seed(i: int) -> bool:
	var home := _bin(i)
	var reach := _spacing(home.z)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for s: int in _bins.get(home + Vector3i(dx, dz, 0), PackedInt32Array()):
				if _positions[seeds[s]].distance_squared_to(_positions[i]) < reach * reach:
					return true
	return false


## The values the renderer reads, for cell [param i] of [param core]: what the replica must rebuild.
static func cell_values(core, i: int) -> Dictionary:
	var volume: int = core.volume_q[i]
	if volume <= 0:
		return {}
	var velocity := Vector2(core.vx_q[i], core.vz_q[i]) / 1000000.0
	if core.geometry_mode == 1:
		var radial := cell_positions_one(core, i).normalized()
		velocity = Vector2(-radial.y, radial.x) * velocity.x + radial * velocity.y
	return {"depth": volume * 1000.0 / core.areas_q[i],
		"temperature": 20.0 + core.current_energy_q(i) / (float(volume) * 10.0),
		"age": core.current_exposure_q(i) / (float(volume) * 10.0),
		"opacity": core.fade_ticks_q[i] / float(core.FADE_DURATION_TICKS) if core.fade_ticks_q[i] > 0 else 1.0,
		"velocity": velocity}


static func cell_positions_one(core, i: int) -> Vector2:
	if core.geometry_mode != 1:
		return Vector2(i % core.width, i / core.width) * (core.cell_mm / 1000.0)
	var z: int = i / core.width
	var angle: float = (i % core.width + 0.5) * TAU / core.width
	return Vector2(cos(angle), sin(angle)) * ((core.radial_edges_mm[z] + core.radial_edges_mm[z + 1]) / 2000.0)


## The summary of [param core] now (~2-5 KB for a 96 x 96 field in eruption): "<raw size>" u32, then deflated
## [header, wet mask (1 bit per cell), per-seed values]. Header: version (u8), width, height, crater rows (u16),
## tick (u32), seed count, flank spacing in m and crater spacing in sectors (u16). Per seed: cell (u16), depth cm (u16), temperature
## (u8, 5 degC steps from 20), surface age (u8, s), opacity (u8, /255), flow x and z (s8 each, 0.1 m/s).
func encode(core) -> PackedByteArray:
	var count: int = core.width * core.height
	var raw := PackedByteArray()
	raw.resize(HEADER + (count + 7) / 8 + seeds.size() * SEED_BYTES)
	raw.encode_u8(0, VERSION)
	raw.encode_u16(2, core.width)
	raw.encode_u16(4, core.height)
	raw.encode_u16(6, core.crater_rows)
	raw.encode_u32(8, core.tick)
	raw.encode_u16(12, seeds.size())
	raw.encode_u16(14, roundi(spacing_m))
	raw.encode_u16(16, crater_sector_step)
	for i: int in core.wet_indices:
		if core.volume_q[i] > 0:
			raw[HEADER + i / 8] |= 1 << (i % 8)
	var at := HEADER + (count + 7) / 8
	for i: int in seeds:
		var v := cell_values(core, i)
		raw.encode_u16(at, i)
		if not v.is_empty():
			raw.encode_u16(at + 2, clampi(roundi(float(v.depth) * 100.0), 0, 65535))
			raw.encode_u8(at + 4, clampi(roundi((float(v.temperature) - 20.0) / 5.0), 0, 255))
			raw.encode_u8(at + 5, clampi(roundi(float(v.age)), 0, 255))
			raw.encode_u8(at + 6, clampi(roundi(float(v.opacity) * 255.0), 0, 255))
			raw.encode_s8(at + 7, clampi(roundi((v.velocity as Vector2).x * 10.0), -127, 127))
			raw.encode_s8(at + 8, clampi(roundi((v.velocity as Vector2).y * 10.0), -127, 127))
		at += SEED_BYTES
	return _deflate(raw)


static func _deflate(raw: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	out.append_array(raw.compress(FileAccess.COMPRESSION_DEFLATE))
	return out


## The bytes of [method _deflate], or empty when malformed or larger than [param limit].
static func _inflate(bytes: PackedByteArray, limit: int) -> PackedByteArray:
	if bytes.size() < 5:
		return PackedByteArray()
	var size := bytes.decode_u32(0)
	if size < 1 or size > limit:
		return PackedByteArray()
	var raw := bytes.slice(4).decompress(size, FileAccess.COMPRESSION_DEFLATE)
	return raw if raw.size() == size else PackedByteArray()


## The patch's grid for a replica, sent once per eruption (~15 KB for 96 x 96, instead of the 665 KB
## checkpoint): version (u8), width, height, crater rows (u16), nominal cell (u32 mm), the rings' edges
## (s32 mm each), then every cell's ground in cm, each ring as differences along its sectors (zigzag varints).
static func encode_grid(core) -> PackedByteArray:
	var raw := PackedByteArray()
	raw.resize(12 + (core.height + 1) * 4)
	raw.encode_u8(0, GRID_VERSION)
	raw.encode_u16(2, core.width)
	raw.encode_u16(4, core.height)
	raw.encode_u16(6, core.crater_rows)
	raw.encode_u32(8, core.cell_mm)
	var at := 12
	for z in core.height + 1:
		raw.encode_s32(at, core.radial_edges_mm[z])
		at += 4
	for z in core.height:
		var previous := 0
		for x in core.width:
			var cm: int = roundi(core.terrain_q[z * core.width + x] / 10.0)
			var delta := cm - previous
			var zigzag := (delta << 1) ^ (delta >> 63)
			while zigzag >= 0x80:
				raw.append((zigzag & 0x7f) | 0x80)
				zigzag >>= 7
			raw.append(zigzag)
			previous = cm
	return _deflate(raw)


## {width, height, crater_rows, cell_mm, radial_edges_mm (PackedInt64Array), bed (PackedFloat64Array, m)} of
## [method encode_grid] bytes, or {} when malformed.
static func decode_grid(bytes: PackedByteArray) -> Dictionary:
	var raw := _inflate(bytes, 12 + (MAX_SIDE + 1) * 4 + MAX_SIDE * MAX_SIDE * 10)
	if raw.size() < 12 or raw[0] != GRID_VERSION:
		return {}
	var width := raw.decode_u16(2)
	var height := raw.decode_u16(4)
	if width < 1 or height < 1 or width > MAX_SIDE or height > MAX_SIDE:
		return {}
	if raw.size() < 12 + (height + 1) * 4 + width * height or raw.decode_u16(6) > height:
		return {}
	var edges := PackedInt64Array()
	var at := 12
	for z in height + 1:
		edges.append(raw.decode_s32(at))
		at += 4
	var bed := PackedFloat64Array()
	for z in height:
		var cm := 0
		for x in width:
			var zigzag := 0
			var shift := 0
			while true:
				if at >= raw.size() or shift > 56:
					return {}
				var byte := raw[at]
				at += 1
				zigzag |= (byte & 0x7f) << shift
				shift += 7
				if byte < 0x80:
					break
			cm += (zigzag >> 1) ^ -(zigzag & 1)
			bed.append(cm / 100.0)
	if at != raw.size():
		return {}
	return {"width": width, "height": height, "crater_rows": raw.decode_u16(6), "cell_mm": raw.decode_u32(8),
		"radial_edges_mm": edges, "bed": bed}


## Every cell's rebuilt values from [param bytes] (an [method encode] result), with [param positions] the
## cells' centres and [param bed] their ground (m): {tick, wet (PackedByteArray 0/1), depth, temperature, age,
## opacity (PackedFloat64Array), velocity (PackedVector2Array)}, or {} when the bytes are not a summary.
## A cell takes its values from the seeds of its own zone only (crater or flanks): a 140 m deep pool must not
## thicken the flows next to the rim. In the crater, the depth is the least of the interpolated depth and the
## interpolated level over the cell's ground (a pond is flat, a film on a wall follows the wall).
static func reconstruct(bytes: PackedByteArray, positions: PackedVector2Array, bed: PackedFloat64Array) -> Dictionary:
	var count := positions.size()
	var raw := _inflate(bytes, HEADER + (count + 7) / 8 + count * SEED_BYTES)
	if raw.size() < HEADER or raw[0] != VERSION:
		return {}
	var width := raw.decode_u16(2)
	var crater_rows := raw.decode_u16(6)
	var n_seeds := raw.decode_u16(12)
	var spacing := maxf(1.0, raw.decode_u16(14))
	var crater_step := maxi(1, raw.decode_u16(16))
	if width * raw.decode_u16(4) != count or bed.size() != count:
		return {}
	if raw.size() != HEADER + (count + 7) / 8 + n_seeds * SEED_BYTES:
		return {}
	var wet := PackedByteArray()
	wet.resize(count)
	for i in count:
		wet[i] = (raw[HEADER + i / 8] >> (i % 8)) & 1
	# The seeds still wet carry values; a dry seed's cell has none.
	var at := HEADER + (count + 7) / 8
	var seed_pos := PackedVector2Array()
	var seed_cells := PackedInt32Array()
	var seed_vals: Array[PackedFloat64Array] = []
	var bins := {}
	var ring_bins := {} # crater ring -> PackedInt32Array of seed numbers
	for s in n_seeds:
		var cell := raw.decode_u16(at)
		if cell < count and wet[cell] == 1:
			var zone := zone_of(cell, width, crater_rows)
			var values := PackedFloat64Array([raw.decode_u16(at + 2) / 100.0, 20.0 + raw[at + 4] * 5.0, raw[at + 5],
				raw[at + 6] / 255.0, raw.decode_s8(at + 7) / 10.0, raw.decode_s8(at + 8) / 10.0])
			if zone == 1:
				var ring: PackedInt32Array = ring_bins.get(cell / width, PackedInt32Array())
				ring.append(seed_pos.size())
				ring_bins[cell / width] = ring
			else:
				var key := Vector3i(floori(positions[cell].x / spacing), floori(positions[cell].y / spacing), 0)
				var bin: PackedInt32Array = bins.get(key, PackedInt32Array())
				bin.append(seed_pos.size())
				bins[key] = bin
			seed_pos.append(positions[cell])
			seed_cells.append(cell)
			seed_vals.append(values)
		at += SEED_BYTES
	# Locals, stored in the result at the end: a packed array read from a Dictionary is a copy.
	var depth := PackedFloat64Array()
	var temperature := PackedFloat64Array()
	var age := PackedFloat64Array()
	var opacity := PackedFloat64Array()
	var velocity := PackedVector2Array()
	depth.resize(count)
	temperature.resize(count)
	age.resize(count)
	opacity.resize(count)
	velocity.resize(count)
	var out := {"tick": raw.decode_u32(8), "wet": wet, "depth": depth, "temperature": temperature, "age": age,
		"opacity": opacity, "velocity": velocity}
	if seed_pos.is_empty():
		return out
	for i in count:
		if wet[i] == 0:
			continue
		var zone := zone_of(i, width, crater_rows)
		var near := _nearest_in_crater(i, width, crater_rows, seed_cells, ring_bins, crater_step) \
			if zone == 1 else _nearest(positions[i], zone, seed_pos, bins, spacing)
		var total := 0.0
		var level := 0.0
		var sums := PackedFloat64Array([0, 0, 0, 0, 0, 0])
		for s: int in near:
			# Crater: in grid steps (a seed spacing = 1); flanks: in m, with the same 5 % floor.
			var w := 1.0 / (_crater_d2(i, seed_cells[s], width, crater_step) + 0.05) if zone == 1 \
				else 1.0 / (positions[i].distance_squared_to(seed_pos[s]) + spacing * spacing * 0.05)
			total += w
			level += (seed_vals[s][0] + bed[seed_cells[s]]) * w
			for k in 6:
				sums[k] += seed_vals[s][k] * w
		depth[i] = sums[0] / total
		if zone == 1:
			# A pond is flat: its level over this cell's ground, unless that is more than the interpolated depth
			# (a thin film on a steep crater wall, where the ground changes faster than the lava).
			depth[i] = clampf(level / total - bed[i], 0.01, depth[i])
		temperature[i] = sums[1] / total
		age[i] = sums[2] / total
		opacity[i] = sums[3] / total
		velocity[i] = Vector2(sums[4], sums[5]) / total
	out.depth = depth
	out.temperature = temperature
	out.age = age
	out.opacity = opacity
	out.velocity = velocity
	return out


## Squared crater distance between cells [param i] and [param j] on the polar grid: sectors apart in seed
## spacings, and rings apart.
static func _crater_d2(i: int, j: int, width: int, step: int) -> float:
	var sectors := sectors_apart(i, j, width) / float(step)
	var rings := float(i / width - j / width)
	return sectors * sectors + rings * rings


## Up to NEAREST crater seeds closest to cell [param i] (see [method _crater_d2]): its ring and the next ones,
## further while too few are found.
static func _nearest_in_crater(i: int, width: int, crater_rows: int, seed_cells: PackedInt32Array,
		ring_bins: Dictionary, step: int) -> PackedInt32Array:
	var ring := i / width
	var found := PackedInt32Array()
	var dist := PackedFloat64Array()
	var reach := 1
	while reach <= crater_rows:
		found.clear()
		dist.clear()
		for z in range(maxi(0, ring - reach), mini(crater_rows, ring + reach + 1)):
			for s: int in ring_bins.get(z, PackedInt32Array()):
				found.append(s)
				dist.append(_crater_d2(i, seed_cells[s], width, step))
		if found.size() >= NEAREST:
			break
		reach += 1
	var order := range(found.size())
	order.sort_custom(func(a: int, b: int) -> bool: return dist[a] < dist[b])
	var out := PackedInt32Array()
	for k in mini(NEAREST, order.size()):
		out.append(found[order[k]])
	return out


## Up to NEAREST seeds closest to [param p], searching rings of bins outwards.
static func _nearest(p: Vector2, zone: int, seed_pos: PackedVector2Array, bins: Dictionary, spacing: float) -> PackedInt32Array:
	var home := Vector3i(floori(p.x / spacing), floori(p.y / spacing), zone)
	var found := PackedInt32Array()
	var dist := PackedFloat64Array()
	var reach := 1
	var settled := false
	while reach < 64:
		found.clear()
		dist.clear()
		for dx in range(-reach, reach + 1):
			for dz in range(-reach, reach + 1):
				for s: int in bins.get(home + Vector3i(dx, dz, 0), PackedInt32Array()):
					found.append(s)
					dist.append(p.distance_squared_to(seed_pos[s]))
		# Enough seeds: one more ring, where a closer one than the square's corners may still be.
		if found.size() >= NEAREST or (found.size() > 0 and reach >= 8):
			if settled:
				break
			settled = true
		reach += 1
	var order := range(found.size())
	order.sort_custom(func(a: int, b: int) -> bool: return dist[a] < dist[b])
	var out := PackedInt32Array()
	for k in mini(NEAREST, order.size()):
		out.append(found[order[k]])
	return out
