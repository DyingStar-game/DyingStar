@tool
class_name CrackNoise
extends RefCounted
## What makes the corundum crack network organic: the seed of its Voronoi, a
## domain warp that makes each crack wander (the meander), and a noise that
## eats into each rim on its own (the alcoves and narrows). Read by
## ArideDesertCorundumPlateauTerrain.crack_edge_distance_m and crack_rim_snap.
##
## Everything here rides on MountainNoise's integer hash and value noise: no
## sine, only IEEE arithmetic, so a Windows client and the Linux server stand
## on the same crack bit for bit, with or without the C# twin
## (CrackVoronoiNative, configured from this object).
##
## The walls stay vertical whatever the noise: the section is a box and the
## rim snap slides the vertices onto the curved rim and foot. The noise only
## moves WHERE the wall is. Octaves finer than twice the pitch are dropped,
## pitch floored at the finest chunk's (finest_m), as the mountains do: a
## gameplay query (pitch 0) sees exactly what the finest collision carves.

## Octaves of the meander (wavelength halves each time, weight halves).
const MEANDER_OCTAVES := 2
## Octaves of the rim noise.
const RIM_OCTAVES := 3
## The warp's largest slope, amplitude × 2π / wavelength: past ~0.5 a warp
## folds the contours over themselves. Clamped here.
const MAX_WARP_SLOPE := 0.4

var seed_value := 0
var meander_amp_m := 0.0
var meander_wavelength_m := 1500.0
var rim_amp_m := 0.0
var rim_wavelength_m := 400.0
## The finest chunk's vertex pitch (m): the floor of the octave gate.
var finest_m := 0.0
## CrackVoronoiNative configured like this object, or null (GDScript path).
var native: RefCounted = null

static var _plain: CrackNoise = null
static var _native_tried := false
static var _native_script: Script = null


## The network with no meander and no rim noise, seed 0: what a caller without
## a planet (tests, a bare crack_offset) gets.
static func plain() -> CrackNoise:
	if _plain == null:
		_plain = CrackNoise.new()
		_plain.bind_native()
	return _plain


## A planet's network. [param width_m] bounds the rim noise so the crack never
## closes (two rims eaten by their amplitude still leave two pitches open).
static func make(seed_in: int, meander_amp: float, meander_wavelength: float, rim_amp: float,
		rim_wavelength: float, width_m: float, finest: float) -> CrackNoise:
	var n := CrackNoise.new()
	n.seed_value = seed_in
	n.meander_wavelength_m = maxf(meander_wavelength, 1.0)
	n.meander_amp_m = clampf(meander_amp, 0.0, MAX_WARP_SLOPE * n.meander_wavelength_m / TAU)
	n.rim_wavelength_m = maxf(rim_wavelength, 1.0)
	n.rim_amp_m = clampf(rim_amp, 0.0, maxf((width_m - 2.0 * finest) * 0.5 * 0.5, 0.0))
	n.finest_m = maxf(finest, 0.0)
	n.bind_native()
	return n


## The network of [param data] (PlanetData), from its crack_* exports.
static func for_planet(data: Resource) -> CrackNoise:
	return make(data.crack_noise_seed, data.crack_meander_amp_m, data.crack_meander_wavelength_m,
			data.crack_rim_amp_m, data.crack_rim_wavelength_m, data.crack_width_m,
			data.terrain_vertex_spacing_m())


## Configure the C# twin, when the assembly is there.
func bind_native() -> void:
	if not _native_tried:
		_native_tried = true
		_native_script = NativeScript.load_usable("res://scenes/planet/native/CrackVoronoiNative.cs",
				["EdgeDn", "Configure", "EdgeDistance", "Snap"])
	if _native_script == null:
		return
	native = _native_script.new()
	native.Configure(seed_value, meander_amp_m, meander_wavelength_m, rim_amp_m, rim_wavelength_m,
			finest_m)


## The three integer seeds of the Voronoi jitter (x, y, z).
func voronoi_seed(axis: int) -> int:
	return seed_value * 16 + 1 + axis


## Re-keys the chunk cache: every field here is baked geometry.
func fingerprint() -> String:
	return "%d_%.2f_%.1f_%.2f_%.1f" % [seed_value, meander_amp_m, meander_wavelength_m, rim_amp_m,
			rim_wavelength_m]


## The meander: where the Voronoi is read for the surface point [param q]
## (planet-local metres, radius × dir), for a grid of effective pitch [param eff_m].
func warp(q: Vector3, dir: Vector3, radius: float, eff_m: float) -> Vector3:
	if meander_amp_m <= 0.0:
		return q
	var wx := 0.0
	var wy := 0.0
	var wz := 0.0
	var lam := meander_wavelength_m
	var w := 1.0
	var norm := 0.0
	for o in MEANDER_OCTAVES:
		norm += w
		if lam >= 2.0 * eff_m:
			var s := dir * (radius / lam)
			var k := seed_value * 16 + 5 + o * 3
			wx += w * MountainNoise.snoise(s, k)
			wy += w * MountainNoise.snoise(s, k + 1)
			wz += w * MountainNoise.snoise(s, k + 2)
		lam *= 0.5
		w *= 0.5
	var a := meander_amp_m / norm
	return q + Vector3(wx * a, wy * a, wz * a)


## The rim noise at [param dir] (m, zero-mean): how far the rim is eaten back
## (positive widens the crack) for a grid of effective pitch [param eff_m].
func rim(dir: Vector3, radius: float, eff_m: float) -> float:
	if rim_amp_m <= 0.0:
		return 0.0
	var total := 0.0
	var lam := rim_wavelength_m
	var w := 1.0
	var norm := 0.0
	for o in RIM_OCTAVES:
		norm += w
		if lam >= 2.0 * eff_m:
			total += w * MountainNoise.snoise(dir * (radius / lam), seed_value * 16 + 11 + o)
		lam *= 0.5
		w *= 0.5
	return rim_amp_m * total / norm
