@tool
extends Control

@onready var devmoderoot = %devmoderoot

func _ready() -> void:
	_on_reload_command_pressed()

func _on_reload_command_pressed() -> void:
	# read the devmodefolder
	var children = devmoderoot.get_children()
	for child in children:
		child.free()
	var i = 0
	var dir = DirAccess.open("res://levels/devmode")
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir():
				var btn = Button.new()
				btn.text = file_name
				btn.size = Vector2(160, 31)
				btn.pressed.connect(_on_button_pressed.bind(file_name))
				btn.position = Vector2(0, i * 40)
				i += 1
				devmoderoot.add_child(btn)
			file_name = dir.get_next()
	else:
		print("An error occurred when trying to access the path.")


func _on_button_pressed(file_name: String):
	var editor = EditorInterface.get_editor_settings()
	editor.set_project_metadata("debug_options", "run_instance_count", 2.0)
	editor.set_project_metadata("debug_options", "multiple_instances_enabled", true)
	editor.set_project_metadata("debug_options", "run_instances_config", [
		{
			"arguments": "--srvini=test/ini/srv1.ini --devmode=" + file_name,
			"features": "dedicated_server",
			"override_args": false,
			"override_features": false
		},
		{
			"arguments": "",
			"features": "devmode",
			"override_args": false,
			"override_features": false
		}
	])
	EditorInterface.restart_editor(true)


func _on_horizon_clients_pressed(extra_arg_0: int) -> void:
	var editor = EditorInterface.get_editor_settings()
	editor.set_project_metadata("debug_options", "run_instance_count", (1 + extra_arg_0))
	editor.set_project_metadata("debug_options", "multiple_instances_enabled", true)
	var instances = [
		{
			"arguments": "--srvini=test/ini/srv1.ini",
			"features": "dedicated_server",
			"override_args": false,
			"override_features": false
		},
		{
			"arguments": "",
			"features": "",
			"override_args": false,
			"override_features": false
		}
	]
	if extra_arg_0 >= 2:
		instances.append(
			{
				"arguments": "",
				"features": "",
				"override_args": false,
				"override_features": false
			}
		)
	if extra_arg_0 >= 3:
		instances.append(
			{
				"arguments": "",
				"features": "",
				"override_args": false,
				"override_features": false
			}
		)

	editor.set_project_metadata("debug_options", "run_instances_config", instances)
	EditorInterface.restart_editor(true)
