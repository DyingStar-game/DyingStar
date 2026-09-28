class_name NetStaticBody
extends StaticBody3D
## A networked structure that does not move on its own: a city, a spawn building, a depot, a station.
##
## Networking itself (uuid, replication, reparent, delete) lives in the PropSync child; this is only the
## facade that exposes `uuid` on the body, because that is what parent-by-uuid resolution looks for
## ("uuid" in node) — a structure other props and players hang from must answer it. It was written out
## identically in each of those scripts; a structure now inherits it.

var _sync: PropSync

var uuid: String:
	get:
		var s := _prop_sync()
		return s.uuid if s != null else ""
	set(value):
		var s := _prop_sync()
		if s != null:
			s.uuid = value


## Cached PropSync child, resolved lazily so a facade access before _ready still works.
func _prop_sync() -> PropSync:
	if _sync == null:
		_sync = PropSync.of(self)
	return _sync
