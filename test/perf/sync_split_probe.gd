extends Node3D
## Does ClientPerf's `sync=X (flush= xform+timers= tweens= rs=)` put each cost where it is? One phase made slow once a
## second (arg phase=flush|xform|timers|rs): a call deferred from _process that burns 300 ms, 30 000 static
## bodies turned in _process (their transform flush), an idle SceneTreeTimer that burns 300 ms, or a worker
## thread making 40 512² textures through the RenderingServer (queued, run in RenderingServer::sync on the
## main thread). Run it WITH a window: headless draws nothing, and `sync=` is measured up to the draw.
##   <godot> --path . res://test/perf/sync_split_probe.tscn -- phase=rs

var _phase := "none"
var _holder: Node3D
var _frames := 0
var _textures: Array[RID] = []


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("phase="):
			_phase = a.get_slice("=", 1)
	_holder = Node3D.new()
	add_child(_holder)
	if _phase == "xform":
		for k in 30000:
			var body := StaticBody3D.new()
			var shape := CollisionShape3D.new()
			shape.shape = BoxShape3D.new()
			body.add_child(shape)
			body.position = Vector3(k % 200, 0, k / 200) * 3.0
			_holder.add_child(body)


func _burn(ms: float) -> void:
	var t := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t < int(ms * 1000.0):
		pass


func _textures_on_worker() -> void:
	var image := Image.create_empty(512, 512, false, Image.FORMAT_RGBA8)
	for k in 40:
		_textures.append(RenderingServer.texture_2d_create(image))


func _process(_delta: float) -> void:
	_frames += 1
	if _frames % 60 != 30:
		return
	match _phase:
		"flush":
			_burn.call_deferred(300.0)
		"timers":
			get_tree().create_timer(0.0).timeout.connect(_burn.bind(300.0))
		"xform":
			_holder.rotate_y(0.5)
		"rs":
			WorkerThreadPool.add_task(_textures_on_worker)
	if _frames > 300:
		for rid in _textures:
			RenderingServer.free_rid(rid)
		get_tree().quit()
