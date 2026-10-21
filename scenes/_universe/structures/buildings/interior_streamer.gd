class_name InteriorStreamer
extends Node

## Where something is drawn, the inside of a home exists only near it: an apartment's interior (its
## furniture, bathroom and mirror, the template's "Interior" child) is instanced within LOAD_M of the
## camera and freed past UNLOAD_M. A village has 252 homes and a player sees a handful from the inside;
## the shells -- container, doors, plates -- stay. Headless (the dedicated server, the tests) nothing is
## drawn and every interior stays: the server checks the uses and carries their collisions.
##
## The building takes the interior out of its template room before copying it (take_from), so the
## copies are shells; a building with this streamer then instances them back as the camera nears.

## Distance (m) from the camera to an apartment's middle under which its interior is instanced.
const LOAD_M := 30.0
## Distance (m) over which a loaded interior is freed: a margin, so walking along a wall does not load
## and free the same one in turn.
const UNLOAD_M := 40.0
## Seconds between two looks at a building's apartments.
const CHECK_S := 0.25
## Interiors instanced per frame, all the buildings together: arriving in a village they come one by one.
const PER_FRAME := 1
## The node name an interior takes in its apartment.
const INTERIOR := &"Interior"

static var _frame: int = -1
static var _spent: int = 0

## Called with each apartment whose interior was just instanced (the building shows its state there).
signal loaded(room: Node)

var _scene: PackedScene
var _pose: Transform3D
var _rooms: Node
var _middle: Vector3
var _wait: float = 0.0


## Whether interiors are streamed here: only where something is drawn.
static func wanted() -> bool:
	return DisplayServer.get_name() != "headless"


## Take the interior out of [param template] (before its building copies it) and return the streamer
## that instances it back in the apartments under [param rooms] whose middle -- [param middle], local
## to an apartment -- the camera nears. Null when the template has no interior.
static func take_from(template: Node, rooms: Node, middle: Vector3) -> InteriorStreamer:
	var inside := template.get_node_or_null(NodePath(INTERIOR)) as Node3D
	if inside == null or inside.scene_file_path == "":
		return null
	var streamer := InteriorStreamer.new()
	streamer.name = "InteriorStreamer"
	streamer._scene = load(inside.scene_file_path) as PackedScene
	streamer._pose = inside.transform
	streamer._rooms = rooms
	streamer._middle = middle
	template.remove_child(inside)
	inside.free()
	return streamer


## Whether an apartment's interior should be there, [param loaded_now] or not, [param distance_m] from
## the camera. Pure.
static func wants(loaded_now: bool, distance_m: float) -> bool:
	return distance_m < (UNLOAD_M if loaded_now else LOAD_M)


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = CHECK_S
	var camera := get_viewport().get_camera_3d()
	if camera != null and is_instance_valid(_rooms):
		refresh(camera.global_position)


## Instance or free the interiors for a camera at [param eye] (global).
func refresh(eye: Vector3) -> void:
	for room: Node in _rooms.get_children():
		if not (room is Node3D):
			continue
		var inside: Node = room.get_node_or_null(NodePath(INTERIOR))
		var want: bool = wants(inside != null, eye.distance_to((room as Node3D).global_transform * _middle))
		if inside != null and not want:
			room.remove_child(inside)  # its name is free at once; the node goes at the end of the frame
			inside.queue_free()
		elif inside == null and want and _spend():
			var fresh := _scene.instantiate() as Node3D
			fresh.name = INTERIOR
			fresh.transform = _pose
			room.add_child(fresh)
			loaded.emit(room)


## One instancing of this frame's budget, if any is left.
static func _spend() -> bool:
	var frame: int = Engine.get_process_frames()
	if frame != _frame:
		_frame = frame
		_spent = 0
	if _spent >= PER_FRAME:
		return false
	_spent += 1
	return true
