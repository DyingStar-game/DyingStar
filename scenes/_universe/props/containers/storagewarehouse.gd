extends Node3D

## Networked static warehouse. All networking (uuid, replication, reparenting, delete) lives in the
## PropSync child node (type_name "storagewarehouse", non-carriable) — see the scene. This body only
## exposes `uuid` so other systems can resolve it as a networked parent by uuid.

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
