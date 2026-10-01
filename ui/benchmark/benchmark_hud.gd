class_name BenchmarkHud
extends CanvasLayer
## The one line the benchmark leaves on screen while the rest of the interface is hidden: which step
## it is on, and how to stop it. Styled like ScreenToast, at the bottom so the sky and the horizon
## the measurement turns across stay clear. Added AFTER the interface is hidden, so it stays.

var _label : Label = null


func _init() -> void:
	layer = 127
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_label.offset_top = -64.0
	_label.offset_bottom = -32.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_constant_override("outline_size", 6)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_child(_label)


## Show `text` (already translated). Called when the step changes, not every frame: a label that
## changes re-lays out, and that would land in what is being measured.
func show_text(text: String) -> void:
	_label.text = text
