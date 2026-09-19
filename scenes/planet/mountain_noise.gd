@tool
class_name MountainNoise
## Deterministic noise for the procedural mountains (MountainRelief).
##
## Same contract as SurfaceNoise — a PURE function of position, no engine
## state, no RNG — with one difference that matters at hundreds of metres of
## amplitude: the lattice hash is INTEGER arithmetic (a 32-bit mixer on the
## floored cell coordinates), not fract(sin(x) * 43758). A one-ulp libm
## difference between the Windows client and the Linux server changes such a
## sine hash completely; under BiomeRelief's ±2 m nobody sees it, under a
## 500 m massif the server would catch every player 100 m under the ground.
## Everything after the hash is continuous (lerps, smoothsteps, sqrt): a
## floor() that flips at a cell boundary because of a rounding difference
## returns the same value to an ulp, since value noise is continuous there.
## The only libm transcendental left is pow() for exponents outside the
## exact set {0.5, 1, 1.5, 2, 3}; the exporter presets stay in that set.
##
## Exact twin in tools/planettech/qgis/export/planet/mountain_noise.py,
## pinned by the golden values of test/unit/test_mountain_noise.gd.

const _M32 := 0xFFFFFFFF
## Hard cap on the octaves of one zone (12 halvings of an 8 km base = 2 m).
const MAX_OCTAVES := 12
## Frequency ratio between octaves.
const LACUNARITY := 2.0


## Style of one mountain zone, resolved once at pack-decode time so the
## per-sample loop reads fields, not a Dictionary. Every field is authored in
## QGIS (layers/mountains.py); the exporter fills the preset defaults.
class Params:
	extends RefCounted
	## Plateau lift under the whole zone (m, feathered like the rest).
	var lift_m := 0.0
	## Peak-to-floor amplitude of the noise (m).
	var amplitude_m := 300.0
	## Wavelength of the first octave (m).
	var wavelength_m := 6000.0
	## Number of detail layers stacked on the first wavelength (1 = large forms only).
	var octaves := 6
	## Amplitude ratio between octaves.
	var persistence := 0.45
	## 0 = rolling fbm, 1 = ridged (sharp crests).
	var ridge := 0.0
	## Power curve on the normalised height: > 1 = flat lowlands, sharp peaks.
	var exponent := 1.0
	## Terrace step (m); 0 = none. Walls take `terrace_width` of each step.
	var terrace_step_m := 0.0
	var terrace_width := 0.15
	## Domain warp, in wavelengths (0 = none, 0.3 = organic).
	var warp := 0.0
	## Inward feather from the polygon edge (m).
	var feather_m := 250.0
	var seed := 0
	## Sum of the octave amplitudes — the normaliser, computed once.
	var _norm := 1.0

	func finalize() -> void:
		octaves = clampi(octaves, 1, MAX_OCTAVES)
		var a := 1.0
		var s := 0.0
		for _k in octaves:
			s += a
			a *= persistence
		_norm = s if s > 0.0 else 1.0

	static func from_zone(z: Dictionary) -> Params:
		var p := Params.new()
		p.lift_m = float(z.get("lift_m", p.lift_m))
		p.amplitude_m = float(z.get("amplitude_m", p.amplitude_m))
		p.wavelength_m = maxf(float(z.get("wavelength_m", p.wavelength_m)), 1.0)
		p.octaves = int(z.get("octaves", p.octaves))
		p.persistence = clampf(float(z.get("persistence", p.persistence)), 0.05, 0.95)
		p.ridge = clampf(float(z.get("ridge", p.ridge)), 0.0, 1.0)
		p.exponent = maxf(float(z.get("exponent", p.exponent)), 0.1)
		p.terrace_step_m = maxf(float(z.get("terrace_step_m", p.terrace_step_m)), 0.0)
		p.terrace_width = clampf(float(z.get("terrace_width", p.terrace_width)), 0.01, 1.0)
		p.warp = maxf(float(z.get("warp", p.warp)), 0.0)
		p.feather_m = maxf(float(z.get("feather_m", p.feather_m)), 1.0)
		p.seed = int(z.get("seed", p.seed))
		p.finalize()
		return p


## 32-bit lattice hash of an integer cell and a seed. The products wrap in
## int64 and are masked to their low 32 bits, which is the same number in
## Python's unbounded ints — that is what makes the twin exact.
static func hash_i(ix: int, iy: int, iz: int, seed: int) -> int:
	var h: int = ((ix * 0x8DA6B343) ^ (iy * 0xD8163841) ^ (iz * 0xCB1AB31F) ^ (seed * 0x9E3779B1) ^ 0x27D4EB2F) & _M32
	h ^= h >> 16
	h = (h * 0x7FEB352D) & _M32
	h ^= h >> 15
	h = (h * 0x846CA68B) & _M32
	h ^= h >> 16
	return h


## Cell value in [0, 1): the top 24 bits of the hash, exactly representable.
static func cell(ix: int, iy: int, iz: int, seed: int) -> float:
	return float(hash_i(ix, iy, iz, seed) >> 8) / 16777216.0


## Value noise in [0, 1], C² (quintic fade), on the integer hash.
static func vnoise(p: Vector3, seed: int) -> float:
	var fx := floorf(p.x)
	var fy := floorf(p.y)
	var fz := floorf(p.z)
	var ix := int(fx)
	var iy := int(fy)
	var iz := int(fz)
	var tx := p.x - fx
	var ty := p.y - fy
	var tz := p.z - fz
	var wx := tx * tx * tx * (tx * (tx * 6.0 - 15.0) + 10.0)
	var wy := ty * ty * ty * (ty * (ty * 6.0 - 15.0) + 10.0)
	var wz := tz * tz * tz * (tz * (tz * 6.0 - 15.0) + 10.0)
	var x00 := lerpf(cell(ix, iy, iz, seed), cell(ix + 1, iy, iz, seed), wx)
	var x10 := lerpf(cell(ix, iy + 1, iz, seed), cell(ix + 1, iy + 1, iz, seed), wx)
	var x01 := lerpf(cell(ix, iy, iz + 1, seed), cell(ix + 1, iy, iz + 1, seed), wx)
	var x11 := lerpf(cell(ix, iy + 1, iz + 1, seed), cell(ix + 1, iy + 1, iz + 1, seed), wx)
	return lerpf(lerpf(x00, x10, wy), lerpf(x01, x11, wy), wz)


## Signed value noise in [-1, 1] — zero-mean, so an octave the LOD gate drops
## removes detail without shifting the surface.
static func snoise(p: Vector3, seed: int) -> float:
	return vnoise(p, seed) * 2.0 - 1.0


## x^e for x in [0, 1] — exact arithmetic for the preset exponents, libm pow
## only for a custom one.
static func pow_fast(x: float, e: float) -> float:
	if e == 1.0:
		return x
	if e == 2.0:
		return x * x
	if e == 3.0:
		return x * x * x
	if e == 1.5:
		return x * sqrt(x)
	if e == 0.5:
		return sqrt(x)
	return pow(x, e)


## Terrace [param h_m] (metres) into steps of [param step_m]: each step is flat
## over (1 - width) of its run and climbs to the next over the last `width`.
## C0 continuous, monotone, identity when step_m <= 0.
static func terrace(h_m: float, step_m: float, width: float) -> float:
	if step_m <= 0.0:
		return h_m
	var q := h_m / step_m
	var k := floorf(q)
	var f := q - k
	var f2 := smoothstep(1.0 - width, 1.0, f)
	return (k + f2) * step_m


## Normalised mountain shape in [0, 1] at unit direction [param dir] on a
## sphere of [param radius], for style [param prm], on a grid of vertex
## pitch [param eff_spacing_m]. Octaves are coarse→fine and the loop stops at
## the first one the grid cannot carry (pitch ≥ half its wavelength): a
## feature the grid cannot represent must not exist in either geometry.
## Returns -1.0 when not even the first octave fits (caller keeps the lift).
static func shape(dir: Vector3, radius: float, prm: Params, eff_spacing_m: float) -> float:
	var wl := prm.wavelength_m
	if eff_spacing_m >= wl * 0.5:
		return -1.0
	var p := dir * (radius / wl)
	if prm.warp > 0.0:
		var w := prm.warp
		p = Vector3(
			p.x + w * snoise(p, prm.seed + 101),
			p.y + w * snoise(p, prm.seed + 202),
			p.z + w * snoise(p, prm.seed + 303))
	var sum := 0.0
	var amp := 1.0
	var freq := 1.0
	var seed := prm.seed
	var ridge := prm.ridge
	for k in prm.octaves:
		if k > 0 and eff_spacing_m >= (wl / freq) * 0.5:
			break
		var n := vnoise(p * freq, seed + k)
		var v := n * 2.0 - 1.0
		if ridge > 0.0:
			# Ridged: fold the signed noise, crest where it crosses zero,
			# then recentre so a dropped octave stays zero-mean.
			var r := 1.0 - absf(v)
			r = r * r * 2.0 - 1.0
			v = lerpf(v, r, ridge)
		sum += v * amp
		amp *= prm.persistence
		freq *= LACUNARITY
	var h := clampf(0.5 + 0.5 * sum / prm._norm, 0.0, 1.0)
	return pow_fast(h, prm.exponent)
