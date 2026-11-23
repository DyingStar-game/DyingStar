class_name WeatherCanyon
extends RefCounted
## The trench of the corundum crack network under a place, as WeatherLocal reads it: how deep in it the
## place is and which way the trench runs. The weather prototype's Planet.canyon_at (branch wip/weather),
## kept beside the weather instead of in Planet.
##
## One difference from the prototype: the trench's direction. The prototype read it from the Voronoi's
## edge plane (ArideDesertCorundumPlateauTerrain.crack_axis, which develop does not have). Here the two
## blocks either side of the trench are found with crack_cell (the block under the place, and the first
## other block met a trench's width away): the trench runs along the plane halfway between their feature
## points. Same trench, same direction up to the meander's warp; a place where three blocks meet takes the
## first neighbour found.

## A place's answer is kept by cell of this side (m): the trench's direction does not change in that.
const MEMO_M := 5.0
const MEMO_MAX := 2048
## The neighbouring block is looked for this many trench widths away, in this many directions.
const PROBE_WIDTHS := 1.0
const PROBES := 8

static var _memo := {}
static var _mutex := Mutex.new()


## {"depth": 0..1 (1 on the floor of a trench, fading to 0 one trench-depth above it; 0 on the plateau, off
## corundum, in a POI's sphere or on a massif), "axis": unit (east, north) along the trench}. {} on a body
## without the network. [param above_m]: the place's height over the ground there.
static func at(data: PlanetData, dir: Vector3, above_m: float = 0.0) -> Dictionary:
	if data == null or not data.corundum_default_biome or data.crack_width_m <= 0.0 or data.crack_spacing_m <= 0.0:
		return {}
	var at_floor := _floor_at(data, dir)
	if float(at_floor["depth"]) <= 0.0:
		return at_floor
	# Above the floor the trench's wind fades out over the trench's own depth: a flyer feels the plateau's.
	var out := at_floor.duplicate()
	out["depth"] = float(at_floor["depth"]) * clampf(1.0 - above_m / maxf(data.crack_depth_m, 1.0), 0.0, 1.0)
	return out


## The same on the trench's floor, kept by cell.
static func _floor_at(data: PlanetData, dir: Vector3) -> Dictionary:
	var at_m := dir * data.radius
	var key := [data.get_instance_id(), floori(at_m.x / MEMO_M), floori(at_m.y / MEMO_M), floori(at_m.z / MEMO_M)]
	_mutex.lock()
	var known: Variant = _memo.get(key)
	_mutex.unlock()
	if known != null:
		return known
	var out := _read(data, dir)
	_mutex.lock()
	if _memo.size() >= MEMO_MAX:
		_memo.clear()
	_memo[key] = out
	_mutex.unlock()
	return out


static func _read(data: PlanetData, dir: Vector3) -> Dictionary:
	var open := {"depth": 0.0, "axis": Vector2.ZERO}
	var noise := data.crack_noise()
	var edge := ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(dir, data.radius, data.crack_spacing_m,
			data.crack_width_m, 0.0, noise)
	if edge >= data.crack_width_m * 0.5:
		return open
	var depth := CrackCarve.depth_factor(data, dir, null)
	if depth <= 0.0:
		return open
	var here: Vector3 = ArideDesertCorundumPlateauTerrain.crack_cell(dir, data.radius, data.crack_spacing_m, noise)[1]
	var axes: Array = Planet.local_axes(dir)
	var reach := data.crack_width_m * PROBE_WIDTHS / data.radius
	for k in PROBES:
		var turn := TAU * k / PROBES
		var probe := (dir + ((axes[0] as Vector3) * cos(turn) + (axes[1] as Vector3) * sin(turn)) * reach).normalized()
		var there: Vector3 = ArideDesertCorundumPlateauTerrain.crack_cell(probe, data.radius, data.crack_spacing_m, noise)[1]
		if there.is_equal_approx(here):
			continue
		# Across the trench: from one block's feature point to the other's. Along it: that, crossed with up.
		var along := (there - here).cross(dir)
		if along.length_squared() < 1e-12:
			continue
		along = along.normalized()
		return {"depth": depth, "axis": Vector2(along.dot(axes[0]), along.dot(axes[1])).normalized()}
	return {"depth": depth, "axis": Vector2.ZERO}
