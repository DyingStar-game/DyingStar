class_name ChimneySmokeModel
extends RefCounted
## The puffs of one chimney's smoke, in the chimney's frame: the mouth at the origin, +Y up, metres. A
## fixed pool of COUNT puffs, one born every life_s / COUNT seconds and reborn when it dies: each rises
## and slows, swells, drifts with the wind and fades. Everything derives from the clock and the puff's
## index, so nothing is kept between updates and nothing goes on the network. The arrays are the
## volcano's (VolcanoPlumeModel): the same plume shader draws them.

const COUNT := 24

## Seconds a puff lives.
var life_s := 12.0
## Rise speed at the mouth (m/s).
var rise_speed := 3.0
## Seconds over which the rise slows down (the smoke climbs rise_speed * rise_slow_s at most).
var rise_slow_s := 6.0
## Radius of a puff leaving the mouth (m).
var mouth_radius := 0.6
## Widening of the column, m of radius per m travelled.
var spread := 0.22
## Density of a fresh puff.
var density := 1.0
## Horizontal wind at the mouth, in this frame (m/s).
var wind := Vector2.ZERO
## Seconds added to the clock: each chimney puffs on its own.
var phase := 0.0

var a := PackedVector4Array()  # xyz, radius
var b := PackedVector4Array()  # density, shade, noise seed, cloudiness
var c := PackedVector4Array()  # sun transmittance, sky visibility, cos spin, sin spin
## How many of the arrays' first entries are live puffs.
var count := 0
## Bounds of the live puffs (this frame), for the box the shader draws in.
var low := Vector3.ZERO
var high := Vector3.ZERO


func _init(size: int = COUNT) -> void:
	a.resize(size)
	b.resize(size)
	c.resize(size)


## Lay out the puffs at clock [param t] (s).
func update(t: float) -> void:
	var step := life_s / float(COUNT)
	count = 0
	low = Vector3(-mouth_radius, 0.0, -mouth_radius)
	high = Vector3(mouth_radius, mouth_radius, mouth_radius)
	for i: int in range(COUNT):
		var since := t + phase - float(i) * step
		var cycle := floori(since / life_s)
		var age := since - float(cycle) * life_s
		var puff := puff_at(age, i * 7919 + cycle)
		if puff.is_empty():
			continue
		var s: Vector4 = puff["a"]
		a[count] = s
		b[count] = puff["b"]
		c[count] = puff["c"]
		count += 1
		var centre := Vector3(s.x, s.y, s.z)
		low = low.min(centre - Vector3.ONE * s.w)
		high = high.max(centre + Vector3.ONE * s.w)


## The puff [param age] seconds old, of seed [param seed_value]: {"a", "b", "c"} as the shader reads them,
## {} once it has faded (or not born yet).
func puff_at(age: float, seed_value: int) -> Dictionary:
	if age < 0.0 or age >= life_s:
		return {}
	var k := age / life_s
	var fade := smoothstep(0.0, 0.05, k) * pow(1.0 - k, 1.3)
	if fade * density <= 0.03:
		return {}
	var rise := rise_speed * rise_slow_s * (1.0 - exp(-age / rise_slow_s))
	# The wind takes the puff once it is out of the mouth's shelter.
	var drift := wind * age * smoothstep(0.0, 1.5, age)
	var jitter := Vector2(_hash(seed_value, 1) - 0.5, _hash(seed_value, 2) - 0.5) * mouth_radius * (0.6 + k * 2.0)
	var travelled := sqrt(rise * rise + drift.length_squared())
	var radius := mouth_radius * 1.2 + spread * travelled
	var spin := _hash(seed_value, 3) * TAU + age * (_hash(seed_value, 4) - 0.5) * 0.6
	return {
		"a": Vector4(drift.x + jitter.x, rise, drift.y + jitter.y, radius),
		"b": Vector4(density * fade, lerpf(0.45, 0.85, _hash(seed_value, 5)), _hash(seed_value, 6) * 97.0, 0.15),
		"c": Vector4(0.85, 0.9, cos(spin), sin(spin)),
	}


static func _hash(n: int, salt: int) -> float:
	return VolcanoRandom.hash01(n, salt)
