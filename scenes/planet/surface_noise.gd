@tool
class_name SurfaceNoise
## Deterministic noise for surface colouring, shared by every biome that bakes
## a tint into the vertex colour (the corundum iron stain, the per-rock shading
## of RockCatalogue…).
##
## Pure functions of position: a fract(sin(dot)) lattice hash and a
## trilinearly-interpolated value noise on top of it. No engine state, no RNG,
## only IEEE doubles — so a client and the server evaluating the same vertex
## direction get the same value, and the chunk cache can bake the result.
## The corundum crack network (ArideDesertCorundumPlateauTerrain) is built on
## the same hash, so the two stay in lock-step.


## Per-cell jitter in [0,1)³.
static func hash3(c: Vector3) -> Vector3:
	var x := sin(c.dot(Vector3(127.1, 311.7, 74.7))) * 43758.5453123
	var y := sin(c.dot(Vector3(269.5, 183.3, 246.1))) * 43758.5453123
	var z := sin(c.dot(Vector3(113.5, 271.9, 124.6))) * 43758.5453123
	return Vector3(x - floor(x), y - floor(y), z - floor(z))


static func hash1(c: Vector3) -> float:
	return hash3(c).x


## Value noise in [0, 1], C² continuous (quintic smoothstep between lattice
## points, so no creases show on a smooth surface).
static func vnoise(p: Vector3) -> float:
	var i := p.floor()
	var f := p - i
	var w := f * f * f * (f * (f * 6.0 - Vector3(15, 15, 15)) + Vector3(10, 10, 10))
	var c000 := hash1(i + Vector3(0, 0, 0))
	var c100 := hash1(i + Vector3(1, 0, 0))
	var c010 := hash1(i + Vector3(0, 1, 0))
	var c110 := hash1(i + Vector3(1, 1, 0))
	var c001 := hash1(i + Vector3(0, 0, 1))
	var c101 := hash1(i + Vector3(1, 0, 1))
	var c011 := hash1(i + Vector3(0, 1, 1))
	var c111 := hash1(i + Vector3(1, 1, 1))
	var x00 := lerpf(c000, c100, w.x)
	var x10 := lerpf(c010, c110, w.x)
	var x01 := lerpf(c001, c101, w.x)
	var x11 := lerpf(c011, c111, w.x)
	var y0 := lerpf(x00, x10, w.y)
	var y1 := lerpf(x01, x11, w.y)
	return lerpf(y0, y1, w.z)


## Two-octave mottling in [0, 1] at a point [param dir] of a sphere of
## [param radius]: large blotches of [param blotch_m] and finer streaks of
## [param streak_m], mixed 70 / 30. This is the pattern the rock tints use.
static func mottle(dir: Vector3, radius: float, blotch_m: float, streak_m: float) -> float:
	var blotch := vnoise(dir * (radius / blotch_m))
	var streak := vnoise(dir * (radius / streak_m))
	return clampf(blotch * 0.7 + streak * 0.3, 0.0, 1.0)
