extends Node3D
## What an apartment's interior costs when InteriorStreamer instances it near the camera: one interior a
## second, in _process as the streamer does, ClientPerf on (debug_perf) -- read its [CPerf!] lines, the frame
## after each (`bodies+=` and `pengine=X (flush timers xform jolt)` of the physics steps that follow).
##   <godot> [--headless] --path . res://test/perf/interior_stream_probe.tscn [-- strip=<class|script.gd>,... far=3.3e10 crowd=3000]

const INTERIOR := "res://scenes/_universe/structures/buildings/apartment_interior.tscn"

var _scene: PackedScene
var _strip: PackedStringArray = []
var _made := 0
var _wait := 1.0
## far=<m>: everything that far from the origin, as a village on a planet is (3.3e10 m), among `crowd` static
## bodies (crowd=<n>, a village's).
var _origin := Vector3.ZERO


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("strip="):
			_strip = a.get_slice("=", 1).split(",")
	var crowd := 0
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("far="):
			_origin = Vector3(float(a.get_slice("=", 1)), 0, 0)
		if a.begins_with("crowd="):
			crowd = int(a.get_slice("=", 1))
	position = _origin
	for k in crowd:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		body.add_child(shape)
		body.position = Vector3(k % 60, 0, k / 60) * 4.0 - Vector3(120, 0, 120)
		add_child(body)
	_scene = load(INTERIOR) as PackedScene
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 1.6, 8)
	cam.make_current()


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = 1.0
	if _made >= 6:
		get_tree().quit()
		return
	var fresh := _scene.instantiate() as Node3D
	fresh.position = Vector3(_made * 6.0, 0, 0)
	for node in fresh.find_children("*", "", true, false):
		var sc := node.get_script() as Script
		if node.get_class() in _strip or (sc != null and sc.resource_path.get_file() in _strip):
			node.get_parent().remove_child(node)
			node.free()
	var t := Time.get_ticks_usec()
	add_child(fresh)
	print("[IntProbe] interior %d entered: %.1f ms" % [_made, (Time.get_ticks_usec() - t) / 1000.0])
	_made += 1
