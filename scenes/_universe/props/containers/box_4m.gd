class_name Box4m

extends RigidBody3D

## Networked 4 m hauling box. All networking (uuid, replication, reparent, delete) lives in the PropSync
## child node (type_name "box", non-carriable) — see the scene. The body exposes `uuid` so it can be
## resolved as a networked parent by uuid.

@export var inside_space: World3D

var uuid: String:
	get:
		var s := PropSync.of(self)
		return s.uuid if s != null else ""
	set(value):
		var s := PropSync.of(self)
		if s != null:
			s.uuid = value
