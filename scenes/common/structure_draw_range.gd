class_name StructureDrawRange
extends RefCounted
## Gives buildings a draw distance, driven by Graphics > Roads, rails and buildings distance.
##
## Called from the ONE place every networked object is instantiated (server/client.gd), beside
## TerrainBlend.attach_to — so a building added to the registry tomorrow is covered with no code
## change. A planet arrives through the same call: its own static buildings (Tarsis 3's wind farm,
## the cargo depots) are found by walking down to them.
##
## A building is a NetStaticBody (city, spawn building, depot) or any scene under
## res://scenes/_universe/structures/. NOT the orbital station — huge, far away, and meant to be
## seen from the ground — nor what can move inside a building (vehicles, loose props), nor the
## planet's terrain, which has its own distances.

const OPTION : String = "structures_distance"
## The same flat cap as roads (RoadTerrain.FAR_VISIBILITY_M): at x1.0 a building is drawn as far as
## the road leading to it. Before this option buildings had no limit; at 15 km they cover a few
## pixels, so the default look does not change.
const FAR_M : float = RoadTerrain.FAR_VISIBILITY_M
## A part of a building is drawn up to this many metres per metre of its longest side: about 7 pixels
## at 1080p where it goes. A factory city draws 2 700 parts, nearly all with a shadow; this leaves about
## half of them from anywhere in it (2026-11-06). Lower = fewer draws, parts leaving sooner.
const PART_M_PER_M : float = 100.0
## ...and never less than this (m), for what is seen from across a street.
const PART_MIN_M : float = 60.0


static func attach_to(root: Node) -> void:
	if root == null or Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return
	# The station is not a building, and nothing in it is: it must stay visible from the ground.
	if _moves(root) or root is PlanetTerrain or root is OrbitalStation:
		return
	if is_building(root):
		_cover(root)
		return
	for child in root.get_children():
		attach_to(child)


static func is_building(node: Node) -> bool:
	if node is OrbitalStation:
		return false
	return node is NetStaticBody or node.scene_file_path.contains("/_universe/structures/")


## Track every mesh of a building — including those built after it spawned (a spawn building's
## apartments arrive with its data): each node reports the children that enter it later.
static func _cover(node: Node) -> void:
	if _moves(node):
		return
	if node is GeometryInstance3D:
		_track(node)
	if not node.child_entered_tree.is_connected(_cover):
		node.child_entered_tree.connect(_cover)
	for child in node.get_children():
		_cover(child)


static func _track(mesh: GeometryInstance3D) -> void:
	# Already tracked, or given a range by its own scene: a deliberate range is left alone.
	if DrawRange.is_tracked(mesh) or mesh.visibility_range_end > 0.0:
		return
	# A begin with no end is the far level of an authored LOD chain (the vehicle lift's rails,
	# landings, railings): its begin is the hand-off from the level before, whose end is authored and
	# never scaled. Only its far cap follows the option — scaling the begin too left the whole lift
	# undrawn between the two at x1.5 (rails missing from 50 to 75 m).
	DrawRange.track(mesh, OPTION, mesh.visibility_range_begin, part_end_m(mesh), false)


## How far the part [param mesh] is drawn (m), from its size. FAR_M when that size cannot be told yet (a
## CSG builds its mesh later) or when it hands off from another level of detail.
static func part_end_m(mesh: GeometryInstance3D) -> float:
	if mesh.visibility_range_begin > 0.0:
		return FAR_M
	var side := part_side_m(mesh)
	return FAR_M if side <= 0.0 else clampf(side * PART_M_PER_M, PART_MIN_M, FAR_M)


## The longest side of [param mesh] (m, with its own scale), 0 when it cannot be told.
static func part_side_m(mesh: GeometryInstance3D) -> float:
	var size := Vector3.ZERO
	if mesh is CSGBox3D:
		size = (mesh as CSGBox3D).size
	elif mesh is CSGCylinder3D:
		var c := mesh as CSGCylinder3D
		size = Vector3(c.radius * 2.0, c.height, c.radius * 2.0)
	elif mesh is CSGSphere3D:
		size = Vector3.ONE * (mesh as CSGSphere3D).radius * 2.0
	elif mesh is MeshInstance3D and (mesh as MeshInstance3D).mesh != null:
		size = (mesh as MeshInstance3D).mesh.get_aabb().size
	return _longest(size * mesh.transform.basis.get_scale().abs())


static func _longest(v: Vector3) -> float:
	return maxf(v.x, maxf(v.y, v.z))


## Vehicles, loose props and players in a building keep their own rules. A player walks into one (a
## city, the lift's Platform System) by a reparent: covered, its whole body and UI were walked on
## entry (~30 ms) and its meshes kept the building's draw distance after it left.
static func _moves(node: Node) -> bool:
	return node is Vehicle or node is RigidBody3D or node is Player
