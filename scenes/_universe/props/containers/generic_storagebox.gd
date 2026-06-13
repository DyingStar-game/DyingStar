extends Node3D

## Networked static storage box (decor; non-carriable). All networking (uuid, replication, reparenting,
## delete) lives in the PropSync child node (type_name "box", enable_carry = false) — see the scene.
## This body only exposes `uuid` so other systems can resolve it as a networked parent by uuid.

var uuid: String:
	get:
		var s := PropSync.of(self)
		return s.uuid if s != null else ""
	set(value):
		var s := PropSync.of(self)
		if s != null:
			s.uuid = value
