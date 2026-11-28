extends Node3D
## Does ClientPerf's `pengine=X (flush= timers= xform= jolt=)` put each cost where it is? Headless, one phase
## made slow at a time (arg phase=flush|timers|xform|bodies|compound|none): a call deferred from _physics_process that
## burns 300 ms, a physics SceneTreeTimer that burns 300 ms, 30 000 static bodies turned once a second (their
## transform flush), or added at once (with their bodies+= count). Read the [CPerf!] lines it prints.
##   <godot> --headless --path . res://test/perf/pengine_split_probe.tscn -- phase=xform

var _phase := "none"
var _holder: Node3D
var _steps := 0


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("phase="):
			_phase = a.get_slice("=", 1)
	_holder = Node3D.new()
	add_child(_holder)
	if _phase == "xform":
		_add_bodies()


func _add_bodies() -> void:
	for k in 30000:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		body.add_child(shape)
		body.position = Vector3(k % 200, 0, k / 200) * 3.0
		_holder.add_child(body)


## 1 000 static bodies of 20 box shapes each: Jolt builds each one's compound shape at its first step.
func _add_compound_bodies() -> void:
	for k in 1000:
		var body := StaticBody3D.new()
		for j in 20:
			var shape := CollisionShape3D.new()
			shape.shape = BoxShape3D.new()
			shape.position = Vector3(j * 1.5, 0, 0)
			body.add_child(shape)
		body.position = Vector3(k % 40, 0, k / 40) * 40.0
		_holder.add_child(body)


func _burn(ms: float) -> void:
	var t := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t < int(ms * 1000.0):
		pass


func _physics_process(_delta: float) -> void:
	_steps += 1
	if _steps % 60 != 30:
		return
	match _phase:
		"flush":
			_burn.call_deferred(300.0)
		"timers":
			get_tree().create_timer(0.0, true, true).timeout.connect(_burn.bind(300.0))
		"xform":
			_holder.rotate_y(0.5)
		"bodies":
			if _steps == 30:
				_add_bodies()
		"compound":
			if _steps == 30:
				_add_compound_bodies()
	if _steps > 300:
		get_tree().quit()
