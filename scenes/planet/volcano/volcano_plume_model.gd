class_name VolcanoPlumeModel
extends RefCounted
## Fixed pool of smoke puffs. Births, shape and activity derive from the shared clock and stable seed;
## drift integrates the locally sampled planetary weather. No per-puff network replication.
## Frame: the vent at the origin, +Y up, metres.
##
## The volcano's life is activity(birth): a puff remembers the activity at its birth, so a lull climbs
## the column as a neck and a burst climbs it as a bulge, long after it happened at the vent.

const COUNT := 220
## Seconds a puff lives. COUNT puffs over LIFE: one born every LIFE / COUNT seconds.
const LIFE := 600.0

var rise_speed := 110.0  # m/s at the vent
var slowdown_m := 3500.0  # height over which the rise speed halves
var ceiling_m := 8500.0  # neutral height of a full-strength puff
var vent_radius := 300.0
var spread := 0.16  # column widening, m per m of height
var umbrella_m := 2600.0  # radial push at the ceiling
var wind := Vector2(-27.0, 5.0)  # m/s at the ceiling
var calm := 0.16  # activity floor: what is left in a lull
var density := 1.0
var lifetime_s := LIFE
var ash_brightness := 1.0
var ash_shade := 0.5
var appearance_seed := 0
## Seconds added to the clock in activity(): each volcano breathes on its own.
var phase := 0.0
var profile: VolcanoActivityProfile
var volcano_seed := 0
var volcano_key := ""
var dormant := false
## Integral of the sampled wind: old smoke keeps drifting instead of snapping to a new heading.
var _wind_history: Array[Vector3] = []
var _last_wind := Vector2.ZERO
var sun_dir := Vector3(0.5, 0.65, 0.35).normalized()
var sigma := 0.018  # extinction (1/m) at density 1

var a := PackedVector4Array()  # xyz, radius
var b := PackedVector4Array()  # density, ash shade, noise seed, cloudiness
var c := PackedVector4Array()  # sun transmittance, sky visibility, cos spin, sin spin
var _next_light := 0
var active_indices := PackedInt32Array()


func _init() -> void:
	a.resize(COUNT)
	b.resize(COUNT)
	c.resize(COUNT)


## Independent dimensions make short/dark and tall/light plumes possible too.
## Assigned once per volcano, before the terrain's size scaling, never per frame.
func configure_appearance(seed_value: int, key: String, variation: float = 1.0) -> void:
	appearance_seed = seed_value ^ int(key.hash())
	var amount := clampf(variation, 0.0, 1.0)
	ceiling_m *= lerpf(1.0, lerpf(0.55, 1.35, _hash(appearance_seed, 501)), amount)
	rise_speed *= lerpf(1.0, lerpf(0.75, 1.3, _hash(appearance_seed, 502)), amount)
	lifetime_s = LIFE * lerpf(1.0, lerpf(0.55, 1.4, _hash(appearance_seed, 503)), amount)
	spread *= lerpf(1.0, lerpf(0.65, 1.55, _hash(appearance_seed, 504)), amount)
	umbrella_m *= lerpf(1.0, lerpf(0.45, 1.65, _hash(appearance_seed, 505)), amount)
	density *= lerpf(1.0, lerpf(0.65, 1.4, _hash(appearance_seed, 506)), amount)
	ash_brightness = lerpf(1.0, lerpf(0.45, 1.65, _hash(appearance_seed, 507)), amount)
	ash_shade = lerpf(0.5, _hash(appearance_seed, 508), amount)


static func _hash(n: int, salt: int) -> float:
	return VolcanoRandom.hash01(n, salt)


static func _noise1(x: float, salt: int) -> float:
	return VolcanoRandom.noise1(x, salt)


## The volcano's breath at time [param tau], 0..~1.6: long calm spells, spells of work, sudden kicks.
func activity(when: float) -> float:
	if profile != null:
		return profile.activity_at(when, volcano_seed, volcano_key, dormant)
	var tau := when + phase
	var spell := smoothstep(0.25, 0.5, _noise1(tau / 150.0, 11))
	var breath := lerpf(0.55, 1.1, _noise1(tau / 22.0, 23))
	var kick := pow(_noise1(tau / 45.0, 37), 5.0) * 2.2
	return clampf(lerpf(calm, 1.0, spell) * breath + kick * lerpf(0.25, 1.0, spell), 0.0, 1.6)


func eruption_activity(when: float) -> float:
	if profile != null:
		return profile.activity_at(when, volcano_seed, volcano_key, dormant, true)
	return activity(when)


func state_label(when: float) -> String:
	if eruption_activity(when) > 0.001:
		return "ERUPTION"
	if activity(when) > 0.001:
		return "FORMATION DU PANACHE" if activity(when) > activity(when - 1.0) + 0.001 else "PANACHE SEUL"
	for puff in b:
		if puff.x > 0.001:
			return "DISSIPATION"
	return "ETEINT"


func update(t: float, light_budget: int) -> void:
	var dt := lifetime_s / float(COUNT)
	active_indices.clear()
	var wind_now := _wind_integral(t) if not _wind_history.is_empty() else Vector2.ZERO
	for i in COUNT:
		var phase := t - float(i) * dt
		var cycle := floori(phase / lifetime_s)
		var birth := float(i) * dt + float(cycle) * lifetime_s
		var age := t - birth
		var id := i + cycle * COUNT
		var emission: Vector2
		if profile != null:
			emission = profile.sample_smoke(birth, t, volcano_seed, volcano_key, dormant)
		else:
			var strength := activity(birth)
			emission = Vector2(strength, strength)
		if emission.y <= 0.0:
			b[i] = Vector4.ZERO
			c[i] = Vector4(1, 1, 0, 1)
			continue
		var strength := emission.x
		var puff_id := id ^ appearance_seed
		var r1 := _hash(puff_id, 1)
		var r2 := _hash(puff_id, 2)
		var r3 := _hash(puff_id, 3)
		var r4 := _hash(puff_id, 4)
		var r5 := _hash(puff_id, 5)
		var r6 := _hash(puff_id, 6)
		var life_t := age / lifetime_s
		# Rise: the speed decays with height (closed form), then a soft ceiling a strong puff climbs higher.
		var climb := slowdown_m * (sqrt(1.0 + 2.0 * rise_speed * age / slowdown_m) - 1.0)
		var ceiling := ceiling_m * lerpf(0.72, 1.08, r1) * lerpf(0.45, 1.0, clampf(strength, 0.0, 1.2)) * sqrt(maxf(1.0, strength / 1.2))
		var y := ceiling * (1.0 - exp(-climb / ceiling))
		var up := y / ceiling_m
		# The vent's aim wanders with time: puffs born together share it, so the column snakes as it climbs.
		var aim := Vector2(_noise1(birth / 34.0, 41) - 0.5, _noise1(birth / 34.0, 43) - 0.5) * 2.0
		var offset := aim * y * 0.2
		# Wind grows with height.
		var drift := wind * age if _wind_history.is_empty() else wind_now - _wind_integral(birth)
		offset += drift * (0.06 + 0.94 * up * up)
		# Spread in the column, then the umbrella's outward push at the ceiling.
		var ang := TAU * r2
		var dir := Vector2(cos(ang), sin(ang))
		var column_r := vent_radius + spread * y
		var near_top := smoothstep(0.55, 1.0, up)
		offset += dir * sqrt(r3) * column_r * 0.85
		offset += dir * umbrella_m * near_top * (0.35 + 0.65 * sqrt(r3)) * (1.0 - exp(-age / 120.0))
		var radius := (vent_radius * 1.1 + spread * 0.85 * y) * lerpf(0.65, 1.3, r4)
		radius *= lerpf(0.55, 1.1, clampf(strength, 0.0, 1.3))
		radius *= 1.0 + 1.5 * smoothstep(0.35, 1.0, life_t)
		var fade := smoothstep(0.0, 5.0, age) * (1.0 - smoothstep(0.3, 1.0, life_t))
		var dens := density * fade * clampf(emission.y * 4.0, 0.0, 1.0)
		var cloudy := smoothstep(0.45, 0.95, life_t)
		var spin := (r5 - 0.5) * 0.02 * age + TAU * r6
		a[i] = Vector4(offset.x, y, offset.y, radius)
		b[i] = Vector4(dens, clampf(ash_shade + (lerpf(r5, r6, 0.4) - 0.5) * 0.35, 0.0, 1.0), float(puff_id & 1023) * 0.137, cloudy)
		c[i].z = cos(spin)
		c[i].w = sin(spin)
		if dens > 0.0:
			active_indices.append(i)
	_light(light_budget)


func sample_wind(t: float, value: Vector2) -> void:
	wind = value
	var history_s := maxf(LIFE, lifetime_s)
	if _wind_history.is_empty() or t < _wind_history[-1].x or t - _wind_history[-1].x > history_s:
		_wind_history.assign([Vector3(t - history_s, -value.x * history_s, -value.y * history_s), Vector3(t, 0.0, 0.0)])
		_last_wind = value
		return
	var last := _wind_history[-1]
	if t - last.x < 0.5:
		return
	var drift := (_last_wind + value) * 0.5 * (t - last.x)
	_wind_history.append(Vector3(t, last.y + drift.x, last.z + drift.y))
	_last_wind = value
	while _wind_history.size() > 2 and _wind_history[1].x < t - history_s:
		_wind_history.pop_front()


func _wind_integral(t: float) -> Vector2:
	var newest := _wind_history[-1]
	if t >= newest.x:
		return Vector2(newest.y, newest.z) + _last_wind * (t - newest.x)
	var low := 0
	var high := _wind_history.size() - 1
	while high - low > 1:
		var mid := (low + high) / 2
		if _wind_history[mid].x <= t:
			low = mid
		else:
			high = mid
	var first := _wind_history[low]
	var last := _wind_history[high]
	var f := clampf((t - first.x) / maxf(last.x - first.x, 0.001), 0.0, 1.0)
	return Vector2(lerpf(first.y, last.y, f), lerpf(first.z, last.z, f))


func wind_displacement(t: float, age: float) -> Vector2:
	if _wind_history.is_empty():
		return wind * age
	return _wind_integral(t) - _wind_integral(t - age)


## Sun transmittance and sky visibility of each puff through all the others. Per puff, not per pixel:
## this is what sets a dark core with bright rims. N^2, so spread over frames.
func _light(budget: int) -> void:
	if active_indices.is_empty():
		_next_light = 0
		return
	for _n in mini(budget, active_indices.size()):
		_next_light %= active_indices.size()
		var i := active_indices[_next_light]
		_next_light += 1
		var p := Vector3(a[i].x, a[i].y, a[i].z)
		var sun_od := 0.0
		var sky_od := 0.0
		for j in active_indices:
			if j == i:
				continue
			var rj := a[j].w
			var d := Vector3(a[j].x, a[j].y, a[j].z) - p
			sun_od += _chord(d, sun_dir, rj) * b[j].x
			sky_od += _chord(d, Vector3.UP, rj) * b[j].x
		c[i].x = exp(-sun_od * 0.0045 * 0.22)
		c[i].y = exp(-sky_od * 0.0045 * 0.12)


static func _chord(d: Vector3, ray: Vector3, r: float) -> float:
	var along := d.dot(ray)
	if along <= 0.0:
		return 0.0
	var h := r * r - (d.length_squared() - along * along)
	return 2.0 * sqrt(h) if h > 0.0 else 0.0
