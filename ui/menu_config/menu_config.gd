class_name MenuConfig

extends Control

static var is_shown: bool = false

## Actions grouped the way a player looks for them, each mapped to the translation key for what it
## actually does. ONE structure rather than a list of families beside a table of labels: two of
## those drift, and an action would end up in a family with no label, or the reverse.
##
## The action NAME cannot be changed to explain itself: it is an identifier, not a label. "jump"
## travels to the server inside client_send_action_to_server, and PlayerServer matches on it as a
## compile-time constant. But a player reading the settings has no way to guess that the jump key is
## also what starts a vault or a climb -- it was reported as "the vault key is not configurable",
## when it was configurable all along under a name that never mentioned vaulting. "action" and
## "interact" are worse still: two different keys whose names say the same thing.
const ACTION_GROUPS : Dictionary = {
	"%%KM_GROUP_GENERAL": {
		"pause": "%%ACT_PAUSE",
		"star_map": "%%ACT_STAR_MAP",
		"star_map_zoom_in": "%%ACT_STAR_MAP_ZOOM_IN",
		"star_map_zoom_out": "%%ACT_STAR_MAP_ZOOM_OUT",
		"toggle_chat": "%%ACT_TOGGLE_CHAT",
		"write_in_chat": "%%ACT_WRITE_IN_CHAT",
		"game_record": "%%ACT_GAME_RECORD",
	},
	"%%KM_GROUP_ON_FOOT": {
		"move_forward": "%%ACT_MOVE_FORWARD",
		"move_back": "%%ACT_MOVE_BACK",
		"move_left": "%%ACT_MOVE_LEFT",
		"move_right": "%%ACT_MOVE_RIGHT",
		"jump": "%%ACT_JUMP",
		"crouch": "%%ACT_CROUCH",
		"prone": "%%ACT_PRONE",
		"sprint": "%%ACT_SPRINT",
		"action": "%%ACT_ACTION",
		"interact": "%%ACT_INTERACT",
		"walk_speed_up": "%%ACT_WALK_SPEED_UP",
		"walk_speed_down": "%%ACT_WALK_SPEED_DOWN",
		"toggle_flashlight": "%%ACT_TOGGLE_FLASHLIGHT",
		"emote_wheel": "%%ACT_EMOTE_WHEEL",
		"toggle_tool": "%%ACT_TOGGLE_TOOL",
		"aim": "%%ACT_AIM",
		"perforate": "%%ACT_PERFORATE",
		"carry_rotate_cw": "%%ACT_CARRY_ROTATE_CW",
		"carry_rotate_ccw": "%%ACT_CARRY_ROTATE_CCW",
		"carry_free_rotate": "%%ACT_CARRY_FREE_ROTATE",
	},
	"%%KM_GROUP_VEHICLE": {
		"vehicle_ignition": "%%ACT_VEHICLE_IGNITION",
		"brake": "%%ACT_BRAKE",
		"vehicle_lights": "%%ACT_VEHICLE_LIGHTS",
		"vehicle_horn": "%%ACT_VEHICLE_HORN",
		"vehicle_horn_special": "%%ACT_VEHICLE_HORN_SPECIAL",
		"vehicle_reset": "%%ACT_VEHICLE_RESET",
		"exit": "%%ACT_EXIT",
	},
	"%%KM_GROUP_FLIGHT": {
		"strafe_up": "%%ACT_STRAFE_UP",
		"strafe_down": "%%ACT_STRAFE_DOWN",
		"roll_left": "%%ACT_ROLL_LEFT",
		"roll_right": "%%ACT_ROLL_RIGHT",
	},
	"%%KM_GROUP_DEBUG": {
		"toggle_debug": "%%ACT_TOGGLE_DEBUG",
		"spawn_wheel": "%%ACT_SPAWN_WHEEL",
		"toggle_eva": "%%ACT_TOGGLE_EVA",
		"zapette": "%%ACT_ZAPETTE",
		"debug_time_forward": "%%ACT_DEBUG_TIME_FORWARD",
		"debug_time_back": "%%ACT_DEBUG_TIME_BACK",
		"debug_toggle_moon_lights": "%%ACT_DEBUG_TOGGLE_MOON_LIGHTS",
		"debug_isolate_light": "%%ACT_DEBUG_ISOLATE_LIGHT",
	},
}
## Anything the table above never classified lands here rather than disappearing from the page. A
## new action is therefore always rebindable, and shows the opened-out form of its name until
## someone files it.
const GROUP_OTHER : String = "%%KM_GROUP_OTHER"
## Tabs carry the navigation, so they read at a size between the page title and a row.
const TAB_FONT_SIZE : int = 22

var input_button_scene = preload("res://ui/menu_config/input_button.tscn")

var is_remapping = false
var action_to_remap = null
var remapping_button = null

## One entry per displayed family: {"header": Label, "rows": {translated label -> Button}}.
var _groups: Array[Dictionary] = []
var _tab_buttons: Array[Button] = []
var _tab_bar: HBoxContainer = null
var _tab: int = 0
## Built once, then swapped between tabs: rebuilding a StyleBox on every keystroke of the search
## box would allocate for nothing.
var _tab_idle: StyleBoxFlat = null
var _tab_active: StyleBoxFlat = null
var _tab_hover: StyleBoxFlat = null
var keycode_dic: Dictionary = {}
var last_press = ""

@onready var action_list = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ActionList
@onready var search_bar = $PanelContainer/MarginContainer/VBoxContainer/SearchBar
@onready var save_config = $PanelContainer/MarginContainer/VBoxContainer/SaveButton

func _ready() -> void:
	is_shown = false
	if GameOrchestrator.is_server(): return
	# Back to the project defaults, then the player's saved remaps over them. The LOADING lives in
	# SettingsManager, which applies it at BOOT for the whole game: this page must not be the only
	# thing that applies a remap, or the bindings depend on having opened it once. One parser, one
	# owner. Removing the dead MenuConfig copy from pause_menu.tscn is what exposed that.
	InputMap.load_from_project_settings()
	SettingsManager.load_keybindings()
	keycode_dic = SettingsManager.keybindings.duplicate()
	create_action_list()

func create_action_list() -> void:
	_groups.clear()
	for item in action_list.get_children():
		item.queue_free()
	var unfiled : Array[String] = _listable_actions()
	for group_key in ACTION_GROUPS:
		var members : Array[String] = []
		for action in ACTION_GROUPS[group_key]:
			if unfiled.has(action):
				members.append(action)
				unfiled.erase(action)
		_add_group(str(group_key), members, ACTION_GROUPS[group_key])
	_add_group(GROUP_OTHER, unfiled, {})
	_build_tabs()
	_refresh_visibility()


## The actions this page may show. Engine ui_* actions are none of the player's business, and a
## switched-off dev tool keeps its binding in the InputMap (so it can be brought back without
## re-adding one) but must not be listed: rebinding a key that does nothing would only confuse.
func _listable_actions() -> Array[String]:
	var out : Array[String] = []
	for action in InputMap.get_actions():
		if action.begins_with("ui_"):
			continue
		if Globals.ENABLED_DEV_TOOLS.has(action) and not Globals.is_dev_tool_enabled(action):
			continue
		out.append(action)
	return out


## One family: a heading (only ever shown while searching, see _refresh_visibility) and its rows.
func _add_group(group_key: String, actions: Array[String], labels: Dictionary) -> void:
	if actions.is_empty():
		return
	var header := Label.new()
	header.text = group_key
	header.uppercase = true
	header.modulate = SettingsStyle.ACTIVE_COLOR
	action_list.add_child(header)
	var rows : Dictionary = {}
	for action in actions:
		var label_key : String = str(labels.get(action, action.replace("_", " ")))
		var row : Button = _add_action_row(action, label_key)
		# Keyed by what the player READS, because that is what they type in the search box: keying
		# by "%%ACT_JUMP" would make searching for "jump" match nothing.
		rows[tr(label_key)] = row
	_groups.append({"header": header, "rows": rows})


func _add_action_row(action: String, label_key: String) -> Button:
	var action_bt = input_button_scene.instantiate()
	var action_label = action_bt.find_child("LabelAction")
	var input_label = action_bt.find_child("LabelInput")
	# The KEY goes in, not translated text: a Label re-translates its own text, so the list follows
	# a language change on its own. Casing is presentation and lives on the Label (uppercase = true),
	# which applies it AFTER translation — .to_upper() on a key would shout the key, not the words.
	action_label.text = label_key
	var events = InputMap.action_get_events(action)
	input_label.text = format_input_label(events[0] as InputEvent) if not events.is_empty() else ""
	action_list.add_child(action_bt)
	action_bt.pressed.connect(_on_input_button_pressed.bind(action_bt, action))
	return action_bt


## A row of family tabs under the search box. Built from the groups that actually produced rows, so
## an empty family (every dev tool switched off, say) never shows an empty tab.
func _build_tabs() -> void:
	if _tab_bar != null:
		_tab_bar.queue_free()
	_tab_buttons.clear()
	_tab_idle = _tab_box(Color(0.0, 0.0, 0.0, 0.0))
	_tab_active = _tab_box(SettingsStyle.ACTIVE_BG)
	_tab_hover = _tab_box(SettingsStyle.HOVER_COLOR)
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	var holder : Node = search_bar.get_parent()
	holder.add_child(_tab_bar)
	holder.move_child(_tab_bar, search_bar.get_index() + 1)
	for i in _groups.size():
		var tab := Button.new()
		tab.text = str(_groups[i]["header"].text)
		tab.add_theme_font_size_override("font_size", TAB_FONT_SIZE)
		# The default Button styleboxes would draw a raised widget; a tab is a surface.
		tab.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		tab.add_theme_stylebox_override("pressed", _tab_active)
		tab.pressed.connect(_on_tab_pressed.bind(i))
		_tab_bar.add_child(tab)
		_tab_buttons.append(tab)
	_tab = clampi(_tab, 0, maxi(_groups.size() - 1, 0))


func _on_tab_pressed(index: int) -> void:
	_tab = index
	# Picking a family is a navigation, not a filter: a leftover search would show the new tab
	# already filtered, with no sign of why half of it is missing. Setting text from code emits
	# nothing, so the refresh is ours to call.
	search_bar.text = ""
	_refresh_visibility()


## Decide what shows: the open family, or — while searching — every family at once.
##
## A search deliberately ignores the tabs. The whole reason someone types in that box is that they
## do NOT know which family holds the key they want, so searching "jump" from the vehicle tab has
## to find it.
func _refresh_visibility() -> void:
	var search : String = search_bar.text.strip_edges().to_lower()
	var searching : bool = search != ""
	for i in _groups.size():
		var group : Dictionary = _groups[i]
		var any_shown : bool = false
		for label in group["rows"]:
			var shown : bool = search in str(label).to_lower() if searching else i == _tab
			group["rows"][label].visible = shown
			any_shown = any_shown or shown
		# Headings only earn their place while searching: they say which family a hit belongs to.
		# Without a search the open tab already says it, and an empty one would read as a dead
		# category.
		group["header"].visible = searching and any_shown
	for i in _tab_buttons.size():
		_paint_tab(_tab_buttons[i], i == _tab and not searching)


## A selected tab gets both the amber wording and the surface behind it: colour alone was too quiet
## to find on a wide screen, which is the whole reason the tabs exist.
func _paint_tab(tab: Button, active: bool) -> void:
	var ink : Color = SettingsStyle.ACTIVE_COLOR if active else SettingsStyle.INACTIVE_COLOR
	tab.add_theme_color_override("font_color", ink)
	tab.add_theme_color_override("font_hover_color", ink)
	tab.add_theme_color_override("font_pressed_color", SettingsStyle.ACTIVE_COLOR)
	tab.add_theme_stylebox_override("normal", _tab_active if active else _tab_idle)
	tab.add_theme_stylebox_override("hover", _tab_active if active else _tab_hover)


## Tab-shaped: padded so the row has real height, and rounded at the top only so it reads as a tab
## sitting on the list rather than as a floating pill.
static func _tab_box(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.content_margin_left = 20.0
	box.content_margin_right = 20.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	box.corner_radius_top_left = 6
	box.corner_radius_top_right = 6
	return box


func format_input_label(event: InputEvent) -> String:
	if event is InputEventKey:
		# Show the modifiers too, so an "Alt + ²" binding doesn't read as a bare key.
		var mods := ""
		if event.ctrl_pressed: mods += "Ctrl + "
		if event.alt_pressed: mods += "Alt + "
		if event.shift_pressed: mods += "Shift + "
		if event.meta_pressed: mods += "Meta + "
		return mods + _physical_key_name(event.physical_keycode)

	return event.as_text()

## Human key name for a physical keycode: prefer the label printed on the key in the active layout
## (e.g. "²" on an AZERTY row), and fall back to the layout keycode name (e.g. "Apostrophe") when the
## key has no printable label. Physical keycodes keep bindings layout-independent; this only affects
## how they READ in the Controls list.
func _physical_key_name(physical_keycode: int) -> String:
	var label := DisplayServer.keyboard_get_label_from_physical(physical_keycode)
	if label != 0:
		var label_text := OS.get_keycode_string(label)
		if label_text.strip_edges() != "":
			return label_text
	var keycode := DisplayServer.keyboard_get_keycode_from_physical(physical_keycode)
	return OS.get_keycode_string(keycode)

func _on_input_button_pressed(b, a):
	if !is_remapping:
		is_remapping = true
		action_to_remap = a
		remapping_button = b
		b.find_child("LabelInput").text = "%%KM_PRESS_KEY"
	get_tree().root.get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:

	if not visible:
		return

	# This page owns the keyboard ONLY while it is capturing a binding. Outside that, Esc belongs to
	# whoever opened the page: the pause menu frees its settings overlay, the settings page has its
	# Return button. Swallowing every event here is what trapped players in Settings > Controls.
	# This page used to carry a second Return button of its own, wired to nothing at all, which is
	# why Esc was consumed here while nothing acted on it. That button is gone: the settings shell's
	# Return is the only one, and it works.
	if not is_remapping:
		return

	if event.is_action_pressed("pause"):
		# Esc ABORTS the capture instead of being bound to the action. Both used to happen at once:
		# the old Esc branch emitted "return", then this one bound Escape to whatever was selected.
		var kept: Array[InputEvent] = InputMap.action_get_events(action_to_remap)
		remapping_button.find_child("LabelInput").text = (
			format_input_label(kept[0]) if not kept.is_empty() else ""
		)
		_end_remap()
	elif event is InputEventKey or (event is InputEventMouseButton && event.pressed):
		InputMap.action_erase_events(action_to_remap)
		InputMap.action_add_event(action_to_remap, event)
		_update_action_list(remapping_button, event)
		if event is InputEventKey:
			keycode_dic.set(action_to_remap, event.as_text_physical_keycode())
		elif event is InputEventMouseButton:
			keycode_dic.set(action_to_remap, "mouse_" + str(event.button_index))
		_end_remap()
		save_config.visible = true

	# The key being bound must not also fire the action it is being bound to.
	get_viewport().set_input_as_handled()

## Leave capture mode. One place, so a new way of ending a capture cannot forget one of the three.
func _end_remap() -> void:
	is_remapping = false
	action_to_remap = null
	remapping_button = null

func _update_action_list(button: Button, ev: InputEvent):
	button.find_child("LabelInput").text = format_input_label(ev)

func _on_reset_button_pressed() -> void:
	InputMap.load_from_project_settings()
	keycode_dic.clear()
	create_action_list()
	save_config.visible = true

func _on_text_edit_text_changed(_new_text: String) -> void:
	_refresh_visibility()


func _on_save_button_pressed() -> void:
	# "\t" = indentation
	var json := JSON.stringify(keycode_dic, "\t")
	var file := FileAccess.open(SettingsManager.INPUT_MAP_FILEPATH, FileAccess.WRITE)
	if file == null:
		push_warning("[DyingStar] could not write the keybindings file — this session only.")
		return
	file.store_string(json)
	file.close()

	# Keep the runtime owner in step with the file, so nothing re-reads it to know the truth.
	SettingsManager.keybindings = keycode_dic.duplicate()
	save_config.visible = false
