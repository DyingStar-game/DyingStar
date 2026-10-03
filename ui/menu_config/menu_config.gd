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
		"%%KM_SECTION_SERVICES": {
			"toggle_services": "%%ACT_SERVICES",
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
		"look_left": "%%ACT_LOOK_LEFT",
		"look_right": "%%ACT_LOOK_RIGHT",
		"look_up": "%%ACT_LOOK_UP",
		"look_down": "%%ACT_LOOK_DOWN",
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

## The two devices a binding belongs to, in their columns' order (InputDevice.Kind).
const COLUMNS : Array[InputDevice.Kind] = [InputDevice.Kind.KEYBOARD_MOUSE, InputDevice.Kind.GAMEPAD]
## Each column's heading, and what its cell says while it listens.
const COLUMN_TITLES : Dictionary = {
	InputDevice.Kind.KEYBOARD_MOUSE: "%%KM_COLUMN_KEYBOARD", InputDevice.Kind.GAMEPAD: "%%KM_COLUMN_PAD",
}
const LISTENING : Dictionary = {
	InputDevice.Kind.KEYBOARD_MOUSE: "%%KM_PRESS_KEY", InputDevice.Kind.GAMEPAD: "%%KM_PRESS_PAD",
}
## What a cell with nothing bound shows.
const UNBOUND : String = "—"
## A binding cell's width, both columns alike.
const CELL_WIDTH : float = 180.0

var is_remapping = false
var action_to_remap = null
var remapping_button = null
## The device of the cell being captured (InputDevice.Kind).
var _remapping_device : InputDevice.Kind = InputDevice.Kind.KEYBOARD_MOUSE
## Decides what the keys pressed during a capture add up to. Alive only while one is running.
var _capture: BindingCapture = null

## One entry per displayed family: {"header": Label, "rows": {translated label -> its line},
## "sections": [{"header": Label}]} — the titled sections of the family.
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
	# Reached like any line, and named with the button that presses it while it has the focus.
	save_config.focus_mode = Control.FOCUS_ALL
	save_config.focus_entered.connect(_label_save)
	save_config.focus_exited.connect(_label_save)
	create_action_list()

func create_action_list() -> void:
	_groups.clear()
	for item in action_list.get_children():
		item.queue_free()
	_add_column_titles()
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
		for action: String in section[1]:
			var label_key : String = str(section[1][action])
			# Keyed by what the player READS, because that is what they type in the search box:
			# keying by "%%ACT_JUMP" would make searching for "jump" match nothing.
			rows[tr(label_key)] = _add_action_row(action, label_key)
		if title != null:
			titled.append({"header": title})
	_groups.append({"header": header, "rows": rows, "sections": titled})


## One action: its name, then a cell per device (keyboard and mouse, gamepad), each showing that
## device's binding and capturing a new one when clicked. Lit as a whole under the pointer, like the
## other settings pages' lines.
func _add_action_row(action: String, label_key: String) -> Control:
	# The KEY goes in, not translated text: a Label re-translates its own text, so the list follows
	# a language change on its own.
	var line : HBoxContainer = _factory.row(label_key)
	(line.get_child(0) as Label).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for kind: InputDevice.Kind in COLUMNS:
		var cell : Button = _factory.button(_binding_text(action, kind))
		cell.custom_minimum_size.x = CELL_WIDTH
		cell.size_flags_horizontal = Control.SIZE_SHRINK_END
		cell.pressed.connect(_on_input_button_pressed.bind(cell, action, kind))
		line.add_child(cell)
	var row := SettingsRow.new()
	row.add_child(line)
	action_list.add_child(row)
	return row


## What a cell shows: the device's first binding of the action, or a dash.
static func _binding_text(action: String, kind: InputDevice.Kind) -> String:
	var events : Array[InputEvent] = InputDevice.bindings(action, kind)
	return InputLabel.for_event(events[0]) if not events.is_empty() else UNBOUND


## The columns' headings, over the list: what each column of cells binds.
func _add_column_titles() -> void:
	var line := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(spacer)
	for kind: InputDevice.Kind in COLUMNS:
		var title : Label = _factory.header(str(COLUMN_TITLES[kind]))
		title.custom_minimum_size.x = CELL_WIDTH
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.add_child(title)
	action_list.add_child(line)


## A row of family tabs under the search box. Built from the groups that actually produced rows, so
## an empty family (every dev tool switched off, say) never shows an empty tab.
func _build_tabs() -> void:
	if _tab_bar != null:
		_tab_bar.queue_free()
	_tab_bar = TabStrip.new(TAB_FONT_SIZE, 28)
	_tab_bar.alignment = BoxContainer.ALIGNMENT_BEGIN
	# Reached like any other item, with the cross or the arrows, which then open the tab beside: the
	# shoulder buttons are the settings' categories and the triggers the bar's entries.
	_tab_bar.arrows_select()
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


func _on_input_button_pressed(cell: Button, action: String, kind: InputDevice.Kind) -> void:
	if !is_remapping:
		is_remapping = true
		action_to_remap = action
		remapping_button = cell
		_remapping_device = kind
		# Listening to the clicked column's device only: a key does not land in the gamepad's cell.
		_capture = BindingCapture.new(kind)
		BindingCapture.listening = true
		cell.text = str(LISTENING[kind])
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

	# The pointer stays free to move while we listen; only keys, buttons and the gamepad are ours.
	if InputDevice.kind_of(event) < 0:
		return

	# The ESCAPE KEY aborts, from either column: the gamepad has no key of its own to give up with, and
	# its Start button may be the very one being bound to the pause.
	if event is InputEventKey and event.is_action_pressed("pause"):
		# Esc ABORTS the capture instead of being bound to the action. Both used to happen at once:
		# the old Esc branch emitted "return", then this one bound Escape to whatever was selected.
		remapping_button.text = _binding_text(action_to_remap, _remapping_device)
		_end_remap()
	elif _capture.feed(event) == BindingCapture.Verdict.BIND:
		# Which key, and with which modifiers, is BindingCapture's call: a modifier going down waits
		# for the key it is held for, so Alt+X is bound as Alt+X and not as Alt.
		var bound: InputEvent = _capture.bound
		# This device's bindings only: the key leaves the gamepad's button where it was.
		InputDevice.rebind(action_to_remap, bound)
		remapping_button.text = InputLabel.for_event(bound)
		var entry: Dictionary = SettingsManager.keybindings_of(keycode_dic.get(action_to_remap, {}))
		entry[InputDevice.KEYS[_remapping_device]] = InputEventCodec.encode(bound)
		keycode_dic[action_to_remap] = entry
		_end_remap()
		_offer_save()

	# The key being bound must not also fire the action it is being bound to, nor the click press the
	# row under the pointer or scroll the list.
	get_viewport().set_input_as_handled()

## Leave capture mode. One place, so a new way of ending a capture cannot forget one of the four.
func _end_remap() -> void:
	is_remapping = false
	action_to_remap = null
	remapping_button = null
	_capture = null
	BindingCapture.listening = false


## Freed in the middle of a capture (the menu closed, the game left): the menus are not left deaf.
func _exit_tree() -> void:
	if is_remapping:
		_end_remap()

func _on_reset_button_pressed() -> void:
	InputMap.load_from_project_settings()
	keycode_dic.clear()
	create_action_list()
	_offer_save()


## There are changes to save: the Save button shows — and, without the mouse, takes the focus, so A
## saves straight away (up from it goes back to the lines for another change).
func _offer_save() -> void:
	save_config.visible = true
	if not InputDevice.pointer:
		save_config.grab_focus.call_deferred()


## "Save changes (A)" while it has the focus without the mouse; the plain words otherwise.
func _label_save() -> void:
	var hint : String = InputLabel.for_action(&"ui_accept")
	# The key itself when plain, so a change of language still translates it.
	save_config.text = tr("%%KM_SAVEKEYCHANGE") + " (" + hint + ")" \
			if save_config.has_focus() and not InputDevice.pointer and hint != "" else "%%KM_SAVEKEYCHANGE"


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
	var had_focus : bool = save_config.has_focus()
	save_config.visible = false
	# Saved with A: the focus goes back to the page's first line rather than nowhere.
	if had_focus:
		MenuFocus.take(self)
