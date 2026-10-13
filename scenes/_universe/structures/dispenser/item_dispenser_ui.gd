class_name ItemDispenserUI
extends Panel

## An item dispenser's screen (ItemDispenser): the logo of the ARES subsidiary running the machine
## and its title, one row per item (its pictogram and its name), what the machine is doing, and
## DISPENSE. Borderless: flat rows on the dark screen, the chosen one lit in the subsidiary's colour
## (AresBrand). While an item is on its way the rows give way to a ring that fills, the seconds left in
## its middle. Pure display: it says which item was asked for and is told about the delivery and the
## hatch; the dispenser does the rest. setup() builds it, once the machine says whose it is.

signal dispense_requested(spec_path: String)

const BG_COLOR := Color(0.06, 0.07, 0.09)
const TEXT := Color(0.92, 0.93, 0.95)
const DIM := Color(1.0, 1.0, 1.0, 0.55)
const TITLE_FONT: int = 30
const BUTTON_FONT: int = 34
const ROW_FONT: int = 26
const STATUS_FONT: int = 24
const ROW_PX: int = 84
## Height (px) of the subsidiary's logo in the header.
const LOGO_PX: float = 56.0
const ICON_PX: int = 72
## The delivery ring: its line width and the countdown's size (px).
const RING_WIDTH_PX: float = 16.0
const RING_FONT: int = 110
## How long (s) a request waits for its delivery to be announced, or a delivery for its item in the
## hatch, before the button comes back: the server may have refused it (busy, hatch full meanwhile).
const ANSWER_WAIT_S: float = 2.0
## How long (s) a refusal stays on the status line.
const REFUSAL_SHOWN_S: float = 3.0

var _rows: VBoxContainer
var _group := ButtonGroup.new()
var _status: Label
var _dispense: Button
var _tray_full: bool = false
## An item was asked for and the hatch has not filled yet; until when (ms) to wait for news of it.
var _waiting: bool = false
var _waiting_until_ms: int = 0
## A refusal on the status line (a translation key) and until when (ms).
var _refusal_key: String = ""
var _refusal_until_ms: int = 0
## The delivery on show: when it ends (ms) and how long it lasts (s); 0 when none.
var _delivery_end_ms: int = 0
var _delivery_total_s: float = 0.0
var _ring: DeliveryRing
## The subsidiary's colour (AresBrand): the screen's lines, its chosen row, its ring, its button.
var _accent: Color = Color.WHITE


## Build the screen for [param subsidiary] (AresBrand), under [param title_key], offering [param items]
## (DispenserCatalog); the first one chosen.
func setup(subsidiary: AresBrand.Subsidiary, title_key: String, items: Array[Resource]) -> void:
	_accent = AresBrand.colour(subsidiary)
	_build(subsidiary, title_key)
	show_items(items)


func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_msec()
	if _delivery_end_ms > 0:
		var left: float = maxf(float(_delivery_end_ms - now) / 1000.0, 0.0)
		_ring.show_left(left, _delivery_total_s)
		if left <= 0.0:
			_delivery_end_ms = 0
			_ring.visible = false
			_rows.visible = true
	if _waiting and now > _waiting_until_ms:
		_waiting = false  # no news: refused, the button comes back
		_show_status()
	if _refusal_key != "" and now > _refusal_until_ms:
		_refusal_key = ""
		_show_status()


## The server said no ([param reason_key], a translation key): on the status line for a while, and
## the button back at once.
func show_refusal(reason_key: String) -> void:
	_refusal_key = reason_key
	_refusal_until_ms = Time.get_ticks_msec() + int(REFUSAL_SHOWN_S * 1000.0)
	_waiting = false
	_show_status()


## A delivery is on its way: [param left_s] of [param total_s] s still to go. The rows give way to
## the ring until it is over.
func start_delivery(left_s: float, total_s: float) -> void:
	_delivery_total_s = total_s
	_delivery_end_ms = Time.get_ticks_msec() + int(left_s * 1000.0)
	_waiting = true
	_waiting_until_ms = _delivery_end_ms + int(ANSWER_WAIT_S * 1000.0)
	_rows.visible = false
	_ring.visible = true
	_ring.show_left(left_s, total_s)
	_show_status()


## One row per item of [param items] (DispenserCatalog.all); the first one chosen.
func show_items(items: Array[Resource]) -> void:
	for child in _rows.get_children():
		child.queue_free()
	var first: Button = null
	for item: Resource in items:
		var row := _item_row(item)
		_rows.add_child(row)
		first = row if first == null else first
	if first != null:
		first.button_pressed = true
	_show_status()


## Something lies in the hatch ([param full]): nothing more until it is taken.
func set_tray_full(full: bool) -> void:
	_tray_full = full
	if full:
		_waiting = false
	_show_status()


## The path of the chosen item's .tres, "" when none.
func chosen() -> String:
	var pressed: BaseButton = _group.get_pressed_button()
	return str(pressed.get_meta("spec_path", "")) if pressed != null else ""


## What the status line says: [param tray_full] hatch, [param waiting] for one asked for, else pick.
static func status_key(tray_full: bool, waiting: bool) -> String:
	if tray_full:
		return "%%DISPENSER_TAKE_ITEMS"
	return "%%DISPENSER_SENT" if waiting else "%%DISPENSER_PICK"


func _show_status() -> void:
	if _status == null:
		return
	_status.text = _refusal_key if _refusal_key != "" else status_key(_tray_full, _waiting)
	_status.add_theme_color_override("font_color", _accent if _tray_full or _refusal_key != "" else DIM)
	_dispense.disabled = _tray_full or _waiting or chosen() == ""


func _on_dispense_pressed() -> void:
	var path: String = chosen()
	if path == "" or _tray_full:
		return
	_waiting = true
	_waiting_until_ms = Time.get_ticks_msec() + int(ANSWER_WAIT_S * 1000.0)
	_show_status()
	dispense_requested.emit(path)


func _build(subsidiary: AresBrand.Subsidiary, title_key: String) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	add_theme_stylebox_override("panel", bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	column.add_child(_header(subsidiary, title_key))
	var rule := ColorRect.new()
	rule.color = _accent
	rule.custom_minimum_size = Vector2(0, 4)
	column.add_child(rule)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 8)
	_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_rows)
	_ring = DeliveryRing.new()
	_ring.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ring.visible = false
	_ring.colour = _accent
	_ring.width = RING_WIDTH_PX
	_ring.font = AresBrand.font() if AresBrand.font() != null else ThemeDB.fallback_font
	_ring.font_size = RING_FONT
	column.add_child(_ring)
	_status = _label("", STATUS_FONT, DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_dispense = Button.new()
	_dispense.text = "%%DISPENSER_DISPENSE"
	_dispense.custom_minimum_size = Vector2(0, 80)
	_dispense.focus_mode = Control.FOCUS_NONE
	_style_button(_dispense, _accent, BG_COLOR, BUTTON_FONT)
	_dispense.pressed.connect(_on_dispense_pressed)
	column.add_child(_dispense)


func _header(subsidiary: AresBrand.Subsidiary, title_key: String) -> Control:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 20)
	line.add_child(AresBrand.logo_control(subsidiary, LOGO_PX))
	var title := _label(title_key, TITLE_FONT, _accent)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.custom_minimum_size = Vector2(1, 0)  # may shrink: the screen is narrow
	line.add_child(title)
	return line


## An item's row: its pictogram and translated name, a flat toggle of the items' group.
func _item_row(item: Resource) -> Button:
	var row := Button.new()
	row.toggle_mode = true
	row.button_group = _group
	row.text = str(item.get("display_name"))
	row.icon = item.get("icon")
	row.expand_icon = false
	row.add_theme_constant_override("icon_max_width", ICON_PX)
	row.add_theme_constant_override("h_separation", 28)
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.clip_text = true
	row.custom_minimum_size = Vector2(0, ROW_PX)
	row.focus_mode = Control.FOCUS_NONE
	row.set_meta("spec_path", item.resource_path)
	_style_button(row, Color(1, 1, 1, 0.0), TEXT, ROW_FONT)
	var lit := StyleBoxFlat.new()
	lit.bg_color = Color(_accent, 0.22)
	lit.border_color = _accent
	lit.border_width_left = 6
	lit.content_margin_left = 20
	for state: String in ["pressed", "hover_pressed"]:
		row.add_theme_stylebox_override(state, lit)
	row.add_theme_color_override("font_pressed_color", _accent)
	row.add_theme_color_override("font_hover_pressed_color", _accent)
	row.add_theme_color_override("icon_pressed_color", _accent)
	row.toggled.connect(func(_on: bool) -> void: _show_status())
	return row


## Flat [param fill] background (lighter when hovered), [param ink] text at [param font_size].
static func _style_button(button: Button, fill: Color, ink: Color, font_size: int) -> void:
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = fill.lightened(0.15) if state == "hover" and fill.a > 0.0 \
				else (Color(1, 1, 1, 0.06) if state == "hover" else fill)
		if state == "disabled":
			box.bg_color = Color(fill, fill.a * 0.35)
		box.content_margin_left = 20
		box.content_margin_right = 20
		button.add_theme_stylebox_override(state, box)
	button.add_theme_font_size_override("font_size", font_size)
	for key: String in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(key, ink)
	button.add_theme_color_override("font_disabled_color", Color(ink, 0.4))
	if AresBrand.font() != null:
		button.add_theme_font_override("font", AresBrand.font())


static func _label(text: String, font_size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", colour)
	if AresBrand.font() != null:
		label.add_theme_font_override("font", AresBrand.font())
	return label


## A ring that fills as a delivery goes on, the whole seconds left in its middle.
class DeliveryRing:
	extends Control

	var colour: Color = Color.WHITE
	var width: float = 16.0
	var font: Font
	var font_size: int = 110
	## How much of the delivery is done (0..1) and the whole seconds left.
	var progress: float = 0.0
	var seconds: int = 0

	## [param left_s] of [param total_s] s still to go.
	func show_left(left_s: float, total_s: float) -> void:
		progress = 1.0 - clampf(left_s / total_s, 0.0, 1.0) if total_s > 0.0 else 1.0
		seconds = ceili(left_s)
		queue_redraw()

	func _draw() -> void:
		var centre: Vector2 = size * 0.5
		var radius: float = minf(size.x, size.y) * 0.5 - width
		draw_arc(centre, radius, 0.0, TAU, 96, Color(colour, 0.15), width, true)
		if progress > 0.0:
			draw_arc(centre, radius, -PI * 0.5, -PI * 0.5 + TAU * progress, 96, colour, width, true)
		if font != null:
			var text: String = str(seconds)
			var height: float = font.get_ascent(font_size) - font.get_descent(font_size)
			draw_string(font, Vector2(0.0, centre.y + height * 0.5), text, HORIZONTAL_ALIGNMENT_CENTER,
					size.x, font_size, colour)
