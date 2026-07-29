extends MeshInstance3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""

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
