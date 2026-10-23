@tool
class_name FixtureSpawn
extends Marker3D

## SERVER: a networked prop that belongs in a building from the start (the garage's pallet transporter),
## handed to the network once, here, by MarkerSpawn. Its uuid is drawn from the building's and this
## marker's name, so it is the same on every boot: a prop the server already knows (moved since, or
## asleep far away) is left where it is, and none ever piles up. Clients do nothing; the editor shows
## the prop where it will stand (a preview, never saved), so it is placed by eye.
##
## Never put a networked prop straight into a building's scene instead: it gets no uuid, so the server
## and every client each keep their own copy, and a push on one is seen by no one else.

## The networked prop placed here: a scene whose PropSync names its network type.
@export var scene: PackedScene:
	set(value):
		scene = value
		if Engine.is_editor_hint() and is_inside_tree():
			_show_preview()

const PREVIEW := "Preview"


func _ready() -> void:
	if Engine.is_editor_hint():
		_show_preview()
		return
	if not GameOrchestrator.is_server():
		return
	# Deferred: the building is given its uuid and registered right after it enters the tree.
	_spawn_once.call_deferred()


func _spawn_once() -> void:
	var building: Node = MarkerSpawn.building_of(self)
	var agent: Node = NetworkOrchestrator.network_agent
	if building == null or scene == null or agent == null:
		return
	var uuid: String = uuid_for(PropSync.of(building).uuid, name)
	if agent.prop_registry.has(uuid):
		return
	MarkerSpawn.spawn(scene, MarkerSpawn.scene_type(scene), self, uuid)


## EDITOR: the prop drawn at the marker, frozen, owned by no one so it is never saved in the scene.
func _show_preview() -> void:
	var old: Node = get_node_or_null(PREVIEW)
	if old != null:
		old.free()
	if scene == null:
		return
	var preview: Node = scene.instantiate()
	preview.name = PREVIEW
	if preview is RigidBody3D:
		(preview as RigidBody3D).freeze = true
	add_child(preview)


## The uuid of the prop of marker [param marker_name] in the building [param building_uuid]: the same on
## every boot, different in every building.
static func uuid_for(building_uuid: String, marker_name: String) -> String:
	return PropSpawn.stable_uuid("%s|%s" % [building_uuid, marker_name])
