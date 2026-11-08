class_name ServiceStyle
extends RefCounted

## One vocabulary of colours, fonts and StyleBoxes for the DataPad (A.R.E.S. OS). Every section is
## built in code, so the look has to live somewhere central — this is that place, the way
## [SettingsStyle] is for the settings pages.
##
## The palette and the recipes follow the A.R.E.S. OS mock-up (2026-11): a near-black ground, neutral
## panels with a hairline edge, one amber voice for "you are here" and the primary action. Poppins
## carries the text; Xolonium, the ARES face of the town halls and the neon signs, carries the titles,
## the brand, the clock and the big figures. The mock-up is drawn at 1440 px wide; the tablet is laid
## out at 1920, so its sizes are scaled up here rather than copied.

const FONT := preload("res://ui/Poppins-Regular.ttf")
const FONT_BOLD := preload("res://ui/Poppins-Bold.ttf")
const FONT_ITALIC := preload("res://ui/Poppins-Italic.ttf")
const FONT_BOLD_ITALIC := preload("res://ui/Poppins-BoldItalic.ttf")
## The ARES face: titles, brand, clock, big figures.
const FONT_ARES := preload("res://assets/fonts/Xolonium/Xolonium-Regular.ttf")

# Surfaces, from the window down to a hovered row.
const BG: Color = Color("#0A0D12")
const RAIL: Color = Color("#07090D")
const PANEL: Color = Color("#10141B")
const SURFACE: Color = Color("#171C26")
const SURFACE_2: Color = Color("#141922")
const FIELD_BG: Color = Color("#0D1117")
const SEG_BG: Color = Color("#11151D")
const SELECTED_BG: Color = Color("#1B2130")
const TRACK: Color = Color("#232B3A")
# Back-compat names the sections still use.
const PANEL_ALT: Color = SURFACE
const SURFACE_HOVER: Color = Color("#1D2330")
const SURFACE_PRESSED: Color = FIELD_BG

# Lines.
const LINE: Color = Color("#1F2633")
const LINE_2: Color = Color("#2D3646")
const LINE_HOVER: Color = Color("#3A4558")
const LINE_CARD: Color = Color("#232B3A")
const LINE_DASH: Color = Color("#283041")
const BORDER: Color = LINE
const BORDER_STRONG: Color = LINE_2

# Voice.
const ACCENT: Color = Color("#F5B83D")
const ACCENT_HOVER: Color = Color("#FFC65A")
const ACCENT_PRESSED: Color = Color("#D99F2B")
const ACCENT_SOFT: Color = Color("#2A2110")
const ACCENT_LINE: Color = Color(0.961, 0.722, 0.239, 0.55)
const ON_ACCENT: Color = Color("#1A1200")
const TEXT: Color = Color("#E6E9EF")
const TEXT_2: Color = Color("#B4BCCB")
const MUTED: Color = Color("#9AA3B5")
const HINT: Color = Color("#8A93A6")
const PLACEHOLDER: Color = Color("#6B7488")
const INFO: Color = Color("#8FD3E8")
const GOOD: Color = Color("#6EE7B7")
const GOOD_SOFT: Color = Color("#10302A")
const WARN: Color = Color("#F49A9A")
const WARN_LINE: Color = Color("#4A2328")
# Back-compat alias used by the panels' unqualified names.
const DIM: Color = MUTED

const RADIUS: int = 12
const RADIUS_SMALL: int = 10
const RADIUS_PANEL: int = 16

## Text sizes at the tablet's 1920 px (the mock-up's sizes, scaled).
const SIZE_BODY: int = 16
const SIZE_SMALL: int = 14
const SIZE_CAPTION: int = 13
const SIZE_TITLE: int = 32
const SIZE_HEADING: int = 30
const SIZE_BIG: int = 34

## Button kinds for [method apply_button_kind].
enum ButtonKind { SECONDARY, PRIMARY, GHOST, DANGER }


# ---------------------------------------------------------------------------------------------
# StyleBox factories
# ---------------------------------------------------------------------------------------------

static func flat(bg: Color, radius: int = RADIUS, border: Color = BORDER, border_width: int = 1,
		pad_x: float = 0.0, pad_y: float = 0.0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.set_corner_radius_all(radius)
	if border_width > 0:
		box.set_border_width_all(border_width)
		box.border_color = border
	if pad_x > 0.0:
		box.content_margin_left = pad_x
		box.content_margin_right = pad_x
	if pad_y > 0.0:
		box.content_margin_top = pad_y
		box.content_margin_bottom = pad_y
	return box


static func empty() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()


## A box with only a bottom line: the header's rule, a sub-tab's underline.
static func underline(colour: Color, width: int = 1, pad_x: float = 0.0, pad_y: float = 0.0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color.TRANSPARENT
	box.border_width_bottom = width
	box.border_color = colour
	box.content_margin_left = pad_x
	box.content_margin_right = pad_x
	box.content_margin_top = pad_y
	box.content_margin_bottom = pad_y
	return box


# ---------------------------------------------------------------------------------------------
# Applying the look to a control
# ---------------------------------------------------------------------------------------------

static func font_of(control: Control, size: int = 0, bold: bool = false) -> void:
	control.add_theme_font_override("font", FONT_BOLD if bold else FONT)
	if size > 0:
		control.add_theme_font_size_override("font_size", size)


## The ARES face (Xolonium) on a title, the brand, the clock or a big figure.
static func ares_of(control: Control, size: int = 0) -> void:
	control.add_theme_font_override("font", FONT_ARES)
	if size > 0:
		control.add_theme_font_size_override("font_size", size)


## A ready label: [param text] in [param colour], Poppins (bold or not) at [param size].
static func label(text: String, colour: Color = TEXT, size: int = SIZE_BODY, bold: bool = false) -> Label:
	var made := Label.new()
	made.text = text
	made.add_theme_color_override("font_color", colour)
	font_of(made, size, bold)
	return made


## A ready label in the ARES face: a title, a big figure.
static func ares_label(text: String, colour: Color = TEXT, size: int = SIZE_BIG) -> Label:
	var made := Label.new()
	made.text = text
	made.add_theme_color_override("font_color", colour)
	ares_of(made, size)
	return made


## The window itself: the tablet's near-black slab.
static func apply_window(panel: Panel) -> void:
	var box := flat(Color(BG, 0.98), 20, Color("#222A38"), 1)
	box.shadow_color = Color(0, 0, 0, 0.45)
	box.shadow_size = 18
	panel.add_theme_stylebox_override("panel", box)


## One of the tablet's content panels (the main card, the action column): a dark slab inside a
## hairline. [param _glow] is kept for the callers of the amber-framed look it replaced.
static func apply_frame(panel: PanelContainer, _glow: float = 0.0) -> void:
	panel.add_theme_stylebox_override("panel", flat(PANEL, RADIUS_PANEL, LINE, 1, 28.0, 26.0))


## A card inside a panel: a stat, a summary, a fact (the mock-up's `.card`).
static func apply_card(panel: PanelContainer, pad: float = 20.0) -> void:
	panel.add_theme_stylebox_override("panel", flat(SURFACE, RADIUS, LINE_CARD, 1, pad, pad * 0.9))


## A bottom-bar tab: a bare tile, muted, lit amber-on-amber-soft while it is the one on show.
static func apply_nav(button: Button, active: bool) -> void:
	var normal: StyleBoxFlat = flat(ACCENT_SOFT, RADIUS_SMALL, ACCENT, 1, 16.0, 14.0) if active \
			else flat(Color.TRANSPARENT, RADIUS_SMALL, Color.TRANSPARENT, 1, 16.0, 14.0)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover",
			flat(ACCENT_SOFT if active else SEG_BG, RADIUS_SMALL,
					ACCENT if active else Color.TRANSPARENT, 1, 16.0, 14.0))
	button.add_theme_stylebox_override("pressed", flat(ACCENT_SOFT, RADIUS_SMALL, ACCENT, 1, 16.0, 14.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT, 1))
	button.add_theme_stylebox_override("disabled",
			flat(Color.TRANSPARENT, RADIUS_SMALL, Color.TRANSPARENT, 1, 16.0, 14.0))
	var text: Color = ACCENT if active else MUTED
	button.add_theme_color_override("font_color", text)
	button.add_theme_color_override("font_hover_color", ACCENT if active else TEXT)
	button.add_theme_color_override("font_pressed_color", ACCENT)
	button.add_theme_color_override("font_disabled_color", MUTED)
	button.add_theme_color_override("font_focus_color", text)
	font_of(button, 15, true)


## The common button: secondary (surface, hairline), as every section has always called it.
static func apply_button(button: Button, primary: bool = false) -> void:
	apply_button_kind(button, ButtonKind.PRIMARY if primary else ButtonKind.SECONDARY)


## A button of a given [enum ButtonKind]: the amber call to action, the plain secondary, the bare
## ghost (Cancel) or the red-edged danger (Abandon).
static func apply_button_kind(button: Button, kind: ButtonKind) -> void:
	var bg: Color = SURFACE
	var hover_bg: Color = SURFACE
	var pressed_bg: Color = FIELD_BG
	var edge: Color = LINE_2
	var hover_edge: Color = LINE_HOVER
	var ink: Color = TEXT
	match kind:
		ButtonKind.PRIMARY:
			bg = ACCENT
			hover_bg = ACCENT_HOVER
			pressed_bg = ACCENT_PRESSED
			edge = ACCENT
			hover_edge = ACCENT_HOVER
			ink = ON_ACCENT
		ButtonKind.GHOST:
			bg = Color.TRANSPARENT
			hover_bg = SEG_BG
			pressed_bg = FIELD_BG
		ButtonKind.DANGER:
			bg = Color.TRANSPARENT
			hover_bg = Color(WARN, 0.08)
			pressed_bg = Color(WARN, 0.14)
			edge = WARN_LINE
			hover_edge = WARN
			ink = WARN
	button.add_theme_stylebox_override("normal", flat(bg, RADIUS_SMALL, edge, 1, 18.0, 10.0))
	button.add_theme_stylebox_override("hover", flat(hover_bg, RADIUS_SMALL, hover_edge, 1, 18.0, 10.0))
	button.add_theme_stylebox_override("pressed", flat(pressed_bg, RADIUS_SMALL, hover_edge, 1, 18.0, 10.0))
	button.add_theme_stylebox_override("disabled",
			flat(Color(bg, bg.a * 0.45), RADIUS_SMALL, Color(edge, 0.45), 1, 18.0, 10.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT, 2))
	button.add_theme_color_override("font_color", ink)
	button.add_theme_color_override("font_hover_color", ink)
	button.add_theme_color_override("font_pressed_color", ink)
	button.add_theme_color_override("font_disabled_color", Color(ink, 0.45))
	button.add_theme_color_override("font_focus_color", ink)
	font_of(button, SIZE_BODY, kind == ButtonKind.PRIMARY)


## A text link (the mock-up's "Open the bank →"): amber words, no box.
static func apply_link(button: Button) -> void:
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, empty())
	button.add_theme_color_override("font_color", ACCENT)
	button.add_theme_color_override("font_hover_color", Color("#FFD27A"))
	button.add_theme_color_override("font_pressed_color", ACCENT_PRESSED)
	button.add_theme_color_override("font_focus_color", ACCENT)
	button.add_theme_color_override("font_disabled_color", MUTED)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	font_of(button, SIZE_SMALL, true)


static func apply_field(field: LineEdit) -> void:
	field.add_theme_stylebox_override("normal", flat(FIELD_BG, RADIUS_SMALL, LINE_2, 1, 16.0, 10.0))
	field.add_theme_stylebox_override("focus", flat(FIELD_BG, RADIUS_SMALL, ACCENT, 1, 16.0, 10.0))
	field.add_theme_stylebox_override("read_only", flat(PANEL, RADIUS_SMALL, LINE, 1, 16.0, 10.0))
	field.add_theme_color_override("font_color", TEXT)
	field.add_theme_color_override("font_placeholder_color", PLACEHOLDER)
	field.add_theme_color_override("font_uneditable_color", MUTED)
	field.add_theme_color_override("caret_color", ACCENT)
	field.add_theme_color_override("selection_color", Color(ACCENT, 0.25))
	font_of(field, SIZE_BODY)


static func apply_textarea(area: TextEdit) -> void:
	area.add_theme_stylebox_override("normal", flat(FIELD_BG, RADIUS_SMALL, LINE_2, 1, 16.0, 12.0))
	area.add_theme_stylebox_override("focus", flat(FIELD_BG, RADIUS_SMALL, ACCENT, 1, 16.0, 12.0))
	area.add_theme_stylebox_override("read_only", flat(PANEL, RADIUS_SMALL, LINE, 1, 16.0, 12.0))
	area.add_theme_color_override("font_color", TEXT)
	area.add_theme_color_override("font_placeholder_color", PLACEHOLDER)
	area.add_theme_color_override("caret_color", ACCENT)
	area.add_theme_color_override("selection_color", Color(ACCENT, 0.25))
	font_of(area, SIZE_BODY)


## Rich text uses dedicated theme items (not `font`): set every face so BBCode bold/italic render with
## the project's Poppins, not the engine default.
static func apply_rich_text(label_node: RichTextLabel, size: int = 15) -> void:
	label_node.add_theme_font_override("normal_font", FONT)
	label_node.add_theme_font_override("bold_font", FONT_BOLD)
	label_node.add_theme_font_override("italics_font", FONT_ITALIC)
	label_node.add_theme_font_override("bold_italics_font", FONT_BOLD_ITALIC)
	label_node.add_theme_font_size_override("normal_font_size", size)
	label_node.add_theme_font_size_override("bold_font_size", size)
	label_node.add_theme_font_size_override("italics_font_size", size)
	label_node.add_theme_font_size_override("bold_italics_font_size", size)
	label_node.add_theme_color_override("default_color", TEXT)


## A list of rows: each row a dark tile, the selected one amber-edged (the mock-up's `.item`).
static func apply_list(list: ItemList) -> void:
	list.add_theme_stylebox_override("panel", flat(Color.TRANSPARENT, RADIUS, Color.TRANSPARENT, 0))
	var selected := flat(SELECTED_BG, RADIUS, ACCENT, 1, 16.0, 12.0)
	list.add_theme_stylebox_override("selected", selected)
	list.add_theme_stylebox_override("selected_focus", selected)
	list.add_theme_stylebox_override("hovered", flat(SURFACE_2, RADIUS, LINE_HOVER, 1, 16.0, 12.0))
	list.add_theme_stylebox_override("hovered_selected", selected)
	list.add_theme_stylebox_override("hovered_selected_focus", selected)
	list.add_theme_stylebox_override("cursor", empty())
	list.add_theme_stylebox_override("cursor_unfocused", empty())
	list.add_theme_stylebox_override("focus", empty())
	list.add_theme_color_override("font_color", TEXT)
	list.add_theme_color_override("font_selected_color", TEXT)
	list.add_theme_color_override("font_hovered_color", TEXT)
	list.add_theme_constant_override("v_separation", 14)
	list.add_theme_constant_override("h_separation", 10)
	font_of(list, SIZE_BODY)


static func apply_option(option: OptionButton) -> void:
	option.add_theme_stylebox_override("normal", flat(FIELD_BG, RADIUS_SMALL, LINE_2, 1, 16.0, 10.0))
	option.add_theme_stylebox_override("hover", flat(FIELD_BG, RADIUS_SMALL, LINE_HOVER, 1, 16.0, 10.0))
	option.add_theme_stylebox_override("pressed", flat(FIELD_BG, RADIUS_SMALL, ACCENT, 1, 16.0, 10.0))
	option.add_theme_stylebox_override("disabled",
			flat(Color(FIELD_BG, 0.5), RADIUS_SMALL, Color(LINE_2, 0.5), 1, 16.0, 10.0))
	option.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT_LINE, 1))
	for colour: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		option.add_theme_color_override(colour, TEXT)
	option.add_theme_color_override("font_disabled_color", Color(TEXT, 0.45))
	font_of(option, SIZE_BODY)


## The groove a segmented control sits in (the mock-up's `.seg`): its pills are [method apply_segment].
static func apply_segment_groove(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", flat(SEG_BG, RADIUS, LINE, 1, 5.0, 5.0))


## A segment of a segmented control: a bare label, filled amber while it is the open one.
static func apply_segment(button: Button, active: bool) -> void:
	var on := flat(ACCENT, RADIUS_SMALL - 2, ACCENT, 0, 22.0, 10.0)
	var off := flat(Color.TRANSPARENT, RADIUS_SMALL - 2, Color.TRANSPARENT, 0, 22.0, 10.0)
	button.add_theme_stylebox_override("normal", on if active else off)
	button.add_theme_stylebox_override("hover",
			on if active else flat(SURFACE, RADIUS_SMALL - 2, Color.TRANSPARENT, 0, 22.0, 10.0))
	button.add_theme_stylebox_override("pressed", on)
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL - 2, ACCENT_LINE, 1))
	button.add_theme_stylebox_override("disabled", off)
	var text: Color = ON_ACCENT if active else TEXT_2
	button.add_theme_color_override("font_color", text)
	button.add_theme_color_override("font_hover_color", ON_ACCENT if active else TEXT)
	button.add_theme_color_override("font_pressed_color", ON_ACCENT)
	button.add_theme_color_override("font_focus_color", text)
	button.add_theme_color_override("font_disabled_color", Color(TEXT_2, 0.45))
	font_of(button, SIZE_BODY, active)


## A sub-tab (the mock-up's `.subtab`): words over a 2 px line, amber while it is the open one.
static func apply_subtab(button: Button, active: bool) -> void:
	var line: Color = ACCENT if active else Color.TRANSPARENT
	button.add_theme_stylebox_override("normal", underline(line, 2, 2.0, 16.0))
	button.add_theme_stylebox_override("hover", underline(line, 2, 2.0, 16.0))
	button.add_theme_stylebox_override("pressed", underline(ACCENT, 2, 2.0, 16.0))
	button.add_theme_stylebox_override("focus", underline(ACCENT_LINE, 2, 2.0, 16.0))
	button.add_theme_stylebox_override("disabled", underline(Color.TRANSPARENT, 2, 2.0, 16.0))
	var text: Color = ACCENT if active else MUTED
	button.add_theme_color_override("font_color", text)
	button.add_theme_color_override("font_hover_color", ACCENT if active else TEXT)
	button.add_theme_color_override("font_pressed_color", ACCENT)
	button.add_theme_color_override("font_focus_color", text)
	button.add_theme_color_override("font_disabled_color", Color(MUTED, 0.45))
	font_of(button, SIZE_BODY, active)


## A choice chip (the mock-up's `.choice button`): a small toggle, amber-edged while chosen.
static func apply_choice(button: Button, active: bool) -> void:
	var box: StyleBoxFlat = flat(ACCENT_SOFT, RADIUS_SMALL, ACCENT, 1, 18.0, 9.0) if active \
			else flat(FIELD_BG, RADIUS_SMALL, LINE_2, 1, 18.0, 9.0)
	button.add_theme_stylebox_override("normal", box)
	button.add_theme_stylebox_override("hover",
			box if active else flat(FIELD_BG, RADIUS_SMALL, LINE_HOVER, 1, 18.0, 9.0))
	button.add_theme_stylebox_override("pressed", flat(ACCENT_SOFT, RADIUS_SMALL, ACCENT, 1, 18.0, 9.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT_LINE, 1))
	button.add_theme_stylebox_override("disabled", flat(FIELD_BG, RADIUS_SMALL, LINE, 1, 18.0, 9.0))
	var text: Color = ACCENT if active else TEXT_2
	for colour: String in ["font_color", "font_focus_color"]:
		button.add_theme_color_override(colour, text)
	button.add_theme_color_override("font_hover_color", ACCENT if active else TEXT)
	button.add_theme_color_override("font_pressed_color", ACCENT)
	font_of(button, SIZE_SMALL, true)


## A row tile (the mock-up's `.item`): a dark tile that lights under the pointer and stays
## amber-edged while it is the selected one.
static func apply_tile(button: Button, active: bool = false) -> void:
	var normal: StyleBoxFlat = flat(SELECTED_BG, RADIUS, ACCENT, 1, 16.0, 12.0) if active \
			else flat(SURFACE_2, RADIUS, Color("#222A38"), 1, 16.0, 12.0)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover",
			flat(SELECTED_BG if active else SURFACE_2, RADIUS, ACCENT if active else LINE_HOVER, 1, 16.0, 12.0))
	button.add_theme_stylebox_override("pressed", flat(SELECTED_BG, RADIUS, ACCENT, 1, 16.0, 12.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS, ACCENT_LINE, 1))
	button.add_theme_stylebox_override("disabled", flat(PANEL, RADIUS, LINE, 1, 16.0, 12.0))


## A card that is a button (the home's stat cards): a [method apply_card] that lights under the pointer.
static func apply_card_button(button: Button) -> void:
	button.add_theme_stylebox_override("normal", flat(SURFACE, RADIUS, LINE_CARD, 1, 22.0, 20.0))
	button.add_theme_stylebox_override("hover", flat(SURFACE, RADIUS, LINE_HOVER, 1, 22.0, 20.0))
	button.add_theme_stylebox_override("pressed", flat(SURFACE_2, RADIUS, ACCENT, 1, 22.0, 20.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS, ACCENT_LINE, 1))
	button.add_theme_stylebox_override("disabled", flat(SURFACE, RADIUS, LINE_CARD, 1, 22.0, 20.0))


static func apply_check(check: CheckBox) -> void:
	check.add_theme_color_override("font_color", TEXT)
	check.add_theme_color_override("font_hover_color", ACCENT)
	check.add_theme_color_override("font_pressed_color", ACCENT)
	font_of(check, SIZE_BODY)


## The coloured status pill (the mock-up's `.pill`): a soft fill of [param colour], no edge.
static func apply_pill(panel: PanelContainer, colour: Color) -> void:
	var soft: Color = GOOD_SOFT if colour == GOOD else Color(colour, 0.14)
	panel.add_theme_stylebox_override("panel", flat(soft, 999, Color.TRANSPARENT, 0, 14.0, 5.0))


## A small square badge (a mission's step, a good's code — the mock-up's `.thumb`).
static func apply_thumb(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", flat(Color("#202838"), RADIUS_SMALL, Color.TRANSPARENT, 0, 6.0, 6.0))
