@tool
extends Control

## Show the result of an import/export/clear (incl. the server spawn position) in the panel.
func show_status(text: String) -> void:
	var lbl := get_node_or_null("MarginContainer/VBoxContainer/ServerPropsStatus")
	if lbl:
		lbl.text = text

func _on_horizon_clients_pressed(extra_arg_0: int) -> void:
	var editor = EditorInterface.get_editor_settings()
	var actual_instance_config: Array = editor.get_project_metadata("debug_options", "run_instances_config")
	var actual_launch_mode: String = actual_instance_config.back().arguments
	var actual_instance_count: int = editor.get_project_metadata("debug_options", "run_instance_count")
	var needed_instance_count: int = 1 + extra_arg_0

	# A launch configuration left by the former devmode (client straight to a game server) is
	# replaced even when the instance count matches.
	if actual_instance_count == needed_instance_count and not actual_launch_mode.contains("--devmode="):
		self.set_focus_mode(Control.FOCUS_ALL)
		self.grab_focus()
		self.set_focus_mode(Control.FOCUS_NONE)
		return

	editor.set_project_metadata("debug_options", "run_instance_count", needed_instance_count)
	editor.set_project_metadata("debug_options", "multiple_instances_enabled", true)

	var instances = []
	print("\t")
	for instance in range(extra_arg_0):
		instances.append({
				"arguments": "",
				"features": "",
				"override_args": false,
				"override_features": false
			})
	instances.append({
				"arguments": "--srvini=test/ini/srv1.ini",
				"features": "dedicated_server",
				"override_args": false,
				"override_features": false
			})

	editor.set_project_metadata("debug_options", "run_instances_config", instances)
	EditorInterface.restart_editor(true)
