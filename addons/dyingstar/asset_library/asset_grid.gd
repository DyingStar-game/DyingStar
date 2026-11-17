@tool
extends ItemList

## The asset library's grid of thumbnails. Each item carries its asset's path as metadata.
##
## Dragging from it hands over what the FileSystem dock hands over, {"type": "files", "files": [...]}, so
## the 3D view, the scene tree and the inspector take the drop with no code of their own: a model
## dropped in the 3D view is instanced there, a material dropped on a mesh is applied to it.

## Width and height, in pixels, of the icon that follows the pointer while dragging.
const DRAG_ICON_SIZE := 48


func _get_drag_data(at_position: Vector2) -> Variant:
	var index := get_item_at_position(at_position, true)
	if index < 0:
		return null
	var paths := PackedStringArray()
	if is_selected(index):
		for selected in get_selected_items():
			paths.append(str(get_item_metadata(selected)))
	else:
		paths.append(str(get_item_metadata(index)))
	set_drag_preview(_drag_preview(index, paths.size()))
	return {"type": "files", "files": paths, "from": self}


func _drag_preview(index: int, count: int) -> Control:
	var box := HBoxContainer.new()
	var icon := TextureRect.new()
	icon.texture = get_item_icon(index)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(DRAG_ICON_SIZE, DRAG_ICON_SIZE)
	box.add_child(icon)
	var label := Label.new()
	label.text = get_item_text(index) if count == 1 else "%d assets" % count
	box.add_child(label)
	return box
