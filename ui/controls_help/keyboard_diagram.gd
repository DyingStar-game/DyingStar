class_name KeyboardDiagram
extends Control
## The keyboard, drawn rather than pictured: every key reads as the player's own layout prints it
## (AZERTY, QWERTY, QWERTZ — the same names as the controls page), and the keys the help's lines use
## light up with their numbers. A picture could not follow a layout, nor a key the player rebound.
##
## Keys are placed by physical position (the bindings are physical too); the rows are a standard
## 105-key block without the numeric pad. Both Shifts, Ctrls and Alts light up for one binding.

## [physical keycode (KEY_NONE: a gap), width in key units] per row, top to bottom.
const ROWS : Array = [
	[[KEY_ESCAPE, 1.0], [KEY_NONE, 0.5], [KEY_F1, 1.0], [KEY_F2, 1.0], [KEY_F3, 1.0], [KEY_F4, 1.0],
			[KEY_NONE, 0.5], [KEY_F5, 1.0], [KEY_F6, 1.0], [KEY_F7, 1.0], [KEY_F8, 1.0], [KEY_NONE, 0.5],
			[KEY_F9, 1.0], [KEY_F10, 1.0], [KEY_F11, 1.0], [KEY_F12, 1.0]],
	[[KEY_QUOTELEFT, 1.0], [KEY_1, 1.0], [KEY_2, 1.0], [KEY_3, 1.0], [KEY_4, 1.0], [KEY_5, 1.0], [KEY_6, 1.0],
			[KEY_7, 1.0], [KEY_8, 1.0], [KEY_9, 1.0], [KEY_0, 1.0], [KEY_MINUS, 1.0], [KEY_EQUAL, 1.0],
			[KEY_BACKSPACE, 2.0]],
	[[KEY_TAB, 1.5], [KEY_Q, 1.0], [KEY_W, 1.0], [KEY_E, 1.0], [KEY_R, 1.0], [KEY_T, 1.0], [KEY_Y, 1.0],
			[KEY_U, 1.0], [KEY_I, 1.0], [KEY_O, 1.0], [KEY_P, 1.0], [KEY_BRACKETLEFT, 1.0],
			[KEY_BRACKETRIGHT, 1.0], [KEY_BACKSLASH, 1.5]],
	[[KEY_CAPSLOCK, 1.75], [KEY_A, 1.0], [KEY_S, 1.0], [KEY_D, 1.0], [KEY_F, 1.0], [KEY_G, 1.0], [KEY_H, 1.0],
			[KEY_J, 1.0], [KEY_K, 1.0], [KEY_L, 1.0], [KEY_SEMICOLON, 1.0], [KEY_APOSTROPHE, 1.0],
			[KEY_ENTER, 2.25]],
	[[KEY_SHIFT, 2.25], [KEY_Z, 1.0], [KEY_X, 1.0], [KEY_C, 1.0], [KEY_V, 1.0], [KEY_B, 1.0], [KEY_N, 1.0],
			[KEY_M, 1.0], [KEY_COMMA, 1.0], [KEY_PERIOD, 1.0], [KEY_SLASH, 1.0], [KEY_SHIFT, 2.75]],
	[[KEY_CTRL, 1.25], [KEY_META, 1.25], [KEY_ALT, 1.25], [KEY_SPACE, 6.25], [KEY_ALT, 1.25],
			[KEY_META, 1.25], [KEY_MENU, 1.25], [KEY_CTRL, 1.25]],
]
## Widest row, in key units: the drawing is sized on it.
const ROW_UNITS : float = 15.0
## Gap between two keys, as a share of a key unit.
const GAP_SHARE : float = 0.1
## The function-key row stands this far (key units) above the others.
const F_ROW_GAP : float = 0.4

## "key:<physical keycode>" -> the numbers to show on that key.
var numbers : Dictionary = {}
## "key:<physical keycode>" -> what the key does, shown while the pointer rests on it.
var tips : Dictionary = {}

## Each key drawn: [its rect, its physical keycode], for the pointer.
var _boxes : Array = []

var _names : Dictionary = {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS  # the pointer over a key shows what it does
	resized.connect(queue_redraw)


## Width over height of the drawing: the help sizes its box on it.
static func aspect() -> float:
	return ROW_UNITS / (ROWS.size() + F_ROW_GAP)


func _draw() -> void:
	var unit : float = minf(size.x / ROW_UNITS, size.y / (ROWS.size() + F_ROW_GAP))
	var origin := Vector2((size.x - unit * ROW_UNITS) * 0.5, (size.y - unit * (ROWS.size() + F_ROW_GAP)) * 0.5)
	var gap : float = unit * GAP_SHARE
	var font : Font = SettingsRowFactory.FONT
	_boxes.clear()
	var y : float = origin.y
	for row_index: int in ROWS.size():
		var x : float = origin.x
		for key: Array in ROWS[row_index]:
			var width : float = unit * float(key[1])
			if key[0] != KEY_NONE:
				var box := Rect2(x + gap * 0.5, y + gap * 0.5, width - gap, unit - gap)
				_boxes.append([box, key[0]])
				_draw_key(box, key[0], unit, font)
			x += width
		y += unit + (unit * F_ROW_GAP if row_index == 0 else 0.0)


func _draw_key(box: Rect2, keycode: int, unit: float, font: Font) -> void:
	var spot : String = "key:%d" % keycode
	var lit : bool = numbers.has(spot)
	# Bound, but to something outside the legend: ringed in amber, so the pointer knows it has a tooltip.
	var bound : bool = tips.has(spot)
	var style := StyleBoxFlat.new()
	style.bg_color = ControlsHelp.ACCENT if lit else ControlsHelp.KEY_FILL
	style.border_color = ControlsHelp.ACCENT if lit or bound else ControlsHelp.KEY_EDGE
	style.set_border_width_all(2 if bound and not lit else 1)
	style.set_corner_radius_all(int(unit * 0.12))
	draw_style_box(style, box)
	var label : String = _name_of(keycode)
	var font_size : int = int(unit * (0.36 if label.length() <= 2 else 0.22 if label.length() <= 4 else 0.18))
	var colour : Color = ControlsHelp.INK if lit else ControlsHelp.TEXT
	draw_string(font, Vector2(box.position.x + unit * 0.12, box.position.y + unit * 0.42), label,
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x - unit * 0.18, font_size, colour)
	if lit:
		BadgedPicture.draw_badge(self, box.position + Vector2(box.size.x - unit * 0.12, box.size.y - unit * 0.12),
				BadgedPicture.joined(numbers[spot]), unit * 0.42)


## What the key says, as the controls page writes it (the active layout's label).
## What the key under [param at] does, or "" (no tooltip).
func _get_tooltip(at: Vector2) -> String:
	for entry: Array in _boxes:
		if (entry[0] as Rect2).has_point(at):
			return tips.get("key:%d" % entry[1], "")
	return ""


## A key that prints a character shows the character itself — "$", ")", "ù" — rather than its name, which
## a keycap could only show cut short ("Dolla", "Paren").
func _name_of(keycode: int) -> String:
	if not _names.has(keycode):
		_names[keycode] = key_face(keycode)
	return _names[keycode]


## What the keycap of [param keycode] (physical) bears in the active layout.
static func key_face(keycode: int) -> String:
	if DisplayServer.get_name() != "headless":
		var label : int = DisplayServer.keyboard_get_label_from_physical(keycode)
		if label > 32 and label < KEY_SPECIAL:
			return String.chr(label).to_upper()
	return InputLabel._physical_key_name(keycode)


## The drawn key that prints [param keycode] in the active layout (a binding by letter — the microphone
## on M — sits on AZERTY where QWERTY has its comma), or [param keycode] itself when no key prints it.
static func physical_of(keycode: int) -> int:
	if DisplayServer.get_name() != "headless":
		for row: Array in ROWS:
			for key: Array in row:
				if key[0] != KEY_NONE and DisplayServer.keyboard_get_keycode_from_physical(key[0]) == keycode:
					return key[0]
	return keycode

