class_name ScreenToast
extends CanvasLayer
## A short line of text at the top of the screen that fades out on its own: "the thing you just did
## worked". Above every game layer, and it never takes the mouse.

## How long the message stays fully visible, then how long it takes to fade, in seconds.
@export var hold_seconds: float = 2.5
@export var fade_seconds: float = 0.6

var _label: Label = null
var _tween: Tween = null


func _init() -> void:
	layer = 128
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_label.offset_top = 24.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_constant_override("outline_size", 6)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.visible = false
	add_child(_label)


## Show `text` (already translated) and fade it out. A new message replaces the one on screen.
func show_message(text: String) -> void:
	if _tween != null:
		_tween.kill()
	_label.text = text
	_label.modulate.a = 1.0
	_label.visible = true
	_tween = create_tween()
	_tween.tween_interval(hold_seconds)
	_tween.tween_property(_label, "modulate:a", 0.0, fade_seconds)
	_tween.tween_callback(_label.hide)


## Take the message off the screen at once (a screenshot must not photograph the previous one).
func clear() -> void:
	if _tween != null:
		_tween.kill()
	_label.hide()
