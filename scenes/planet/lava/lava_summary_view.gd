extends RefCounted
## CLIENT: a lava patch shown from the server's summaries (LavaSummary) instead of simulated. It has the fields
## the renderer (viscous_lava_surface.gd), the edge smoke (lava_edge_smoke.gd) and the lava runtime read from a
## presentation solver (viscous_lava_solver.gd), filled by [method apply] from a rebuilt summary. No physics:
## the grid and its ground come once from the prop (LavaSummary.encode_grid), the values every few seconds.

const Summary = preload("res://scenes/planet/lava/lava_summary.gd")

var width := 0
var height := 0
var geometry_mode := 1
var cell_mm := 0
var cell_m := 0.0
var crater_rows := 0
var radial_edges_mm := PackedInt64Array()
var radial_centres := PackedFloat32Array()
var tick := 0
var presentation_enabled := true
var bed := PackedFloat64Array()
var depth := PackedFloat64Array()
var temperature := PackedFloat64Array()
var age := PackedFloat64Array()
var velocity := PackedVector2Array()
var opacity := PackedFloat32Array()
var positions := PackedVector2Array()
## 1 L stands for a wet cell, 0 for a dry one: the renderer only tests volume_q[i] == 0.
var volume_q := PackedInt64Array()
var wet_indices := PackedInt32Array()
var active_indices := PackedInt32Array()
var visual_dirty := PackedInt32Array()
var _neighbors := PackedInt32Array()


## The view of grid [param bytes] (LavaSummary.encode_grid), dry everywhere, or null when malformed.
static func from_grid(bytes: PackedByteArray) -> RefCounted:
	var grid := Summary.decode_grid(bytes)
	if grid.is_empty():
		return null
	var view := new()
	view.width = grid.width
	view.height = grid.height
	view.crater_rows = grid.crater_rows
	view.cell_mm = grid.cell_mm
	view.cell_m = grid.cell_mm / 1000.0
	view.radial_edges_mm = grid.radial_edges_mm
	view.bed = grid.bed
	var count: int = view.width * view.height
	for z in view.height:
		view.radial_centres.append((view.radial_edges_mm[z] + view.radial_edges_mm[z + 1]) / 2000.0)
	view.positions = Summary.cell_positions(view)
	view.depth.resize(count)
	view.temperature.resize(count)
	view.temperature.fill(20.0)
	view.age.resize(count)
	view.velocity.resize(count)
	view.opacity.resize(count)
	view.volume_q.resize(count)
	view._neighbors.resize(count * 4)
	for i in count:
		var x: int = i % view.width
		var z: int = i / view.width
		view._neighbors[i * 4] = z * view.width + posmod(x - 1, view.width)
		view._neighbors[i * 4 + 1] = z * view.width + (x + 1) % view.width
		view._neighbors[i * 4 + 2] = i - view.width if z > 0 else -1
		view._neighbors[i * 4 + 3] = i + view.width if z < view.height - 1 else -1
	return view


## Takes the values of [param fields] (LavaSummary.reconstruct). Every cell wet before or now is marked for
## the renderer: a cell gone dry must be cleared on screen. A worker may call it while it owns the view.
func apply(fields: Dictionary) -> void:
	var wet: PackedByteArray = fields.wet
	var dirty := PackedByteArray()
	dirty.resize(wet.size())
	for i in wet_indices:
		dirty[i] = 1
	var fresh_depth: PackedFloat64Array = fields.depth
	var fresh_temperature: PackedFloat64Array = fields.temperature
	var fresh_age: PackedFloat64Array = fields.age
	var fresh_opacity: PackedFloat64Array = fields.opacity
	var fresh_velocity: PackedVector2Array = fields.velocity
	wet_indices = PackedInt32Array()
	for i in wet.size():
		volume_q[i] = wet[i]
		if wet[i] == 1:
			wet_indices.append(i)
			dirty[i] = 1
			depth[i] = fresh_depth[i]
			temperature[i] = fresh_temperature[i]
			age[i] = fresh_age[i]
			opacity[i] = fresh_opacity[i]
			velocity[i] = fresh_velocity[i]
		else:
			depth[i] = 0.0
	active_indices = wet_indices
	visual_dirty = PackedInt32Array()
	for i in dirty.size():
		if dirty[i] == 1:
			visual_dirty.append(i)
	tick = int(fields.tick)


func take_visual_dirty() -> PackedInt32Array:
	var result := visual_dirty
	visual_dirty = PackedInt32Array()
	return result


func refresh_views(_full: bool = true) -> void:
	presentation_enabled = true


func release_views() -> void:
	presentation_enabled = false


## The server deletes the prop once the deposit is gone: nothing to retire before that.
func cleanup_complete() -> bool:
	return false
