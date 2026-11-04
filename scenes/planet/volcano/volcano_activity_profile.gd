@tool
class_name VolcanoActivityProfile
extends Resource
## Shared, versioned configuration. All clients derive the same eruptions from UTC and the seed.
const DIRECTORY := "res://scenes/planet/volcano/profiles/"
static var _profiles: Dictionary = {}

## Random activities on the volcanoes that are not dormant. Off: only idle smoke and dated events remain.
@export var random_enabled := true
## Mean time (s) between two starts of activity on one volcano: lower = more frequent.
@export_range(10.0, 604800.0) var interval_s := 600.0
## Shift of each start, as a share (0..0.4) of the interval, either way: higher = less regular.
@export_range(0.0, 0.4) var interval_jitter := 0.25
## Length (s) of a random activity, ramps included. Must fit in the shortest possible interval.
@export_range(1.0, 86400.0) var duration_s := 90.0
## Weakest strength (0..4) drawn for an activity: raises the smallest plumes and eruptions.
@export_range(0.0, 4.0) var strength_min := 0.8
## Strongest strength (0..4) drawn for an activity: raises the largest plumes and eruptions.
@export_range(0.0, 4.0) var strength_max := 1.6
## Smoke strength (0..1) between activities: 0 = nothing leaves the vent, higher = a volcano that always smokes.
@export_range(0.0, 1.0) var idle_strength := 0.0
## Chance (0..1) that an activity throws stones; the others are smoke alone. Higher = more eruptions.
@export_range(0.0, 1.0) var eruption_chance := 0.55
## Rise of the emission (s) at the start of an activity: higher = a plume that builds up more slowly.
@export_range(1.0, 3600.0) var ramp_up_s := 45.0
## Fall of the emission (s) at the end of an activity: higher = a gentler stop.
@export_range(1.0, 3600.0) var ramp_down_s := 30.0
## Time (s) the smoke already emitted takes to fade once an activity ends: higher = it hangs in the air longer.
@export_range(1.0, 3600.0) var dissipation_s := 120.0
## Seed of the random activities: another value gives another sequence, the same one on every client.
@export var seed := 1
## Multiplier (0..5) of the weather's wind on the smoke: higher = plumes bent further, 0 = straight up.
@export_range(0.0, 5.0) var wind_multiplier := 1.6
## How much (0..1) plumes differ in height, length, width and shade: 0 = all alike, 1 = full variety.
@export_range(0.0, 1.0) var appearance_variation := 1.0
## Dated events of this planet, on top of the random activities: the strongest one wins.
@export var events: Array[VolcanoEvent] = []


static func path_for(planet: String) -> String:
	return DIRECTORY + planet.validate_filename() + ".tres"


static func for_planet(planet: String) -> VolcanoActivityProfile:
	if not _profiles.has(planet):
		var path := path_for(planet)
		_profiles[planet] = load(path) if ResourceLoader.exists(path) else VolcanoActivityProfile.new()
	return _profiles[planet]


func validation_error() -> String:
	if not is_finite(interval_s) or interval_s < 10.0 or interval_s > 604800.0:
		return "Intervalle : de 10 secondes a 7 jours."
	if not is_finite(duration_s) or duration_s < 1.0 or duration_s > interval_s * (1.0 - 2.0 * interval_jitter):
		return "La duree doit tenir dans l'intervalle le plus court (avec aleatoire)."
	if interval_jitter < 0.0 or interval_jitter > 0.4 or strength_min < 0.0 or strength_max < strength_min or strength_max > 4.0:
		return "Verifiez les bornes de force et la variation de l'intervalle."
	if eruption_chance < 0.0 or eruption_chance > 1.0 or ramp_up_s < 1.0 or ramp_down_s < 1.0 or dissipation_s < 1.0:
		return "Verifiez la probabilite d'eruption et les durees de transition."
	for event in events:
		if event == null or event.duration_s < 1.0 or event.strength < 0.0 or event.strength > 4.0 or event.start_unix <= 0.0:
			return "Evenement invalide."
	return ""


func has_events(key: String) -> bool:
	for event in events:
		if event != null and (event.volcano_key.is_empty() or event.volcano_key == key):
			return true
	return false


func activity_at(
	when: float, volcano_seed: int, key: String, dormant: bool = false, eruption_only: bool = false, observed_at: float = -1.0
) -> float:
	return _sample_at(when, volcano_seed, key, dormant, eruption_only, observed_at).y


## x = emitted strength, y = remaining smoke now. Evaluate the schedule only once per puff.
func sample_smoke(when: float, observed_at: float, volcano_seed: int, key: String, dormant: bool) -> Vector2:
	return _sample_at(when, volcano_seed, key, dormant, false, observed_at)


func _sample_at(when: float, volcano_seed: int, key: String, dormant: bool, eruption_only: bool, observed_at: float) -> Vector2:
	var result := 0.0 if dormant or eruption_only else idle_strength
	var emitted := result
	if random_enabled and not dormant:
		var period := maxf(interval_s, 10.0)
		var offset := VolcanoRandom.hash01(volcano_seed, seed + 301) * period
		var cycle := floori((when + offset) / period)
		for slot in range(cycle - 1, cycle + 2):
			if eruption_only and VolcanoRandom.hash01(slot + volcano_seed, seed + 304) >= eruption_chance:
				continue
			var jitter := (VolcanoRandom.hash01(slot + volcano_seed, seed + 302) * 2.0 - 1.0) * clampf(interval_jitter, 0.0, 0.4) * period
			var start := float(slot) * period - offset + jitter
			var length := clampf(duration_s, 1.0, period * (1.0 - 2.0 * clampf(interval_jitter, 0.0, 0.4)))
			var age := when - start
			if age >= 0.0 and age < length:
				var strength := lerpf(strength_min, strength_max, VolcanoRandom.hash01(slot + volcano_seed, seed + 303))
				var amount := strength * VolcanoEvent.emission_envelope(age, length, ramp_up_s, ramp_down_s, eruption_only)
				emitted = maxf(emitted, amount)
				if observed_at >= 0.0:
					amount *= 1.0 - smoothstep(start + length, start + length + dissipation_s, observed_at)
				result = maxf(result, amount)
	for event in events:
		if event != null:
			var amount := event.activity_at(when, key, eruption_only)
			emitted = maxf(emitted, amount)
			if observed_at >= 0.0:
				amount *= (
					1.0 - smoothstep(event.start_unix + event.duration_s, event.start_unix + event.duration_s + dissipation_s, observed_at)
				)
			result = maxf(result, amount)
	return Vector2(clampf(emitted, 0.0, 4.0), clampf(result, 0.0, 4.0))


func copy_from(source: VolcanoActivityProfile) -> void:
	var applied := source.duplicate(true)
	for property in applied.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			set(property.name, applied.get(property.name))
