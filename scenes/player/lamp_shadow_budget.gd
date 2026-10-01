class_name LampShadowBudget
extends Node
## Shadow budget for the LAMPS of the world: the ceiling spots of the spawn apartments, the LED panels
## of the cargo depot, every Omni / Spot / AreaLight3D a scene was authored with a shadow. Client-only,
## one instance, a child of the local player (built by PlayerClient.setup), beside TorchShadowBudget,
## which keeps the avatars' torches.
##
## Every shadowed lamp needs a place in the positional shadow atlas, and the atlas has a fixed number
## (88 with the engine's quadrant subdivisions). The spawn rows and the depot together hold far more,
## so the lamps took turns: whichever lost its place lost its shadow until the next allocation, and the
## far lamps blinked. Every shadow is also a whole depth pass of what its light reaches. Measured at the
## spawn with the lamps on (RTX 3090, 3440x1400): 52 -> 60 fps with this budget. (The NEAR lamps blinked
## for another reason, the planet's spin steps: see Planet.rotation_update_hz.)
##
## Twice a second, the shadowed lamps within `max_distance` of the camera are ranked by distance and
## only the `max_shadows` nearest keep their shadow; every other lamp still LIGHTS, it just casts
## nothing. A lamp holding a shadow is ranked `hysteresis_m` closer than it is, so two lamps at the same
## distance do not trade the shadow back and forth as the player moves.
##
## Two kinds of light are never ranked against the lamps: the player's own torch (an avatar's light,
## left to TorchShadowBudget, which never touches the owner's), and the lights of the vehicle the player
## sits in — they keep their shadow whatever the count, on top of the budget.

const INTERVAL : float = 0.5
## Marks a lamp authored with a shadow: once the budget has switched its shadow off, the flag alone no
## longer says so (a lamp reparented, a crate carried, comes back through node_added without it).
const META_AUTHORED : StringName = &"_lamp_shadow_authored"

## How many lamps may cast a shadow at once. Well under the atlas, so it is never full.
@export var max_shadows : int = 8
## Beyond this distance from the camera (m) a lamp never casts: its shadow is a few pixels from there.
@export var max_distance : float = 60.0
## The head start a lamp that already casts keeps over a challenger, in metres.
@export var hysteresis_m : float = 3.0

var _lamps : Dictionary = {}
var _elapsed : float = INTERVAL  # evaluate on the first frame, then every INTERVAL


func _ready() -> void:
	# Measurement switch: every lamp keeps the shadow it was authored with, as before this budget.
	if ClientConfig.get_bool("debug_no_lamp_budget", false):
		print("[LampShadowBudget] !! debug_no_lamp_budget=true — every lamp casts, the atlas may be full.")
		set_process(false)
		return
	for node in get_tree().root.find_children("*", "Light3D", true, false):
		_consider(node)
	get_tree().node_added.connect(_consider)
	get_tree().node_removed.connect(func(node: Node) -> void: _lamps.erase(node))


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < INTERVAL:
		return
	_elapsed = 0.0
	_evaluate()


## The lamps currently ranked (for the debug readouts and the tests).
func lamp_count() -> int:
	return _lamps.size()


func _consider(node: Node) -> void:
	if not node is Light3D or node is DirectionalLight3D:
		return
	if not ((node as Light3D).shadow_enabled or node.has_meta(META_AUTHORED)):
		return
	if _on_an_avatar(node):
		return  # the torches belong to TorchShadowBudget (and the owner's own keeps its shadow)
	node.set_meta(META_AUTHORED, true)
	_lamps[node] = true


func _evaluate() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye : Vector3 = cam.global_position
	var vehicle : Node = _seated_vehicle()
	var ranked : Array = []  # [score, lamp]
	for lamp : Variant in _lamps.keys():
		if not is_instance_valid(lamp):
			_lamps.erase(lamp)
			continue
		var light := lamp as Light3D
		if not light.is_visible_in_tree():
			continue  # off: it costs nothing whatever its flag; ranked again when it lights up
		if vehicle != null and vehicle.is_ancestor_of(light):
			light.shadow_enabled = true
			continue
		var d : float = eye.distance_to(light.global_position)
		if d > max_distance:
			light.shadow_enabled = false
			continue
		ranked.append([d - (hysteresis_m if light.shadow_enabled else 0.0), light])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in ranked.size():
		var keep : bool = i < max_shadows
		if ranked[i][1].shadow_enabled != keep:
			ranked[i][1].shadow_enabled = keep


## The vehicle the local player (this node's parent) sits in, or null on foot.
func _seated_vehicle() -> Node:
	var player := get_parent() as Player
	if player == null or not is_instance_valid(player._seat_node):
		return null
	var node : Node = player._seat_node
	while node != null and not node is VehicleBody3D:
		node = node.get_parent()
	return node


static func _on_an_avatar(node: Node) -> bool:
	var parent : Node = node.get_parent()
	while parent != null:
		if parent is Player:
			return true
		parent = parent.get_parent()
	return false
