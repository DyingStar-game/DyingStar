class_name ServiceAppTile
extends Button

## One app on the tablet's home grid: a card with a vector glyph over its name. A [Button] so it is
## focusable and clickable like any control; the glyph and the label are children that ignore the
## mouse, so the whole card is the hit target.

var app_id: String = ""


func setup(id: String, title: String, icon_kind: ServiceAppIcon.Kind) -> void:
	app_id = id
	custom_minimum_size = Vector2(148, 104)
	ServiceStyle.apply_tile(self)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 10.0
	box.offset_right = -10.0
	box.offset_top = 16.0
	box.offset_bottom = -12.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := ServiceAppIcon.new()
	icon.kind = icon_kind
	icon.colour = ServiceStyle.ACCENT
	icon.custom_minimum_size = Vector2(48, 48)
	center.add_child(icon)
	box.add_child(center)

	var label := Label.new()
	label.text = title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(label, 15)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
