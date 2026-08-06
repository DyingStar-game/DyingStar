extends StaticBody3D

@onready var kiosk_interaction_area: Area3D = $KioskInteractionArea

func _ready() -> void:
	kiosk_interaction_area.connect("interacted", _on_interaction_requested)
	#kiosk_interaction_area.connect("body_entered", on_player_entered)
	#kiosk_interaction_area.connect("body_exited", on_player_exited)
#
#func on_player_entered(player: Node3D) -> void:
	#if player is Player and not multiplayer.is_server():
		#Globals.print_rich_distinguished("[color=green]COUCOU, JE VEUX UN SHIP %s[/color]", [player.name])
		#player.interact_label.text = "[F] Request your ship"
		#player.interact_label.show()
		#var spawn_position: Vector3 = global_position + Vector3(0.0,10.0,0.0)
		#player.emit_signal("client_action_requested", {"action": "spawn", "entity": "ship"})
		##OnlineOrchestrator.spawn_ship.rpc_id(1, player_scene_path, spawn_position, spawn_up, peer_id)
#
#func on_player_exited(player: Node3D) -> void:
	#if player is Player and not multiplayer.is_server():
		#Globals.print_rich_distinguished("[color=green]AU REVOIR %s[/color]", [player.name])
		#player.interact_label.hide()

func _on_interaction_requested(interactor: Node) -> void:
	if interactor is Player and not multiplayer.is_server():
		var spawn_position: Vector3 = interactor.global_position - interactor.global_basis.z * 5.0 + interactor.global_basis.y * 5.0

		var player_up = interactor.global_transform.basis.y.normalized()
		var to_player = (interactor.global_transform.origin - spawn_position)
		to_player -= to_player.dot(player_up) * player_up
		to_player = to_player.normalized()
		var ship_basis: Basis = Basis.looking_at(to_player, player_up)
		ship_basis = ship_basis.rotated(Vector3.UP, deg_to_rad(-90))
		var spawn_rotation = ship_basis.get_euler()

		interactor.emit_signal(
			"client_action_requested",
			{"action": "spawn", "entity": "ship", "spawn_position": spawn_position, "spawn_rotation": spawn_rotation}
		)
