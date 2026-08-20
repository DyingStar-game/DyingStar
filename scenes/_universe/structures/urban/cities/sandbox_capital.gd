extends StaticBody3D

## Networked city hub. All networking (uuid, replication, reparent, delete) lives in the PropSync child
## node (type_name "city", non-carriable). Many props are parented to the city, so the body exposes
## `uuid` for parent-by-uuid resolution. (The old nav-mesh bake and _align_to_surface paths were dead
## code and have been removed along with the networking boilerplate.)

var _sync: PropSync

## Cached PropSync child, resolved lazily so a facade access before _ready still works.
func _prop_sync() -> PropSync:
	if _sync == null:
		_sync = PropSync.of(self)
	return _sync

var uuid: String:
	get:
		var s := _prop_sync()
		return s.uuid if s != null else ""
	set(value):
		var s := _prop_sync()
		if s != null:
			s.uuid = value
