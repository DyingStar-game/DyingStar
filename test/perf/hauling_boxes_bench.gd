extends Node3D
## Client cost of a cargo depot whose shelves the admin fill stocked: the 193 shelves of
## cargo_depot_shelves.json (metal_shelf.tscn), and hauling_box.tscn on a share of their slots, every
## one dressed as the client dresses a replica (ReplicaDress.prepare: frozen, no physics process).
## Run WITH a display:
##   godot --path . res://test/perf/hauling_boxes_bench.tscn -- fill=0.52 [noboxes] [nolabel] [labelrange=4]
##       [labelcut] [noarea]
##       [nobody] [nomesh] [noboxshadow] [noshadow] [sun=0] [origin=8e10] [walker] [spin=0.25]
## origin= puts the whole rig that far from the world origin, where the client's planet is (Jolt's
## broadphase is float32 there); nothing renders correctly that far, the frame time is then the scripts
## and the physics. walker: a character capsule walks down the aisle with move_and_slide, like our own
## player (the SERVER's case: the client never runs move_and_slide). owner: the client's own player
## instead — a CharacterBody3D placed by position each physics step (the network moves it), with the
## InteractRay (areas, layer 6), the AreaDetector (zones) and the WeatherMasks scan (160 m sphere on
## world | prop every 30 steps); noray / nodetector / noscan drop one of them. depot: the shelves stand
## in the real cargo_depot.tscn (its 27 shadowed AreaLight3D panels); nolightshadow turns those shadows
## off. mover: a shadow-casting capsule walks down the aisle in front of the camera, as our own body
## does, so the lights' shadows have something to redraw. gravity: a planet's PlanetGravity sphere
## (monitoring, mask = MASK_MOVERS, which includes the prop layer the boxes sit on) under the rig.
## shelfoff: the boxes on the prop layer turned off (layer 0), the candidate fix. terrain=N: N×N
## terrain-like chunks around the depot, each a 64 m concave trimesh StaticBody3D on `world` (the client's
## terrain chunk colliders). areamask0: every box's interact Area3D gets collision_mask 0.
## labelhidden: every id frame hidden. spin=HZ: the rig turns by a hair that many times a second, like
## planet_body's spin refresh.
## The camera stands in the depot aisle, looking down the rows. Prints one line
## `PROBE boxes=… frame_ms=… rcpu_ms=… rgpu_ms=… draws=… …` and appends it to
## user://hauling_boxes_bench.txt.
const WARMUP := 120
const FRAMES := 300
const SHELF_SCENE := preload("res://scenes/_universe/props/furniture/metal_shelf.tscn")
const BOX_SCENE := preload("res://scenes/_universe/props/containers/hauling_box.tscn")
const DEPOT_SCENE := preload("res://scenes/_universe/structures/industrial/cargo_depot.tscn")
const LAYOUT := "res://scenes/_universe/structures/industrial/cargo_depot_shelves.json"

var _fill := 0.52
var _label_range := 0.0
var _origin := 0.0
var _flags: Dictionary = {}
var _boxes := 0
var _frame := 0
var _last_usec := 0
var _sum_frame := 0.0
var _max_frame := 0.0
var _sum_rcpu := 0.0
var _sum_rgpu := 0.0
var _max_setup := 0.0
var _sum_setup := 0.0
var _peak_proc := 0.0
var _peak_phys := 0.0
var _draws := 0
var _prims := 0
var _rid: RID
var _walker: CharacterBody3D = null
var _walk_from := Vector3.ZERO
var _walk_dir := Vector3.RIGHT
var _walk_t := 0.0
var _spin_hz := 0.0
var _terrain_n := 0
var _spin_accum := 0.0
var _spins := 0
var _phys_usec := 0
var _phys_steps := 0
var _owner_body: CharacterBody3D = null
var _scan_usec := 0
var _scans := 0
var _mover: MeshInstance3D = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("fill="):
			_fill = float(a.substr(5))  # share of the slots holding a box (0.52 ≈ the 2400 of the fill)
		elif a.begins_with("labelrange="):
			_label_range = float(a.substr(11))  # visibility_range_end (m) of every id frame, 0 = none
		elif a.begins_with("terrain="):
			_terrain_n = int(a.substr(8))
		elif a.begins_with("spin="):
			_spin_hz = float(a.substr(5))
		elif a.begins_with("origin="):
			_origin = float(a.substr(7))  # world offset (m) of the whole rig, e.g. 3.3e10 = a planet
		else:
			_flags[a] = true
	get_window().size = Vector2i(1920, 1080)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	position = Vector3(_origin, 0.0, _origin)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	ground.mesh = plane
	add_child(ground)
	if not _flags.has("sun=0"):
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
		sun.shadow_enabled = not _flags.has("noshadow")
		sun.directional_shadow_max_distance = 250.0  # the client's shadow_distance
		add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.6, 0.8)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e
	add_child(env)

	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var holder: Node3D = self
	if _flags.has("depot"):
		holder = DEPOT_SCENE.instantiate() as Node3D
		ReplicaDress.prepare(holder, true)
		add_child(holder)
		if _flags.has("nolightshadow"):
			for light in holder.find_children("*", "Light3D", true, false):
				(light as Light3D).shadow_enabled = false
	if _terrain_n > 0:
		var pm := PlaneMesh.new()
		pm.size = Vector2(64.0, 64.0)
		pm.subdivide_width = 31
		pm.subdivide_depth = 31
		var tri := pm.create_trimesh_shape()
		for ix in range(_terrain_n):
			for iz in range(_terrain_n):
				var chunk := StaticBody3D.new()
				var ccs := CollisionShape3D.new()
				ccs.shape = tri
				chunk.add_child(ccs)
				chunk.position = Vector3((ix - _terrain_n * 0.5) * 64.0, -0.05, (iz - _terrain_n * 0.5) * 64.0)
				add_child(chunk)
	if _flags.has("gravity"):
		var grav := Area3D.new()
		grav.collision_layer = 1 << (Globals.LAYER_ZONE - 1)
		grav.collision_mask = Globals.MASK_MOVERS
		grav.monitoring = true
		grav.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
		grav.gravity_point = true
		var gs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 6.4e6
		gs.shape = sph
		gs.position = Vector3(0.0, -6.356e6, 0.0)
		grav.add_child(gs)
		add_child(grav)
	var layout: Array = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for entry: Dictionary in layout:
		var shelf := SHELF_SCENE.instantiate() as Shelf
		ReplicaDress.prepare(shelf)
		var p: Dictionary = entry["position"]
		var r: Dictionary = entry["rotation"]
		shelf.position = Vector3(p["x"], p["y"], p["z"])
		shelf.rotation = Vector3(r["x"], r["y"], r["z"])
		holder.add_child(shelf)
		lo = lo.min(shelf.position)
		hi = hi.max(shelf.position)
		if _flags.has("noboxes"):
			continue
		for slot in shelf.shelf_slots:
			if rng.randf() >= _fill:
				continue
			var box := BOX_SCENE.instantiate() as RigidBody3D
			ReplicaDress.prepare(box)
			box.position = slot
			shelf.add_child(box)
			_strip(box)
			_boxes += 1

	# Standing in the middle of the depot, eye height, looking down the long axis of the rows.
	var cam := Camera3D.new()
	var mid := (lo + hi) * 0.5
	var along_x := (hi.x - lo.x) > (hi.z - lo.z)
	cam.position = Vector3(lo.x + 2.0, 1.7, mid.z) if along_x else Vector3(mid.x, 1.7, lo.z + 2.0)
	cam.fov = 85.0
	add_child(cam)
	cam.look_at(cam.global_position + (Vector3.RIGHT if along_x else Vector3.BACK) * 10.0, Vector3.UP)
	cam.current = true
	if _flags.has("mover"):
		_mover = MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.35
		cm.height = 1.8
		_mover.mesh = cm
		add_child(_mover)
		_walk_from = cam.position + (Vector3.RIGHT if along_x else Vector3.BACK) * 3.0
		_walk_from.y = 0.9
		_walk_dir = Vector3.RIGHT if along_x else Vector3.BACK
	if _flags.has("walker"):
		_walker = CharacterBody3D.new()
		_walker.collision_layer = 2
		_walker.collision_mask = 15
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.35
		cap.height = 1.8
		cs.shape = cap
		_walker.add_child(cs)
		add_child(_walker)
		_walk_from = Vector3(cam.position.x, 1.0, cam.position.z)
		_walk_dir = Vector3.RIGHT if along_x else Vector3.BACK
		_walker.position = _walk_from
		var floor_body := StaticBody3D.new()
		var fs := CollisionShape3D.new()
		var fb := BoxShape3D.new()
		fb.size = Vector3(400.0, 1.0, 400.0)
		fs.shape = fb
		fs.position.y = -0.5
		floor_body.add_child(fs)
		add_child(floor_body)
	if _flags.has("owner"):
		_owner_body = CharacterBody3D.new()
		_owner_body.collision_layer = 2
		_owner_body.collision_mask = 15
		var ocs := CollisionShape3D.new()
		var ocap := CapsuleShape3D.new()
		ocap.radius = 0.35
		ocap.height = 1.8
		ocs.shape = ocap
		ocs.position.y = 0.9
		_owner_body.add_child(ocs)
		if not _flags.has("noray"):
			var ray := RayCast3D.new()
			ray.target_position = Vector3(0.0, 0.0, -3.0)
			ray.collision_mask = 32
			ray.collide_with_areas = true
			ray.collide_with_bodies = false
			ray.position.y = 1.6
			_owner_body.add_child(ray)
		if not _flags.has("nodetector"):
			var det := Area3D.new()
			det.collision_layer = 0
			det.collision_mask = 16
			det.monitorable = false
			var dcs := CollisionShape3D.new()
			dcs.shape = ocap
			dcs.position.y = 0.9
			det.add_child(dcs)
			_owner_body.add_child(det)
		add_child(_owner_body)
		_walk_from = Vector3(cam.position.x, 0.0, cam.position.z)
		_walk_dir = Vector3.RIGHT if along_x else Vector3.BACK
		_owner_body.position = _walk_from
	_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_rid, true)
	_last_usec = Time.get_ticks_usec()


## Bisection switches, one part of the box removed each.
func _strip(box: RigidBody3D) -> void:
	if _flags.has("labelhidden"):
		for n in box.find_children("*", "Label3D", false, false):
			(n as Label3D).visible = false
	if _flags.has("nolabel"):
		for n in box.find_children("*", "Label3D", false, false):
			n.free()
	for n in box.find_children("*", "Label3D", false, false):
		if _label_range > 0.0:
			(n as Label3D).visibility_range_end = _label_range
		if _flags.has("labelcut"):
			(n as Label3D).alpha_cut = Label3D.ALPHA_CUT_DISCARD
	if _flags.has("noarea"):
		for n in box.find_children("*", "Area3D", false, false):
			n.free()
	if _flags.has("areamask0"):
		for n in box.find_children("*", "Area3D", false, false):
			(n as Area3D).collision_mask = 0
	if _flags.has("shelfoff"):
		box.collision_layer = 0
		box.collision_mask = 0
	if _flags.has("nobody"):
		box.collision_layer = 0
		box.collision_mask = 0
		for n in box.find_children("*", "CollisionShape3D", false, false):
			(n as CollisionShape3D).disabled = true
	if _flags.has("nomesh"):
		box.get_node("BoxMesh").visible = false
	if _flags.has("noboxshadow"):
		for n in box.find_children("*", "GeometryInstance3D", true, false):
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if _spin_hz > 0.0:
		_spin_accum += delta
		if _spin_accum >= 1.0 / _spin_hz:
			_spin_accum = 0.0
			rotate_y(1e-7)
			_spins += 1
	if _walker != null:
		_walk_t += delta
		var v := _walk_dir * 1.5 * (1.0 if fmod(_walk_t, 20.0) < 10.0 else -1.0)
		_walker.velocity = v + Vector3.DOWN * 2.0
		_walker.move_and_slide()
	if _mover != null:
		_walk_t += delta
		_mover.position = _walk_from + _walk_dir * 1.5 * fmod(_walk_t, 20.0)
	if _owner_body != null:
		_walk_t += delta
		_owner_body.position = _walk_from + _walk_dir * 1.5 * fmod(_walk_t, 20.0)
		if not _flags.has("noscan") and Engine.get_physics_frames() % 30 == 0:
			var s0 := Time.get_ticks_usec()
			var sphere := SphereShape3D.new()
			sphere.radius = 160.0
			var params := PhysicsShapeQueryParameters3D.new()
			params.shape = sphere
			params.transform = Transform3D(Basis.IDENTITY, _owner_body.global_position)
			params.collision_mask = (1 << 0) | (1 << 3)
			params.collide_with_areas = false
			get_world_3d().direct_space_state.intersect_shape(params, 256)
			_scan_usec += Time.get_ticks_usec() - s0
			_scans += 1
	_phys_usec += Time.get_ticks_usec() - t0
	_phys_steps += 1


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := float(now - _last_usec) / 1000.0
	_last_usec = now
	_frame += 1
	if _frame <= WARMUP:
		return
	_sum_frame += frame_ms
	_max_frame = maxf(_max_frame, frame_ms)
	_sum_rcpu += RenderingServer.viewport_get_measured_render_time_cpu(_rid)
	_sum_rgpu += RenderingServer.viewport_get_measured_render_time_gpu(_rid)
	var setup_ms := RenderingServer.get_frame_setup_time_cpu()
	_sum_setup += setup_ms
	_max_setup = maxf(_max_setup, setup_ms)
	_peak_proc = maxf(_peak_proc, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_peak_phys = maxf(_peak_phys, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draws = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_prims = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	if _frame == WARMUP + FRAMES:
		var line := ("PROBE boxes=%d labelrange=%.1f flags=%s frame_ms=%.2f max=%.1f fps=%.0f proc<=%.1f"
				+ " phys<=%.1f script_phys_us=%.0f steps=%d scan_us=%.0f rcpu_ms=%.2f rgpu_ms=%.2f"
				+ " setup_ms=%.2f setup_max=%.1f draws=%d prims=%d objects=%d") % [
			_boxes, _label_range, ",".join(_flags.keys()), _sum_frame / FRAMES, _max_frame,
			1000.0 * FRAMES / _sum_frame, _peak_proc, _peak_phys,
			float(_phys_usec) / maxf(_phys_steps, 1), _phys_steps, float(_scan_usec) / maxf(_scans, 1),
			_sum_rcpu / FRAMES,
			_sum_rgpu / FRAMES, _sum_setup / FRAMES, _max_setup, _draws, _prims,
			int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))]
		print(line)
		var f := FileAccess.open("user://hauling_boxes_bench.txt", FileAccess.READ_WRITE)
		if f == null:
			f = FileAccess.open("user://hauling_boxes_bench.txt", FileAccess.WRITE)
		else:
			f.seek_end()
		f.store_line(line)
		f.close()
		get_tree().quit()
