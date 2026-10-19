class_name InstancePicker
extends VBoxContainer

## Pick one of the caller's own INVENTORY INSTANCES, by what they hold, instead of typing its uuid.
##
## An instance is a discrete physical object — a crate, a module, a rig — that service-inventory
## gives a stable id of. Nothing about that id is knowable and nothing about it is memorable, so
## typing one is not a thing a player can do: the field asked for something only the service knows.
## The list here is the player's own (`GET /api/me/inventory`, the `instances` window), shown as the
## good it holds plus where it is, and a row click IS the pick.
##
## It is deliberately OPTIONAL in the forms that host it: an order or a demand names an instance
## only when the seller means one specific object rather than any unit of that good. So this reports
## "none" as a legitimate answer, and its host sends no `instanceId` at all in that case.

signal picked(instance_id: String)

## One window fetches both lists; the instances are the half this reads.
const LIMIT: int = 100

var _instances: Array = []
var _loaded: bool = false
var _picker: OptionButton
var _chosen: String = ""


func _init() -> void:
	add_theme_constant_override("separation", 4)


func _ready() -> void:
	var label := Label.new()
	label.text = "%%SVC_LBL_INSTANCES"
	label.add_theme_color_override("font_color", ServiceStyle.MUTED)
	add_child(label)

	_picker = OptionButton.new()
	ServiceStyle.apply_option(_picker)
	_picker.custom_minimum_size = Vector2(320, 40)
	_picker.item_selected.connect(func(_i: int) -> void: _on_selected())
	add_child(_picker)
	refresh()


func refresh() -> void:
	_load()


## Fill from a `GET /api/me/inventory` answer (the whole result, or the items array).
func fill(source: Variant) -> void:
	if source is Dictionary and (source as Dictionary).get("data") is Dictionary:
		var data: Dictionary = source["data"]
		_instances = data.get("instances", []) if data.get("instances") is Array else []
	elif source is Array:
		_instances = source
	if _picker == null:
		return
	var remembered := _chosen
	_picker.clear()
	# « any unit » first: most orders mean the good, not one object, so the common case is the
	# default rather than the first instance.
	_picker.add_item("%%SVC_MSG_INSTANCE_ANY")
	_picker.set_item_metadata(0, "")
	for instance: Dictionary in _instances:
		_picker.add_item(display_line(instance))
		_picker.set_item_metadata(_picker.item_count - 1, str(instance.get("id", "")))
	if _instances.is_empty():
		_picker.add_item("%%SVC_MSG_NO_INSTANCES")
	_picker.select(0)
	_chosen = ""
	if remembered != "":
		for i: int in range(_picker.item_count):
			if str(_picker.get_item_metadata(i)) == remembered:
				_picker.select(i)
				_chosen = remembered
				break


## The chosen instance's id, or null when the answer is "any unit of that good".
func param_value() -> Variant:
	return _chosen if _chosen != "" else null


## What to print for this choice in a sentence.
func param_label() -> String:
	return display_line(_instance_of(_chosen)) if _chosen != "" else "%%SVC_MSG_INSTANCE_ANY"


## The id, for a caller that wants it directly (a market form, which has no sentence).
func picked_id() -> String:
	return _chosen


## The list row: the good it holds, and its status, so two crates of ore are told apart by where
## they are (stored in a hold, out in the world) rather than by a number.
static func display_line(instance: Dictionary) -> String:
	var good := str(instance.get("goodType", "")).strip_edges()
	var status := str(instance.get("status", "")).strip_edges()
	var head := good if good != "" else str(instance.get("id", ""))
	return "%s — %s" % [head, status] if status != "" else head


func _instance_of(instance_id: String) -> Dictionary:
	for instance: Dictionary in _instances:
		if str(instance.get("id", "")) == instance_id:
			return instance
	return {}


func _on_selected() -> void:
	_chosen = str(_picker.get_item_metadata(_picker.selected)) if _picker.selected >= 0 else ""
	picked.emit(_chosen)


func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var result: Dictionary = await PlayerServices.inventory_me(LIMIT, 0)
	if bool(result.get("ok", false)):
		fill(result)
	else:
		_say(HttpClient.describe_error(result), ServiceStyle.WARN)


func _say(message: String, colour: Color) -> void:
	var host := get_parent()
	while host != null and not host.has_method("_say"):
		host = host.get_parent()
	if host != null:
		host.call("_say", message, colour)