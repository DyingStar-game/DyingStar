extends Node3D

## Cycles ARKit face units on the injected character, each held a few frames, camera on the face.

const POSES: Array = [
	["neutre", {}],
	["jawOpen", {"jawOpen": 1.0}],
	["mouthSmile", {"mouthSmileLeft": 1.0, "mouthSmileRight": 1.0}],
	["eyeBlink", {"eyeBlinkLeft": 1.0, "eyeBlinkRight": 1.0}],
	["browInnerUp", {"browInnerUp": 1.0}],
	["browDown", {"browDownLeft": 1.0, "browDownRight": 1.0}],
	["cheekPuff", {"cheekPuff": 1.0}],
	["mouthPucker", {"mouthPucker": 1.0}],
	["mouthFunnel", {"mouthFunnel": 1.0, "jawOpen": 0.3}],
	["tongueOut", {"tongueOut": 1.0, "jawOpen": 0.4}],
	["mouthFrown", {"mouthFrownLeft": 1.0, "mouthFrownRight": 1.0}],
	["noseSneer", {"noseSneerLeft": 1.0, "noseSneerRight": 1.0}],
	["eyeSquint", {"eyeSquintLeft": 1.0, "eyeSquintRight": 1.0}],
	["rire", {"jawOpen": 0.4, "mouthSmileLeft": 0.9, "mouthSmileRight": 0.9, "eyeSquintLeft": 0.5, "eyeSquintRight": 0.5}],
]
const HOLD := 6

var _meshes: Array[MeshInstance3D] = []
var _frame := 0
var _label: Label3D
var _capture: Array = []
var _names: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--face="):
			var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(arg.trim_prefix("--face=")))
			_names = data["names"]
			_capture = data["frames"]
	var body: Node3D = load("res://assets/_universe/characters/humanoids/man_ddurieux.glb").instantiate()
	add_child(body)
	for m in body.find_children("*", "MeshInstance3D", true, false):
		if (m as MeshInstance3D).get_blend_shape_count() > 0:
			_meshes.append(m)
	print("FACE meshes with blend shapes: ", _meshes.map(func(m): return "%s(%d)" % [m.name, m.get_blend_shape_count()]))
	var sk: Skeleton3D = body.find_children("*", "Skeleton3D", true, false)[0]
	var head: Vector3 = sk.to_global(sk.get_bone_global_rest(sk.find_bone(&"Head")).origin)
	var cam := Camera3D.new()
	cam.fov = 30.0
	add_child(cam)
	cam.look_at_from_position(head + Vector3(0.0, 0.03, 0.62), head + Vector3(0.0, 0.03, 0.0))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.36, 0.42)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.55, 0.6)
	add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-25.0, 20.0, 0.0)
	add_child(key)
	_label = Label3D.new()
	_label.pixel_size = 0.0006
	_label.position = head + Vector3(-0.11, 0.2, 0.05)
	add_child(_label)


func _process(_delta: float) -> void:
	if not _capture.is_empty():
		_play_capture()
		return
	var pose: Array = POSES[mini(_frame / HOLD, POSES.size() - 1)]
	_label.text = pose[0]
	for m in _meshes:
		for i in m.get_blend_shape_count():
			m.set_blend_shape_value(i, 0.0)
		for shape in pose[1]:
			var idx: int = m.find_blend_shape_by_name(shape)
			if idx != -1:
				m.set_blend_shape_value(idx, pose[1][shape])
	_frame += 1


## Plays a MediaPipe face capture (face_capture.json): one set of 52 ARKit scores per frame.
func _play_capture() -> void:
	var entry: Dictionary = _capture[mini(_frame, _capture.size() - 1)]
	_label.text = "%.1f s" % entry["t"]
	if entry.get("found", false):
		var scores: Array = entry["blend"]
		for m in _meshes:
			for k in _names.size():
				var idx: int = m.find_blend_shape_by_name(_names[k])
				if idx != -1:
					m.set_blend_shape_value(idx, scores[k])
	_frame += 1
