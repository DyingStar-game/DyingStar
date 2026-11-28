class_name InteriorGiDirector
extends Node
## Bounce light inside buildings without anyone pressing a button: a VoxelGI is baked for a building when the
## camera comes near it (InteriorGi), kept while it stays around, shown only for the nearest few, freed once
## the camera is far. Client only; one per observer (ClientSky.attach). Prototype, OFF unless client.ini
## `debug_interior_gi_auto=true` or the render lab's "Automatic" switch turns it on.
##
## A building is any node that stands on a TerrainPad (every fixed object must have one). They are learnt as
## they enter the tree (SceneTree.node_added), never by walking the whole tree each frame.
##
## Baking is synchronous and costs 0.2 to 0.5 s (garage, town hall, measured 2026-11-27): it is started at
## APPROACH_M, before the player is inside, and at most one per BAKE_GAP_S. A door or an airlock can ask for
## it earlier with prewarm().

## Bake when the camera comes this close to a building's origin, metres.
@export var approach_m: float = 45.0
## Free a building's VoxelGI once the camera is this far, metres (its memory back; it is baked again on return).
@export var forget_m: float = 220.0
## How many baked buildings are shown at once, nearest first: each costs 1 to 1.5 ms of GPU (village bench).
@export var max_active: int = 2
## Seconds between two bakes, so two buildings reached together do not stack their hitches in one frame.
@export var bake_gap_s: float = 0.5

## Switched by client.ini or the render lab; read every tick.
static var auto: bool = false
## The render lab's "VoxelGI on": false hides every baked probe, to compare with and without.
static var shown: bool = true
## Buildings a door or an airlock asked to bake before the camera is near (prewarm()).
static var _wanted: Array[Node3D] = []

const InteriorGiScript := preload("res://scenes/common/interior_gi.gd")
## Seconds between two looks at the distances: buildings do not move under the camera that fast.
const TICK_S := 0.25

var _buildings: Array[Node3D] = []
var _left: float = 0.0
var _gap_left: float = 0.0


## Bake [param building] at the next chance, whatever the distance: for a door or an airlock that opens.
static func prewarm(building: Node3D) -> void:
	if building != null and not building in _wanted:
		_wanted.append(building)


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)
		return
	if ClientConfig.get_bool("debug_interior_gi_auto", false):
		auto = true
		print("[InteriorGi] !! debug_interior_gi_auto=true -- buildings get bounce light on approach (prototype).")
	get_tree().node_added.connect(_on_node_added)
	for pad in get_tree().root.find_children("*", "", true, false):
		_on_node_added(pad)


func _on_node_added(node: Node) -> void:
	if not node is TerrainPad:
		return
	var building := node.get_parent() as Node3D
	if building != null and not building in _buildings:
		_buildings.append(building)


func _process(delta: float) -> void:
	_gap_left -= delta
	_left -= delta
	if _left > 0.0:
		return
	_left = TICK_S
	# Off, it leaves every probe alone: a VoxelGI baked by hand (render lab, bench) is not its to free or hide.
	if not auto:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var near: Array = []  # [distance, building, gi]
	for building: Node3D in _buildings.duplicate():
		if not is_instance_valid(building) or not building.is_inside_tree():
			_buildings.erase(building)
			continue
		# Both positions are ~3e10 m out: subtract them (doubles) before measuring.
		var d := (camera.global_position - building.global_position).length()
		var gi := building.get_node_or_null(NodePath(InteriorGiScript.NODE_NAME)) as VoxelGI
		if gi != null and d > forget_m:
			building.remove_child(gi)
			gi.queue_free()
			continue
		var wanted: bool = building in _wanted
		if gi == null and (d < approach_m or wanted) and _gap_left <= 0.0:
			gi = InteriorGiScript.ensure(building)
			_wanted.erase(building)
			_gap_left = bake_gap_s
		if gi != null:
			near.append([d, building, gi])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in near.size():
		var probe: VoxelGI = near[i][2]
		probe.visible = shown and i < max_active
