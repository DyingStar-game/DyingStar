class_name LampShadowBudget
extends Node
## Shadow budget for the LAMPS of the world: the ceiling spots of the spawn apartments, the LED panels
## of the cargo depot, the street lamps -- every Omni / Spot / AreaLight3D placed in a scene. Client-only,
## one instance, a child of the local player (built by PlayerClient.setup), beside TorchShadowBudget,
## which keeps the avatars' torches.
##
## Every shadowed lamp needs a place in the positional shadow atlas, and the atlas has a fixed number
## (88 with the engine's quadrant subdivisions). The spawn rows and the depot together hold far more,
## so the lamps took turns: whichever lost its place lost its shadow until the next allocation, and the
## far lamps blinked. Every shadow is also a whole depth pass of what its light reaches. Measured at the
## spawn with the lamps on (RTX 3090, 3440x1400): 52 -> 60 fps with this budget. (The NEAR lamps blinked
## for another reason, the planet's steps: an engine bug fixed by our build, see Planet.rotation_update_hz.)
##
## Twice a second, the lamps within `max_distance` of the camera are ranked by distance and only the
## `max_shadows` nearest cast a shadow; every other lamp still LIGHTS, it just casts nothing. A lamp
## holding a shadow is ranked `hysteresis_m` closer than it is, so two lamps at the same distance do not
## trade the shadow back and forth as the player moves.
##
## WHICH lamps are ranked is not left to the "Shadow" box of each light: a lamp placed in a scene is
## ranked whether its author ticked it or not. The street lamps never had it ticked, for the cost, and
## cast nothing at any distance (playtest 2026-11-20); the cost is this budget's to bound, and
## `max_distance` is the one setting for all of them, the player's (Graphics > Shadows). A scene light
## that must never cast -- a rotating beacon, a vehicle's position lights -- goes in the group
## [constant NO_SHADOW_GROUP]. A light made by CODE keeps what its script gave it: a neon's glow, a
## spark, a cave's fill light are built without a shadow on purpose.
##
## Two kinds of light are never ranked against the lamps: the player's own torch (an avatar's light,
## left to TorchShadowBudget, which never touches the owner's), and the lights of the vehicle the player
## sits in that were authored with a shadow -- its headlights keep it whatever the count, on top of the
## budget.

const INTERVAL : float = 0.5
## Marks a lamp authored with a shadow: once the budget has switched its shadow off, the flag alone no
## longer says so (a lamp reparented, a crate carried, comes back through node_added without it).
const META_AUTHORED : StringName = &"_lamp_shadow_authored"
## Marks a scene lamp authored WITHOUT one, for the same reason the other way round: holding a shadow
## the budget gave it, it would come back looking authored with it.
const META_GIVEN : StringName = &"_lamp_shadow_given"
## A scene light in this group never casts and is never ranked.
const NO_SHADOW_GROUP : StringName = &"no_lamp_shadow"
## The graphics option `max_distance` follows (GraphicsOptions).
const DISTANCE_OPTION : String = "lamp_shadow_distance"

## How many lamps may cast a shadow at once. Well under the atlas, so it is never full.
@export var max_shadows : int = 8
## Beyond this distance from the camera (m) a lamp never casts: its shadow is a few pixels from there.
## Zero: no lamp casts at all. The player's option when `distance_option` names one.
@export var max_distance : float = 60.0
## The head start a lamp that already casts keeps over a challenger, in metres.
@export var hysteresis_m : float = 3.0
## The graphics option that sets `max_distance`, followed as the player changes it. Empty: the value
## above stands (the tests, a scene with no player settings).
@export var distance_option : String = DISTANCE_OPTION

## lamp -> whether it was authored with a shadow.
var _lamps : Dictionary = {}
var _elapsed : float = INTERVAL  # evaluate on the first frame, then every INTERVAL


func _ready() -> void:
	# Measurement switch: every lamp keeps the shadow it was authored with, as before this budget.
	if ClientConfig.get_bool("debug_no_lamp_budget", false):
		print("[LampShadowBudget] !! debug_no_lamp_budget=true — every lamp casts, the atlas may be full.")
		set_process(false)
		return
	if distance_option != "":
		max_distance = float(SettingsManager.render.effective(distance_option))
		SettingsManager.render.changed.connect(_on_options_changed)
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


func _on_options_changed(keys: PackedStringArray) -> void:
	if distance_option in keys:
		max_distance = float(SettingsManager.render.effective(distance_option))
		_elapsed = INTERVAL  # seen on the next frame, not half a second after the slider


func _consider(node: Node) -> void:
	if not node is Light3D or node is DirectionalLight3D:
		return
	var light := node as Light3D
	if light.is_in_group(NO_SHADOW_GROUP) or _on_an_avatar(light):
		return  # the torches belong to TorchShadowBudget (and the owner's own keeps its shadow)
	var given : bool = light.has_meta(META_GIVEN)  # known already: moved out of its scene, it has no owner
	var authored : bool = light.has_meta(META_AUTHORED) or (light.shadow_enabled and not given)
	if not authored and not given and light.owner == null:
		return  # made by code, without a shadow: its script decided
	if light.get_world_3d() != get_viewport().world_3d:
		return  # a lamp of another world (a preview, a map): no distance to our camera means anything
	light.set_meta(META_AUTHORED if authored else META_GIVEN, true)
	_lamps[light] = authored


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
		if max_distance <= 0.0:
			light.shadow_enabled = false  # the player wants none: the vehicle's included
			continue
		if vehicle != null and bool(_lamps[lamp]) and vehicle.is_ancestor_of(light):
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
