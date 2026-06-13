extends StaticBody3D

## Networked city hub. All networking (uuid, replication, reparent, delete) lives in the PropSync child
## node (type_name "city", non-carriable). Many props are parented to the city, so the body exposes
## `uuid` for parent-by-uuid resolution. (The old nav-mesh bake and _align_to_surface paths were dead
## code and have been removed along with the networking boilerplate.)

var uuid: String:
	get:
		var s := PropSync.of(self)
		return s.uuid if s != null else ""
	set(value):
		var s := PropSync.of(self)
		if s != null:
			s.uuid = value
