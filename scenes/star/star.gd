extends MeshInstance3D


func _process(_delta: float) -> void:
	if multiplayer.is_server(): return
	var camera = get_viewport().get_camera_3d()
	if camera:
		$DirectionalLight3D.look_at(camera.global_position)
	
