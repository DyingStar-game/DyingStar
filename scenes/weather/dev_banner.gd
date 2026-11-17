class_name DevBanner
extends CanvasLayer
## A line of text at the top of the screen for the weather's dev tools (WeatherIsolate, WeatherBench):
## what they are doing, where the player looks, not only in the log.


var _label: Label = null


func _init(node_name: String = "DevBanner") -> void:
	name = node_name
	layer = 100
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_label.position.y = 90.0
	_label.add_theme_font_size_override(&"font_size", 22)
	_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_label.add_theme_constant_override(&"outline_size", 6)
	add_child(_label)


## Show [param text].
func show_text(text: String) -> void:
	_label.text = text


## What is shown.
func shown() -> String:
	return _label.text
