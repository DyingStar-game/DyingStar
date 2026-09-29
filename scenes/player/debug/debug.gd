@tool
extends Control


const HOLD_THRESHOLD_MS: float = 300.0


var press_start_time: float = 0.0
var is_checking_hold: bool = false


func _ready() -> void:
	set_process(false)
	
	var universe_title_background: ColorRect = get_node_or_null("MarginContainer/Sections/Universe/PanelContainer/Debug Section Background")
	var server_title_background: ColorRect = get_node_or_null("MarginContainer/Sections/Server/PanelContainer/Debug Section Background")
	var server_box_title_background: ColorRect = get_node_or_null("MarginContainer/Sections/Server Box/PanelContainer/Debug Section Background")
	var client_title_background: ColorRect = get_node_or_null("MarginContainer/Sections/Client/PanelContainer/Debug Section Background")
	
	var universe_planet_time: Label = get_node_or_null("MarginContainer/Sections/Universe/Universe Values/MarginContainer/VBoxContainer/planet_time")
	var universe_altitude: Label = get_node_or_null("MarginContainer/Sections/Universe/Universe Values/MarginContainer/VBoxContainer/altitude")
	
	if universe_title_background != null:
		universe_title_background.set_instance_shader_parameter("corner_cuts", Vector4(0, 12, 0, 0)) # coin haut-droit de 12px
	if server_title_background != null:
		server_title_background.set_instance_shader_parameter("corner_cuts", Vector4(0, 12, 0, 0)) # coin haut-droit de 12px
	if server_box_title_background != null:
		server_box_title_background.set_instance_shader_parameter("corner_cuts", Vector4(0, 12, 0, 0)) # coin haut-droit de 12px
	if client_title_background != null:
		client_title_background.set_instance_shader_parameter("corner_cuts", Vector4(0, 12, 0, 0)) # coin haut-droit de 12px
	
	if Engine.is_editor_hint():
		return
	
	if not GameOrchestrator.is_server():
		if universe_planet_time:
			universe_planet_time.set_player(owner)
		if universe_altitude:
			universe_altitude.set_player(owner)


func _on_normal_player_display_debug(show: bool) -> void:
	if Engine.is_editor_hint():
		return
	
	if show:
		visible = true
	else:
		visible = false
