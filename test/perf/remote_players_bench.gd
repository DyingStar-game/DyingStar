extends Node3D
## Cost of N REMOTE avatars on THIS machine, using the real player.tscn on its remote path
## (remote_player = true, PlayerClient presentation, CharacterAnimator, name tag, footsteps).
## Run WITH a display:
##   godot --path . res://test/perf/remote_players_bench.tscn -- count=30 [move=0] [noanim] [notag]
##       [nopuppet] [noshadow] [nophys] [noskel] [noscript] [sharedtag] [torch] [budget] [behind] [sun=0]
## The avatars walk in small circles (move=1, default) fed at 30 Hz through net_set_target, like the
## network does, so the walk animation, interpolation and footsteps all run. Prints one line
## `PROBE count=… frame_ms=… proc_ms=… phys_ms=… rcpu_ms=… rgpu_ms=… draws=… prims=…` and appends it
## to user://remote_players_bench.txt.
const WARMUP := 120
const FRAMES := 300
const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

var _count := 30
var _move := true
var _flags: Dictionary = {}
var _players: Array[Node3D] = []
var _origins: Array[Vector3] = []
var _frame := 0
var _last_usec := 0
var _sum_frame := 0.0
var _max_frame := 0.0
var _sum_rcpu := 0.0
var _sum_rgpu := 0.0
var _peak_proc := 0.0
var _peak_phys := 0.0
var _draws := 0
var _prims := 0
var _rid: RID
var _net_accum := 0.0
var _t := 0.0
var _shared_layer: CanvasLayer = null
var _shared_tags: Array[Label] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("count="):
			_count = int(a.substr(6))
		elif a.begins_with("move="):
			_move = int(a.substr(5)) != 0
		else:
			_flags[a] = true
	get_window().size = Vector2i(1920, 1080)
	# Raw frame time, not the monitor's refresh: vsync off, no fps cap.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.4, 0.35)
	ground.material_override = mat
	add_child(ground)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)

	if not _flags.has("sun=0"):
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
		sun.shadow_enabled = not _flags.has("noshadow")
		sun.directional_shadow_max_distance = 300.0
		add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.6, 0.8)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e
	add_child(env)

	# Camera at standing height, the crowd spread on a grid 2.5 m apart in front of it (all on screen).
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.7, 14.0)
	cam.rotation_degrees = Vector3(-6.0, 0.0, 0.0)
	cam.fov = 90.0
	add_child(cam)
	cam.current = true

	var cols := int(ceil(sqrt(float(_count))))
	for i in range(_count):
		var p := PLAYER_SCENE.instantiate() as Node3D
		var x := (float(i % cols) - float(cols - 1) * 0.5) * 2.5
		var z := -float(i / cols) * 2.5
		if _flags.has("behind"):
			z = 30.0 - z  # the whole crowd behind the camera: off-screen, never rendered
		var origin := Vector3(x, 0.0, z)
		p.spawn_position = origin
		p.name = "Player%02d" % i
		p.remote_player = true
		p.set_physics_process(false)
		add_child(p)
		p.client_uuid = "bench-%d" % i
		p.net_set_target(origin, Vector3.ZERO)
		p.net_reset_interp()
		_players.append(p)
		_origins.append(origin)
	# Bisection switches, applied after setup() built the remote presentation.
	for p in _players:
		if _flags.has("nopuppet"):
			p.puppet.visible = false
		if _flags.has("noanim"):
			var animator: Node = p.puppet.get_node_or_null("CharacterAnimator")
			if animator != null:
				animator.set_process(false)
		if _flags.has("notag"):
			for layer in p.get_children():
				if layer is CanvasLayer:
					layer.queue_free()
		if _flags.has("noskel"):
			# Freeze the AnimationPlayer: no bone pose written, no skeleton/skin update.
			var ap: AnimationPlayer = p.puppet.get_node_or_null("AnimationPlayer")
			if ap != null:
				ap.active = false
		if _flags.has("noscript"):
			# Silence the per-frame GDScript of the remote presentation (role + mining tool).
			p.get_node("Role").set_process(false)
			p.mining_tool.set_process(false)
		if _flags.has("sharedtag"):
			# Same 30 labels, ONE CanvasLayer instead of two per avatar (the candidate fix).
			for layer in p.get_children():
				if layer is CanvasLayer:
					layer.queue_free()
			if _shared_layer == null:
				_shared_layer = CanvasLayer.new()
				add_child(_shared_layer)
			var tag := Label.new()
			tag.text = p.name
			tag.add_theme_font_size_override("font_size", 15)
			tag.add_theme_color_override("font_outline_color", Color.BLACK)
			tag.add_theme_constant_override("outline_size", 6)
			_shared_layer.add_child(tag)
			_shared_tags.append(tag)
		if _flags.has("torch"):
			p.flashlight.visible = true  # every avatar's head torch lit (night scene)
		if _flags.has("nophys"):
			for cs in p.find_children("*", "CollisionShape3D", true, false):
				(cs as CollisionShape3D).disabled = true
	if _flags.has("budget"):
		add_child(TorchShadowBudget.new())  # the owner's torch shadow budget, without an owner
	_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_rid, true)
	_last_usec = Time.get_ticks_usec()


func _process(delta: float) -> void:
	_t += delta
	# 30 Hz replicated movement: each avatar walks a 1.5 m circle at ~1 m/s.
	if _move:
		_net_accum += delta
		if _net_accum >= 1.0 / 30.0:
			_net_accum = 0.0
			for i in _players.size():
				var a := _t * 0.7 + float(i)
				var target := _origins[i] + Vector3(cos(a), 0.0, sin(a)) * 1.5
				_players[i].net_set_target(target, Vector3(0.0, -a, 0.0))
	if not _shared_tags.is_empty():
		var cam := get_viewport().get_camera_3d()
		for i in _shared_tags.size():
			var head: Vector3 = _players[i].global_position + Vector3(0.0, 2.0, 0.0)
			_shared_tags[i].position = cam.unproject_position(head) - _shared_tags[i].size * 0.5
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
	_peak_proc = maxf(_peak_proc, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_peak_phys = maxf(_peak_phys, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draws = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_prims = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	if _frame == WARMUP + FRAMES:
		var line := "PROBE count=%d move=%d flags=%s frame_ms=%.2f max=%.1f fps=%.0f proc<=%.1f phys<=%.1f rcpu_ms=%.2f rgpu_ms=%.2f draws=%d prims=%d objects=%d" % [
			_count, 1 if _move else 0, ",".join(_flags.keys()), _sum_frame / FRAMES, _max_frame,
			1000.0 * FRAMES / _sum_frame, _peak_proc, _peak_phys, _sum_rcpu / FRAMES,
			_sum_rgpu / FRAMES, _draws, _prims,
			int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))]
		print(line)
		var f := FileAccess.open("user://remote_players_bench.txt", FileAccess.READ_WRITE)
		if f == null:
			f = FileAccess.open("user://remote_players_bench.txt", FileAccess.WRITE)
		else:
			f.seek_end()
		f.store_line(line)
		f.close()
		get_tree().quit()
