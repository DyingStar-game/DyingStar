@tool
extends Control

@onready var devmodelist = $MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer

func _ready() -> void:
	_on_reload_command_pressed()

func _on_reload_command_pressed() -> void:
	# read the devmodefolder
	var children = devmodelist.get_children()
	for child in children.slice(1, children.size()):
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
				btn.size_flags_horizontal = Control.SIZE_FILL
				btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
				btn.pressed.connect(_on_button_pressed.bind(file_name))
				i += 1
				devmodelist.add_child(btn)
			file_name = dir.get_next()
	else:
		print("An error occurred when trying to access the path.")
	
	self.set_focus_mode(Control.FOCUS_ALL)
	self.grab_focus()
	self.set_focus_mode(Control.FOCUS_NONE)


func _on_button_pressed(file_name: String):
	var editor = EditorInterface.get_editor_settings()
	var actual_instance_config: Array = editor.get_project_metadata("debug_options", "run_instances_config", [{"arguments":""}])
	var actual_launch_mode: String = actual_instance_config.back().arguments
	
	if actual_launch_mode.contains("--devmode="):
		self.set_focus_mode(Control.FOCUS_ALL)
		self.grab_focus()
		self.set_focus_mode(Control.FOCUS_NONE)
		return
	
	editor.set_project_metadata("debug_options", "run_instance_count", 2.0)
	editor.set_project_metadata("debug_options", "multiple_instances_enabled", true)
	editor.set_project_metadata("debug_options", "run_instances_config", [
		{
			"arguments": "",
			"features": "devmode",
			"override_args": false,
			"override_features": false
		},
		{
			"arguments": "--srvini=test/ini/srv1.ini --devmode=" + file_name,
			"features": "dedicated_server",
			"override_args": false,
			"override_features": false
		},
	])
	EditorInterface.restart_editor(true)


func _on_horizon_clients_pressed(extra_arg_0: int) -> void:
	var editor = EditorInterface.get_editor_settings()
	var actual_instance_config: Array = editor.get_project_metadata("debug_options", "run_instances_config", [{"arguments":""}])
	var actual_launch_mode: String = actual_instance_config.back().arguments
	var actual_instance_count: int = editor.get_project_metadata("debug_options", "run_instance_count", extra_arg_0 + 2)
	var needed_instance_count: int = 1 + extra_arg_0
	
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
