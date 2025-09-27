extends Node

var player_name: String = "I am an idiot !"
var player_uuid: String = ""
var online_mode: bool = false
var is_gut_running: bool = false

func print_rich_distinguished(message: String, extras: Array) -> void:
	var peer_id: int = -1
	var instance_color = "lightsteelblue"
	var instance_name = "Not instantiated yet"
	if GameOrchestrator and GameOrchestrator.current_network_role != null:
		instance_color = GameOrchestrator.distinguish_instances[GameOrchestrator.current_network_role]["instance_color"]
		instance_name = GameOrchestrator.distinguish_instances[GameOrchestrator.current_network_role]["instance_name"]
		peer_id = NetworkOrchestrator.network_agent.peer_id if GameOrchestrator.current_network_role == GameOrchestrator.NetworkRole.PLAYER else 1
	var prefix = "[color=" + instance_color + "][" + instance_name + "(" +  str(peer_id) + ")][/color]"

	var formatted_message = message

	if not extras.is_empty():
		formatted_message = message % extras

	print_rich(prefix + formatted_message)

func align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	xform.basis = xform.basis.orthonormalized()
	return xform

func log(message: String):
	var header = "[color=green][lb]client[rb][/color]"
	if multiplayer and GameOrchestrator.is_server():
		header = "[color=teal][lb]server[rb][/color]: "
	print_rich(header + message)
