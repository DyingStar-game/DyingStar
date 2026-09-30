@tool
extends EditorInspectorPlugin

## Turns PropSync's `type_name` into a dropdown of the types defined in items_def/ (horizonserver's
## <type>_def.json). PropSync itself is not @tool, so the dropdown lives here rather than in a
## _validate_property on the component.

const ServerPropsIO = preload("res://addons/dyingstar/server_props_io.gd")
const PROP_SYNC_SCRIPT := "res://scenes/globals/prop_sync.gd"


func _can_handle(object: Object) -> bool:
	# By path: the editor holds a placeholder instance of the non-@tool script.
	var s = object.get_script()
	return s != null and s.resource_path == PROP_SYNC_SCRIPT


func _parse_property(_object: Object, _type: Variant.Type, name: String, _hint: PropertyHint,
		_hint_string: String, _usage: int, _wide: bool) -> bool:
	if name != "type_name":
		return false
	add_property_editor(name, TypeNameProperty.new())
	return true


class TypeNameProperty extends EditorProperty:
	var _options := OptionButton.new()
	var _types := PackedStringArray()  # the value behind each item index
	var _updating := false

	func _init() -> void:
		_options.clip_text = true
		_options.item_selected.connect(_on_selected)
		add_child(_options)
		add_focusable(_options)

	func _update_property() -> void:
		var current := str(get_edited_object().get(get_edited_property()))
		_updating = true
		_options.clear()
		_types = ServerPropsIO.def_types()
		# A value with no definition (e.g. "station") stays selectable as is, flagged — never
		# silently replaced by the first known type.
		var unknown := not _types.has(current)
		if unknown:
			_types.insert(0, current)
			_options.add_item("%s (not in items_def)" % current)
			_options.set_item_tooltip(0, "No %s%s in items_def/ — this type is not replicated by Horizon."
				% [current, ServerPropsIO.DEFS_SUFFIX])
		for i in range(_options.item_count, _types.size()):
			_options.add_item(_types[i])
		_options.select(_types.find(current))
		_options.modulate = get_theme_color("warning_color", "Editor") if unknown else Color.WHITE
		_updating = false

	func _on_selected(index: int) -> void:
		if not _updating:
			emit_changed(get_edited_property(), _types[index])
