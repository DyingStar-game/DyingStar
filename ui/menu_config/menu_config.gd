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
##
## A family can be cut into SECTIONS, each under its own title: an entry whose value is a dictionary
## of its own is a section, keyed by its title. General gathers four unrelated things (the star chart,
## the chat, the sound, the captures) and read as one long list without them.
const ACTION_GROUPS : Dictionary = {
	"%%KM_GROUP_GENERAL": {
		"pause": "%%ACT_PAUSE",
		"%%KM_SECTION_STAR_MAP": {
			"star_map": "%%ACT_STAR_MAP",
			"star_map_zoom_in": "%%ACT_STAR_MAP_ZOOM_IN",
			"star_map_zoom_out": "%%ACT_STAR_MAP_ZOOM_OUT",
		},
		"%%KM_SECTION_CHAT": {
			"toggle_chat": "%%ACT_TOGGLE_CHAT",
			"write_in_chat": "%%ACT_WRITE_IN_CHAT",
		},
		"%%KM_SECTION_AUDIO": {
			"toggle_speaker": "%%ACT_TOGGLE_SPEAKER",
			"toggle_microphone": "%%ACT_TOGGLE_MICROPHONE",
		},
		"%%KM_SECTION_GALLERY": {
			"screenshot": "%%ACT_SCREENSHOT",
			"screenshot_debug": "%%ACT_SCREENSHOT_DEBUG",
			"game_record": "%%ACT_GAME_RECORD",
		},
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
		"vehicle_speed_limiter": "%%ACT_VEHICLE_SPEED_LIMITER",
		"vehicle_limiter_up": "%%ACT_VEHICLE_LIMITER_UP",
		"vehicle_limiter_down": "%%ACT_VEHICLE_LIMITER_DOWN",
		"vehicle_reset": "%%ACT_VEHICLE_RESET",
		"exit": "%%ACT_EXIT",
	},
	# Weightless: out of a station's gravity, or the dev flight. These four were filed under "In flight"
	# while only a long-gone test ship read them; they are how an astronaut moves now. A ship of its own
	# would bring its own tab back, with its own keys — an action can only live in one family.
	"%%KM_GROUP_EVA": {
		"strafe_up": "%%ACT_STRAFE_UP",
		"strafe_down": "%%ACT_STRAFE_DOWN",
		"roll_left": "%%ACT_ROLL_LEFT",
		"roll_right": "%%ACT_ROLL_RIGHT",
		"eva_stabilize": "%%ACT_EVA_STABILIZE",
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
## Tabs carry the navigation: the settings tabs' own look (TabStrip), a step smaller.
const TAB_FONT_SIZE : int = 15

var input_button_scene = preload("res://ui/menu_config/input_button.tscn")

var is_remapping = false
var action_to_remap = null
var remapping_button = null
## Decides what the keys pressed during a capture add up to. Alive only while one is running.
var _capture: BindingCapture = null

## One entry per displayed family: {"header": Label, "rows": {translated label -> Button},
## "sections": [{"header": Label, "rows": Array[Button]}]} — the titled sections of the family.
var _groups: Array[Dictionary] = []
var _tab_bar: TabStrip = null
## The settings pages' heading look, for the page title and the family headings.
var _factory := SettingsRowFactory.new()
var _tab: int = 0
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
	_factory.style_header($PanelContainer/MarginContainer/VBoxContainer/HBoxContainer/Title)
	create_action_list()

func create_action_list() -> void:
	_groups.clear()
	for item in action_list.get_children():
		item.queue_free()
	var unfiled : Array[String] = _listable_actions()
	for group_key in ACTION_GROUPS:
		var sections : Array = []
		for section: Array in sections_of(ACTION_GROUPS[group_key]):
			var members : Dictionary = {}
			for action: String in section[1]:
				if unfiled.has(action):
					members[action] = section[1][action]
					unfiled.erase(action)
			if not members.is_empty():
				sections.append([section[0], members])
		_add_group(str(group_key), sections)
	var others : Dictionary = {}
	for action: String in unfiled:
		others[action] = action.replace("_", " ")
	_add_group(GROUP_OTHER, [["", others]] if not others.is_empty() else [])
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


## A family's entries as its sections, in order: [title key ("" for none), {action: label key}].
## Consecutive actions outside any section make one untitled section.
static func sections_of(group: Dictionary) -> Array:
	var out : Array = []
	var loose : Dictionary = {}
	for key: String in group:
		if group[key] is Dictionary:
			if not loose.is_empty():
				out.append(["", loose])
				loose = {}
			out.append([key, group[key]])
		else:
			loose[key] = group[key]
	if not loose.is_empty():
		out.append(["", loose])
	return out


## Every action of a family, section or not, with its label key.
static func labels_of(group: Dictionary) -> Dictionary:
	var out : Dictionary = {}
	for section: Array in sections_of(group):
		out.merge(section[1])
	return out


## One family: a heading (only ever shown while searching, see _refresh_visibility), and its
## sections, each under its title if it has one, as [title key, {action: label key}].
func _add_group(group_key: String, sections: Array) -> void:
	if sections.is_empty():
		return
	var header := Label.new()
	header.text = group_key
	_factory.style_header(header)
	action_list.add_child(header)
	var rows : Dictionary = {}
	var titled : Array[Dictionary] = []
	for section: Array in sections:
		var title : Label = null
		if str(section[0]) != "":
			title = _factory.header(str(section[0]))
			action_list.add_child(title)
		var section_rows : Array[Button] = []
		for action: String in section[1]:
			var label_key : String = str(section[1][action])
			var row : Button = _add_action_row(action, label_key)
			# Keyed by what the player READS, because that is what they type in the search box:
			# keying by "%%ACT_JUMP" would make searching for "jump" match nothing.
			rows[tr(label_key)] = row
			section_rows.append(row)
		if title != null:
			titled.append({"header": title, "rows": section_rows})
	_groups.append({"header": header, "rows": rows, "sections": titled})


func _add_action_row(action: String, label_key: String) -> Button:
	var action_bt = input_button_scene.instantiate()
	var action_label = action_bt.find_child("LabelAction")
	var input_label = action_bt.find_child("LabelInput")
	# The KEY goes in, not translated text: a Label re-translates its own text, so the list follows
	# a language change on its own.
	action_label.text = label_key
	var events = InputMap.action_get_events(action)
	input_label.text = InputLabel.for_event(events[0] as InputEvent) if not events.is_empty() else ""
	action_list.add_child(action_bt)
	action_bt.pressed.connect(_on_input_button_pressed.bind(action_bt, action))
	return action_bt


## A row of family tabs under the search box. Built from the groups that actually produced rows, so
## an empty family (every dev tool switched off, say) never shows an empty tab.
func _build_tabs() -> void:
	if _tab_bar != null:
		_tab_bar.queue_free()
	_tab_bar = TabStrip.new(TAB_FONT_SIZE, 28)
	_tab_bar.alignment = BoxContainer.ALIGNMENT_BEGIN
	var holder : Node = search_bar.get_parent()
	holder.add_child(_tab_bar)
	holder.move_child(_tab_bar, search_bar.get_index() + 1)
	for i in _groups.size():
		# The heading's text is already translated: tr() on it gives it back unchanged.
		_tab_bar.add_entry(StringName(str(i)), str(_groups[i]["header"].text))
	_tab_bar.selected.connect(func(key: StringName) -> void: _on_tab_pressed(int(String(key))))
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
		# A section's title goes with its family's tab. During a search the family heading says where
		# a hit is; a section title over one surviving row would only repeat it.
		for section: Dictionary in group["sections"]:
			(section["header"] as Label).visible = not searching and i == _tab
	# While searching no tab is open: the hits come from every family.
	_tab_bar.set_active(&"" if searching else StringName(str(_tab)))


func _on_input_button_pressed(b, a):
	if !is_remapping:
		is_remapping = true
		action_to_remap = a
		remapping_button = b
		_capture = BindingCapture.new()
		b.find_child("LabelInput").text = "%%KM_PRESS_KEY"
	get_tree().root.get_viewport().set_input_as_handled()

## In _input, not _unhandled_input: the page is covered with controls, and a control under the pointer
## takes a mouse press before anything unhandled is ever offered. That is why the wheel click could
## not be bound, nor any other button; and the search box, once typed in, kept the keys as well.
func _input(event: InputEvent) -> void:

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

	# The pointer stays free to move while we listen; only keys and buttons are ours.
	if not (event is InputEventKey or event is InputEventMouseButton):
		return

	if event.is_action_pressed("pause"):
		# Esc ABORTS the capture instead of being bound to the action. Both used to happen at once:
		# the old Esc branch emitted "return", then this one bound Escape to whatever was selected.
		var kept: Array[InputEvent] = InputMap.action_get_events(action_to_remap)
		remapping_button.find_child("LabelInput").text = (
			InputLabel.for_event(kept[0]) if not kept.is_empty() else ""
		)
		_end_remap()
	elif _capture.feed(event) == BindingCapture.Verdict.BIND:
		# Which key, and with which modifiers, is BindingCapture's call: a modifier going down waits
		# for the key it is held for, so Alt+X is bound as Alt+X and not as Alt.
		var bound: InputEvent = _capture.bound
		InputMap.action_erase_events(action_to_remap)
		InputMap.action_add_event(action_to_remap, bound)
		_update_action_list(remapping_button, bound)
		keycode_dic.set(action_to_remap, InputEventCodec.encode(bound))
		_end_remap()
		save_config.visible = true

	# The key being bound must not also fire the action it is being bound to, nor the click press the
	# row under the pointer or scroll the list.
	get_viewport().set_input_as_handled()

## Leave capture mode. One place, so a new way of ending a capture cannot forget one of the four.
func _end_remap() -> void:
	is_remapping = false
	action_to_remap = null
	remapping_button = null
	_capture = null

func _update_action_list(button: Button, ev: InputEvent):
	button.find_child("LabelInput").text = InputLabel.for_event(ev)

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
