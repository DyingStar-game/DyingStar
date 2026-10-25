extends Node3D
## Cost of keeping the first-person eye out of walls (CharacterAnimator.keep_eye_out_of_walls): a
## sphere swept with cast_motion against a ray, a wall in the way or not, near the world origin or as
## far from it as the client's planet is (Jolt's broadphase is float32 there).
## Run headless:
##   godot --headless --path . res://test/perf/eye_sweep_bench.tscn -- [origin=8e10] [terrain=N] [cells=64]
## The wall is a 4 x 3 m concave trimesh of cells x cells quads (a building's collision), terrain=N adds
## N x N terrain-like 64 m concave chunks around it on `world`. Prints one `PROBE` line per case:
## microseconds per call.
const CALLS := 500

var _origin := 0.0
var _terrain := 0
var _cells := 64
var _done := false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() == 2 and kv[0] == "origin":
			_origin = float(kv[1])
		elif kv.size() == 2 and kv[0] == "terrain":
			_terrain = int(kv[1])
		elif kv.size() == 2 and kv[0] == "cells":
			_cells = int(kv[1])
	position = Vector3(_origin, 0.0, 0.0)
	# The wall: its face at z = -0.5, the eye's axis at the origin, looking down -Z.
	_add_static(_grid_wall(4.0, 3.0, _cells), Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.5)))
	for i in _terrain:
		for j in _terrain:
			var at := Vector3((i - _terrain / 2.0) * 64.0, -0.01, (j - _terrain / 2.0) * 64.0)
			_add_static(_grid_floor(64.0, 32), Transform3D(Basis.IDENTITY, at))


func _physics_process(_delta: float) -> void:
	if _done or Engine.get_physics_frames() < 3:
		return
	_done = true
	var space := get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = 0.15
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.collision_mask = Globals.MASK_OBSTACLE
	var from := to_global(Vector3(0.0, 1.6, 0.0))
	for case: Array in [["hit", Vector3(0.0, 0.0, -0.5)], ["miss", Vector3(0.0, 0.0, 0.3)]]:
		var motion: Vector3 = case[1]
		q.transform = Transform3D(Basis.IDENTITY, from)
		q.motion = motion
		var t0 := Time.get_ticks_usec()
		var fractions = null
		for k in CALLS:
			fractions = space.cast_motion(q)
		var cast_us := float(Time.get_ticks_usec() - t0) / CALLS
		var ray := PhysicsRayQueryParameters3D.create(from, from + motion.normalized() * (motion.length() + 0.15),
				Globals.MASK_OBSTACLE)
		t0 = Time.get_ticks_usec()
		var hit := {}
		for k in CALLS:
			hit = space.intersect_ray(ray)
		var ray_us := float(Time.get_ticks_usec() - t0) / CALLS
		var line := "PROBE case=%s origin=%s terrain=%d cells=%d cast_motion_us=%.1f fractions=%s ray_us=%.1f ray_hit=%s" \
				% [case[0], str(_origin), _terrain, _cells, cast_us, str(fractions), ray_us, str(not hit.is_empty())]
		print(line)
	get_tree().quit()


func _add_static(shape: Shape3D, xf: Transform3D) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	body.transform = xf
	add_child(body)


## A vertical w x h trimesh in the XY plane, n x n quads.
static func _grid_wall(w: float, h: float, n: int) -> ConcavePolygonShape3D:
	var faces := PackedVector3Array()
	for i in n:
		for j in n:
			var x0 := -w * 0.5 + w * i / n
			var x1 := -w * 0.5 + w * (i + 1) / n
			var y0 := h * j / n
			var y1 := h * (j + 1) / n
			faces.append_array([Vector3(x0, y0, 0), Vector3(x1, y1, 0), Vector3(x1, y0, 0),
					Vector3(x0, y0, 0), Vector3(x0, y1, 0), Vector3(x1, y1, 0)])  # clockwise from +Z: faces the eye
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape


## A horizontal s x s trimesh in the XZ plane, n x n quads.
static func _grid_floor(s: float, n: int) -> ConcavePolygonShape3D:
	var faces := PackedVector3Array()
	for i in n:
		for j in n:
			var x0 := s * i / n
			var x1 := s * (i + 1) / n
			var z0 := s * j / n
			var z1 := s * (j + 1) / n
			faces.append_array([Vector3(x0, 0, z0), Vector3(x1, 0, z1), Vector3(x1, 0, z0),
					Vector3(x0, 0, z0), Vector3(x0, 0, z1), Vector3(x1, 0, z1)])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape
