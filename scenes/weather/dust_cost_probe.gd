class_name DustCostProbe
extends RefCounted
## What the wind's dust costs, in the log (client.ini debug_dust_probe=true): every PERIOD_S one line
## "[DustCost]" with the CPU time of the weather reading and of the frame's dust work (mean and worst
## frame), the ground grids' share of it (ground queries and colour reads, and whether each is building),
## the whole frame's GPU time, and what the layer was asked to draw (density and steps near and far, lamp
## beams). The GPU time of the dust alone is the difference with Graphics > Wind-blown dust Off.

const PERIOD_S: float = 2.0

var _age: float = 0.0
var _frames: int = 0
var _update_us: int = 0
var _frame_us: int = 0
var _frame_max_us: int = 0
var _gpu_ms: float = 0.0
var _grid_us: Dictionary = {}  # name -> Vector2i(ground µs, colour µs) over the period


## true when client.ini asks for the probe.
static func wanted() -> bool:
	return ClientConfig.get_bool("debug_dust_probe", false)


## One frame: [param update_us] reading the weather, [param frame_us] the frame's dust work (grids
## included), the [param grids] (name -> DustGround) whose spent time is read and cleared, the frame's
## [param gpu_ms], after [param delta_s]. Returns the line to log once a period is over, else "".
func frame(update_us: int, frame_us: int, grids: Dictionary, gpu_ms: float, delta_s: float,
		layer: Dictionary) -> String:
	_frames += 1
	_update_us += update_us
	_frame_us += frame_us
	_frame_max_us = maxi(_frame_max_us, update_us + frame_us)
	_gpu_ms += gpu_ms
	for name: String in grids:
		var grid: DustGround = grids[name]
		_grid_us[name] = (_grid_us.get(name, Vector2i.ZERO) as Vector2i) + grid.take_spent_us()
	_age += delta_s
	if _age < PERIOD_S:
		return ""
	var line: String = report(grids, layer)
	_age = 0.0
	_frames = 0
	_update_us = 0
	_frame_us = 0
	_frame_max_us = 0
	_gpu_ms = 0.0
	_grid_us.clear()
	return line


## [param key] of [param layer] as a number: 0 for a shader parameter never set (it reads back null).
static func _num(layer: Dictionary, key: String) -> float:
	var value: Variant = layer.get(key)
	return float(value) if value is float or value is int else 0.0


## The period's line (see the class). [param layer]: what the layer was asked to draw.
func report(grids: Dictionary, layer: Dictionary) -> String:
	var n: float = maxf(float(_frames), 1.0)
	var parts: PackedStringArray = ["[DustCost] %d frames" % _frames,
		"cpu dust %.2f ms/frame (weather %.2f, worst frame %.2f)" % [(_update_us + _frame_us) / 1000.0 / n,
			_update_us / 1000.0 / n, _frame_max_us / 1000.0],
	]
	for name: String in grids:
		var grid: DustGround = grids[name]
		var spent: Vector2i = _grid_us.get(name, Vector2i.ZERO)
		parts.append("%s grid %.2f ms/frame (colour %.2f)%s, last build %d cells" % [name,
			spent.x / 1000.0 / n, spent.y / 1000.0 / n,  " building" if grid.is_building() else "",
			grid.last_build_cells])
	parts.append("gpu frame %.2f ms" % (_gpu_ms / n))
	parts.append("layer: near %.5f /m x %d steps, far %.5f /m x %d steps, %d lamps, setting %d" % [
		_num(layer, "near"), int(_num(layer, "near_steps")), _num(layer, "far"),
		int(_num(layer, "far_steps")), int(_num(layer, "lamps")), int(_num(layer, "setting"))])
	return " | ".join(parts)
