@tool
class_name VolcanoEvent
extends Resource
## Absolute UTC seconds, independent of sky speed and debug time.
## Name shown in the authoring panel; no effect on the volcano.
@export var label := "Evenement volcanique"
## Start of the event, in UTC seconds since 1970.
@export var start_unix: float = 0.0
## Length (s) of the event, ramps included. The smoke then fades over the profile's dissipation_s.
@export_range(1.0, 86400.0) var duration_s := 120.0
## Strength (0..4) of the activity: higher = a larger plume and, in an eruption, more and faster stones.
@export_range(0.0, 4.0) var strength := 1.6
## Empty targets every volcano on this planet; otherwise VolcanoFeatures.key_of.
@export var volcano_key := ""
## On: the event throws stones. Off: smoke alone, however strong.
@export var eruption_enabled := true
## Rise of the emission (s) at the start of the event: higher = a plume that builds up more slowly.
@export_range(1.0, 3600.0) var ramp_up_s := 45.0
## Fall of the emission (s) at the end of the event: higher = a gentler stop.
@export_range(1.0, 3600.0) var ramp_down_s := 30.0


func activity_at(when: float, key: String, eruption_only: bool = false) -> float:
	if not volcano_key.is_empty() and volcano_key != key:
		return 0.0
	if eruption_only and not eruption_enabled:
		return 0.0
	var age := when - start_unix
	return strength * emission_envelope(age, duration_s, ramp_up_s, ramp_down_s, eruption_only)


## Shared by scheduled events and random activity, so both follow the same transitions.
static func emission_envelope(age: float, length: float, rise: float, fall: float, eruptive: bool) -> float:
	# Rocks start after the smoke has begun to form, even in an eruptive episode.
	if eruptive:
		var delay := minf(rise, length * 0.35)
		return envelope(age - delay, length - delay, rise * 0.25, fall)
	return envelope(age, length, rise, fall)


static func envelope(age: float, length: float, rise: float, fall: float) -> float:
	if age < 0.0 or age >= length:
		return 0.0
	var up := clampf(rise, 0.01, length * 0.45)
	var down := clampf(fall, 0.01, length * 0.45)
	return smoothstep(0.0, up, age) * (1.0 - smoothstep(length - down, length, age))
