extends MeshInstance3D

@export var uuid: String = ""

var spawn_position: Vector3 = Vector3.ZERO

func _ready() -> void:
	position = spawn_position

func _process(_delta: float) -> void:
	if GameOrchestrator.is_server(): return
	var camera = get_viewport().get_camera_3d()
	if camera:
		$DirectionalLight3D.look_at(camera.global_position)

func client_channel_data_update(data: Dictionary) -> void:
	pass
