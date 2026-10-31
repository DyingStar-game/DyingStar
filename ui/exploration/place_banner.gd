class_name PlaceBanner
extends CanvasLayer
## The name of the place the player just entered, high on the screen for a few seconds (PlaceWatcher): its
## approved name and who discovered it, or "uncharted" while ARES has approved none.

const LAYER := 15
const HOLD_S := 4.0
const FADE_S := 0.6
## Its top edge, as a share of the screen's height.
const TOP_SHARE := 0.16

var _box: VBoxContainer
var _title: Label
var _subtitle: Label
var _tween: Tween = null


func _init() -> void:
	layer = LAYER
	visible = false
	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_box.anchor_top = TOP_SHARE
	_box.anchor_bottom = TOP_SHARE
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)
	_title = _label(30, true, ServiceStyle.ACCENT)
	_subtitle = _label(16, false, ServiceStyle.TEXT)


## Show [param title] over [param subtitle] (may be empty), then fade out.
func show_place(title: String, subtitle: String) -> void:
	_title.text = title
	_subtitle.text = subtitle
	_subtitle.visible = subtitle != ""
	if _tween != null:
		_tween.kill()
	_box.modulate.a = 0.0
	visible = true
	_tween = create_tween()
	_tween.tween_property(_box, "modulate:a", 1.0, FADE_S)
	_tween.tween_interval(HOLD_S)
	_tween.tween_property(_box, "modulate:a", 0.0, FADE_S)
	_tween.tween_callback(func() -> void: visible = false)


func _label(size: int, bold: bool, color: Color) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # names and finished sentences
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ServiceStyle.font_of(label, size, bold)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 6)
	_box.add_child(label)
	return label
