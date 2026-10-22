class_name GoodTypePicker
extends HBoxContainer

## Pick a `goodType` from the market's own catalogue, by name, instead of typing it.
##
## A goodType is a contract between the game and three services — the catalogue in `market_catalog`,
## the stack or instance it names, the price it is sold at — and typing one wrong fails silently: no
## such buy, no order, no error worth reading. The catalogue is already fetched by the market tab, so
## this only has to present it: the list is [code]displayName[/code] with the raw [code]goodType[/code]
## beside it, because the raw string is what an economic value is keyed on and a builder has to be
## able to see it.
##
## An empty catalogue is a real state, not an error (the market's catalog is empty in dev), so it
## says so and leaves the field editable rather than pretending there is nothing to pick.
##
## A free-text field sits in front of the list, pre-filled with the pick, for the case the catalogue
## does not carry yet: the market sells whatever its catalogue says, and a caller who knows the
## string must not be walled out of a value the service would have accepted.

## The catalogue changed. The host refills rather than refetching: it already holds the list.
signal refilled

## Rows a caller may page through. The API's own maximum, so the picker needs no page of its own.
const LIMIT: int = 100

var _goods: Array = []
var _field: LineEdit
var _picker: OptionButton


func _init() -> void:
	add_theme_constant_override("separation", 8)


## [param width] is the field's minimum width; the list takes the rest.
func setup(width: float = 180.0) -> void:
	_field = LineEdit.new()
	_field.placeholder_text = "%%SVC_PH_GOOD_TYPE"
	_field.custom_minimum_size = Vector2(width, 40)
	ServiceStyle.apply_field(_field)
	add_child(_field)

	_picker = OptionButton.new()
	ServiceStyle.apply_option(_picker)
	_picker.custom_minimum_size = Vector2(200, 40)
	_picker.item_selected.connect(func(_i: int) -> void: _on_selected())
	add_child(_picker)

	var refresh := Button.new()
	refresh.text = "%%SVC_ACT_REFRESH"
	ServiceStyle.apply_button(refresh)
	refresh.pressed.connect(func() -> void: refilled.emit())
	add_child(refresh)

	fill([])


## Repopulate from a `GET /api/market/catalog` answer (the array itself, or the whole result).
func fill(source: Variant) -> void:
	_goods = []
	if source is Dictionary and (source as Dictionary).get("data") is Array:
		_goods = (source as Dictionary)["data"]
	elif source is Array:
		_goods = source
	if _picker == null:
		return
	_picker.clear()
	for good: Dictionary in _goods:
		_picker.add_item(display_line(good))
		_picker.set_item_metadata(_picker.item_count - 1, str(good.get("goodType", "")))
	if _goods.is_empty():
		_picker.add_item("%%SVC_MSG_NO_GOODS")
		_picker.set_item_metadata(0, "")
	_picker.select(0)
	# A catalog that just loaded must not silently replace what the builder already chose.
	var current := _field.text.strip_edges()
	if current != "":
		_select_good(current)


## The value in the protocol the builder collectors speak.
func param_value() -> Variant:
	var raw := _field.text.strip_edges()
	return raw if raw != "" else null


## The good's own name, for a clause sentence.
func param_label() -> String:
	return param_label_of(param_value())


## The pick's display name, or the raw string when the catalogue does not carry it.
func param_label_of(good_type: Variant) -> String:
	var wanted := str(good_type)
	for good: Dictionary in _goods:
		if str(good.get("goodType", "")) == wanted:
			return str(good.get("displayName", wanted))
	return wanted


## The list row for a catalogue entry: the name a buyer recognises, then the exact string, because
## they are often not the same and the second is what everything else is keyed on.
static func display_line(good: Dictionary) -> String:
	var raw := str(good.get("goodType", ""))
	var label := str(good.get("displayName", "")).strip_edges()
	if label == "" or label == raw:
		return raw
	return "%s — %s" % [label, raw]


func _select_good(good_type: String) -> void:
	for i: int in range(_picker.item_count):
		if str(_picker.get_item_metadata(i)) == good_type:
			_picker.select(i)
			_field.text = good_type
			return


func _on_selected() -> void:
	var picked := str(_picker.get_item_metadata(_picker.selected)) if _picker.selected >= 0 else ""
	if picked != "":
		_field.text = picked