class_name CarryPlacement
extends RefCounted

## Where a carried crate would be PUT DOWN right now — the single source of truth behind both the
## white placement disc the owner sees (drawn client-side every physics frame so it has no network
## latency) and the server's authoritative drop. GDScript statics, no state, like PropNet: the client
## and the server run the exact same resolution on their own copy of the world, so what the player
## aims at is what the server places.
##
## The resolved `position` is where the crate's UNDERSIDE lands (its footprint centre), so a caller
## only has to lift the body by its own half-height along `normal`.
##
## Resolution always succeeds: the aim ray either hits a surface within RAY_LENGTH, or the disc hangs
## flat in mid-air at the end of the ray (`on_surface` false) and the dropped crate simply falls from
## there. There is no "nothing to aim at" case, so E always drops and the player can never be stuck
## holding a crate.

## How far ahead of the eye the placement ray reaches (m). Short on purpose: you place things at
## arm's length, you don't fling them across the room.
const RAY_LENGTH := 2.0
## Attract tolerance (m): a candidate feature (top face of another crate, a side-by-side neighbour, a
## free shelf slot) this close to the raw hit swallows the disc, so crates stack and line up cleanly
## instead of landing at whatever arbitrary point the crosshair happened to be on.
const SNAP_DIST := 0.30
## Only crates whose origin is within this distance (m) of the raw hit are considered for snapping —
## keeps the per-frame candidate scan to the handful of props actually around the aim point.
const SNAP_SEARCH := 1.5

## Resolve the placement under the crosshair. [param eye] is the camera pivot's global transform
## (-Z = gaze), [param up] the player's up_direction, [param exclude] the RIDs to ignore (the player
## and the crate it holds), [param held] the carried body (its footprint drives the neighbour snap;
## may be null). Must be called from the physics step — direct_space_state is null outside it.
##
## Returns {position: Vector3, normal: Vector3, on_surface: bool, snapped: bool, shelf: Node}.
static func resolve(space: PhysicsDirectSpaceState3D, eye: Transform3D, up: Vector3,
		exclude: Array[RID], tree: SceneTree, held: Node3D) -> Dictionary:
	var from: Vector3 = eye.origin
	var to: Vector3 = from - eye.basis.z * RAY_LENGTH
	# Default = the free-air end of the ray, lying flat. Every early-out below keeps this.
	var result: Dictionary = {
		"position": to, "normal": up, "on_surface": false, "snapped": false, "shelf": null,
	}
	if space == null:
		return result
	var query := PhysicsRayQueryParameters3D.create(from, to, Globals.MASK_OBSTACLE, exclude)
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return result
	var pos: Vector3 = hit["position"]
	# Float32 artefact guard (same reason as PropSpawn.ground_point): at this project's astronomic
	# coordinates the ray origin is imprecise in Jolt's narrowphase, so a ray can "catch" a collider
	# far away. A hit well beyond the ray's own length is nonsense — treat it as a miss.
	if pos.distance_to(from) > RAY_LENGTH * 1.5:
		return result
	result["position"] = pos
	result["normal"] = (hit["normal"] as Vector3).normalized()
	result["on_surface"] = true
	_snap(result, tree, held)
	return result

## Pull the disc onto the nearest snap candidate within SNAP_DIST of the raw hit, in place. Only runs
## for a hit on a real surface — there is nothing to line up against in mid-air.
static func _snap(result: Dictionary, tree: SceneTree, held: Node3D) -> void:
	if tree == null:
		return
	var raw: Vector3 = result["position"]
	var best: Vector3 = raw
	var best_normal: Vector3 = result["normal"]
	var best_dist: float = SNAP_DIST
	var best_shelf: Node = null
	# The held crate's own footprint: how far to the side a neighbour candidate sits, and how far
	# below a shelf slot's centre its underside is.
	var held_size := Vector3.ZERO
	if held != null:
		held_size = Globals.collision_aabb(held, Transform3D.IDENTITY).size

	# Candidate set 1 — other crates: their TOP FACE (stack on it) and the four SIDE-BY-SIDE spots on
	# the plane the crate itself rests on (line up next to it).
	for node in tree.get_nodes_in_group("carriable"):
		if node == held or not (node is Node3D) or not is_instance_valid(node):
			continue
		var body := node as Node3D
		if body.global_position.distance_to(raw) > SNAP_SEARCH:
			continue
		var bounds := Globals.collision_aabb(body, Transform3D.IDENTITY)
		if bounds.size == Vector3.ZERO:
			continue
		var xform: Transform3D = body.global_transform
		var mid: Vector3 = bounds.get_center()
		var top: Vector3 = xform * Vector3(mid.x, bounds.end.y, mid.z)
		var base: Vector3 = xform * Vector3(mid.x, bounds.position.y, mid.z)
		var step_x: float = (bounds.size.x + (held_size.x if held_size.x > 0.0 else bounds.size.x)) * 0.5
		var step_z: float = (bounds.size.z + (held_size.z if held_size.z > 0.0 else bounds.size.z)) * 0.5
		var candidates: Array[Vector3] = [
			top,
			base + xform.basis.x * step_x, base - xform.basis.x * step_x,
			base + xform.basis.z * step_z, base - xform.basis.z * step_z,
		]
		for point in candidates:
			var dist: float = point.distance_to(raw)
			if dist < best_dist:
				best_dist = dist
				best = point
				best_normal = xform.basis.y.normalized()  # sit the same way up as the crate we align to
				best_shelf = null

	# Candidate set 2 — free shelf slots. A slot marks the crate's CENTRE (see shelf.store_at_nearest_slot),
	# so lower it by half the held crate to keep `position` meaning "where the underside lands".
	for node in tree.get_nodes_in_group("shelf"):
		if not (node is Node3D) or not is_instance_valid(node) or not ("shelf_slots" in node):
			continue
		var shelf := node as Node3D
		var slots: Array = shelf.shelf_slots
		var occupied: Array = shelf.shelf_slots_occupied if "shelf_slots_occupied" in shelf else []
		var shelf_up: Vector3 = shelf.global_basis.y.normalized()
		for i in slots.size():
			if i < occupied.size() and bool(occupied[i]):
				continue
			var point: Vector3 = shelf.to_global(slots[i]) - shelf_up * (held_size.y * 0.5)
			var dist: float = point.distance_to(raw)
			if dist < best_dist:
				best_dist = dist
				best = point
				best_normal = shelf_up
				best_shelf = shelf

	result["position"] = best
	result["normal"] = best_normal
	result["snapped"] = best != raw
	result["shelf"] = best_shelf

## Orthonormal basis standing on a surface: +Y along `normal`, facing where `spin` (the carry
## orientation) was pointing. Same convention as Globals.align_with_y, but it also survives the case
## that one degenerates on — a normal parallel to the reference facing, i.e. any wall.
static func surface_basis(spin: Basis, normal: Vector3) -> Basis:
	var y: Vector3 = normal.normalized()
	if y.length_squared() < 0.5:
		y = Vector3.UP
	# The facing to keep. Against a wall it ends up parallel to the normal and says nothing about the
	# spin around it, so fall back to the crate's own up — never parallel to its own -Z.
	var facing: Vector3 = spin.z
	if absf(facing.dot(y)) > 0.99:
		facing = spin.y
	var x: Vector3 = (-facing.cross(y)).normalized()
	return Basis(x, y, x.cross(y))

## Seat a body so its underside rests on a resolved placement, keeping the carry orientation about
## the surface normal. Returns the transform to assign to the body's global_transform. In mid-air
## (`on_surface` false) the body is CENTRED on the point instead and simply falls from there.
static func seat(body: Node3D, result: Dictionary, carry_basis: Basis) -> Transform3D:
	var basis: Basis = surface_basis(carry_basis, result["normal"])
	var bounds := Globals.collision_aabb(body, Transform3D.IDENTITY)
	var mid: Vector3 = bounds.get_center()
	var seat_local := Vector3(mid.x, bounds.position.y if bool(result["on_surface"]) else mid.y, mid.z)
	return Transform3D(basis, (result["position"] as Vector3) - basis * seat_local)

## Radius (m) of the placement disc for [param body]: half its WIDEST footprint side, i.e. the circle
## INSCRIBED in the crate's footprint — the disc is then as wide as the crate itself. (Using the
## half-diagonal instead circumscribes it and the disc visibly overhangs all four corners.) Falls back
## to a sane default for a shapeless body.
static func disc_radius(body: Node3D) -> float:
	if body == null:
		return 0.2
	var size := Globals.collision_aabb(body, Transform3D.IDENTITY).size
	if size == Vector3.ZERO:
		return 0.2
	return maxf(size.x, size.z) * 0.5
