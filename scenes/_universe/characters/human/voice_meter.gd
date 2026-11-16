class_name VoiceMeter
extends RefCounted

## How loud a voice is right now, 0..1 -- what moves a talking face's mouth (FaceLife).
##
## The voice chat gives no level per speaker: a remote voice goes from LiveKit's native reader straight
## into its speaker's AudioStreamGenerator. So a speaker that a live face listens to is given an audio bus
## of its own, sent to the bus it played on, and the bus' peak is read. Buses are made on demand and
## removed when the face stops listening or the speaker is gone; at most MAX_BUSES at once (the faces
## close enough to be live are few).
##
## Our own voice never plays here: livekit.gd writes the microphone's level to own_level while it sends.

## Buses a meter may add to the layout at once.
const MAX_BUSES: int = 8
## Peak (dB) read as silence, and as a full voice. A voice 8 m away is ~12 dB under one at 2 m.
const SILENCE_DB: float = -48.0
const FULL_DB: float = -18.0
const BUS_PREFIX: String = "VoiceMeter"

## Level of the local microphone while it sends (0..1, raw peak), 0 otherwise.
static var own_level: float = 0.0
static var _metered: Dictionary = {}  # speaker instance id -> [bus name, the bus it played on]


## Level 0..1 of [param speaker] (an AudioStreamPlayer or AudioStreamPlayer3D), metered from now on.
static func level(speaker: Node) -> float:
	if not is_instance_valid(speaker):
		return 0.0
	var entry: Array = _metered.get(speaker.get_instance_id(), [])
	if entry.is_empty():
		entry = _attach(speaker)
		if entry.is_empty():
			return 0.0
	var bus: int = AudioServer.get_bus_index(entry[0])
	if bus == -1:
		return 0.0
	var peak: float = maxf(AudioServer.get_bus_peak_volume_left_db(bus, 0), AudioServer.get_bus_peak_volume_right_db(bus, 0))
	return level_of_db(peak)


## The 0..1 level of a peak in dB.
static func level_of_db(peak_db: float) -> float:
	return clampf(inverse_lerp(SILENCE_DB, FULL_DB, peak_db), 0.0, 1.0)


## Stop metering [param speaker]: it plays on its own bus again, the meter's bus is removed.
static func release(speaker: Node) -> void:
	if speaker == null:
		return
	_drop(speaker.get_instance_id())


## Buses in use (tests, diagnostics).
static func metered_count() -> int:
	return _metered.size()


## Remove the buses of speakers that were freed without a release.
static func sweep() -> void:
	for id: int in _metered.keys():
		if not is_instance_valid(instance_from_id(id)):
			_drop(id)


static func _attach(speaker: Node) -> Array:
	sweep()
	if _metered.size() >= MAX_BUSES:
		return []
	var played_on: StringName = speaker.get(&"bus")
	var bus_name: String = "%s%d" % [BUS_PREFIX, speaker.get_instance_id()]
	AudioServer.add_bus()
	var bus: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus, bus_name)
	AudioServer.set_bus_send(bus, played_on)
	speaker.set(&"bus", StringName(bus_name))
	var entry: Array = [bus_name, played_on]
	_metered[speaker.get_instance_id()] = entry
	return entry


static func _drop(id: int) -> void:
	var entry: Array = _metered.get(id, [])
	if entry.is_empty():
		return
	_metered.erase(id)
	var speaker: Object = instance_from_id(id)
	if is_instance_valid(speaker):
		speaker.set(&"bus", entry[1])
	var bus: int = AudioServer.get_bus_index(entry[0])
	if bus != -1:
		AudioServer.remove_bus(bus)
