class_name ServiceStyle
extends RefCounted

## One vocabulary of colours, fonts and StyleBoxes for the services terminal. Every section is built in
## code, so the look has to live somewhere central — this is that place, the way [SettingsStyle] is for
## the settings pages. Poppins is the project's UI face (the settings menus use it); the amber is the
## one the whole game already uses for "you are here".

const FONT := preload("res://ui/Poppins-Regular.ttf")
const FONT_BOLD := preload("res://ui/Poppins-Bold.ttf")
const FONT_ITALIC := preload("res://ui/Poppins-Italic.ttf")
const FONT_BOLD_ITALIC := preload("res://ui/Poppins-BoldItalic.ttf")

# Surfaces, from the window down to a hovered row.
const BG: Color = Color(0.050, 0.055, 0.070, 0.97)
const PANEL: Color = Color(0.085, 0.095, 0.120, 1.0)
const PANEL_ALT: Color = Color(0.115, 0.128, 0.162, 1.0)
const SURFACE_HOVER: Color = Color(0.165, 0.180, 0.225, 1.0)
const SURFACE_PRESSED: Color = Color(0.070, 0.078, 0.100, 1.0)
const BORDER: Color = Color(1.0, 1.0, 1.0, 0.07)
const BORDER_STRONG: Color = Color(1.0, 1.0, 1.0, 0.16)

# Voice.
const ACCENT: Color = Color(1.0, 0.73, 0.03)
const ACCENT_HOVER: Color = Color(1.0, 0.80, 0.22)
const ACCENT_PRESSED: Color = Color(0.90, 0.62, 0.0)
const ACCENT_SOFT: Color = Color(1.0, 0.73, 0.03, 0.16)
const ACCENT_LINE: Color = Color(1.0, 0.73, 0.03, 0.55)
const TEXT: Color = Color(0.90, 0.92, 0.96)
const MUTED: Color = Color(0.60, 0.64, 0.71)
const ON_ACCENT: Color = Color(0.10, 0.08, 0.02)
const GOOD: Color = Color(0.40, 0.85, 0.50)
const WARN: Color = Color(1.0, 0.45, 0.35)
# Back-compat aliases used by the panels' unqualified names.
const DIM: Color = MUTED

const RADIUS: int = 10
const RADIUS_SMALL: int = 7


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


# ---------------------------------------------------------------------------------------------
# Applying the look to a control
# ---------------------------------------------------------------------------------------------

static func font_of(control: Control, size: int = 0, bold: bool = false) -> void:
	control.add_theme_font_override("font", FONT_BOLD if bold else FONT)
	if size > 0:
		control.add_theme_font_size_override("font_size", size)


## The window itself: a large rounded slab with a soft drop shadow.
static func apply_window(panel: Panel) -> void:
	var box := flat(BG, 14, BORDER_STRONG, 1)
	box.shadow_color = Color(0, 0, 0, 0.45)
	box.shadow_size = 18
	panel.add_theme_stylebox_override("panel", box)


static func apply_button(button: Button, primary: bool = false) -> void:
	var font_color: Color = ON_ACCENT if primary else TEXT
	var normal_bg: Color = ACCENT if primary else PANEL_ALT
	var hover_bg: Color = ACCENT_HOVER if primary else SURFACE_HOVER
	var pressed_bg: Color = ACCENT_PRESSED if primary else SURFACE_PRESSED
	var normal_border: Color = Color.TRANSPARENT if primary else BORDER
	button.add_theme_stylebox_override("normal", flat(normal_bg, RADIUS_SMALL, normal_border, 1, 14.0, 8.0))
	button.add_theme_stylebox_override("hover", flat(hover_bg, RADIUS_SMALL, normal_border, 1, 14.0, 8.0))
	button.add_theme_stylebox_override("pressed", flat(pressed_bg, RADIUS_SMALL, normal_border, 1, 14.0, 8.0))
	button.add_theme_stylebox_override("disabled", flat(PANEL, RADIUS_SMALL, BORDER, 1, 14.0, 8.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT, 1))
	button.add_theme_color_override("font_color", font_color)
	button.add_theme_color_override("font_hover_color", font_color)
	button.add_theme_color_override("font_pressed_color", font_color)
	button.add_theme_color_override("font_disabled_color", MUTED)
	button.add_theme_color_override("font_focus_color", font_color)
	font_of(button, 15)


## A sidebar entry: flat by default, amber left bar + soft fill when it is the open one.
static func apply_tab(button: Button, active: bool) -> void:
	var base := flat(ACCENT_SOFT if active else Color.TRANSPARENT, RADIUS_SMALL,
			ACCENT_LINE if active else Color.TRANSPARENT, 2 if active else 0, 14.0, 11.0)
	if active:
		# Only the left edge keeps the amber bar; the other three sides are dropped.
		base.border_width_top = 0
		base.border_width_bottom = 0
		base.border_width_right = 0
	button.add_theme_stylebox_override("normal", base)
	button.add_theme_stylebox_override("hover", flat(SURFACE_HOVER, RADIUS_SMALL, Color.TRANSPARENT, 0, 14.0, 11.0))
	button.add_theme_stylebox_override("pressed", flat(SURFACE_PRESSED, RADIUS_SMALL, Color.TRANSPARENT, 0, 14.0, 11.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT_LINE, 1))
	button.add_theme_color_override("font_color", ACCENT if active else TEXT)
	button.add_theme_color_override("font_hover_color", ACCENT if active else TEXT)
	button.add_theme_color_override("font_pressed_color", ACCENT if active else TEXT)
	font_of(button, 16, active)


static func apply_field(field: LineEdit) -> void:
	field.add_theme_stylebox_override("normal", flat(PANEL_ALT, RADIUS_SMALL, BORDER, 1, 12.0, 8.0))
	field.add_theme_stylebox_override("focus", flat(PANEL_ALT, RADIUS_SMALL, ACCENT, 1, 12.0, 8.0))
	field.add_theme_stylebox_override("read_only", flat(PANEL, RADIUS_SMALL, BORDER, 1, 12.0, 8.0))
	field.add_theme_color_override("font_color", TEXT)
	field.add_theme_color_override("font_placeholder_color", Color(MUTED, 0.75))
	field.add_theme_color_override("font_uneditable_color", MUTED)
	field.add_theme_color_override("caret_color", ACCENT)
	field.add_theme_color_override("selection_color", ACCENT_SOFT)
	font_of(field, 15)


static func apply_textarea(area: TextEdit) -> void:
	area.add_theme_stylebox_override("normal", flat(PANEL_ALT, RADIUS_SMALL, BORDER, 1, 12.0, 8.0))
	area.add_theme_stylebox_override("focus", flat(PANEL_ALT, RADIUS_SMALL, ACCENT, 1, 12.0, 8.0))
	area.add_theme_stylebox_override("read_only", flat(PANEL, RADIUS_SMALL, BORDER, 1, 12.0, 8.0))
	area.add_theme_color_override("font_color", TEXT)
	area.add_theme_color_override("font_placeholder_color", Color(MUTED, 0.75))
	area.add_theme_color_override("caret_color", ACCENT)
	area.add_theme_color_override("selection_color", ACCENT_SOFT)
	font_of(area, 15)


## Rich text uses dedicated theme items (not `font`): set every face so BBCode bold/italic render with
## the project's Poppins, not the engine default.
static func apply_rich_text(label: RichTextLabel, size: int = 15) -> void:
	label.add_theme_font_override("normal_font", FONT)
	label.add_theme_font_override("bold_font", FONT_BOLD)
	label.add_theme_font_override("italics_font", FONT_ITALIC)
	label.add_theme_font_override("bold_italics_font", FONT_BOLD_ITALIC)
	label.add_theme_font_size_override("normal_font_size", size)
	label.add_theme_font_size_override("bold_font_size", size)
	label.add_theme_font_size_override("italics_font_size", size)
	label.add_theme_font_size_override("bold_italics_font_size", size)
	label.add_theme_color_override("default_color", TEXT)


static func apply_list(list: ItemList) -> void:
	list.add_theme_stylebox_override("panel", flat(PANEL, RADIUS, BORDER, 1, 6.0, 6.0))
	var selected := flat(ACCENT_SOFT, RADIUS_SMALL, ACCENT_LINE, 1, 10.0, 5.0)
	list.add_theme_stylebox_override("selected", selected)
	list.add_theme_stylebox_override("selected_focus", selected)
	list.add_theme_stylebox_override("hovered", flat(SURFACE_HOVER, RADIUS_SMALL, Color.TRANSPARENT, 0, 10.0, 5.0))
	list.add_theme_stylebox_override("focus", empty())
	list.add_theme_color_override("font_color", TEXT)
	list.add_theme_color_override("font_selected_color", ACCENT)
	list.add_theme_color_override("font_hovered_color", ACCENT_HOVER)
	list.add_theme_constant_override("v_separation", 6)
	list.add_theme_constant_override("h_separation", 8)
	font_of(list, 14)


static func apply_option(option: OptionButton) -> void:
	apply_button(option)
	option.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT_LINE, 1))


## A segmented-control tab inside an app: a pill that fills amber when it is the open one.
static func apply_segment(button: Button, active: bool) -> void:
	button.add_theme_stylebox_override("normal",
			flat(ACCENT_SOFT if active else PANEL_ALT, RADIUS_SMALL,
					ACCENT_LINE if active else BORDER, 1, 16.0, 8.0))
	button.add_theme_stylebox_override("hover",
			flat(SURFACE_HOVER, RADIUS_SMALL, ACCENT_LINE if active else BORDER, 1, 16.0, 8.0))
	button.add_theme_stylebox_override("pressed",
			flat(ACCENT_SOFT if active else SURFACE_PRESSED, RADIUS_SMALL,
					ACCENT_LINE if active else BORDER, 1, 16.0, 8.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS_SMALL, ACCENT, 1))
	button.add_theme_stylebox_override("disabled", flat(PANEL, RADIUS_SMALL, BORDER, 1, 16.0, 8.0))
	var text: Color = ACCENT if active else TEXT
	button.add_theme_color_override("font_color", text)
	button.add_theme_color_override("font_hover_color", text)
	button.add_theme_color_override("font_pressed_color", text)
	button.add_theme_color_override("font_focus_color", text)
	font_of(button, 14)


## A home-grid app tile: a roomy card that lights up under the pointer, and stays amber-marked while
## its app is the open one.
static func apply_tile(button: Button, active: bool = false) -> void:
	button.add_theme_stylebox_override("normal",
			flat(ACCENT_SOFT if active else PANEL_ALT, RADIUS,
					ACCENT_LINE if active else BORDER, 1, 10.0, 10.0))
	button.add_theme_stylebox_override("hover", flat(SURFACE_HOVER, RADIUS, ACCENT_LINE, 1, 10.0, 10.0))
	button.add_theme_stylebox_override("pressed", flat(SURFACE_PRESSED, RADIUS, ACCENT_LINE, 1, 10.0, 10.0))
	button.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, RADIUS, ACCENT, 1))
	button.add_theme_stylebox_override("disabled", flat(PANEL, RADIUS, BORDER, 1, 10.0, 10.0))


static func apply_check(check: CheckBox) -> void:
	check.add_theme_color_override("font_color", TEXT)
	check.add_theme_color_override("font_hover_color", ACCENT)
	check.add_theme_color_override("font_pressed_color", ACCENT)
	font_of(check, 15)


## The coloured dot + text pill the header uses for status.
static func apply_pill(panel: PanelContainer, colour: Color) -> void:
	var box := flat(Color(colour, 0.14), 999, Color(colour, 0.45), 1, 14.0, 6.0)
	box.set_corner_radius_all(999)
	panel.add_theme_stylebox_override("panel", box)
