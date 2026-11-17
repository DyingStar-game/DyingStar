class_name CharacterCreator
extends CanvasLayer

## The character creator, over the main menu: the categories and their sliders on the left, the figure
## on the right (CreatorPreview), undo / redo, random, presets, from photos (PhotoDialog), and save.
##
## It edits a CharacterAppearance and keeps it on this machine (CharacterStore.save_edit): the next spawn
## sends it to the server, which validates it, replicates it and has it persisted (set_appearance). It
## opens from the menu bar ("Character"), and on its own at the first "Enter universe" of a player who
## has no look kept here yet (first_enter): its main button then saves and enters.
##
## Built in code from the slider catalogue (CharacterAppearance.catalogue): a slider added to the bank
## appears here with its translated name, nothing to lay out by hand.

## The player asked to enter the universe with this look (first_enter only; already saved).
signal enter_requested

const _SOUNDS: PackedScene = preload("res://ui/InstallSounds.tscn")
## Categories: key -> caption. Body and face hold sub-tabs (the catalogue's `tab` of each slider).
const TABS: Dictionary = {
	&"body": "%%CHAR_TAB_BODY", &"face": "%%CHAR_TAB_FACE", &"skin": "%%CHAR_TAB_SKIN",
	&"hair": "%%CHAR_TAB_HAIR", &"eyes": "%%CHAR_TAB_EYES", &"outfit": "%%CHAR_TAB_OUTFIT",
}
const SUBTABS: Dictionary = {
	&"body": {&"shape": "%%CHAR_SUB_SHAPE", &"torso": "%%CHAR_SUB_TORSO", &"hips": "%%CHAR_SUB_HIPS",
			&"arms": "%%CHAR_SUB_ARMS", &"legs": "%%CHAR_SUB_LEGS"},
	&"face": {&"overall": "%%CHAR_SUB_OVERALL", &"head": "%%CHAR_SUB_HEAD", &"eyes": "%%CHAR_SUB_EYES", &"nose": "%%CHAR_SUB_NOSE",
			&"mouth": "%%CHAR_SUB_MOUTH", &"jaw": "%%CHAR_SUB_JAW", &"ears": "%%CHAR_SUB_EARS"},
}
## Where the preview camera goes for each category.
## The label of each skin detail's slider (CharacterAppearance.SKIN_DETAILS).
const SKIN_DETAIL_LABELS: Dictionary = {&"freckles": "%%CHAR_SKIN_FRECKLES", &"moles": "%%CHAR_SKIN_MOLES",
	&"wrinkles": "%%CHAR_SKIN_WRINKLES", &"redness": "%%CHAR_SKIN_REDNESS", &"eye_bags": "%%CHAR_SKIN_EYE_BAGS",
	&"unevenness": "%%CHAR_SKIN_UNEVENNESS"}
## The head of hair's settings shown as sliders, 0..1 (HairCut fields), after its length.
const HAIR_SLIDERS: Array = [["sides", "%%CHAR_HAIR_SIDES"], ["volume", "%%CHAR_HAIR_VOLUME"], ["curl", "%%CHAR_HAIR_CURL"],
	["density", "%%CHAR_HAIR_DENSITY"], ["fringe", "%%CHAR_HAIR_FRINGE"], ["recession", "%%CHAR_HAIR_RECESSION"],
	["crown_bald", "%%CHAR_HAIR_CROWN_BALD"], ["low_line", "%%CHAR_HAIR_LOW_LINE"],
	["flyaways", "%%CHAR_HAIR_FLYAWAYS"]]
## Labels of HairCut.Part and HairCut.Tie, in their order.
const HAIR_PARTS: Array = ["%%CHAR_HAIR_PART_CROWN", "%%CHAR_HAIR_PART_CENTRE", "%%CHAR_HAIR_PART_LEFT", "%%CHAR_HAIR_PART_RIGHT",
	"%%CHAR_HAIR_PART_BACK", "%%CHAR_HAIR_PART_CREST", "%%CHAR_HAIR_PART_UP"]
const HAIR_TIES: Array = ["%%CHAR_HAIR_TIE_LOOSE", "%%CHAR_HAIR_TIE_PONYTAIL", "%%CHAR_HAIR_TIE_BUN", "%%CHAR_HAIR_TIE_TOP_BUN"]
## The label of each hair style (catalogue id; HairCut.PRESETS) a head of hair may start from.
const HAIR_PRESET_LABELS: Dictionary = {"none": "%%CHAR_NONE", "buzz": "%%CHAR_HAIR_PRESET_BUZZ",
	"short_crop": "%%CHAR_HAIR_PRESET_SHORT_CROP", "side_part": "%%CHAR_HAIR_PRESET_SIDE_PART",
	"swept_back": "%%CHAR_HAIR_PRESET_SWEPT_BACK", "bob": "%%CHAR_HAIR_PRESET_BOB", "medium_wavy": "%%CHAR_HAIR_PRESET_MEDIUM_WAVY",
	"long_straight": "%%CHAR_HAIR_PRESET_LONG_STRAIGHT", "ponytail": "%%CHAR_HAIR_PRESET_PONYTAIL", "bun": "%%CHAR_HAIR_PRESET_BUN",
	"curly": "%%CHAR_HAIR_PRESET_CURLY", "afro": "%%CHAR_HAIR_PRESET_AFRO", "crest": "%%CHAR_HAIR_PRESET_CREST"}
## The beard's settings shown as sliders, 0..1 (BeardCut fields), after its length; its shapes' labels.
const BEARD_SLIDERS: Array = [["moustache", "%%CHAR_BEARD_MOUSTACHE_ZONE"], ["chin", "%%CHAR_BEARD_CHIN"],
	["cheeks", "%%CHAR_BEARD_CHEEKS"], ["neck", "%%CHAR_BEARD_NECK"], ["connect", "%%CHAR_BEARD_CONNECT"],
	["density", "%%CHAR_BEARD_DENSITY"]]
const BEARD_SHAPES: Array = ["%%CHAR_BEARD_SHAPE_ROUNDED", "%%CHAR_BEARD_SHAPE_SQUARE", "%%CHAR_BEARD_SHAPE_POINTED"]
## The beard picker's label of each catalogue beard id.
const BEARD_LABELS: Dictionary = {"none": "%%CHAR_NONE", "full": "%%CHAR_BEARD_FULL", "moustache": "%%CHAR_BEARD_MOUSTACHE",
	"goatee": "%%CHAR_BEARD_GOATEE", "stubble": "%%CHAR_BEARD_STUBBLE"}
const FRAMING: Dictionary = {&"face": &"face", &"skin": &"face", &"hair": &"hair", &"eyes": &"face"}
## The swatch shown for each eye colour (human_catalogue.json eye_colours), and its name.
const EYE_SWATCHES: Dictionary = {
	"brown": [Color(0.33, 0.2, 0.1), "%%CHAR_EYE_BROWN"], "brownlight": [Color(0.55, 0.38, 0.2), "%%CHAR_EYE_HAZEL"],
	"green": [Color(0.35, 0.5, 0.25), "%%CHAR_EYE_GREEN"], "bluegreen": [Color(0.3, 0.5, 0.5), "%%CHAR_EYE_BLUEGREEN"],
	"blue": [Color(0.3, 0.45, 0.7), "%%CHAR_EYE_BLUE"], "lightblue": [Color(0.5, 0.65, 0.85), "%%CHAR_EYE_LIGHTBLUE"],
	"deepblue": [Color(0.15, 0.25, 0.55), "%%CHAR_EYE_DEEPBLUE"], "grey": [Color(0.55, 0.58, 0.6), "%%CHAR_EYE_GREY"],
	"ice": [Color(0.75, 0.85, 0.92), "%%CHAR_EYE_ICE"],
}
## The outfit tab: one group per GDD zone (the first zone of a garment's code), in this order.
const GARMENT_ZONES: Array = [["1", "%%CHAR_GARMENT_HEAD"], ["3", "%%CHAR_GARMENT_TORSO"], ["4", "%%CHAR_GARMENT_ARMS"],
	["5", "%%CHAR_GARMENT_HANDS"], ["8", "%%CHAR_GARMENT_LEGS"], ["9", "%%CHAR_GARMENT_FEET"], ["0", "%%CHAR_GARMENT_BODY"]]
## ... and one picker per layer a character is created in (GDD layers 0..3: underwear to coat; armour is
## equipment, worn in game).
const GARMENT_LAYERS: Array = ["%%CHAR_GARMENT_LAYER_0", "%%CHAR_GARMENT_LAYER_1", "%%CHAR_GARMENT_LAYER_2",
	"%%CHAR_GARMENT_LAYER_3"]
## Seconds a look must stay unchanged to become an undo step (a slider drag is one step, not fifty).
const STEP_SETTLE_S: float = 0.4
## Width of the column of categories and sliders (px, before the interface scale).
const PANEL_WIDTH_PX: float = 560.0
const _MARGIN_PX: float = 32.0
const _TAB_FONT_SIZE: int = 17

## Set before adding: opened by "Enter universe" for a player without a look yet.
var first_enter: bool = false
## The look being edited.
var look: CharacterAppearance
var _saved: CharacterAppearance
var _history := AppearanceHistory.new()
var _tab: StringName = &"body"
var _subtab: Dictionary = {&"body": &"shape", &"face": &"overall"}
var _factory := SettingsRowFactory.new(SettingsStyle.FONT_SIZE, 14, 230.0, true)
var _tabs: TabStrip
var _subtabs: TabStrip
var _rows: VBoxContainer
var _scroll: ScrollContainer
var _preview: CreatorPreview
var _undo: Button
var _redo: Button
var _save: Button
var _presets: OptionButton
var _settle: Timer


## The look the creator starts from: the one kept here, else the one the server would give this player
## until they make theirs (CharacterAppearance.from_uuid of their account), else the default.
static func starting_look() -> CharacterAppearance:
	var kept: CharacterAppearance = CharacterStore.saved()
	if kept != null:
		return kept
	var account: String = PlayerServices.token_subject()
	return CharacterAppearance.from_uuid(account) if account != "" else CharacterAppearance.preset("default_male")


func _ready() -> void:
	look = starting_look()
	_saved = look.duplicate_appearance()
	_history.reset(look.encode())
	_settle = Timer.new()
	_settle.one_shot = true
	_settle.wait_time = STEP_SETTLE_S
	_settle.timeout.connect(_commit_step)
	add_child(_settle)
	_build_layout()
	_preview.set_appearance(look)
	_open_tab(_tab)
	_refresh_buttons()


# --- layout ----------------------------------------------------------------------------------------------

func _build_layout() -> void:
	var root := MarginContainer.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_theme_constant_override("margin_top", int(TopBar.HEIGHT_PX + 16.0))
	for side in ["margin_left", "margin_right", "margin_bottom"]:
		root.add_theme_constant_override(side, int(_MARGIN_PX))
	add_child(root)
	SafeArea.keep(root)
	var split := HBoxContainer.new()
	split.mouse_filter = Control.MOUSE_FILTER_IGNORE
	split.add_theme_constant_override("separation", 24)
	root.add_child(split)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH_PX, 0.0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.0, 0.0, 0.0, 0.9)
	box.set_corner_radius_all(6)
	box.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", box)
	panel.theme = load("res://ui/settings_page/settings_theme.tres") as Theme
	split.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)

	_tabs = TabStrip.new(_TAB_FONT_SIZE, 22)
	_tabs.alignment = BoxContainer.ALIGNMENT_BEGIN
	for key: StringName in TABS:
		_tabs.add_entry(key, TABS[key])
	_tabs.selected.connect(_open_tab)
	_tabs.pad_navigation(&"ui_page_previous", &"ui_page_next")
	column.add_child(_tabs)
	_subtabs = TabStrip.new(_TAB_FONT_SIZE - 3, 16)
	_subtabs.alignment = BoxContainer.ALIGNMENT_BEGIN
	_subtabs.selected.connect(_open_subtab)
	_subtabs.pad_navigation(&"ui_subpage_previous", &"ui_subpage_next")
	column.add_child(_subtabs)
	column.add_child(HSeparator.new())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)
	MenuFocus.follow(_rows)
	column.add_child(HSeparator.new())

	var tools := HBoxContainer.new()
	tools.name = "Tools"
	column.add_child(tools)
	_tool_button(tools, "%%CHAR_RANDOM_TAB", _randomise_tab)
	_tool_button(tools, "%%CHAR_RANDOM_ALL", _randomise_all)
	_tool_button(tools, "%%CHAR_RESET", _reset)
	_undo = _tool_button(tools, "%%CHAR_UNDO", _step_back)
	_redo = _tool_button(tools, "%%CHAR_REDO", _step_forward)
	var actions := HBoxContainer.new()
	actions.name = "Actions"
	column.add_child(actions)
	_presets = OptionButton.new()
	_presets.add_theme_font_override("font", SettingsRowFactory.FONT)
	_presets.add_item(tr("%%CHAR_PRESET"))
	_presets.add_item(tr("%%CHAR_PRESET_MALE"))
	_presets.add_item(tr("%%CHAR_PRESET_FEMALE"))
	_presets.item_selected.connect(_pick_preset)
	actions.add_child(_presets)
	_tool_button(actions, "%%CHAR_FROM_PHOTOS", _from_photos)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(gap)
	_save = Button.new()
	_save.text = "%%CHAR_ENTER_WITH" if first_enter else "%%CHAR_SAVE"
	_save.add_theme_font_override("font", SettingsRowFactory.FONT)
	_save.add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR)
	_save.pressed.connect(_on_save)
	actions.add_child(_save)
	var sounds: Node = _SOUNDS.instantiate()
	sounds.root_path = NodePath("../Root")  # it wants one; the buttons are in the two rows below
	add_child(sounds)
	sounds.install_sounds(tools)
	sounds.install_sounds(actions)

	_preview = CreatorPreview.new()
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_preview)


func _tool_button(parent: Container, text_key: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text_key
	button.add_theme_font_override("font", SettingsRowFactory.FONT)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


# --- tabs ------------------------------------------------------------------------------------------------

func _open_tab(key: StringName) -> void:
	_tab = key
	_tabs.set_active(key)
	_subtabs = _rebuild_subtabs(key)
	_preview.focus(FRAMING.get(key, &"body"))
	_build_rows()


func _rebuild_subtabs(key: StringName) -> TabStrip:
	var parent: Node = _subtabs.get_parent()
	var at: int = _subtabs.get_index()
	_subtabs.queue_free()
	var strip := TabStrip.new(_TAB_FONT_SIZE - 3, 16)
	strip.alignment = BoxContainer.ALIGNMENT_BEGIN
	var subs: Dictionary = SUBTABS.get(key, {})
	for sub: StringName in subs:
		strip.add_entry(sub, subs[sub])
	strip.selected.connect(_open_subtab)
	strip.pad_navigation(&"ui_subpage_previous", &"ui_subpage_next")
	strip.visible = not subs.is_empty()
	parent.add_child(strip)
	parent.move_child(strip, at)
	if not subs.is_empty():
		strip.set_active(_subtab[key])
	return strip


func _open_subtab(sub: StringName) -> void:
	_subtab[_tab] = sub
	_subtabs.set_active(sub)
	_build_rows()


# --- rows ------------------------------------------------------------------------------------------------

func _build_rows() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	match _tab:
		&"body":
			if _subtab[&"body"] == &"shape":
				_shape_rows()
			else:
				_modifier_rows(_subtab[&"body"])
		&"face":
			if _subtab[&"face"] == &"overall":
				_axis_rows()
			else:
				_modifier_rows(_subtab[&"face"])
		&"skin":
			_skin_rows()
		&"hair":
			_hair_rows()
		&"eyes":
			_eye_rows()
		&"outfit":
			_garment_rows()
	SettingsRow.wrap_rows(_rows)
	_scroll.scroll_vertical = 0
	if not InputDevice.pointer:
		MenuFocus.take.call_deferred(_rows)


func _shape_rows() -> void:
	_rows.add_child(_factory.header("%%CHAR_SUB_SHAPE"))
	_macro_row("%%CHAR_GENDER", "gender")
	_slider_row("%%CHAR_AGE", HumanMacros.MIN_YEARS, HumanMacros.MAX_YEARS, 1.0, roundf(look.years()),
			func(v: float) -> String: return "%d" % int(v),
			func(v: float) -> void: look.macros["age"] = HumanMacros.age_of(v))
	_macro_row("%%CHAR_HEIGHT", "height")
	_modifier_rows(&"shape")
	_rows.add_child(_factory.header("%%CHAR_ORIGIN"))
	var origins: Array = CharacterAppearance.catalogue().get("origin_labels", [])
	for i in mini(origins.size(), CharacterAppearance.ORIGINS):
		_slider_row(String(origins[i]), 0.0, 1.0, 1.0 / 255.0, look.origins[i], _percent,
				func(v: float) -> void: look.origins[i] = v)


func _macro_row(label_key: String, macro: String) -> void:
	_slider_row(label_key, 0.0, 1.0, 1.0 / 255.0, look.macros[macro], _percent,
			func(v: float) -> void: look.macros[macro] = v)


## The face or body sliders of one catalogue tab (head, nose, torso...), in catalogue order.
func _modifier_rows(tab: StringName) -> void:
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id in sliders.size():
		var entry: Dictionary = sliders[id]
		if StringName(entry["tab"]) != tab:
			continue
		var lowest: float = 0.0 if entry["unipolar"] else -1.0
		_slider_row(entry["label"], lowest, 1.0, 1.0 / 127.0, float(look.modifiers.get(id, 0.0)), _percent,
				func(v: float) -> void:
					if absf(v) < 0.5 / 127.0:
						look.modifiers.erase(id)
					else:
						look.modifiers[id] = v)


## The overall shape (FaceAxes): each slider moves several detailed ones; its position is read from them.
func _axis_rows() -> void:
	for axis: Array in FaceAxes.axes():
		var shares: Dictionary = axis[2]
		var at: Array = [FaceAxes.value_of(look, shares)]  # where the slider was, so a move is a difference
		_slider_row(axis[1], -1.0, 1.0, 1.0 / 127.0, at[0], _percent,
				func(v: float) -> void:
					FaceAxes.move(look, shares, v - at[0])
					at[0] = v)


func _skin_rows() -> void:
	_rows.add_child(_factory.header("%%CHAR_TAB_SKIN"))
	_slider_row("%%CHAR_SKIN_TONE", 0.0, 1.0, 1.0 / 255.0, look.skin_tone, _percent,
			func(v: float) -> void: look.skin_tone = v)
	_slider_row("%%CHAR_SKIN_WARMTH", 0.0, 1.0, 1.0 / 255.0, look.skin_warmth, _centred,
			func(v: float) -> void: look.skin_warmth = v)
	_rows.add_child(_factory.header("%%CHAR_SKIN_DETAILS"))
	for detail: StringName in CharacterAppearance.SKIN_DETAILS:
		_slider_row(SKIN_DETAIL_LABELS[detail], 0.0, 1.0, 1.0 / 255.0, look.get(detail), _percent,
				func(v: float) -> void: look.set(detail, v))
	_slider_row("%%CHAR_SKIN_DIMPLES", 0.0, 1.0, 1.0 / 255.0, look.dimples, _percent,
			func(v: float) -> void: look.dimples = v)


func _hair_rows() -> void:
	_rows.add_child(_factory.header("%%CHAR_TAB_HAIR"))
	_hair_style_row()
	if look.hair > 0:
		# The head of hair's settings (HairCut): every combination is a style. Through look.cut each time:
		# canonicalising makes it anew.
		_slider_row("%%CHAR_HAIR_LENGTH", 0.0, 1.0, 1.0 / 255.0, look.cut.length,
				func(v: float) -> String: return "%d cm" % roundi((0.004 + 0.55 * pow(v, 1.7)) * 100.0),
				func(v: float) -> void: look.cut.length = v)
		for row: Array in HAIR_SLIDERS:
			_slider_row(row[1], 0.0, 1.0, 1.0 / 255.0, float(look.cut.get(row[0])), _percent,
					func(v: float) -> void: look.cut.set(row[0], v))
		_pick_row("%%CHAR_HAIR_PART", HAIR_PARTS, look.cut.part, func(i: int) -> void: look.cut.part = i)
		_pick_row("%%CHAR_HAIR_TIE", HAIR_TIES, look.cut.tie, func(i: int) -> void: look.cut.tie = i)
	_slider_row("%%CHAR_HAIR_DARKNESS", 0.0, 1.0, 1.0 / 255.0, look.hair_eumelanin, _percent,
			func(v: float) -> void: look.hair_eumelanin = v)
	_slider_row("%%CHAR_HAIR_RED", 0.0, 1.0, 1.0 / 255.0, look.hair_pheomelanin, _percent,
			func(v: float) -> void: look.hair_pheomelanin = v)
	_slider_row("%%CHAR_HAIR_GREY", 0.0, 1.0, 1.0 / 255.0, look.hair_grey, _percent,
			func(v: float) -> void: look.hair_grey = v)
	_beard_row()
	if look.beard > 0:  # the beard's settings (BeardCut), through look.beard_cut each time
		_slider_row("%%CHAR_BEARD_LENGTH", 0.0, 1.0, 1.0 / 255.0, look.beard_cut.length,
				func(v: float) -> String: return "%d mm" % roundi((0.0015 + 0.12 * pow(v, 1.6)) * 1000.0),
				func(v: float) -> void: look.beard_cut.length = v)
		for row: Array in BEARD_SLIDERS:
			_slider_row(row[1], 0.0, 1.0, 1.0 / 255.0, float(look.beard_cut.get(row[0])), _percent,
					func(v: float) -> void: look.beard_cut.set(row[0], v))
		_pick_row("%%CHAR_BEARD_SHAPE", BEARD_SHAPES, look.beard_cut.shape, func(i: int) -> void: look.beard_cut.shape = i)
	if CharacterAppearance.choice_count("eyebrows") > 0:
		_rows.add_child(_factory.header("%%CHAR_EYEBROWS"))
		_choice_row("%%CHAR_EYEBROWS", "eyebrows", look.eyebrows, func(i: int) -> void: look.eyebrows = i)
	if CharacterAppearance.choice_count("eyelashes") > 0:
		_choice_row("%%CHAR_EYELASHES", "eyelashes", look.eyelashes, func(i: int) -> void: look.eyelashes = i)


## The style a head of hair starts from (HairCut.PRESETS, by catalogue id), or none: picking one sets
## every setting below to it.
func _hair_style_row() -> void:
	var line: HBoxContainer = _factory.row("%%CHAR_HAIR_STYLE")
	var picker: OptionButton = _factory.option_button()
	for entry: Dictionary in CharacterAppearance.catalogue()["assets"].get("hair", []):
		picker.add_item(tr(HAIR_PRESET_LABELS.get(entry["id"], "%%CHAR_HAIR_STYLE")))
	picker.select(look.hair)
	SettingsRowFactory.fit_names(picker)
	picker.item_selected.connect(func(i: int) -> void:
		look.hair = i
		look.cut = look.style_cut(i)
		_changed()
		_build_rows.call_deferred())
	line.add_child(picker)
	_rows.add_child(line)


## A line choosing one of [param keys] (labels), the [param current] one selected.
func _pick_row(label_key: String, keys: Array, current: int, apply: Callable) -> void:
	var line: HBoxContainer = _factory.row(label_key)
	var picker: OptionButton = _factory.option_button()
	for key: String in keys:
		picker.add_item(tr(key))
	picker.select(current)
	SettingsRowFactory.fit_names(picker)
	picker.item_selected.connect(func(i: int) -> void:
		apply.call(i)
		_changed())
	line.add_child(picker)
	_rows.add_child(line)


## Facial hair (CharacterAppearance.beard), drawn on the skin in the hair's colour.
func _beard_row() -> void:
	var line: HBoxContainer = _factory.row("%%CHAR_BEARD")
	var picker: OptionButton = _factory.option_button()
	# Named after the catalogue's ids, in its order (the bank's: none, full, moustache, goatee, stubble).
	for entry: Dictionary in CharacterAppearance.catalogue()["assets"].get("beard", []):
		picker.add_item(tr(BEARD_LABELS.get(entry["id"], "%%CHAR_BEARD")))
	picker.select(look.beard)
	picker.item_selected.connect(func(i: int) -> void:
		look.beard = i
		look.beard_cut = look.beard_style_cut(i)
		_changed()
		_build_rows.call_deferred())
	line.add_child(picker)
	_rows.add_child(line)


func _eye_rows() -> void:
	_rows.add_child(_factory.header("%%CHAR_EYE_COLOUR"))
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	var colours: Array = CharacterAppearance.catalogue()["eye_colours"]
	for i in colours.size():
		var swatch: Array = EYE_SWATCHES.get(colours[i], [Color.GRAY, "%%CHAR_EYE_COLOUR"])
		var button := Button.new()
		button.custom_minimum_size = Vector2(56.0, 56.0)
		button.tooltip_text = swatch[1]
		button.toggle_mode = true
		button.button_pressed = look.eye_colour == i
		var face := StyleBoxFlat.new()
		face.bg_color = swatch[0]
		face.set_corner_radius_all(28)
		face.set_border_width_all(3 if look.eye_colour == i else 0)
		face.border_color = SettingsStyle.ACTIVE_COLOR
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			button.add_theme_stylebox_override(state, face)
		button.pressed.connect(func() -> void:
			look.eye_colour = i
			_changed()
			_build_rows())
		grid.add_child(button)
	_rows.add_child(grid)


## The garments, zone by zone (GARMENT_ZONES), a picker per layer that has garments there.
func _garment_rows() -> void:
	var entries: Array = CharacterAppearance.garment_entries()
	for zone: Array in GARMENT_ZONES:
		var titled: bool = false
		for layer in GARMENT_LAYERS.size():
			var choices: Array[int] = []
			for i in entries.size():
				var e: Dictionary = entries[i]
				var zones: Array = e.get("zones", [])
				if String(e["id"]) == "none" or zones.is_empty() or int(e.get("layer", 1)) != layer:
					continue
				if String(zones[0]).left(1) == zone[0]:
					choices.append(i)
			if choices.is_empty():
				continue
			if not titled:
				_rows.add_child(_factory.header(zone[1]))
				titled = true
			_garment_row(GARMENT_LAYERS[layer], choices)


## A picker among [param choices] (garment positions in the catalogue): "None" then their names (marked for the
## body they suit). Picking one takes off what it cannot be worn with (GarmentRules): the last choice wins.
func _garment_row(label_key: String, choices: Array[int]) -> void:
	var entries: Array = CharacterAppearance.garment_entries()
	var line: HBoxContainer = _factory.row(label_key)
	var picker: OptionButton = _factory.option_button()
	picker.add_item(tr("%%CHAR_NONE"))
	var selected: int = 0
	for k in choices.size():
		var e: Dictionary = entries[choices[k]]
		var text: String = tr(String(e.get("label", e["id"])))
		if e.get("gender", "any") != "any":
			text += "  (%s)" % tr("%%CHAR_FOR_WOMEN" if e["gender"] == "female" else "%%CHAR_FOR_MEN")
		picker.add_item(text)
		if look.garments.any(func(g: Array) -> bool: return int(g[0]) == choices[k]):
			selected = k + 1
	picker.select(selected)
	SettingsRowFactory.fit_names(picker)
	picker.item_selected.connect(func(i: int) -> void:
		var kept: Array = look.garments.filter(func(g: Array) -> bool: return not choices.has(int(g[0])))
		if i > 0:
			kept.push_front([choices[i - 1], 0])
		look.garments = CharacterAppearance.canonical_garments(kept)
		_changed()
		var scrolled: int = _scroll.scroll_vertical
		_build_rows()  # what the choice took off shows as "None"
		_scroll.set_deferred("scroll_vertical", scrolled))
	line.add_child(picker)
	_rows.add_child(line)


## A line choosing one asset of [param kind] (eyebrows, eyelashes...): "None", then "Style 1", "Style 2"...
func _choice_row(label_key: String, kind: String, current: int, apply: Callable) -> void:
	var line: HBoxContainer = _factory.row(label_key)
	var picker: OptionButton = _factory.option_button()
	var entries: Array = CharacterAppearance.catalogue()["assets"].get(kind, [])
	var n: int = 0
	for entry: Dictionary in entries:
		if entry["id"] == "none":
			picker.add_item(tr("%%CHAR_NONE"))
			continue
		n += 1
		picker.add_item(tr("%%CHAR_STYLE_N") % n)
	picker.select(current)
	SettingsRowFactory.fit_names(picker)
	picker.item_selected.connect(func(i: int) -> void:
		apply.call(i)
		_changed())
	line.add_child(picker)
	_rows.add_child(line)


func _slider_row(label_key: String, lowest: float, highest: float, step: float, value: float, shown: Callable,
		apply: Callable) -> void:
	var line: HBoxContainer = _factory.row(label_key)
	var bar: HSlider = _factory.slider(lowest, highest, step)
	bar.value = value
	var number: Label = _factory.value_label()
	number.text = shown.call(value)
	bar.value_changed.connect(func(v: float) -> void:
		apply.call(v)
		number.text = shown.call(v)
		_changed())
	line.add_child(bar)
	line.add_child(number)
	_rows.add_child(line)


func _percent(v: float) -> String:
	return "%d" % roundi(v * 100.0)


## A value around a neutral middle (0.5 = the texture's own tone): -100 .. 100.
func _centred(v: float) -> String:
	return "%d" % roundi((v - 0.5) * 200.0)


# --- edits -----------------------------------------------------------------------------------------------

## The look changed (a slider, a choice): on the figure at once, an undo step once it settles.
func _changed() -> void:
	_preview.set_appearance(look)
	_settle.start()
	_refresh_buttons()


func _commit_step() -> void:
	_history.push(look.duplicate_appearance().encode())
	_refresh_buttons()


## Replace the whole look (undo, reset, a preset, random): the rows show it, the figure wears it.
func _show(new_look: CharacterAppearance, record: bool = true) -> void:
	look = new_look.duplicate_appearance()
	_preview.set_appearance(look)
	if record:
		_settle.stop()
		_history.push(look.encode())
	_build_rows()
	_refresh_buttons()


func _step_back() -> void:
	_commit_pending()
	var state: String = _history.undo()
	if state != "":
		_show(CharacterAppearance.decode(state), false)


func _step_forward() -> void:
	var state: String = _history.redo()
	if state != "":
		_show(CharacterAppearance.decode(state), false)


## A change still settling becomes its step now (undo right after a drag undoes that drag).
func _commit_pending() -> void:
	if not _settle.is_stopped():
		_settle.stop()
		_commit_step()


func _reset() -> void:
	_commit_pending()
	_show(_saved)


func _pick_preset(index: int) -> void:
	_presets.select(0)
	if index == 0:
		return
	_commit_pending()
	_show(CharacterAppearance.preset("default_male" if index == 1 else "default_female"))


## Draw the open category again at random, the rest of the look kept.
func _randomise_tab() -> void:
	_commit_pending()
	var drawn: CharacterAppearance = CharacterAppearance.random(randi())
	var out: CharacterAppearance = look.duplicate_appearance()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var gender: String = "female" if out.is_female() else "male"
	match _tab:
		&"body":
			if _subtab[&"body"] == &"shape":
				out.macros = drawn.macros
				out.origins = drawn.origins
				_take_modifiers(out, drawn, &"shape")
			else:
				_take_modifiers(out, drawn, _subtab[&"body"])
		&"face":
			if _subtab[&"face"] == &"overall":  # the overall shape is every face slider
				for tab: StringName in SUBTABS[&"face"]:
					_take_modifiers(out, drawn, tab)
			else:
				_take_modifiers(out, drawn, _subtab[&"face"])
		&"skin":
			out.skin_tone = drawn.skin_tone
			out.skin_warmth = drawn.skin_warmth
			for detail: StringName in CharacterAppearance.SKIN_DETAILS:
				out.set(detail, drawn.get(detail))
			out.dimples = drawn.dimples
		&"hair":
			out.hair = CharacterAppearance.random_choice(rng, "hair", gender, 0.1)
			out.hair_eumelanin = drawn.hair_eumelanin
			out.hair_pheomelanin = drawn.hair_pheomelanin
			out.hair_grey = drawn.hair_grey
			out.cut = out.style_cut(out.hair, rng.randf_range(0.55, 1.0))
			out.hair_length = 1.0
			out.eyebrows = drawn.eyebrows
			out.eyelashes = drawn.eyelashes
			out.beard = 0 if out.is_female() else rng.randi_range(0, CharacterAppearance.choice_count("beard") - 1)
			out.beard_cut = out.beard_style_cut(out.beard, rng.randf_range(0.2, 1.0))
			out.beard_length = 1.0
		&"eyes":
			out.eye_colour = drawn.eye_colour
		&"outfit":
			out.garments = CharacterAppearance.random_garments(rng.randi(), gender)
	out.canonicalise()
	_show(out)


## The sliders of one catalogue tab taken from [param drawn], those of the other tabs kept.
func _take_modifiers(out: CharacterAppearance, drawn: CharacterAppearance, tab: StringName) -> void:
	var sliders: Array = CharacterAppearance.catalogue()["modifiers"]
	for id in sliders.size():
		if StringName(sliders[id]["tab"]) != tab:
			continue
		if drawn.modifiers.has(id):
			out.modifiers[id] = drawn.modifiers[id]
		else:
			out.modifiers.erase(id)


func _randomise_all() -> void:
	_commit_pending()
	_show(CharacterAppearance.random(randi()))


## The look made from the player's photos (PhotoDialog), over the body chosen so far: undoable like any change.
func _from_photos() -> void:
	_commit_pending()
	var dialog := PhotoDialog.new()
	dialog.base = look.duplicate_appearance()
	dialog.made.connect(func(made_look: CharacterAppearance) -> void: _show(made_look))
	add_child(dialog)


func _on_save() -> void:
	_commit_pending()
	look.canonicalise()
	CharacterStore.save_edit(look)
	_saved = look.duplicate_appearance()
	_refresh_buttons()
	# Awaited before entering: the creator goes then, and the portrait is drawn by its preview.
	await _keep_sheet(look.duplicate_appearance())
	if first_enter:
		enter_requested.emit()


## The saved look into the player's character sheet (CharacterLibrary), with its portrait: the one it was
## made from, else a new one.
func _keep_sheet(saved_look: CharacterAppearance) -> void:
	var portrait: Image = await _preview.portrait()
	var base: Dictionary = await CharacterLibrary.fetch(CharacterStore.active_id())
	var empty: bool = portrait == null or portrait.is_empty()
	var sheet: Dictionary = CharacterSheet.make(String(base.get("name", "")), saved_look, null if empty else portrait, base)
	var kept: Dictionary = await CharacterLibrary.save(sheet)
	if not kept.is_empty():
		CharacterStore.set_active_id(String(kept["id"]))


func _refresh_buttons() -> void:
	_undo.disabled = not _history.can_undo() and _settle.is_stopped()
	_redo.disabled = not _history.can_redo()
	if not first_enter:
		var unsaved: bool = not look.duplicate_appearance().equals(_saved)
		_save.disabled = not unsaved
		_save.text = "%%CHAR_SAVE" if unsaved else "%%CHAR_SAVED"
