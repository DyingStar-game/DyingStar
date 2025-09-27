extends Node3D

func _on_ready() -> void:
	if not OS.has_feature("dedicated_server") and Globals.online_mode:
		await GameOrchestrator._game_server.create_client()

	#add_child(newplayer)
	#newplayer.global_position = Vector3(10.0, 10.0, 0)
