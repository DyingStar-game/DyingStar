class_name VehicleChartView
extends VehicleNetPart
## The star chart's view on the cab's switchable screen (VehicleScreenMode.MAP), shared by everyone aboard:
## whoever handles the chart there drives it, and the others see that very view on their own chart
## (StarMap.view_state / show_view) -- the same zoom, angles, watched and selected bodies, live. The
## server keeps the last view it was sent by someone seated (PlayerServer "vehicle_chart_view") and
## replicates it; only a view that changed goes on the wire.

const KEY := "chart_view"
## The numbers a view may carry, and the names: anything else a client sends is dropped.
const NUMBERS: Array[String] = ["zoom", "yaw", "pitch", "lean_turn", "lean_angle", "poi"]
const NAMES: Array[String] = ["watch", "select"]
## Longest name kept (a body's key): a view is a few short fields, never a payload.
const NAME_MAX: int = 64

var view: Dictionary = {}

var _sent: Dictionary = {}


## Keep [param from] as the view, cleaned (clean_view). True when it changed.
func set_view(from: Dictionary) -> bool:
	var clean: Dictionary = clean_view(from)
	if clean == view:
		return false
	view = clean
	return true


## Only the fields a view has, of the right kind and finite: a client's dictionary is data, never trusted.
## Static and pure.
static func clean_view(from: Dictionary) -> Dictionary:
	var out := {}
	for key: String in NUMBERS:
		var value: Variant = from.get(key)
		if (value is float or value is int) and is_finite(float(value)):
			out[key] = float(value)
	for key: String in NAMES:
		var value: Variant = from.get(key)
		if value is String:
			out[key] = (value as String).left(NAME_MAX)
	return out


func write_changes(data: Dictionary) -> void:
	if view != _sent:
		data[KEY] = view.duplicate()
		_sent = view.duplicate()


func forget_sent() -> void:
	_sent = {}


func read(data: Dictionary) -> void:
	if data.get(KEY) is Dictionary:
		view = clean_view(data[KEY])
		_sent = view.duplicate()
