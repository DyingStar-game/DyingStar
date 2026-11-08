extends RefCounted
## Authoritative lava model v6: signed 64-bit integer operations only.
## Fixed 100 ms tick. Volume quantum = 1 litre, temperature quantum = 0.1 °C.
## Canonical terrain is in mm. Floating-point presentation is a separate adapter.
## Bounded inputs keep every intermediate product below signed-int64 overflow.

const SCHEMA := 6
const MAGIC := 0x44534c56
const MAX_SIDE := 256
const MAX_TERRAIN_SPAN_MM := 8192000
const MAX_TOTAL_Q := 1000000000000000 # Litres: 1 trillion m3 over this field's lifetime.
const Q_PER_M3 := 1000
const MAX_CELL_Q := 4000000000
const MAX_DEPTH_MM := 512000
const MAX_VELOCITY_Q := 320000000
const SOURCE_IDLE_TICKS := 20
const FADE_DELAY_TICKS := 1200
const FADE_DURATION_TICKS := 1800
const BLACK_T := 8500
const POST_COOL_T_PER_TICK := 6
const MAX_I64 := 9223372036854775807
const MAX_AGE_TICKS := 10000000
const AMBIENT_T := 200
const SOLIDUS_T := 9500
const MAX_T := 14000
const Q16 := 65536
# exp(0.18) approximated by the versioned rational 1197217/1000000.
# Integer-generated, immutable 10°C viscosity multipliers from 950 to 1400°C.
const MU_LUT = [36597940, 30569179, 25533533, 21327406, 17814153, 14879636, 12428521, 10381177, 8671091, 7242707, 6049620, 5053069, 4220680, 3525410, 2944671, 2459597, 2054429, 1716004, 1433328, 1197217, 1000000, 835270, 697676, 582748, 486752, 406569, 339595, 283653, 236926, 197897, 165297, 138067, 115323, 96325, 80457, 67203, 56132, 46885, 39161, 32710, 27321, 22820, 19060, 15920, 13297, 11106]
static var _age_roots := PackedInt64Array()
static var use_native := true
static var _native_checked := false
static var _native_script: Script
var _native: RefCounted

var width := 0
var height := 0
var cell_mm := 0
var tick := 0
var injected_q := 0
var viscosity_q := 1800
var yield_q := 120
var gravity_milli := 9810 # mm/s², shared planet gravity in checkpoints
var _cooling_enabled := true
var cooling_enabled: bool:
	get: return _cooling_enabled
	set(value):
		if value != _cooling_enabled:
			_wake_all()
			_cooling_enabled = value
var limited_cells := 0
var terrain_q := PackedInt64Array()
var volume_q := PackedInt64Array()
var energy_q := PackedInt64Array()
var exposure_q := PackedInt64Array()
var vx_q := PackedInt64Array()
var vz_q := PackedInt64Array()
var _neighbors := PackedInt32Array()
var _flux := PackedInt64Array()
var _dv := PackedInt64Array()
var _de := PackedInt64Array()
var _da := PackedInt64Array()
var _incoming := PackedInt64Array()
var geometry_mode := 0 # 0 Cartesian laboratory, 1 conservative polar volcano field.
var radial_edges_mm := PackedInt64Array()
var crater_rows := 0
var eruption_head_mm := 0
var rim_heights_q := PackedInt64Array()
var cleanup_enabled := false
var last_source_tick := -1
var removed_q := 0
var escaped_q := 0
var fade_ticks_q := PackedInt64Array()
var fade_start_q := PackedInt64Array()
var cleared_indices := PackedInt32Array()
var areas_q := PackedInt64Array()
var capacities_q := PackedInt64Array()
var _edge_width := PackedInt64Array()
var _distance := PackedInt64Array()
var _level_area := PackedInt64Array()
var wet_indices := PackedInt32Array() # Derived acceleration index, not authoritative state.
var _wet_mask := PackedByteArray()
var _has_fading := false
var _born := PackedInt32Array()
# Work lists are derived. A cold cell keeps its energy/age at sleep_epoch_q;
# constant-rate cold cooling and exposure are evaluated exactly when needed.
var use_sleeping := true # Diagnostic full-scan mode must give the same checkpoints.
var sleep_epoch_q := PackedInt64Array()
var active_indices := PackedInt32Array()
var changed_indices := PackedInt32Array()
var _awake_mask := PackedByteArray()
var _work := PackedInt32Array()
var _received := PackedInt32Array()
var last_updated_cells := 0


func configure_q(nx: int, nz: int, spacing_mm: int, terrain: PackedInt64Array) -> bool:
	if nx < 3 or nz < 3 or nx > MAX_SIDE or nz > MAX_SIDE or spacing_mm < 1000 or spacing_mm > 64000:
		return false
	if terrain.size() != nx * nz:
		return false
	var low := 10000000
	var high := -10000000
	for v in terrain:
		if v < -10000000 or v > 10000000:
			return false
		low = mini(low, v)
		high = maxi(high, v)
	if high - low > MAX_TERRAIN_SPAN_MM:
		return false
	width = nx
	height = nz
	cell_mm = spacing_mm
	var area := cell_mm * cell_mm
	var capacity := mini(MAX_CELL_Q, MAX_DEPTH_MM * area / 1000000)
	terrain_q = terrain.duplicate()
	var count := nx * nz
	wet_indices.clear()
	active_indices.clear(); changed_indices.clear(); _work.clear()
	cleared_indices.clear()
	radial_edges_mm.clear()
	geometry_mode = 0
	crater_rows = 0
	eruption_head_mm = 0
	rim_heights_q.clear()
	last_source_tick = -1
	removed_q = 0
	escaped_q = 0
	_has_fading = false
	_born.clear()
	_wet_mask.resize(count); _wet_mask.fill(0)
	_awake_mask.resize(count); _awake_mask.fill(0)
	sleep_epoch_q.resize(count); sleep_epoch_q.fill(-1)
	volume_q.resize(count); volume_q.fill(0)
	energy_q.resize(count); energy_q.fill(0)
	exposure_q.resize(count); exposure_q.fill(0)
	vx_q.resize(count); vx_q.fill(0)
	vz_q.resize(count); vz_q.fill(0)
	_dv.resize(count); _de.resize(count); _da.resize(count); _incoming.resize(count)
	fade_ticks_q.resize(count); fade_ticks_q.fill(0)
	fade_start_q.resize(count); fade_start_q.fill(0)
	areas_q.resize(count); areas_q.fill(area)
	capacities_q.resize(count); capacities_q.fill(capacity)
	_edge_width.resize(count * 4); _edge_width.fill(cell_mm)
	_distance.resize(count * 4); _distance.fill(cell_mm)
	_level_area.resize(count * 4); _level_area.fill(area / 2)
	_flux.resize(count * 4)
	_neighbors.resize(count * 4)
	for z in height:
		for x in width:
			var i := z * width + x
			_neighbors[i * 4] = i - 1 if x > 0 else -1
			_neighbors[i * 4 + 1] = i + 1 if x < width - 1 else -1
			_neighbors[i * 4 + 2] = i - width if z > 0 else -1
			_neighbors[i * 4 + 3] = i + width if z < height - 1 else -1
	if _age_roots.is_empty():
		_age_roots.resize(1025)
		var root := 100
		for second in 1025:
			while (root + 1) * (root + 1) <= (second + 1) * 10000:
				root += 1
			_age_roots[second] = root
	tick = 0
	injected_q = 0
	limited_cells = 0
	_prepare_native()
	return true


func disc_commands(cx_mm: int, cz_mm: int, radius_mm: int, amount_q: int, temperature_t: int) -> PackedInt64Array:
	var result := PackedInt64Array()
	if width == 0 or radius_mm < 1 or radius_mm > 8192000 or amount_q < 1 or amount_q > MAX_TOTAL_Q:
		return result
	if cx_mm < -16384000 or cx_mm > 16384000 or cz_mm < -16384000 or cz_mm > 16384000 or temperature_t < AMBIENT_T or temperature_t > MAX_T:
		return result
	if geometry_mode == 1:
		if cx_mm != 0 or cz_mm != 0: return result
		var rings := 0
		var area := 0
		while rings < height and (radial_edges_mm[rings] + radial_edges_mm[rings + 1]) / 2 <= radius_mm:
			area += areas_q[rings * width] * width
			rings += 1
		if area == 0: return result
		var shares := PackedInt64Array()
		var allocated := 0
		for z in rings:
			var share := mul_div(amount_q, areas_q[z * width], area)
			shares.append(share)
			allocated += share * width
		var remainder := amount_q - allocated
		result.resize(rings * width * 3)
		var at := 0
		for z in rings:
			for x in width:
				var i := z * width + x
				var share := shares[z] + (1 if i < remainder else 0)
				if share > 0:
					result[at] = i; result[at + 1] = share; result[at + 2] = temperature_t
					at += 3
		result.resize(at)
		return result
	var cells := PackedInt32Array()
	for z in range(maxi(0, (cz_mm - radius_mm) / cell_mm), mini(height - 1, (cz_mm + radius_mm) / cell_mm) + 1):
		for x in range(maxi(0, (cx_mm - radius_mm) / cell_mm), mini(width - 1, (cx_mm + radius_mm) / cell_mm) + 1):
			var dx := x * cell_mm - cx_mm
			var dz := z * cell_mm - cz_mm
			if dx * dx + dz * dz <= radius_mm * radius_mm:
				cells.append(z * width + x)
	if cells.is_empty():
		return result
	var share := amount_q / cells.size()
	var remainder := amount_q % cells.size()
	for n in cells.size():
		var amount := share + (1 if n < remainder else 0)
		if amount > 0:
			result.append_array(PackedInt64Array([cells[n], amount, temperature_t]))
	return result


func inject_q(commands: PackedInt64Array) -> bool:
	if width == 0 or commands.size() % 3 != 0 or commands.size() > volume_q.size() * 3:
		return false
	var previous := -1
	var total := 0
	for p in range(0, commands.size(), 3):
		var i := commands[p]
		var amount := commands[p + 1]
		var t := commands[p + 2]
		if i <= previous or i >= volume_q.size() or amount < 1 or amount > capacities_q[i]:
			return false
		if amount > capacities_q[i] - volume_q[i] or t < AMBIENT_T or t > MAX_T:
			return false
		previous = i
		total += amount
	if total > MAX_TOTAL_Q - injected_q:
		return false
	for p in range(0, commands.size(), 3):
		var i := commands[p]
		var amount := commands[p + 1]
		if _wet_mask[i] == 0:
			_wet_mask[i] = 1
			wet_indices.append(i)
		_wake_cell(i)
		volume_q[i] += amount
		energy_q[i] += amount * (commands[p + 2] - AMBIENT_T)
		if AMBIENT_T + energy_q[i] / volume_q[i] > SOLIDUS_T:
			fade_ticks_q[i] = 0; fade_start_q[i] = 0
	injected_q += total
	if total > 0:
		last_source_tick = tick + 1
	return true


func advance_tick(expected_tick: int, commands: PackedInt64Array = PackedInt64Array()) -> bool:
	if width == 0 or expected_tick != tick + 1 or tick >= 1000000000:
		return false
	if viscosity_q < 1 or viscosity_q > 100000 or yield_q < 0 or yield_q > 1000000000 or gravity_milli < 1 or gravity_milli > 50000:
		return false
	if not inject_q(commands):
		return false
	cleared_indices.clear()
	changed_indices.clear()
	_prepare_work(expected_tick)
	last_updated_cells = _work.size()
	if _work.is_empty():
		tick += 1
		return true
	if _native != null and use_native:
		var data: Dictionary = _native.Step(_work, terrain_q, volume_q, energy_q, exposure_q, sleep_epoch_q,
			PackedInt64Array([viscosity_q, yield_q, gravity_milli, int(cooling_enabled),
			last_source_tick, expected_tick, crater_rows, eruption_head_mm]), rim_heights_q)
		volume_q = data.volume; energy_q = data.energy; exposure_q = data.exposure
		vx_q = data.vx; vz_q = data.vz; limited_cells = data.limited
		_born = data.born
		for i in _born: _wet_mask[i] = 1
		wet_indices.append_array(_born)
		_work = data.updated
		sleep_epoch_q = data.epochs
		_finish_tick(expected_tick, data)
		return true
	_flux.fill(0); _dv.fill(0); _de.fill(0); _da.fill(0); _incoming.fill(0)
	vx_q.fill(0); vz_q.fill(0)
	limited_cells = 0
	var pressure := eruption_head_mm * clampi(last_source_tick + SOURCE_IDLE_TICKS + 60 - expected_tick, 0, 60) / 60 if last_source_tick >= 0 else 0
	for i in _work:
		var volume := volume_q[i]
		if volume == 0:
			continue
		var t := AMBIENT_T + energy_q[i] / volume
		if t <= SOLIDUS_T:
			continue
		var physical_surface := terrain_q[i] * 1000 + volume * 1000000000 / areas_q[i]
		var surface := physical_surface + (pressure * 1000 if i / width < crater_rows else 0)
		var mu := mu_at(t)
		var cold := clampi(11500 - t, 0, 2000)
		var tau_y := yield_q + 12 * yield_q * cold * cold / 4000000
		var total := 0
		for direction in 4:
			var k := i * 4 + direction
			var j := _neighbors[k]
			if j < 0:
				continue
			var neighbor := terrain_q[j] * 1000 + volume_q[j] * 1000000000 / areas_q[j] + (pressure * 1000 if j / width < crater_rows else 0)
			var head := surface - neighbor
			var barrier := maxi(terrain_q[i], terrain_q[j])
			if crater_rows > 0 and mini(i / width, j / width) == crater_rows - 1 and maxi(i / width, j / width) == crater_rows:
				barrier = maxi(barrier, rim_heights_q[i % width])
			# Eruptive pressure can lift the AVAILABLE lava over a rim, never
			# invent a face thickness larger than the donor's real liquid column.
			var face_mm := mini(volume * 1000000 / areas_q[i], (surface - barrier * 1000) / 1000)
			if head < 1000 or face_mm < 1:
				continue
			var stress := (2600 * gravity_milli / 1000) * face_mm * (head / 1000) / (1000 * _distance[k])
			if stress <= tau_y:
				continue
			var b := tau_y * Q16 / stress
			var b3 := (b * b / Q16) * b / Q16
			var factor := Q16 - 3 * b / 2 + b3 / 2
			var denominator := 3 * mu
			var face_factor := face_mm * 1000
			var speed := 100000000 if stress > (100000000 * denominator) / face_factor else stress * face_factor / denominator
			speed = speed * factor / Q16
			var level_limit := mul_div(head / 1000, _level_area[k], 1000000) * 48 / 100
			var amount := mini(capacities_q[i], mini((speed * face_mm / 1000) * _edge_width[k] / 10000000, level_limit))
			_flux[i * 4 + direction] = amount
			total += amount
		var limit := volume * 45 / 100
		if total > limit:
			limited_cells += 1
		for direction in 4:
			var k := i * 4 + direction
			var amount := _flux[k]
			if total > limit:
				amount = amount * limit / total
				_flux[k] = amount
			if amount > 0:
				_incoming[_neighbors[k]] += amount
	_born.clear()
	_received.clear()
	for i in _work:
		if volume_q[i] == 0:
			continue
		for direction in 4:
			var k := i * 4 + direction
			var amount := _flux[k]
			if amount == 0:
				continue
			var j := _neighbors[k]
			var room := capacities_q[j] - volume_q[j]
			if _incoming[j] > room:
				amount = amount * room / _incoming[j]
			if amount > 0 and _wet_mask[j] == 0:
				_wet_mask[j] = 1
				_born.append(j)
			if amount > 0 and sleep_epoch_q[j] >= 0:
				_wake_cell(j)
				_received.append(j)
			var heat := mul_div(energy_q[i], amount, volume_q[i])
			var exposure := mul_div(exposure_q[i], amount, volume_q[i])
			_dv[i] -= amount; _dv[j] += amount
			_de[i] -= heat; _de[j] += heat
			_da[i] -= exposure; _da[j] += exposure
			var speed := mini(MAX_VELOCITY_Q, mul_div(amount, _distance[k] * 10000, volume_q[i]))
			if direction < 2:
				vx_q[i] += -speed if direction == 0 else speed
			else:
				vz_q[i] += -speed if direction == 2 else speed
	wet_indices.append_array(_born)
	_work.append_array(_born)
	_work.append_array(_received)
	for i in _work:
		volume_q[i] += _dv[i]
		energy_q[i] += _de[i]
		exposure_q[i] = mini(exposure_q[i] + _da[i] + volume_q[i], volume_q[i] * MAX_AGE_TICKS)
		if volume_q[i] == 0 or not cooling_enabled:
			continue
		var t := AMBIENT_T + energy_q[i] / volume_q[i]
		if t <= BLACK_T:
			energy_q[i] = maxi(0, energy_q[i] - cold_loss_q(volume_q[i]))
			continue
		var second := exposure_q[i] / volume_q[i] / 10
		var root := _age_roots[second] if second <= 1024 else integer_sqrt((second + 1) * 10000)
		var kelvin := (t + 2731) / 10
		var k2 := kelvin * kelvin
		var radiation := maxi(0, k2 * k2 - 7370050801) * 53865 / 1000000000000
		var insulation := 1000 + root * 8
		var delta_t := t - AMBIENT_T
		var air := (radiation + 8 * delta_t / 10) * 1000 / insulation
		var ground := 1200 * delta_t / root
		var loss := (air + ground) * areas_q[i] / 3640000000
		energy_q[i] = maxi(0, energy_q[i] - loss)
	_finish_tick(expected_tick)
	return true


func mu_at(t: int) -> int:
	var offset := clampi(t, 9500, 14000) - 9500
	var index := mini(offset / 100, MU_LUT.size() - 2)
	var fraction := offset - index * 100
	var multiplier: int = MU_LUT[index] + (MU_LUT[index + 1] - MU_LUT[index]) * fraction / 100
	return maxi(1, viscosity_q * multiplier / 1000000)


static func mul_div(a: int, b: int, divisor: int) -> int:
	# Exact positive a*b/divisor without overflowing the intermediate product.
	if a == 0 or b == 0: return 0
	if a <= MAX_I64 / b: return a * b / divisor
	var whole := a / divisor
	var remainder := a % divisor
	if remainder <= MAX_I64 / b:
		return whole * b + remainder * b / divisor
	var result := 0
	var carry := 0
	while b > 0:
		if b & 1:
			result += whole
			carry += remainder
			if carry >= divisor:
				carry -= divisor
				result += 1
		b >>= 1
		if b > 0:
			whole *= 2
			remainder *= 2
			if remainder >= divisor:
				remainder -= divisor
				whole += 1
	return result


static func integer_sqrt(value: int) -> int:
	var x := value
	var y := (x + 1) / 2
	while y < x:
		x = y
		y = (x + value / x) / 2
	return x


func checkpoint() -> PackedByteArray:
	var values := PackedInt64Array([MAGIC, SCHEMA, width, height, cell_mm, tick,
		injected_q, viscosity_q, yield_q, int(cooling_enabled), gravity_milli,
		geometry_mode, int(cleanup_enabled), last_source_tick, removed_q, escaped_q, crater_rows, eruption_head_mm])
	if geometry_mode == 1:
		values.append_array(radial_edges_mm)
		values.append_array(rim_heights_q)
	var energy := energy_q.duplicate()
	var exposure := exposure_q.duplicate()
	var epochs := sleep_epoch_q.duplicate()
	for i in wet_indices:
		if sleep_epoch_q[i] >= 0:
			energy[i] = current_energy_q(i)
			exposure[i] = current_exposure_q(i)
			epochs[i] = tick
	for field in [terrain_q, volume_q, energy, exposure, vx_q, vz_q, fade_ticks_q, fade_start_q, epochs]:
		values.append_array(field)
	var bytes := values.to_byte_array()
	if bytes[0] == 0x56: bytes.bswap64()
	return bytes


func state_digest() -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(checkpoint())
	return context.finish().hex_encode()


func restore(bytes: PackedByteArray) -> bool:
	if bytes.size() < 144 or bytes.size() > 144 + (MAX_SIDE * 2 + 1) * 8 + MAX_SIDE * MAX_SIDE * 72:
		return false
	var stream := StreamPeerBuffer.new()
	stream.big_endian = true
	stream.data_array = bytes
	if stream.get_64() != MAGIC or stream.get_64() != SCHEMA: return false
	var nx := stream.get_64()
	var nz := stream.get_64()
	var spacing := stream.get_64()
	var saved_tick := stream.get_64()
	var injected := stream.get_64()
	var mu := stream.get_64()
	var stress := stream.get_64()
	var cooling := stream.get_64()
	var gravity := stream.get_64()
	var geometry := stream.get_64()
	var cleanup := stream.get_64()
	var source_tick := stream.get_64()
	var removed := stream.get_64()
	var escaped := stream.get_64()
	var crater := stream.get_64()
	var pressure := stream.get_64()
	if nx < 3 or nx > MAX_SIDE or nz < 3 or nz > MAX_SIDE or spacing < 1000 or spacing > 64000: return false
	if geometry < 0 or geometry > 1 or cleanup < 0 or cleanup > 1: return false
	if crater < 0 or crater >= nz or pressure < 0 or pressure > 128000 or (geometry == 0 and crater != 0): return false
	var edge_bytes := ((nz + 1) + (nx if crater > 0 else 0)) * 8 if geometry == 1 else 0
	if bytes.size() != 144 + edge_bytes + nx * nz * 72 or saved_tick < 0 or saved_tick > 1000000000: return false
	if injected < 0 or injected > MAX_TOTAL_Q or removed < 0 or removed > injected or escaped != 0: return false
	if source_tick < -1 or source_tick > saved_tick + 1: return false
	if mu < 1 or mu > 100000 or stress < 0 or stress > 1000000000 or cooling < 0 or cooling > 1 or gravity < 1 or gravity > 50000: return false
	var edges := PackedInt64Array()
	if geometry == 1:
		for i in nz + 1: edges.append(stream.get_64())
	var rim := PackedInt64Array()
	if crater > 0:
		for x in nx: rim.append(stream.get_64())
		for h in rim:
			if h < -10000000 or h > 10000000: return false
	var fields: Array[PackedInt64Array] = []
	for field in 9:
		var data := PackedInt64Array()
		data.resize(nx * nz)
		for i in nx * nz: data[i] = stream.get_64()
		fields.append(data)
	# Validate derived geometry on a temporary object before touching live state.
	var candidate = get_script().get_base_script().new() if get_script().get_base_script() != null else get_script().new()
	var ok: bool = candidate.configure_polar_q(nx, edges, fields[0]) if geometry == 1 else candidate.configure_q(nx, nz, spacing, fields[0])
	if not ok or candidate.cell_mm != spacing: return false
	var total := 0
	for i in nx * nz:
		var v := fields[1][i]
		if v < 0 or v > candidate.capacities_q[i] or fields[2][i] < 0 or fields[2][i] > v * (MAX_T - AMBIENT_T): return false
		if fields[3][i] < 0 or fields[3][i] > v * MAX_AGE_TICKS: return false
		if fields[4][i] < -MAX_VELOCITY_Q or fields[4][i] > MAX_VELOCITY_Q or fields[5][i] < -MAX_VELOCITY_Q or fields[5][i] > MAX_VELOCITY_Q: return false
		if fields[6][i] < 0 or fields[6][i] > FADE_DURATION_TICKS or (v == 0 and fields[6][i] != 0): return false
		if fields[7][i] < 0 or fields[7][i] > candidate.capacities_q[i] or (fields[6][i] == 0 and fields[7][i] != 0) or (fields[6][i] > 0 and fields[7][i] == 0): return false
		var epoch := fields[8][i]
		if epoch != -1 and (epoch != saved_tick or v == 0 or AMBIENT_T + fields[2][i] / v > BLACK_T): return false
		total += v
	if total + removed + escaped != injected: return false
	if geometry == 1: configure_polar_q(nx, edges, fields[0])
	else: configure_q(nx, nz, spacing, fields[0])
	volume_q = fields[1]; energy_q = fields[2]; exposure_q = fields[3]
	vx_q = fields[4]; vz_q = fields[5]; fade_ticks_q = fields[6]; fade_start_q = fields[7]
	tick = saved_tick; injected_q = injected; viscosity_q = mu; yield_q = stress
	cooling_enabled = cooling == 1; gravity_milli = gravity; cleanup_enabled = cleanup == 1
	last_source_tick = source_tick; removed_q = removed; escaped_q = escaped
	crater_rows = crater; eruption_head_mm = pressure; rim_heights_q = rim
	sleep_epoch_q = fields[8]
	for i in volume_q.size():
		if volume_q[i] > 0:
			_wet_mask[i] = 1
			wet_indices.append(i)
			if sleep_epoch_q[i] < 0:
				_awake_mask[i] = 1
				active_indices.append(i)
			_has_fading = _has_fading or fade_ticks_q[i] > 0
	return true


func configure_polar_q(sectors: int, edges: PackedInt64Array, terrain: PackedInt64Array) -> bool:
	var rings := edges.size() - 1
	if sectors < 16 or sectors > MAX_SIDE or rings < 3 or rings > MAX_SIDE or edges[0] != 0: return false
	if edges[-1] > 16384000: return false
	for z in rings:
		if edges[z + 1] - edges[z] < 1000 or edges[z + 1] - edges[z] > 128000: return false
	if not configure_q(sectors, rings, edges[1], terrain): return false
	geometry_mode = 1
	radial_edges_mm = edges.duplicate()
	var row_areas := PackedInt64Array()
	for z in rings:
		# pi = 355/113, versioned integer geometry, <0.000009% area error.
		row_areas.append((edges[z + 1] * edges[z + 1] - edges[z] * edges[z]) * 355 / (113 * sectors))
	for z in rings:
		var area := row_areas[z]
		var radius := (edges[z] + edges[z + 1]) / 2
		var radial_width := edges[z + 1] - edges[z]
		var tangent_width := 710 * radius / (113 * sectors)
		var inward_dist := (edges[z + 1] - edges[z - 1]) / 2 if z > 0 else radius
		var outward_dist := (edges[z + 2] - edges[z]) / 2 if z < rings - 1 else radial_width
		var inner_level := mul_div(area, row_areas[z - 1], area + row_areas[z - 1]) if z > 0 else 0
		var outer_level := mul_div(area, row_areas[z + 1], area + row_areas[z + 1]) if z < rings - 1 else 0
		for x in sectors:
			var i := z * sectors + x
			areas_q[i] = area
			capacities_q[i] = mini(MAX_CELL_Q, MAX_DEPTH_MM * area / 1000000)
			_neighbors[i * 4] = z * sectors + posmod(x - 1, sectors)
			_neighbors[i * 4 + 1] = z * sectors + (x + 1) % sectors
			for d in 4:
				var k := i * 4 + d
				_distance[k] = maxi(1, tangent_width if d < 2 else (inward_dist if d == 2 else outward_dist))
				_edge_width[k] = radial_width if d < 2 else 710 * (edges[z] if d == 2 else edges[z + 1]) / (113 * sectors)
				_level_area[k] = area / 2 if d < 2 else (inner_level if d == 2 else outer_level)
	_prepare_native()
	return true


func cooling_age_ticks(at_tick: int = -1) -> int:
	return maxi(0, (tick if at_tick < 0 else at_tick) - last_source_tick - SOURCE_IDLE_TICKS) if cleanup_enabled and last_source_tick >= 0 else 0


func _apply_cleanup() -> void:
	var cooling_age := cooling_age_ticks(tick + 1)
	if not cleanup_enabled or (cooling_age == 0 and not _has_fading): return
	_has_fading = false
	for i in _work:
		var volume := volume_q[i]
		if cooling_age > 0:
			var cap := maxi(AMBIENT_T, MAX_T - cooling_age * POST_COOL_T_PER_TICK)
			energy_q[i] = mini(energy_q[i], volume * (cap - AMBIENT_T))
		var t := AMBIENT_T + energy_q[i] / volume
		if t > SOLIDUS_T: fade_ticks_q[i] = 0; fade_start_q[i] = 0
		if cleanup_enabled and cooling_age >= FADE_DELAY_TICKS and t <= BLACK_T and fade_ticks_q[i] == 0:
			fade_ticks_q[i] = FADE_DURATION_TICKS
			fade_start_q[i] = volume
		if fade_ticks_q[i] > 0:
			var remaining := fade_ticks_q[i]
			var retained := mini(volume, fade_start_q[i] * (remaining - 1) / FADE_DURATION_TICKS)
			energy_q[i] = mul_div(energy_q[i], retained, volume)
			exposure_q[i] = mul_div(exposure_q[i], retained, volume)
			volume_q[i] = retained
			removed_q += volume - retained
			fade_ticks_q[i] -= 1
			_has_fading = _has_fading or fade_ticks_q[i] > 0
		if volume_q[i] == 0:
			energy_q[i] = 0; exposure_q[i] = 0; vx_q[i] = 0; vz_q[i] = 0; fade_ticks_q[i] = 0; fade_start_q[i] = 0
			_wet_mask[i] = 0
			cleared_indices.append(i)
	if not cleared_indices.is_empty():
		var survivors := PackedInt32Array()
		for i in wet_indices:
			if volume_q[i] > 0: survivors.append(i)
		wet_indices = survivors


func cleanup_complete() -> bool:
	return cleanup_enabled and injected_q > 0 and wet_indices.is_empty()


func _prepare_native() -> void:
	_native = null
	if not use_native: return
	if not _native_checked:
		_native_checked = true
		var loader_path := "res://scenes/planet/native/native_script.gd"
		if ResourceLoader.exists(loader_path) and ResourceLoader.exists("res://scenes/planet/lava/LavaStepNative.cs"):
			var methods: Array[String] = ["Configure", "Step", "GetModelSchema"]
			_native_script = load(loader_path).load_usable("res://scenes/planet/lava/LavaStepNative.cs", methods)
	if _native_script != null:
		var kernel: RefCounted = _native_script.new()
		if kernel.GetModelSchema() == SCHEMA:
			kernel.Configure(width, areas_q, capacities_q, _neighbors, _edge_width, _distance, _level_area,
				PackedInt64Array(MU_LUT), _age_roots,
				PackedInt64Array([AMBIENT_T, SOLIDUS_T, BLACK_T, MAX_AGE_TICKS, MAX_VELOCITY_Q, SOURCE_IDLE_TICKS]))
			_native = kernel


func has_native_backend() -> bool:
	return _native != null


static func cold_loss_q(volume: int) -> int:
	# Once black and immobile: 0.1°C/s, linear in energy, exactly batchable.
	return maxi(1, volume / 10)


func current_energy_q(i: int) -> int:
	var elapsed := tick - sleep_epoch_q[i] if sleep_epoch_q[i] >= 0 else 0
	return maxi(0, energy_q[i] - elapsed * cold_loss_q(volume_q[i])) if cooling_enabled else energy_q[i]


func current_exposure_q(i: int) -> int:
	var elapsed := tick - sleep_epoch_q[i] if sleep_epoch_q[i] >= 0 else 0
	return mini(exposure_q[i] + elapsed * volume_q[i], volume_q[i] * MAX_AGE_TICKS)


func _wake_cell(i: int) -> void:
	if sleep_epoch_q[i] >= 0:
		energy_q[i] = current_energy_q(i)
		exposure_q[i] = current_exposure_q(i)
		sleep_epoch_q[i] = -1
	if _awake_mask[i] == 0:
		_awake_mask[i] = 1
		active_indices.append(i)


func _wake_all() -> void:
	for i in wet_indices: _wake_cell(i)


func _prepare_work(next_tick: int) -> void:
	# Cleanup still progresses after shutdown, including on dormant deposits.
	if active_indices.size() < wet_indices.size() and (not use_sleeping or cooling_age_ticks(next_tick) > 0 or _has_fading):
		_wake_all()
	_work = active_indices.duplicate()


func _finish_tick(next_tick: int, native_result: Dictionary = {}) -> void:
	var cleaning := cleanup_enabled and (cooling_age_ticks(next_tick) > 0 or _has_fading)
	_apply_cleanup() # Shared once by the native and reference kernels.
	tick = next_tick
	changed_indices = _work.duplicate()
	last_updated_cells = _work.size()
	# The compiled kernel already classifies its touched cells. Reuse that list
	# instead of scanning every hot cell again through the script interpreter.
	if not native_result.is_empty() and not cleaning:
		active_indices = native_result.active
		for i in native_result.cold: _awake_mask[i] = 0
		for i in native_result.woken: _awake_mask[i] = int(sleep_epoch_q[i] < 0)
		for i in _born: _awake_mask[i] = int(sleep_epoch_q[i] < 0)
		return
	active_indices.clear()
	for i in _work:
		if volume_q[i] == 0:
			sleep_epoch_q[i] = -1
			_awake_mask[i] = 0
		elif not cleaning and AMBIENT_T + energy_q[i] / volume_q[i] <= BLACK_T:
			sleep_epoch_q[i] = tick
			_awake_mask[i] = 0
			vx_q[i] = 0; vz_q[i] = 0
		else:
			sleep_epoch_q[i] = -1
			_awake_mask[i] = 1
			active_indices.append(i)
			if AMBIENT_T + energy_q[i] / volume_q[i] <= BLACK_T:
				vx_q[i] = 0; vz_q[i] = 0
