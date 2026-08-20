extends MeshInstance3D

## Networked star (client-side display object). All networking lives in the PropSync child node
## (type_name "star", non-carriable) — see the scene. The body exposes `uuid` so it can be resolved as
## a networked parent by uuid.

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

var spawn_position: Vector3 = Vector3.ZERO

func _ready() -> void:
	position = spawn_position

func _process(_delta: float) -> void:
	# Nothing to update per frame: the star mesh is self-illuminated by its shader. The old star
	# OmniLight (which only lit the now-removed far-LOD sphere) is gone — distant bodies light
	# themselves in the terrain shader, and the local surface is lit by the per-player PlayerSunLight.
	pass

func client_channel_data_update(_data: Dictionary) -> void:
	pass
