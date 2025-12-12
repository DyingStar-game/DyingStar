@tool
extends EditorPlugin

const MainPanel = preload("res://addons/dyingstar/main_panel.tscn")

var main_panel_instance

func _enable_plugin() -> void:
	# Add autoloads here.
	pass


func _disable_plugin() -> void:
	# Remove autoloads here.
	pass


func _enter_tree() -> void:
	# Initialization of the plugin goes here.
	main_panel_instance = MainPanel.instantiate()
	add_control_to_bottom_panel(main_panel_instance, "DyingStar")
	# Add the main panel to the editor's main viewport.
	# EditorInterface.get_editor_main_screen().add_child(main_panel_instance)
	# Hide the main panel. Very much required.
	# _make_visible(false)


func _exit_tree() -> void:
	# Clean-up of the plugin goes here.
	#if main_panel_instance:
		#main_panel_instance.queue_free()
	remove_control_from_bottom_panel(main_panel_instance)
	
	if is_instance_valid(main_panel_instance):
		main_panel_instance.queue_free()
		main_panel_instance = null


func _get_plugin_name():
	return "DyingStar"


func _get_plugin_icon():
	# Must return some kind of Texture for the icon.
	#return EditorInterface.get_editor_theme().get_icon("Tools", "EditorIcons")
	pass
