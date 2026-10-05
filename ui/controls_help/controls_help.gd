class_name ControlsHelp
extends CanvasLayer
## The controls help, held open in game (F1 on the keyboard, a long press of Back / View on the pad):
## the device in hand — the drawn keyboard and the mouse, or the gamepad — with the keys of the main
## actions lit and numbered, and beside it the legend, number by number. Built from the InputMap each
## time it opens, so it shows the player's own bindings, in the language of the game.

## The project's palette (the website's and the logo's amber over the warm charcoal).
const ACCENT : Color = Color("#FFBA08")
const INK : Color = Color("#151413")
const TEXT : Color = Color("#FFFFFB")
const KEY_FILL : Color = Color("#2B2827")
const KEY_EDGE : Color = Color("#615957")
## The black veil over the game: dark enough to read on, the scene still there behind. The 2D blends in
## linear light (hdr_2d), where 0.82 only half-darkened a bright sandy ground — the settings' veil is
## 0.93 for the same reason.
const BACKDROP : Color = Color(0.0, 0.0, 0.0, 0.93)
## Above the HUD and every in-game panel.
const LAYER : int = 20
const TITLE_SIZE : int = 30
const TEXT_SIZE : int = 17
## The gamepad's largest size, as a share of the room it is given: at full size it filled the screen's
## height and drowned the legend.
const GAMEPAD_SHARE : float = 0.6
## Room between the legend's sections (px), on top of the heading's own margin.
const SECTION_GAP_PX : int = 6
## The legend's number badges (px).
const LEGEND_BADGE_PX : float = 24.0
## Room around the whole help (px).
const MARGIN_PX : int = 48

const GAMEPAD_PICTURE : Texture2D = preload("res://ui/controls_help/gamepad.png")
const MOUSE_PICTURE : Texture2D = preload("res://ui/controls_help/mouse.png")
## Each spot of the gamepad picture, in shares of its width and height (measured on the picture).
const GAMEPAD_SPOTS : Dictionary = {
	"ls": Vector2(0.246, 0.322), "rs": Vector2(0.631, 0.524),
	"dpad_up": Vector2(0.377, 0.471), "dpad_down": Vector2(0.377, 0.62),
	"dpad_left": Vector2(0.325, 0.546), "dpad_right": Vector2(0.43, 0.546),
	"a": Vector2(0.75, 0.42), "b": Vector2(0.815, 0.327), "x": Vector2(0.685, 0.327), "y": Vector2(0.751, 0.236),
	"back": Vector2(0.431, 0.32), "start": Vector2(0.568, 0.32), "guide": Vector2(0.499, 0.396),
	"lt": Vector2(0.231, 0.062), "lb": Vector2(0.278, 0.12), "rt": Vector2(0.77, 0.062), "rb": Vector2(0.724, 0.12),
}
const MOUSE_SPOTS : Dictionary = {
	"left": Vector2(0.309, 0.235), "right": Vector2(0.69, 0.235), "wheel": Vector2(0.499, 0.235),
	"body": Vector2(0.499, 0.679),
}

## The tooltips' look: the game's own (TooltipPanel).
const GAME_THEME : Theme = preload("res://ui/theme/game_theme.tres")

## The device the help shows now (InputDevice.Kind), -1 while closed.
var showing : int = -1

var _root : Control = null


func _init() -> void:
	layer = LAYER
	visible = false


## Open the help on [param kind]. It stays open, like the star map, until closed (see _input). Rebuilt
## on every opening: a binding may have changed since.
func show_for(kind: InputDevice.Kind) -> void:
	if showing == kind and visible:
		return
	if _root != null:
		remove_child(_root)  # out of the tree now: its tabs and tooltips must not linger a frame
		_root.queue_free()
	_root = _build(kind)
	add_child(_root)
	# In a centred 16:9 area on a wide screen, like the menus: at 21:9 the keyboard spread over the
	# whole width and the legend shrank into a corner. The veil still covers everything.
	SafeArea.keep(_root.get_node("Margin"))
	showing = kind
	visible = true


func hide_help() -> void:
	visible = false
	showing = -1


## The keys that close it: its own, Escape, and on the pad View (the way in), B and Start.
const CLOSING_ACTIONS : Array[StringName] = [&"controls_help", &"pause", &"star_map", &"ui_cancel"]


## Open, it owns the input like the star map: a closing key closes it, and every other key or pad button
## is spent here — Escape must not also open the pause menu behind it, F2 the chart, N mute the sound.
## Clicks go on to the help's own controls (its device tabs) and stop at its root (see _build). (What
## the game reads by polling is frozen by the player's input lock, which counts the help as modal.)
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if closes(event):
		hide_help()
		get_viewport().set_input_as_handled()
	elif blocks(event):
		get_viewport().set_input_as_handled()


static func closes(event: InputEvent) -> bool:
	for action: StringName in CLOSING_ACTIONS:
		if event.is_action_pressed(action):
			return true
	return false


## Whether the open help spends [param event] before anything sees it: the keys and the pad. The pointer
## is left to the help's controls, whose root stops it.
static func blocks(event: InputEvent) -> bool:
	return event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion


func _build(kind: InputDevice.Kind) -> Control:
	var rows : Array[Dictionary] = ControlsHelpRows.rows(kind)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The help is the pointer's only target: a click anywhere on it ends here, never in the game.
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.theme = GAME_THEME
	var veil := ColorRect.new()
	veil.color = BACKDROP
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(veil)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN_PX)
	root.add_child(margin)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 24)
	margin.add_child(column)
	column.add_child(_title_line(kind))
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", 56)
	column.add_child(body)
	var numbers : Dictionary = ControlsHelpRows.numbers_by_spot(rows)
	body.add_child(_diagram(kind, numbers, ControlsHelpRows.tips_by_spot(kind)))
	body.add_child(_legend(rows))
	return root


func _title_line(kind: InputDevice.Kind) -> Control:
	var line := HBoxContainer.new()
	var title := _label(tr("%%HELP_TITLE").to_upper(), TITLE_SIZE, ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(title)
	line.add_child(_device_tabs(kind))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(40, 0)
	line.add_child(gap)
	line.add_child(_label(closing_hint(kind), TEXT_SIZE, TEXT))
	return line


## The other device is one click away: the keyboard's player can see the pad's buttons too.
## The menus' own tabs (TabStrip), named like the controls page's columns.
func _device_tabs(kind: InputDevice.Kind) -> TabStrip:
	var tabs := TabStrip.new(TEXT_SIZE + 3)
	tabs.add_entry(&"keyboard", "%%KM_COLUMN_KEYBOARD")
	tabs.add_entry(&"pad", "%%KM_COLUMN_PAD")
	tabs.set_active(&"pad" if kind == InputDevice.Kind.GAMEPAD else &"keyboard")
	tabs.selected.connect(func(key: StringName) -> void:
		# Deferred: the tabs are freed by the rebuild their own signal asks for.
		show_for.call_deferred(InputDevice.Kind.GAMEPAD if key == &"pad" else InputDevice.Kind.KEYBOARD_MOUSE))
	return tabs


## How to close it on [param kind]: the key that opened it, or Escape (B on the pad).
static func closing_hint(kind: InputDevice.Kind) -> String:
	return InputLabel._tr("%%HELP_CLOSE") % [open_key(kind), MenuConfig._binding_text("ui_cancel", kind)]


## The key that opens the help on [param kind]: F1, or the pad button held (the star map's).
static func open_key(kind: InputDevice.Kind) -> String:
	return MenuConfig._binding_text("star_map" if kind == InputDevice.Kind.GAMEPAD else "controls_help", kind)


## The device drawn: the keyboard with the mouse beside it, or the gamepad. [param tips]: everything each
## key does, shown when the pointer rests on it (kept open).
func _diagram(kind: InputDevice.Kind, numbers: Dictionary, tips: Dictionary) -> Control:
	if kind == InputDevice.Kind.GAMEPAD:
		var pad := BadgedPicture.new(GAMEPAD_PICTURE, GAMEPAD_SPOTS)
		pad.numbers = numbers
		pad.tips = tips
		pad.max_share = GAMEPAD_SHARE
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.size_flags_stretch_ratio = 1.6
		return pad
	var both := HBoxContainer.new()
	both.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	both.size_flags_stretch_ratio = 1.6
	both.add_theme_constant_override("separation", 32)
	var keyboard := KeyboardDiagram.new()
	keyboard.numbers = numbers
	keyboard.tips = tips
	keyboard.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keyboard.size_flags_stretch_ratio = 4.0
	both.add_child(keyboard)
	var mouse := BadgedPicture.new(MOUSE_PICTURE, MOUSE_SPOTS)
	mouse.numbers = numbers
	mouse.tips = tips
	mouse.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	both.add_child(mouse)
	return both


## Number by number, what each lit key does, section by section under the menus' own headings (amber
## capitals over a rule, SettingsRowFactory.header). Each section is a grid of three columns (number,
## keys, action); the keys' column is as wide as the longest of ALL sections, so the sections line up,
## and the legend stays close to the picture instead of spreading to the far edge of the screen.
func _legend(rows: Array[Dictionary]) -> Control:
	var factory := SettingsRowFactory.new(TEXT_SIZE)
	var names_width : float = 0.0
	for row: Dictionary in rows:
		names_width = maxf(names_width, SettingsRowFactory.FONT.get_string_size(
				" ".join(row["names"]), HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_SIZE).x)
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_theme_constant_override("separation", SECTION_GAP_PX)
	var grid : GridContainer = null
	var section : String = ""
	for row: Dictionary in rows:
		if row["section"] != section:
			section = row["section"]
			list.add_child(_heading(factory, section))
			grid = GridContainer.new()
			grid.columns = 3
			grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
			grid.add_theme_constant_override("h_separation", 14)
			grid.add_theme_constant_override("v_separation", 6)
			list.add_child(grid)
		grid.add_child(_badge(row["number"]))
		var names := _label(" ".join(row["names"]), TEXT_SIZE, ACCENT)
		names.custom_minimum_size = Vector2(names_width, 0)
		grid.add_child(names)
		grid.add_child(_label(tr(row["label"]), TEXT_SIZE, TEXT))
	return list


## A section's heading: the menus' own (SettingsRowFactory.header), its rule drawn 2 px and amber. At
## 1 px it fell on a half pixel under the first heading and all but vanished, and the sections ran
## into one another.
func _heading(factory: SettingsRowFactory, section: String) -> Label:
	var heading : Label = factory.header(section)
	var rule := heading.get_theme_stylebox("normal") as StyleBoxFlat
	rule.border_width_bottom = 2
	rule.border_color = Color(ACCENT, 0.7)
	rule.content_margin_bottom = 8.0
	return heading


## A line's number: the very badge the picture carries (BadgedPicture.draw_badge), drawn in a box of
## its own so the grid lines it up.
func _badge(number: int) -> Control:
	var badge := Control.new()
	badge.custom_minimum_size = Vector2(LEGEND_BADGE_PX, LEGEND_BADGE_PX)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.draw.connect(func() -> void:
		BadgedPicture.draw_badge(badge, badge.size * 0.5, str(number), LEGEND_BADGE_PX))
	return badge


func _label(text: String, font_size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # translated above, names left as they are
	label.add_theme_font_override("font", SettingsRowFactory.FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", colour)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
