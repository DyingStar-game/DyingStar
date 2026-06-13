extends Node3D

## Dev test prop. All networking lives in the PropSync child node (type_name "city", non-carriable) —
## see the scene. This body only exposes `uuid` so it can be resolved as a networked parent by uuid.

var uuid: String:
	get:
		var s := PropSync.of(self)
		return s.uuid if s != null else ""
	set(value):
		var s := PropSync.of(self)
		if s != null:
			s.uuid = value
