extends Node
## Files the instances around the camera again in the renderer's spatial index after every step of the
## body the player stands on, so the lamps keep their shadows. Client-only, one instance, a child of
## the local player (built by PlayerClient.setup), beside LampShadowBudget.
##
## WHY. The engine keeps every instance in a tree (DynamicBVH) and, when one moves, skips the update
## if its new box "is_equal_approx" the old one. That tolerance is RELATIVE: 1e-5 of the coordinate.
## A planet sits tens of millions of km from the star, so out there it is hundreds of km wide, and a
## step of the planet (Planet.rotation_update_hz: its spin, and its orbit with it) moves everything it
## carries by ~137 km at once -- under the tolerance on most of the orbit. The tree then keeps the
## instances where they WERE. The camera and the star's shadows never ask the tree (they walk a flat
## list), so nothing shows... except under a lamp: an Omni, Spot or Area light finds what casts its
## shadow THROUGH the tree, finds nothing where it now stands, and draws an empty shadow until later
## steps add up to more than the tolerance. Measured 2026-11-18 on Tarsis 3, frame by frame: 472
## objects in the shadow passes after one step, 0 after the next, and so on -- the lamps' shadows
## switching every 4 s -- with 118 instances near the camera filed 137 km behind it.
##
## HOW. Hiding an instance on the RenderingServer takes it out of the tree and showing it files it
## again from its current box. So after each step, every instance the tree still holds around where
## the camera stood BEFORE that step (found by asking the tree itself) is hidden and shown at once:
## the nodes are not touched and nothing blinks. Measured in a town: 6 890 instances within 160 m in
## 7 to 15 ms, once per step, and not one empty shadow over the steps that followed.
##
## A WORKAROUND for the engine: an exact comparison in DynamicBVH::update makes this node useless.
## It mends the steps only. An instance that moves between two steps (a walking player, a truck)
## still keeps its old place in the tree until the next one.

## The engine's tolerance (CMP_EPSILON in core/math/math_defs.h), relative to the coordinate.
const ENGINE_TOLERANCE := 1e-5
## Head room over the engine's tolerance when deciding that the tree has surely caught up.
const TOLERANCE_MARGIN := 1.1
## Steps remembered at most. One that far back has been filed again by the engine or by this node.
const MAX_HISTORY := 16
## Least time (s) between two refiles, so a body stepped many times a second does not cost a refile
## per frame: the steps in between are remembered and mended together.
const MIN_INTERVAL_S := 0.25

## Half-side (m) of the box around the camera whose instances are filed again after a step. It has to
## hold what the nearby lamps reach (a headlight carries 150 m): raise it and farther casters keep
## their shadow, at more cost per step -- about 7 000 instances and 7 to 15 ms at 160 m in a town.
@export var radius_m: float = 160.0

var _body: Node3D = null
var _body_xform: Transform3D = Transform3D.IDENTITY
## Where the body stood before each of its last steps, newest first.
var _history: Array[Transform3D] = []
var _pending: bool = false
var _since_refile_s: float = MIN_INTERVAL_S


func _ready() -> void:
	# Measurement switch: the engine alone, as before this node.
	if ClientConfig.get_bool("debug_no_render_index_refresh", false):
		print("[RenderIndexRefresh] !! debug_no_render_index_refresh=true — lamp shadows come and go with the planet's steps.")
		set_process(false)


func _process(delta: float) -> void:
	_since_refile_s += delta
	var body: Node3D = carrying_body(get_parent())
	if body != _body:
		# Another body (or none): what was remembered belongs to the one just left.
		_body = body
		_history.clear()
		_pending = false
		if body != null:
			_body_xform = body.global_transform
		return
	if body == null:
		return
	var now: Transform3D = body.global_transform
	if now != _body_xform:
		_history.push_front(_body_xform)
		if _history.size() > MAX_HISTORY:
			_history.resize(MAX_HISTORY)
		_body_xform = now
		_pending = true
	if not _pending or _since_refile_s < MIN_INTERVAL_S:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	_pending = false
	_since_refile_s = 0.0
	var centres: PackedVector3Array = stale_centres(_history, now, camera.global_position)
	# A step the engine has surely seen needs no memory: the tree is right from there on back.
	_history.resize(centres.size())
	if centres.is_empty():
		return
	var token: int = ClientPerf.scope_begin()
	var refiled: int = _refile(centres)
	ClientPerf.scope_end("render_index_refresh", token)
	ClientPerf.gauge("render_index_refiled", refiled)


## The body that carries [param node] through space: the nearest Planet above it (a moon before its
## planet), or null in open space.
static func carrying_body(node: Node) -> Node3D:
	while node != null:
		if node is Planet:
			return node as Node3D
		node = node.get_parent()
	return null


## How far (m) a point at [param position] may have moved with the tree still holding it at its old
## place. The engine skips an update when EVERY axis moved less than 1e-5 of its coordinate, so no
## skipped move is longer than 1e-5 of the distance to the origin.
static func tolerance_m(position: Vector3) -> float:
	return TOLERANCE_MARGIN * ENGINE_TOLERANCE * position.length()


## Where the tree may still hold what stands around [param eye]: the same spot on the body as it was
## before each remembered step ([param history], newest first), as long as that is within the
## engine's tolerance of [param eye]. [param now] is the body's transform today. Stops at the first
## step too far back: the engine has filed everything again since.
static func stale_centres(history: Array[Transform3D], now: Transform3D, eye: Vector3) -> PackedVector3Array:
	var centres := PackedVector3Array()
	var on_body: Vector3 = now.affine_inverse() * eye
	var reach: float = tolerance_m(eye)
	for was: Transform3D in history:
		var centre: Vector3 = was * on_body
		if centre.distance_to(eye) > reach:
			break
		centres.append(centre)
	return centres


## Takes every instance the tree holds around [param centres] out of it and back in, each one once
## (the boxes of two steps overlap when the body barely moved). Returns how many.
func _refile(centres: PackedVector3Array) -> int:
	var world: World3D = get_viewport().find_world_3d()
	if world == null:
		return 0
	var half := Vector3.ONE * radius_m
	var found: Dictionary = {}
	for centre: Vector3 in centres:
		for id: int in RenderingServer.instances_cull_aabb(AABB(centre - half, half * 2.0), world.scenario):
			found[id] = true
	var refiled: int = 0
	for id: int in found:
		var instance := instance_from_id(id) as VisualInstance3D
		if instance == null:
			continue
		var rid: RID = instance.get_instance()
		RenderingServer.instance_set_visible(rid, false)
		RenderingServer.instance_set_visible(rid, instance.is_visible_in_tree())
		refiled += 1
	return refiled
