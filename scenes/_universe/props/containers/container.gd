class_name StorageContainer
extends Node3D

## A storage container: any carriable prop that comes to REST inside its interior volume is FROZEN in
## place — magnetically locked to the floor, so a player or another crate (carried or not) can't knock it
## around. Same idea as a truck's cargo bed, but standalone.
##
## The container is STATIC for now, so the prop is frozen in the WORLD (planet) frame — which Horizon
## already tracks — WITHOUT reparenting it. That keeps it inside the (static) container and replicates
## for free. When containers become movable, the contents will instead be reparented UNDER the container
## (like bed cargo) so they ride it — which needs the container to be a Horizon-tracked frame; not now.
##
## Picking a prop up (E) un-freezes it (the carry sets freeze = false), so it becomes carriable again with
## no extra release step. Setup: put this script on the container root, with an Area3D somewhere inside
## covering the INTERIOR volume (auto-found, or assign `interior`).

const _SCAN_FRAMES := 8  # throttle: scan the interior every N physics ticks

## Interior volume: props that settle inside it get locked. Auto-found (first Area3D descendant) if unset.
@export var interior: Area3D
## Below this linear speed (m/s) a prop counts as "settled" (resting on the floor) and gets locked.
@export var settle_speed: float = 0.4

var _scan_tick: int = 0

func _ready() -> void:
	add_to_group("container")
	if interior == null:
		interior = _find_area(self)

## Server only: scan the interior for settled, un-carried props and freeze them in place. Runs on this
## node's own _physics_process, like the truck's bay scan.
func _physics_process(_delta: float) -> void:
	if not GameOrchestrator.is_server() or interior == null:
		return
	_scan_tick += 1
	if _scan_tick < _SCAN_FRAMES:
		return
	_scan_tick = 0
	var cs := _interior_shape()
	if cs == null or cs.shape == null:
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cs.shape
	q.transform = cs.global_transform
	q.collision_mask = 1 << (Globals.LAYER_PROP - 1)  # crates/props only (not the walls or the player)
	q.collide_with_bodies = true
	for hit in space.intersect_shape(q, 16):
		var body = hit.get("collider")
		if not (body is RigidBody3D):
			continue
		var rb := body as RigidBody3D
		if rb.freeze or rb.get("carried") == true:
			continue  # already locked, or in someone's hands
		if rb.linear_velocity.length() > settle_speed:
			continue  # still moving / bouncing — not settled yet
		if not _rests_on_support(rb, space):
			continue  # held up by a wall or the SIDE of a crate (not the floor) — let it keep falling
		# Freeze it where it rests: STATIC = immovable, so players and other crates bump it without
		# shifting it. It stays parented to the planet frame (Horizon-known), so it replicates and stays
		# inside this (static) container. The carry un-freezes it on pickup.
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		rb.freeze = true

## True only if the body is SUPPORTED FROM BELOW — a floor or a settled crate directly under its
## underside — rather than hanging in the air against a wall or the side of another crate. We find the
## body's real BOTTOM (its collision AABB, so this is right whatever its height or where its origin sits)
## and cast a SHORT ray straddling it: a solid only just below the underside = actually resting. A tall
## crate floating against a wall has a gap under it, so the short ray misses and it keeps falling.
func _rests_on_support(rb: RigidBody3D, space: PhysicsDirectSpaceState3D) -> bool:
	var ab := _body_local_aabb(rb)
	if ab.size == Vector3.ZERO:
		return true  # no shape info to test with: don't block the freeze
	var c := ab.get_center()
	var bottom_world: Vector3 = rb.global_transform * Vector3(c.x, ab.position.y, c.z)  # underside centre
	var up: Vector3 = global_transform.basis.y
	var mask := (1 << (Globals.LAYER_WORLD - 1)) | (1 << (Globals.LAYER_VEHICLE - 1)) \
			| (1 << (Globals.LAYER_PROP - 1))
	var rq := PhysicsRayQueryParameters3D.create(bottom_world + up * 0.10, bottom_world - up * 0.12, \
			mask, [rb.get_rid()])
	return not space.intersect_ray(rq).is_empty()

## Local-space AABB of the body's OWN collision shapes — used to find its underside for the support test.
func _body_local_aabb(rb: RigidBody3D) -> AABB:
	var merged := AABB()
	var has := false
	for owner_id in rb.get_shape_owners():
		var xf: Transform3D = rb.shape_owner_get_transform(owner_id)
		for i in rb.shape_owner_get_shape_count(owner_id):
			var shape := rb.shape_owner_get_shape(owner_id, i)
			if shape == null:
				continue
			var box: AABB = xf * shape.get_debug_mesh().get_aabb()
			merged = merged.merge(box) if has else box
			has = true
	return merged

func _interior_shape() -> CollisionShape3D:
	if interior == null:
		return null
	for c in interior.get_children():
		if c is CollisionShape3D:
			return c
	return null

static func _find_area(n: Node) -> Area3D:
	for c in n.get_children():
		if c is Area3D:
			return c as Area3D
		var nested := _find_area(c)
		if nested != null:
			return nested
	return null
