extends Node
## GPU cost of planet_surface.gdshader (the hex-tiled corundum ground) on THIS machine.
## Run WITH a display: godot --path . res://test/parity/hex_shader_bench.tscn -- <quality 0|1|2>
## Fills a 1080p window with the corundum material seen from standing height and prints the
## mean viewport GPU time over the measured frames as `PROBE quality=<q> gpu_ms=<mean> max=<max>`.
const WARMUP := 60
const FRAMES := 240

var _quality := 2
var _frame := 0
var _sum := 0.0
var _max := 0.0
var _rid: RID


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.is_valid_int():
			_quality = int(a)
	RenderingServer.global_shader_parameter_set("planet_hex_quality", _quality)
	get_window().size = Vector2i(1920, 1080)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4000.0, 4000.0)
	plane.subdivide_depth = 64
	plane.subdivide_width = 64
	ground.mesh = plane
	ground.material_override = load(
			"res://assets/_universe/_shared/materials/mat_mineral_corundum_pure/corundum_outcrop_surface.tres")
	add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.7, 0.0)
	cam.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	cam.fov = 90.0
	add_child(cam)
	cam.current = true
	_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_rid, true)


func _process(_delta: float) -> void:
	_frame += 1
	if _frame <= WARMUP:
		return
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(_rid)
	_sum += gpu
	_max = maxf(_max, gpu)
	if _frame == WARMUP + FRAMES:
		print("PROBE quality=%d gpu_ms=%.2f max=%.2f" % [_quality, _sum / FRAMES, _max])
		get_tree().quit()
