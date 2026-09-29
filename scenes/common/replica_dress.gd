class_name ReplicaDress
extends RefCounted
## How the client dresses an object it places but does not simulate: a replica received from the
## server, or a prop set on the menu stage. The same four things either way, so they live here once:
##   - a contact fringe where it meets the ground (TerrainBlend decides who qualifies);
##   - a draw distance if it is a building (StructureDrawRange decides what counts);
##   - no physics of its own: the client has no terrain collision, so a live body would fall through
##     the planet — the server (or nobody, on the stage) moves it.
## Call before the object enters the tree.


## `deep`: also freeze every RigidBody3D below it (a scene of loose parts, not one networked body).
static func prepare(node: Node, deep: bool = false) -> void:
	TerrainBlend.attach_to(node)
	StructureDrawRange.attach_to(node)
	_freeze(node)
	if deep:
		for body in node.find_children("*", "RigidBody3D", true, false):
			_freeze(body)


static func _freeze(node: Node) -> void:
	node.set_physics_process(false)
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = true
