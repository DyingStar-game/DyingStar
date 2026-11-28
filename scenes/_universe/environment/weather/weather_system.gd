class_name WeatherSystem
extends Node3D
## One weather system (a depression, an anticyclone, a dust storm, a rain front) as Horizon delivers
## it from the weather service: a networked prop parented to its planet, like a village. It holds
## no physics and draws nothing by itself — it is DATA for `WeatherSampler`, which every presenter
## (sky, dust, audio, forces, star map, dev readouts) reads through `Planet.weather_at()`.
##
## The service publishes the centre, the drift and keyframes of future centres and intensities
## (`track`, `intensity_track`, every `keyframe_dt_s` from `from_timestamp`): between two
## updates, a client walks the keyframes on the shared clock (Globals.sim_time()), so the storm
## moves smoothly with nothing on the wire. The dedicated server keeps the last received centre:
## its forces only need the system's position to the nearest kilometre.
##
## ⚠️ Never queue_free() this node on the server: PropSync would announce a deletion to Horizon and
## kill the object for everyone. The service deletes dead systems itself.

const GROUP := &"weather_systems"

## The fields the service writes (see ds-weather-proto::WeatherSystemData).
var kind: StringName = &"depression"
var system_name: String = ""
var radius_m: float = 1.0
var intensity: float = 0.0
var pressure_anomaly_pa: float = 0.0
var velocity: Vector3 = Vector3.ZERO
var from_timestamp: float = 0.0
var keyframe_dt_s: float = 600.0
var track: PackedVector3Array = PackedVector3Array()
var intensity_track: PackedFloat64Array = PackedFloat64Array()
var wind_peak_ms: float = 0.0
var dust_tau: float = 0.0
var precipitation_mm_h: float = 0.0
var humidity: float = 0.0
var born_at: float = 0.0
var dies_at: float = 0.0
## Stable id derived from the uuid, for the readouts.
var id: int = 0

## The centre as received (planet frame), separate from `position` which the client interpolates.
var _received_position: Vector3 = Vector3.ZERO
var _received_intensity: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	if OS.has_feature("dedicated_server"):
		set_process(false)  # the server keeps the last received centre; only clients walk the keyframes
	var net := PropSync.of(self)
	if net != null:
		id = hash(net.uuid)
	# One line per arrival, so a log says whether the weather reached this machine at all.
	print("[Weather] %s arrived under %s (%s, radius %.0f km, intensity %.2f)" % [
		system_name if not system_name.is_empty() else name, get_parent().name if get_parent() != null else "?",
		String(kind), radius_m / 1000.0, intensity])


## Called by PropSync with the (possibly partial) channel data Horizon sent. Position and rotation
## were already applied to the node by PropSync; every other key is read only if present.
func apply_prop_data(data: Dictionary) -> void:
	if data.has("name"):
		system_name = str(data["name"])
	if data.has("kind"):
		kind = StringName(str(data["kind"]))
	if data.has("radius_m"):
		radius_m = float(data["radius_m"])
	if data.has("intensity"):
		intensity = float(data["intensity"])
		_received_intensity = intensity
	if data.has("pressure_anomaly_pa"):
		pressure_anomaly_pa = float(data["pressure_anomaly_pa"])
	if data.has("velocity"):
		velocity = _vec(data["velocity"])
	if data.has("from_timestamp"):
		from_timestamp = float(data["from_timestamp"])
	if data.has("keyframe_dt_s"):
		keyframe_dt_s = maxf(float(data["keyframe_dt_s"]), 1.0)
	if data.has("track"):
		track = PackedVector3Array()
		for p in data["track"]:
			track.append(_vec(p))
	if data.has("intensity_track"):
		intensity_track = PackedFloat64Array()
		for v in data["intensity_track"]:
			intensity_track.append(float(v))
	if data.has("params"):
		var p: Dictionary = data["params"]
		wind_peak_ms = float(p.get("wind_peak_ms", wind_peak_ms))
		dust_tau = float(p.get("dust_tau", dust_tau))
		precipitation_mm_h = float(p.get("precipitation_mm_h", precipitation_mm_h))
		humidity = float(p.get("humidity", humidity))
	if data.has("born_at"):
		born_at = float(data["born_at"])
	if data.has("dies_at"):
		dies_at = float(data["dies_at"])
	if data.has("position"):
		_received_position = _vec(data["position"])


func _process(_delta: float) -> void:
	if OS.has_feature("dedicated_server"):
		return
	_walk_keyframes(Globals.sim_time())


## Place the node between the keyframes for time `t`: linear between two centres, the intensity
## likewise. Before the first keyframe or without any, the received centre holds.
func _walk_keyframes(t: float) -> void:
	var at := _keyframe(t)
	if not at.is_empty():
		position = at[0]
		intensity = at[1]


## [centre, intensity] between the keyframes at time [param t], or [] without a track to walk. Between two
## keyframes the intensity in effect stays when the track carries none for them.
func _keyframe(t: float) -> Array:
	if track.size() < 2:
		return []
	var u: float = (t - from_timestamp) / keyframe_dt_s
	if u <= 0.0:
		return [track[0], intensity_track[0] if intensity_track.size() > 0 else _received_intensity]
	var last: int = track.size() - 1
	if u >= float(last):
		return [track[last], intensity_track[last] if intensity_track.size() > last else 0.0]
	var i: int = int(floor(u))
	var f: float = u - float(i)
	var level := lerpf(intensity_track[i], intensity_track[i + 1], f) if intensity_track.size() > i + 1 else intensity
	return [track[i].lerp(track[i + 1], f), level]


## [method state] where the system will stand at time [param t] (Globals.sim_time() scale), walked on its
## keyframes without moving the node: what the village alarm asks of the storms ten minutes ahead, on the
## server, which keeps the last received centre. Without a track, the state now.
func state_at(t: float) -> Dictionary:
	var out := state()
	var at := _keyframe(t)
	if at.is_empty():
		return out
	var dir: Vector3 = (at[0] as Vector3).normalized()
	if dir.length() > 0.0:
		var ll: Vector2 = HEALPix.vec2lonlat(dir)
		out["lon"] = ll.x
		out["lat"] = ll.y
	out["intensity"] = at[1]
	return out


## What the sampler needs, in one Dictionary: centre as lon/lat on the parent body, σ, intensity,
## kind and parameters. The centre is the node's planet-frame position (HEALPix convention).
func state() -> Dictionary:
	var dir: Vector3 = position.normalized()
	var ll: Vector2 = HEALPix.vec2lonlat(dir) if dir.length() > 0.0 else Vector2.ZERO
	return {
		"id": id,
		"name": system_name,
		"kind": kind,
		"lon": ll.x,
		"lat": ll.y,
		"sigma_m": maxf(radius_m * 0.5, 1.0),
		"intensity": intensity,
		"pressure_anomaly_pa": pressure_anomaly_pa,
		"wind_peak": wind_peak_ms,
		"dust_tau": dust_tau,
		"precipitation_mm_h": precipitation_mm_h,
		"humidity": humidity,
	}


static func _vec(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Dictionary:
		return Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)))
	return Vector3.ZERO
