class_name TeleporterUI
extends Panel

## The teleporter's screen: System → Body → Destination, or coordinates typed by hand.
##
## PRESENTATION ONLY. It emits [signal teleport_requested] and knows nothing about the network, the
## server or how a landing is worked out — same division as the mining depot's screen, which is a
## Panel with two buttons and a signal.
##
## THE COORDINATE FIELDS ARE THE TRUTH. Picking something in the list FILLS them; the button always
## sends what they hold. So there is never a question of which of the two won, and adjusting a POI by
## a few degrees is just editing a number rather than a separate mode.
##
## Built in code rather than as a scene, like [StarMap]: the project has no shared theme, so a screen
## laid out by hand would be a pile of per-scene sub-resources nobody can restyle later.

## A destination was validated. The payload is [method TeleportDestination.to_payload].
signal teleport_requested(payload: Dictionary)

const FONT_PATH: String = "res://assets/fonts/Xolonium/Xolonium-Regular.ttf"
const BG_COLOR: Color = Color(0.06, 0.07, 0.09, 0.92)
const ACCENT: Color = Color(1.0, 0.73, 0.03)  # the project's amber
const DIM: Color = Color(0.62, 0.66, 0.72)
const WARN: Color = Color(1.0, 0.45, 0.35)

var _system: String = ""
var _body_key: String = ""
var _all_dests: Array[TeleportDestination] = []
var _shown_dests: Array[TeleportDestination] = []
var _return_dest: TeleportDestination = null
var _enabled: bool = true

var _system_list: ItemList
var _body_list: ItemList
var _dest_list: ItemList
var _filter: LineEdit
var _lon: LineEdit
var _lat: LineEdit
var _height: LineEdit
var _mode: OptionButton
var _status: Label
var _go_button: Button
var _return_button: Button


func _ready() -> void:
	# The headless server instantiates this scene like any other, but it has nothing to draw and no
	# font to load. Nothing server-side ever calls into here — Teleporter keeps the two sides apart.
	if GameOrchestrator.is_server():
		return
	custom_minimum_size = Vector2(1400, 720)
	_build()


## Escape releases the field instead of pausing the game, and the game must not act on it either.
## Exactly the chat's problem and the chat's answer: a focused LineEdit consumes keys before
## _unhandled_input ever sees them, so anything that has to beat the field is caught here.
func _input(event: InputEvent) -> void:
	if not is_typing():
		return
	if event.is_action_pressed("pause"):
		_release_fields()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------------------------
# Public API — used by Teleporter
# ---------------------------------------------------------------------------------------------

## True while a text field has the keyboard. PlayerClient reads this (through the screen) to stop the
## game acting on what is being typed: most gameplay POLLS the Input singleton, which a focused
## LineEdit cannot consume, so typing "1750" into the height would otherwise equip the mining tool.
func is_typing() -> bool:
	for field: LineEdit in [_filter, _lon, _lat, _height]:
		if field != null and field.has_focus():
			return true
	return false


func set_enabled(on: bool) -> void:
	_enabled = on
	_refresh_buttons()
	if not on:
		_say("Teleporter switched off (Globals.ENABLED_DEV_TOOLS).", WARN)


func load_systems(systems: PackedStringArray, preferred: String) -> void:
	_system_list.clear()
	var pick: int = 0
	for i: int in range(systems.size()):
		_system_list.add_item(systems[i].capitalize())
		_system_list.set_item_metadata(i, systems[i])
		if systems[i] == preferred:
			pick = i
	if _system_list.item_count == 0:
		_say("No system scenes found under %s." % SystemScenes.SYSTEMS_ROOT, WARN)
		return
	_system_list.select(pick)
	_on_system_picked(pick)


## Offer a way back to where the trip started. Null clears it — in deep space there is no lon/lat to
## come back to, and a button that cannot work must not look as though it could.
func set_return_point(dest: TeleportDestination) -> void:
	_return_dest = dest
	_refresh_buttons()


# ---------------------------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------------------------

func _on_system_picked(index: int) -> void:
	_system = str(_system_list.get_item_metadata(index))
	_body_list.clear()
	var rows: Array[Dictionary] = TeleportCatalog.bodies(_system)
	for i: int in range(rows.size()):
		# Moons are indented under their planet: the list is already sorted parent-first, so the
		# indent alone carries the hierarchy without a second widget.
		var prefix: String = "    " if rows[i]["is_moon"] else ""
		_body_list.add_item(prefix + str(rows[i]["label"]))
		_body_list.set_item_metadata(i, str(rows[i]["key"]))
	if _body_list.item_count > 0:
		_body_list.select(0)
		_on_body_picked(0)


func _on_body_picked(index: int) -> void:
	_body_key = str(_body_list.get_item_metadata(index))
	_all_dests = TeleportCatalog.destinations(_body_key)
	_apply_filter()


func _apply_filter() -> void:
	_shown_dests = TeleportCatalog.filter(_all_dests, _filter.text)
	_dest_list.clear()
	for dest: TeleportDestination in _shown_dests:
		var label: String = dest.label
		if dest.detail != "":
			label += "   —   %s" % dest.detail
		_dest_list.add_item(label)
	var poi_count: int = 0
	for dest: TeleportDestination in _all_dests:
		if dest.kind == TeleportDestination.Kind.POI:
			poi_count += 1
	if poi_count == 0:
		# Said plainly, because it is the normal case: eighteen of the nineteen bodies have no POI at
		# all, and an empty list with no explanation reads as a bug.
		_say("%s has no surveyed POI — the entries below are computed for any body." % _body_key, DIM)
	else:
		_say("%d POI on %s." % [poi_count, _body_key], DIM)


func _on_dest_picked(index: int) -> void:
	if index < 0 or index >= _shown_dests.size():
		return
	var dest: TeleportDestination = _shown_dests[index]
	_lon.text = "%.5f" % dest.lon
	_lat.text = "%.5f" % dest.lat
	_height.text = "%.1f" % dest.height
	_mode.select(0 if dest.height_mode == TeleportDestination.Height.GROUND else 1)
	_say(dest.describe(), DIM)


func _on_go_pressed() -> void:
	if not _enabled:
		return
	var dest: TeleportDestination = _typed_destination()
	if dest == null:
		return
	_release_fields()
	teleport_requested.emit(dest.to_payload())
	_say("Sent: %s" % dest.describe(), ACCENT)


func _on_return_pressed() -> void:
	if not _enabled or _return_dest == null:
		return
	_release_fields()
	teleport_requested.emit(_return_dest.to_payload())
	_say("Returning to %s" % _return_dest.describe(), ACCENT)


## What the fields currently describe, or null with the reason shown on screen.
func _typed_destination() -> TeleportDestination:
	if _body_key == "":
		_say("Pick a body first.", WARN)
		return null
	var dest: TeleportDestination = TeleportDestination.new(
			"Manual" if _dest_list.get_selected_items().is_empty() else _dest_list.get_item_text(
					_dest_list.get_selected_items()[0]),
			_body_key,
			_to_float(_lon.text), _to_float(_lat.text), _to_float(_height.text),
			TeleportDestination.Height.GROUND if _mode.selected == 0 \
					else TeleportDestination.Height.SEA,
			TeleportDestination.Kind.MANUAL)
	if not dest.is_valid():
		_say("Longitude must be -180..180, latitude -90..90.", WARN)
		return null
	return dest


func _release_fields() -> void:
	for field: LineEdit in [_filter, _lon, _lat, _height]:
		if field != null and field.has_focus():
			field.release_focus()


func _refresh_buttons() -> void:
	if _go_button != null:
		_go_button.disabled = not _enabled
	if _return_button != null:
		_return_button.disabled = not _enabled or _return_dest == null


func _say(message: String, colour: Color) -> void:
	if _status == null:
		return
	_status.text = message
	_status.add_theme_color_override("font_color", colour)


static func _to_float(text: String) -> float:
	var trimmed: String = text.strip_edges().replace(",", ".")
	return float(trimmed) if trimmed.is_valid_float() else NAN


# ---------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------

func _build() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	bg.set_border_width_all(2)
	bg.border_color = ACCENT * Color(1, 1, 1, 0.5)
	add_theme_stylebox_override("panel", bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)

	column.add_child(_title("TELEPORTER"))

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 18)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(columns)

	_system_list = ItemList.new()
	columns.add_child(_titled_column("SYSTEM", _system_list, 1))
	_system_list.item_selected.connect(_on_system_picked)

	_body_list = ItemList.new()
	columns.add_child(_titled_column("BODY", _body_list, 2))
	_body_list.item_selected.connect(_on_body_picked)

	_filter = LineEdit.new()
	_filter.placeholder_text = "filter…"
	_filter.text_changed.connect(func(_t: String) -> void: _apply_filter())
	_filter.text_submitted.connect(func(_t: String) -> void: _on_go_pressed())
	_dest_list = ItemList.new()
	_dest_list.item_selected.connect(_on_dest_picked)
	_dest_list.item_activated.connect(func(index: int) -> void:
		_on_dest_picked(index)
		_on_go_pressed())
	columns.add_child(_titled_column("DESTINATION", _dest_list, 3, _filter))

	column.add_child(_coordinate_row())

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 48)
	column.add_child(_status)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 14)
	column.add_child(buttons)
	_go_button = Button.new()
	_go_button.text = "TELEPORT"
	_go_button.custom_minimum_size = Vector2(260, 64)
	_go_button.pressed.connect(_on_go_pressed)
	buttons.add_child(_go_button)
	_return_button = Button.new()
	_return_button.text = "RETURN"
	_return_button.custom_minimum_size = Vector2(200, 64)
	_return_button.pressed.connect(_on_return_pressed)
	buttons.add_child(_return_button)
	_refresh_buttons()


func _coordinate_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_lon = _number_field("longitude")
	_lat = _number_field("latitude")
	_height = _number_field("height (m)")
	row.add_child(_label("LON", DIM))
	row.add_child(_lon)
	row.add_child(_label("LAT", DIM))
	row.add_child(_lat)
	row.add_child(_label("HEIGHT", DIM))
	row.add_child(_height)
	_mode = OptionButton.new()
	_mode.add_item("above ground")
	_mode.add_item("above sea level")
	row.add_child(_mode)
	return row


func _number_field(placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size = Vector2(190, 44)
	field.text_submitted.connect(func(_t: String) -> void: _on_go_pressed())
	return field


func _titled_column(title: String, list: ItemList, stretch: int,
		extra: Control = null) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_stretch_ratio = float(stretch)
	box.add_child(_label(title, ACCENT))
	if extra != null:
		box.add_child(extra)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.allow_reselect = true
	box.add_child(list)
	return box


func _title(text: String) -> Label:
	var label := _label(text, ACCENT)
	label.add_theme_font_size_override("font_size", 34)
	return label


func _label(text: String, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", colour)
	if ResourceLoader.exists(FONT_PATH):
		label.add_theme_font_override("font", load(FONT_PATH))
	return label
