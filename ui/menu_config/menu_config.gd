extends Control

var input_button_scene = preload("res://ui/menu_config/input_button.tscn")

@onready var action_list = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ActionList
@onready var search_bar = $PanelContainer/MarginContainer/VBoxContainer/SearchBar
@onready var save_config = $PanelContainer/MarginContainer/VBoxContainer/SaveButton

var input_map_path = "user://inputs.map"
var game_paused: bool = false
var is_remapping = false
var action_to_remap = null
var remapping_button = null

var button_dic: Dictionary = {}
var keycode_dic: Dictionary = {}
var last_press = ""

func _ready() -> void:
	if multiplayer.is_server(): return
	InputMap.load_from_project_settings()
	import_input_map()
	create_action_list()

func create_action_list():
	button_dic.clear()
	for item in action_list.get_children():
		item.queue_free()
	
	for action in InputMap.get_actions():
		if action.begins_with("ui_"):
			continue
		var action_bt = input_button_scene.instantiate()
		var action_label = action_bt.find_child("LabelAction")
		var input_label = action_bt.find_child("LabelInput")
		
		action_label.text = action.replace("_", " ").to_upper()
		
		var events = InputMap.action_get_events(action)
		if not events.is_empty():
			var event = events[0] as InputEvent
			input_label.text = format_input_label(event)
				
		else :
			input_label.text = ""
		
		action_list.add_child(action_bt)
		action_bt.pressed.connect(_on_input_button_pressed.bind(action_bt, action))
		button_dic.set(action_label.text, action_bt)

func format_input_label(event: InputEvent) -> String:
	if event is InputEventKey:
		var keycode = DisplayServer.keyboard_get_keycode_from_physical(event.physical_keycode)
		return OS.get_keycode_string(keycode)
	
	return event.as_text()

func _on_input_button_pressed(b, a):
	if !is_remapping:
		is_remapping = true
		action_to_remap = a
		remapping_button = b
		b.find_child("LabelInput").text = "Press key to bind..."

func _input(ev: InputEvent):
	if is_remapping:
		if(
			ev is InputEventKey ||
			(ev is InputEventMouseButton && ev.pressed)
		):
			InputMap.action_erase_events(action_to_remap)
			InputMap.action_add_event(action_to_remap, ev)
			_update_action_list(remapping_button, ev)
			if ev is InputEventKey:
				keycode_dic.set(action_to_remap, ev.as_text_physical_keycode())
			elif ev is InputEventMouseButton:
				keycode_dic.set(action_to_remap, "mouse_" + str(ev.button_index))
			is_remapping = false
			action_to_remap = null
			remapping_button = null
			save_config.visible = true
			
			accept_event()

func _update_action_list(button: Button, ev: InputEvent):
	button.find_child("LabelInput").text = format_input_label(ev)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("open_shortcut_menu"):
		if not visible:
			visible = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			visible = false
		get_tree().root.get_viewport().set_input_as_handled()
	
	if(event.is_pressed() && last_press == event.as_text()):
		#ignore hold press
		return
	elif event.is_pressed():
		last_press = event.as_text()
		
	if(not event.is_pressed()):
		last_press = ""

func _on_reset_button_pressed() -> void:
	InputMap.load_from_project_settings()
	keycode_dic.clear()
	create_action_list()
	save_config.visible = true

func _on_text_edit_text_changed(new_text: String) -> void:
	var search = new_text.to_lower()
	for k in button_dic:
		if search == "" or search in str(k).to_lower():
			button_dic[k].visible = true
		else:
			button_dic[k].visible = false

func _on_save_button_pressed() -> void:
	# "\t" = indentation
	var json := JSON.stringify(keycode_dic, "\t") 
	var file := FileAccess.open(input_map_path, FileAccess.WRITE)
	file.store_string(json)
	file.close()
	
	print("Actions exportées vers :", input_map_path)
	save_config.visible = false
	$PanelContainer.visible = false
	game_paused = false

func import_input_map() -> void:
	if not FileAccess.file_exists(input_map_path):
		print("Fichier introuvable :", input_map_path)
		return
	
	var file := FileAccess.open(input_map_path, FileAccess.READ)
	var content := file.get_as_text()
	file.close()
	
	var result : Dictionary = JSON.parse_string(content)
	if typeof(result) != TYPE_DICTIONARY:
		print("Fichier JSON invalide")
		return
	
	for action_name in result.keys():
		InputMap.action_erase_events(action_name)
		var ev_str = str(result[action_name])
		keycode_dic[action_name] = ev_str
		var input_event
		if ev_str.begins_with("mouse_"):
			input_event = InputEventMouseButton.new()
			input_event.button_index = int(ev_str.split("_")[1])
		else:
			input_event = InputEventKey.new()
			input_event.physical_keycode = OS.find_keycode_from_string(ev_str)
		print("ev : " + ev_str + " for " + action_name)
		InputMap.action_add_event(action_name, input_event)
	
	print("Actions importées depuis :", input_map_path)
