class_name WeatherField
extends Node3D
## A body's near-ground weather as the weather service's atmosphere model computes it: ONE networked prop
## per simulated body, parented to its planet, that Horizon relays like a WeatherSystem. It holds no
## physics and draws nothing: it is DATA that ClimateWeather samples instead of its climate profile and
## systems while the field is fresh (see docs/WEATHER.md, contract `weather_field`).
##
## The grid is equirectangular, `grid_w` × `grid_h` (128 × 64): column i is centred on longitude
## -180 + (i + 0.5)·360/w (eastward), row j on latitude 90 - (j + 0.5)·180/h (row 0 = north), the same
## lon/lat convention as WeatherSampler and the service's `/point`. `fields` is one base64 string of u16
## values, little-endian, quantity-major then row-major (((q·h) + j)·w + i); a value is
## offset + scale·u with `scales[q] = [offset, scale]`.
##
## The service publishes each model chunk's end state ahead of time (`valid_at`, Unix seconds). The node
## keeps the previous frame and the newest one and interpolates between them on the shared clock
## (Globals.sim_time()); past the newest it holds the newest, with one frame it uses that one.
##
## Frames are plain Dictionaries never written to once made ([method frames]): a worker thread can keep
## and sample them ([method sample_frames]) after this node is gone.
##
## ⚠️ Never queue_free() this node on the server: PropSync would announce a deletion to Horizon and kill
## the object for everyone. The service deletes the field itself when the model stops.

const GROUP := &"weather_fields"
## The quantities in the contract's order, used when `quantities` was not received.
const DEFAULT_QUANTITIES: Array[String] = ["wind_east", "wind_north", "dust_tau", "t_air", "p_sea"]
## How long past the newest frame's `valid_at` the field still counts as fresh, seconds. The service
## publishes one chunk (about an hour on Sandbox) ahead and deletes the field when its model stops: this
## only guards against a service that went silent without saying so.
const FRESH_FOR_S := 7200.0

## The fields the service writes (see ds-weather-proto, FIELD_DEF_JSON).
var grid_w: int = 0
var grid_h: int = 0
var quantities: Array = []
var scales: Array = []
var valid_at: float = 0.0
var model_day: float = 0.0

var _prev: Dictionary = {}
var _newest: Dictionary = {}
var _newest_raw := PackedByteArray()
# Zone 0 (scales) and zone 1 (fields) may reach us in separate messages, either one first: a frame is
# re-decoded once when its scales come after it.
var _newest_needs_scales := false
var _scales_ahead := false
var _warned := false
var _mutex := Mutex.new()


func _ready() -> void:
	add_to_group(GROUP)
	set_process(false)  # nothing to walk: the field is sampled on demand at a given time
	print("[Weather] field arrived under %s (%d x %d, %d frame(s))" % [
		get_parent().name if get_parent() != null else "?", grid_w, grid_h, frames().size()])


## Called by PropSync with the (possibly partial) channel data Horizon sent. Position and rotation were
## already applied to the node by PropSync; every other key is read only if present.
func apply_prop_data(data: Dictionary) -> void:
	if data.has("grid_w"):
		grid_w = int(data["grid_w"])
	if data.has("grid_h"):
		grid_h = int(data["grid_h"])
	if data.has("quantities") and data["quantities"] is Array:
		quantities = (data["quantities"] as Array).duplicate()
	if data.has("scales") and data["scales"] is Array:
		scales = (data["scales"] as Array).duplicate(true)
	if data.has("valid_at"):
		valid_at = float(data["valid_at"])
	if data.has("model_day"):
		model_day = float(data["model_day"])
	if data.has("fields"):
		_receive_fields(Marshalls.base64_to_raw(str(data["fields"])) if data["fields"] is String else PackedByteArray(),
				data.has("scales"))
	elif data.has("scales"):
		if _newest_needs_scales:
			_newest_needs_scales = false
			_redecode_newest()
		else:
			_scales_ahead = true


## The frames held, oldest first: [] before any, [newest], or [previous, newest]. Each frame is
## {valid_at, w, h, index: {quantity name: q}, values: PackedFloat32Array}. Thread-safe.
func frames() -> Array:
	_mutex.lock()
	var out: Array = []
	if not _prev.is_empty():
		out.append(_prev)
	if not _newest.is_empty():
		out.append(_newest)
	_mutex.unlock()
	return out


## The field at a longitude and latitude (degrees) at time [param t] (Globals.sim_time() scale), one key
## per quantity name ("wind_east", "wind_north" m/s, "dust_tau", "t_air" K, "p_sea" Pa). Empty without a
## frame. Thread-safe.
func sample(lon_deg: float, lat_deg: float, t: float) -> Dictionary:
	return sample_frames(frames(), lon_deg, lat_deg, t)


## Whether the field may stand for the weather at [param t] (see FRESH_FOR_S).
func is_fresh(t: float) -> bool:
	return frames_fresh(frames(), t)


## Whether [param held] ([method frames]) may stand for the weather at [param t].
static func frames_fresh(held: Array, t: float) -> bool:
	return not held.is_empty() and t <= float((held[held.size() - 1] as Dictionary)["valid_at"]) + FRESH_FOR_S


## [param held] ([method frames]) sampled at a place and a time: bilinear in space (wrapping in
## longitude, clamped in latitude), linear in time between the two frames, the newest held past its
## `valid_at`, the oldest before its own. Empty when nothing is held.
static func sample_frames(held: Array, lon_deg: float, lat_deg: float, t: float) -> Dictionary:
	if held.is_empty():
		return {}
	var newest: Dictionary = held[held.size() - 1]
	var now := sample_frame(newest, lon_deg, lat_deg)
	if held.size() < 2:
		return now
	var prev: Dictionary = held[0]
	var t0 := float(prev["valid_at"])
	var t1 := float(newest["valid_at"])
	if t >= t1 or t1 <= t0 or int(prev["w"]) != int(newest["w"]) or int(prev["h"]) != int(newest["h"]):
		return now
	var before := sample_frame(prev, lon_deg, lat_deg)
	var f := clampf((t - t0) / (t1 - t0), 0.0, 1.0)
	var out := {}
	for key: String in now:
		out[key] = lerpf(float(before[key]), float(now[key]), f) if before.has(key) else now[key]
	return out


## One frame sampled at a place: bilinear, wrapping in longitude, clamped in latitude.
static func sample_frame(frame: Dictionary, lon_deg: float, lat_deg: float) -> Dictionary:
	var w: int = frame["w"]
	var h: int = frame["h"]
	var values: PackedFloat32Array = frame["values"]
	var x := (lon_deg + 180.0) / 360.0 * w - 0.5
	var y := clampf((90.0 - lat_deg) / 180.0 * h - 0.5, 0.0, h - 1.0)
	var i0 := floori(x)
	var fx := x - i0
	var j0 := mini(floori(y), h - 1)
	var fy := y - j0
	var j1 := mini(j0 + 1, h - 1)
	i0 = posmod(i0, w)
	var i1 := posmod(i0 + 1, w)
	var out := {}
	var index: Dictionary = frame["index"]
	for key: String in index:
		var base: int = int(index[key]) * w * h
		var top := lerpf(values[base + j0 * w + i0], values[base + j0 * w + i1], fx)
		var bottom := lerpf(values[base + j1 * w + i0], values[base + j1 * w + i1], fx)
		out[key] = lerpf(top, bottom, fy)
	return out


## A frame from its wire form: the u16 bytes of `fields`, the grid, the quantities' names and their
## [offset, scale]. {"error": why} when the parts do not fit together (the frame is then ignored).
static func decode_frame(raw: PackedByteArray, w: int, h: int, names: Array, frame_scales: Array,
		at: float) -> Dictionary:
	var q := names.size()
	if w <= 0 or h <= 0 or q == 0:
		return {"error": "grid %d x %d with %d quantities" % [w, h, q]}
	if frame_scales.size() != q:
		return {"error": "%d scales for %d quantities" % [frame_scales.size(), q]}
	var n := w * h
	if raw.size() != q * n * 2:
		return {"error": "%d bytes for %d x %d x %d values" % [raw.size(), q, w, h]}
	var values := PackedFloat32Array()
	values.resize(q * n)
	var index := {}
	for k in q:
		var pair: Variant = frame_scales[k]
		if not (pair is Array) or (pair as Array).size() != 2:
			return {"error": "scale %d is not [offset, scale]" % k}
		var offset := float(pair[0])
		var scale := float(pair[1])
		index[str(names[k])] = k
		var base := k * n
		for m in n:
			values[base + m] = offset + scale * raw.decode_u16((base + m) * 2)
	return {"valid_at": at, "w": w, "h": h, "index": index, "values": values}


func _names() -> Array:
	return quantities if not quantities.is_empty() else DEFAULT_QUANTITIES


## A new `fields` arrived: decode it as the newest frame, the one it replaces kept as the previous.
func _receive_fields(raw: PackedByteArray, scales_with_it: bool) -> void:
	var frame := decode_frame(raw, grid_w, grid_h, _names(), scales, valid_at)
	if frame.has("error"):
		_warn(str(frame["error"]))
		return
	_newest_needs_scales = not (scales_with_it or _scales_ahead)
	_scales_ahead = false
	_mutex.lock()
	if not _newest.is_empty():
		var last := float(_newest["valid_at"])
		if valid_at > last:
			_prev = _newest
		elif valid_at < last:
			_prev = {}  # time went back (the service restarted): nothing to interpolate from
	_newest = frame
	_newest_raw = raw
	_mutex.unlock()


## The newest frame decoded again with the scales that came after it.
func _redecode_newest() -> void:
	if _newest_raw.is_empty():
		return
	var frame := decode_frame(_newest_raw, grid_w, grid_h, _names(), scales, float(_newest.get("valid_at", valid_at)))
	if frame.has("error"):
		_warn(str(frame["error"]))
		return
	_mutex.lock()
	_newest = frame
	_mutex.unlock()


func _warn(why: String) -> void:
	if _warned:
		return
	_warned = true
	push_warning("[Weather] weather_field frame ignored under %s: %s" % [
		get_parent().name if get_parent() != null else "?", why])
