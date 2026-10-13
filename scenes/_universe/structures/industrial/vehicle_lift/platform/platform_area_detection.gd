extends Area3D
## The lift platform's detection volume. Wakes what stands on the platform (its weight is measured from
## contacts) and, on the SERVER, makes it ride: a player, a prop or a vehicle that steps onto the
## platform becomes a child of the Platform System, and goes back to the parent it came from when it
## steps off.
##
## The Platform System, not the Platform: the Platform is a DYNAMIC body hanging from a spring (that is
## how it weighs its load), and a player is a kinematic body. Parented to the Platform, the player
## pushed it down, the Platform carried the player down with it, the player pushed again: both sank
## together until the player fell through (2026-10-13). The Platform System is moved by the lift's
## script only, so what rides it stands on the Platform by physics, as before, and nothing feeds back.
##
## Riding by the tree, not by friction: the platform runs 180 m down a cliff, and a child's LOCAL pose
## stays constant while it does, so a crate or a player at rest on it sends nothing while the lift moves
## (Horizon moves the descendants of a moving prop itself) and the clients carry it with the platform
## they already smooth.
##
## Polled every physics frame rather than driven by body_entered / body_exited: a reparent takes the
## body out of the physics space and back in, which fires an exit and an entry of its own. A rider is
## let go only after EXIT_GRACE_FRAMES frames in a row outside the volume.

## Physics frames in a row a rider must be outside the volume before it is handed back.
const EXIT_GRACE_FRAMES: int = 6

## Rider body -> {"from": WeakRef to the parent it came from (null: unknown), "miss": frames outside,
## "floor_layers": the player's platform_floor_layers before it boarded (players only)}.
var _riders: Dictionary = {}


func _ready() -> void:
	if GameOrchestrator.is_server():
		if not body_entered.is_connected(_on_body_entered_exited):
			body_entered.connect(_on_body_entered_exited.bind("entered"))
		if not body_exited.is_connected(_on_body_entered_exited):
			body_exited.connect(_on_body_entered_exited.bind("exited"))
	else:
		set_physics_process(false)


## WARNING Passer par une Area ne permet plus de faire réagir le poids à ce qui est réellement en contact :
## Si le joueur saute sur le plateforme, il est toujours dans l'Area, son poids est toujours compté
func _on_body_entered_exited(_body: Node3D, _action: String) -> void:
	for body_inside in get_overlapping_bodies():
		if body_inside is PhysicsBody3D and "sleeping" in body_inside:
			body_inside.sleeping = false

	var platform = get_parent_node_3d() as RigidBody3D
	if platform:
		platform.sleeping = false


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var platform := get_parent_node_3d()
	var carrier := platform.get_parent() if platform != null else null
	if not (carrier is Node3D):
		return
	var inside: Dictionary = {}
	for body in get_overlapping_bodies():
		if _can_ride(body, platform, carrier):
			inside[body] = true

	# Boarding. A body already under the carrier that we do not track (loaded that way after a
	# restart) is adopted, with the lift's frame to go back to.
	for body in inside:
		if _riders.has(body):
			_riders[body]["miss"] = 0
		elif body.get_parent() == carrier:
			_track(body, null)
		else:
			_track(body, body.get_parent())
			_move_to(body, carrier)

	# Leaving. Riders taken elsewhere meanwhile (sat in a truck, picked up) are only forgotten.
	for body in _riders.keys():
		if not is_instance_valid(body):
			_riders.erase(body)
			continue
		if body.get_parent() != carrier:
			_forget(body)
			continue
		if inside.has(body):
			continue
		_riders[body]["miss"] += 1
		if _riders[body]["miss"] >= EXIT_GRACE_FRAMES:
			_move_to(body, _exit_parent(body, platform))
			_forget(body)

	# Children of the carrier nobody tracks and that are not on the platform (persisted under it,
	# then the platform moved away): hand them back too. The Platform and the carrier's own parts
	# (Cart) are not riders.
	for child in carrier.get_children():
		if child != platform and child is PhysicsBody3D and not _riders.has(child) \
				and not inside.has(child) and child.owner != carrier and _is_rider_kind(child):
			_move_to(child, _exit_parent(child, platform))


## A body that may ride: a player on foot, a networked prop or a vehicle, not part of the lift itself,
## and not already riding something else (carried by a player, seated or loaded in a truck).
func _can_ride(body: Node, platform: Node, carrier: Node) -> bool:
	if body == platform or body == carrier or not (body is PhysicsBody3D) or not _is_rider_kind(body):
		return false
	var parent := body.get_parent()
	if parent == carrier:
		return true
	if PropNet.rides_parent(body as Node3D):
		return false
	var lift := _lift_of(platform)
	return lift == null or not lift.is_ancestor_of(body)


func _is_rider_kind(body: Node) -> bool:
	return body is Player or "uuid" in body or PropSync.of(body) != null


func _track(body: Node, from: Node) -> void:
	var entry := {"from": weakref(from) if from != null else null, "miss": 0}
	if body is Player:
		# The player rides by the tree now. Left in its floor layers, move_and_slide would also add the
		# platform's velocity: carried twice, it would sink into the deck going down.
		var platform := get_parent_node_3d() as CollisionObject3D
		entry["floor_layers"] = body.platform_floor_layers
		body.platform_floor_layers &= ~platform.collision_layer
	_riders[body] = entry


func _forget(body: Node) -> void:
	var entry: Dictionary = _riders[body]
	if body is Player and entry.has("floor_layers"):
		body.platform_floor_layers = entry["floor_layers"]
	_riders.erase(body)


## Where a rider goes when it steps off: the parent it came from while it is still there, else the
## frame the lift itself stands in.
func _exit_parent(body: Node, platform: Node) -> Node:
	var entry: Dictionary = _riders.get(body, {})
	var from_ref = entry.get("from")
	if from_ref != null:
		var from: Node = from_ref.get_ref()
		if is_instance_valid(from) and from.is_inside_tree():
			return from
	var lift := _lift_of(platform)
	return PropSpawn.find_net_parent(lift if lift != null else platform)


## SERVER: put [param body] under [param parent], keeping where it is, through the path its kind
## replicates from (the player's move, the prop's or the vehicle's own tick reading the tree).
func _move_to(body: Node, parent: Node) -> void:
	if parent == null or body.get_parent() == parent or not parent.is_inside_tree():
		return
	if body is Player:
		body._safe_reparent_and_sync(parent)
		return
	var net := PropSync.of(body)
	if net != null:
		net.server_parent_change(parent)
	else:
		body.reparent(parent)
	# A resting body skips its replication tick: wake it so the new parent_id goes out.
	if body is RigidBody3D and not (body as RigidBody3D).freeze:
		(body as RigidBody3D).sleeping = false


func _lift_of(platform: Node) -> Node:
	var node := platform.get_parent()
	while node != null and not (node is VehicleLift):
		node = node.get_parent()
	return node
