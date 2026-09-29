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


static func attach_to(root: Node) -> void:
	if root == null or Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return
	if _moves(root) or root is PlanetTerrain:
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
	DrawRange.track(mesh, OPTION, mesh.visibility_range_begin, FAR_M)


## Vehicles and loose props parked in a building keep their own rules.
static func _moves(node: Node) -> bool:
	return node is Vehicle or node is RigidBody3D
