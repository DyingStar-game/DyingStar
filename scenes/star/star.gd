extends MeshInstance3D

signal hs_server_prop_update
signal hs_server_prop_delete

@export var uuid: String = ""

var spawn_position: Vector3 = Vector3.ZERO

func _ready() -> void:
	position = spawn_position

func _process(_delta: float) -> void:
	# OmniLight3D radiates from the star's position; no per-frame
	# orientation needed (unlike DirectionalLight3D, which had to be
	# re-aimed at the camera each frame and only lit one planet at a time).
	pass

func client_channel_data_update(_data: Dictionary) -> void:
	pass
