class_name ShipInteriorRider
extends Area3D

## The ship's cabin as a volume (the Spaceship's InteriorZone). On the SERVER, a player who walks in
## becomes a child of the ship and RIDES it by the tree, and goes back to the frame it came from when it
## walks out. The vehicle lift's platform does the same (platform_area_detection.gd), for the same
## reasons:
## - by the tree, not by friction: a child's LOCAL pose stays constant while the ship flies, so a walker
##   at rest sends nothing and every client carries it with the ship it already smooths (positions go
##   parent-local on the wire, ADR 0005);
## - polled every physics frame from get_overlapping_bodies(), never on body_entered / body_exited: a
##   reparent takes the body out of the space and back in, which fires an exit and an entry of its own.
##   The decision is taken on that STATE, with a grace both ways (grace_step);
## - the ship's layer is struck off the rider's platform_floor_layers, else move_and_slide would add the
##   ship's velocity on top of the tree that already carries it.
## Only the server reparents (ADR 0002); a client runs nothing here (monitoring off, no tick).
##
## What the lift does not need: the ship TURNS. Each frame the riders' velocity turns with it
## (turned_velocity), so a walker or a jumper does not slide when the ship yaws or rolls. The ship's
## accelerations are not felt: the tree carries a rider exactly, at any thrust.
##
## Who rides: a player on foot. A seated one (the pilot) is the seat's, and is left alone meanwhile; a
## player found under the ship untracked (just out of the pilot seat, Spaceship._exit_frame, or brought
## back by a restart or a hand-over) is adopted as riding, and handed back once out of the cabin.

## Physics frames in a row a player must overlap the cabin before it rides: a brush of the ramp's end is
## not boarding.
const ENTER_GRACE_FRAMES: int = 3
## Physics frames in a row a rider must be out of the cabin before it is handed back (the lift's).
const EXIT_GRACE_FRAMES: int = 6

## Player -> {"riding": bool, "count": frames toward the change (grace_step), "from": WeakRef to the
## parent it came from (null: unknown), "floor_layers": its platform_floor_layers before (riding only)}.
var _riders: Dictionary = {}
var _last_basis: Basis = Basis.IDENTITY
var _basis_known: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if GameOrchestrator.is_server():
		monitoring = true  # the scene leaves it off: only the server looks
		process_physics_priority = -1  # before the players' tick: their velocity turns before they move
	else:
		monitoring = false
		set_physics_process(false)


func _physics_process(_delta: float) -> void:
	var ship := get_parent() as Node3D
	if ship == null or not ship.is_inside_tree():
		return
	var now: Basis = ship.global_basis.orthonormalized()
	var before: Basis = _last_basis if _basis_known else now
	_last_basis = now
	_basis_known = true

	var inside: Dictionary = {}
	for body in get_overlapping_bodies():
		if body is Player and _on_foot(body):
			inside[body] = true
			if not _riders.has(body):
				_riders[body] = {"riding": body.get_parent() == ship, "count": 0, "from": null}
				if body.get_parent() == ship:
					_strip_floor(body, ship)
	# Under the ship and on foot, not tracked: adopted as riding (see the header).
	for child in ship.get_children():
		if child is Player and not _riders.has(child) and _on_foot(child):
			_riders[child] = {"riding": true, "count": 0, "from": null}
			_strip_floor(child, ship)

	for body in _riders.keys():
		if not is_instance_valid(body):
			_riders.erase(body)
			continue
		var entry: Dictionary = _riders[body]
		var riding: bool = entry["riding"]
		if not _on_foot(body) or (riding and body.get_parent() != ship):
			_forget(body)  # sat down, lying, or taken elsewhere meanwhile (a teleport): not ours now
			continue
		var step: Dictionary = grace_step(riding, inside.has(body), entry["count"])
		entry["count"] = step["count"]
		if step["riding"] and not riding:
			_board(body, ship)
		elif riding and not step["riding"]:
			_leave(body, ship)
		elif not riding and not inside.has(body):
			_riders.erase(body)  # brushed the cabin and went: nothing to remember
		elif riding and before != now:
			body.velocity = turned_velocity(body.velocity, before, now)


## One physics frame of a player's count toward riding or leaving: [param riding] now, [param inside]
## the cabin this frame, [param count] the frames in a row it has already been on the other side. It
## changes after ENTER_GRACE_FRAMES frames in a row inside (boarding) or EXIT_GRACE_FRAMES outside
## (leaving); a frame back on its own side starts the count again. Returns {"riding", "count"}. Pure.
static func grace_step(riding: bool, inside: bool, count: int) -> Dictionary:
	if riding == inside:
		return {"riding": riding, "count": 0}
	var counted: int = count + 1
	if counted >= (EXIT_GRACE_FRAMES if riding else ENTER_GRACE_FRAMES):
		return {"riding": not riding, "count": 0}
	return {"riding": riding, "count": counted}


## [param velocity] (world frame) turned as the ship turned, from [param before] to [param after] (its
## world bases a frame apart): what was "forward along the deck" still is. Pure.
static func turned_velocity(velocity: Vector3, before: Basis, after: Basis) -> Vector3:
	return (after.orthonormalized() * before.orthonormalized().inverse()) * velocity


## A player on its feet: not in a seat, not lying in a bed, not flying in god mode.
func _on_foot(body: Node) -> bool:
	return not body.piloting and not is_instance_valid(body._seat_node) \
			and not is_instance_valid(body.lying_on) and not body.god_mode


func _board(body: Node, ship: Node3D) -> void:
	var entry: Dictionary = _riders[body]
	entry["riding"] = true
	entry["from"] = weakref(body.get_parent())
	_strip_floor(body, ship)
	body._safe_reparent_and_sync(ship)


func _leave(body: Node, ship: Node3D) -> void:
	var target: Node = _exit_parent(body, ship)
	_forget(body)
	if target != null:
		body._safe_reparent_and_sync(target)


## The rider rides by the tree now: off its floor layers goes the ship's (see the header).
func _strip_floor(body: Node, ship: Node3D) -> void:
	var entry: Dictionary = _riders[body]
	if entry.has("floor_layers"):
		return
	entry["floor_layers"] = body.platform_floor_layers
	body.platform_floor_layers &= ~(ship as CollisionObject3D).collision_layer


func _forget(body: Node) -> void:
	var entry: Dictionary = _riders.get(body, {})
	if entry.has("floor_layers"):
		body.platform_floor_layers = entry["floor_layers"]
	_riders.erase(body)


## Where a rider goes when it walks out: the parent it came from while that is still there and on the
## ship's world (a city left behind on another body is not), else the frame the ship itself lives in.
func _exit_parent(body: Node, ship: Node3D) -> Node:
	var from_ref = _riders.get(body, {}).get("from")
	if from_ref != null:
		var from: Node = from_ref.get_ref()
		if is_instance_valid(from) and from.is_inside_tree() and Planet.of(from) == Planet.of(ship):
			return from
	var frame: Node = PropSpawn.find_net_parent(ship)
	return frame if frame != null else ship.get_parent()
