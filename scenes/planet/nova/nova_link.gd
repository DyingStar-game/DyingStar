@tool
class_name NovaLink
extends Node
## The running game's end of the line to the Nova dock in the editor.
##
## The dock's settings show in the game at once, without saving; its "go to" moves send the player; the
## game reports where its camera stands. The line is Godot's own debugger channel (EngineDebugger): it
## exists only while the editor runs the game, never in an exported game, and the terrain creates this node
## only then and only on a client (PlanetTerrain._nova_setup).
##
## Editor → game:  nova:profile [path, values]   one settings file as the dock holds it in memory
##                 nova:goto [dir, above]        put the player over ground point dir, above metres up
##                 nova:hour [hours]             local time of day to keep where the player is (12 = noon)
## Game → editor:  nova:hello [body]             the line is up for this body
##                 nova:camera [dir, height]     ground point under the camera (body frame), metres up

const CHANNEL := "nova"
## Seconds between two looks at the camera, and after the last scatter change before the rocks are re-laid.
const CAMERA_PERIOD := 0.25
const SCATTER_DELAY := 0.3

## The body this end speaks for (set by the terrain before the node enters the tree).
var body_name := ""

var _terrain: PlanetTerrain
var _since_camera := 0.0
var _last_dir := Vector3.ZERO
var _scatter_due := -1.0


func _enter_tree() -> void:
	_terrain = get_parent() as PlanetTerrain
	EngineDebugger.register_message_capture(CHANNEL, _on_message)
	EngineDebugger.send_message(CHANNEL + ":hello", [body_name])


func _exit_tree() -> void:
	EngineDebugger.unregister_message_capture(CHANNEL)


func _on_message(message: String, data: Array) -> bool:
	var nova: NovaBody = _terrain.planet_data.nova
	match message:
		"profile":
			var profile := nova.profile_for_edit(str(data[0]))
			var scatter_before := _scatter_of(profile.values)
			profile.values = (data[1] as Dictionary).duplicate(true)
			nova.refresh_ground()
			if _scatter_of(profile.values) != scatter_before:
				_scatter_due = SCATTER_DELAY
		"goto":
			var scene := get_tree().current_scene
			if scene != null and scene.has_method("nova_goto"):
				scene.nova_goto(data[0], float(data[1]))
		"hour":
			var scene := get_tree().current_scene
			if scene != null and scene.has_method("nova_set_hour"):
				scene.nova_set_hour(float(data[0]))
		_:
			return false
	return true


## The scatter settings among [param values].
static func _scatter_of(values: Dictionary) -> Dictionary:
	var out := {}
	for key: String in values:
		if key.begins_with("scatter/"):
			out[key] = values[key]
	return out


func _process(delta: float) -> void:
	if _scatter_due >= 0.0:
		_scatter_due -= delta
		if _scatter_due < 0.0:
			_terrain.nova_refresh_scatter()
	_since_camera += delta
	if _since_camera < CAMERA_PERIOD:
		return
	_since_camera = 0.0
	var camera := get_viewport().get_camera_3d()
	var planet := _terrain.get_parent() as Planet
	if camera == null or planet == null:
		return
	var dir := planet.to_local(camera.global_position).normalized()
	if dir.is_equal_approx(_last_dir):
		return
	_last_dir = dir
	EngineDebugger.send_message(CHANNEL + ":camera", [dir, planet.surface_altitude_of(camera.global_position)])
