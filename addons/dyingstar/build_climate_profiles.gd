@tool
extends EditorScript
## Generates the ClimateProfile resource of every body from the weather service's derived data
## (`services/weather/data/derived/<system>.json`, written by `cargo test --test export_derived`
## with WEATHER_EXPORT=1). The service is the single implementation of the climate derivation;
## this script only copies numbers into `.tres` files the game can load offline and use as a
## fallback. Never hand-edit the written files: regenerate them (same rule as the atmosphere
## profiles).
##
## Run it after the service's data changes: DyingStar > Rebuild climate profiles, or File > Run.
## Headless: `godot --headless --path . -s addons/dyingstar/build_climate_profiles.gd`.

const DERIVED_JSON := "../services/weather/data/derived/tarsis.json"
const OUTPUT_DIR := "res://scenes/planet/climates"
## Service name → scene body key. The slot of a body is its key ("tarsis_3" is SandBox since the
## 2026-09-03 swap); the service names bodies as the system data does.
const BODY_KEYS := {
	"tarsis 1": "tarsis_1", "tarsis 2": "tarsis_2", "sandbox": "tarsis_3", "gaea": "tarsis_4",
	"tarsis 5": "tarsis_5", "tarsis 6": "tarsis_6", "tarsis 7": "tarsis_7", "tarsis 8": "tarsis_8",
	"p3_m1": "tarsis_3_1", "p3_m2": "tarsis_3_2", "p4_m1": "tarsis_4_1",
	"p5_m1": "tarsis_5_1", "p5_m2": "tarsis_5_2", "p5_m3": "tarsis_5_3", "p5_m4": "tarsis_5_4",
	"p5_m5": "tarsis_5_5", "p5_m6": "tarsis_5_6", "p6_m1": "tarsis_6_1", "p6_m2": "tarsis_6_2",
}
## Where the derived data is read: [constant DERIVED_JSON] beside the project, or under the services
## checkout named by DS_SERVICES_DIR (the CI clones it next to the project; a test may point elsewhere).
static func derived_path() -> String:
	var services: String = OS.get_environment("DS_SERVICES_DIR")
	if not services.is_empty():
		return services.path_join("weather/data/derived/tarsis.json")
	return ProjectSettings.globalize_path("res://").path_join(DERIVED_JSON)


## The profile of every body of [param parsed] (the derived data), by scene key, nothing written: what
## build_all saves, and what test_derived_profiles_current compares with the committed files.
static func profiles_from(parsed: Dictionary, report: Array[String]) -> Dictionary:
	var built: Dictionary = {}
	for body: Dictionary in parsed.get("bodies", []):
		var service_name: String = str(body.get("name", ""))
		var key: String = BODY_KEYS.get(service_name.to_lower(), "")
		if key.is_empty():
			report.append("[ClimateProfiles] %s: no scene key, skipped" % service_name)
			continue
		var profile := ClimateProfile.new()
		profile.body_name = service_name
		profile.weather_seed = int(body.get("seed", 0))
		for field: String in FIELDS:
			if body.has(field):
				profile.set(field, body[field])
		var extras: Dictionary = body.get("extras", {})
		profile.thermal_inertia_tiu = float(extras.get("thermal_inertia_tiu", profile.thermal_inertia_tiu))
		profile.wind_scale_max_ms = float(extras.get("wind_scale_max_ms", profile.wind_scale_max_ms))
		profile.dust_tau_max = float(extras.get("dust_tau_max", profile.dust_tau_max))
		built[key] = profile
	return built


## Derived field → ClimateProfile property (same names where they match).
const FIELDS := ["has_atmosphere", "radius_m", "surface_gravity", "rotation_period_s", "tidal_locked",
	"tilt_deg", "orbit_period_s", "pressure_pa", "rho0_kg_m3", "scale_height_m", "irradiance_w_m2",
	"bond_albedo", "t_eq_k", "t_surface_k", "diurnal_amplitude_k", "radiative_time_s",
	"delta_t_equator_pole_k", "coriolis_45_s", "hadley_edge_deg", "cells", "v10_scale_m_s",
	"v10_threshold_m_s", "sound_speed_m_s"]


func _run() -> void:
	var report: Array[String] = build_all()
	for line in report:
		print(line)


## Build every profile; returns the report lines. Static so a headless runner and tests can call it.
static func build_all() -> Array[String]:
	var report: Array[String] = []
	var path: String = derived_path()
	if not FileAccess.file_exists(path):
		report.append("[ClimateProfiles] derived data not found: %s" % path)
		return report
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not parsed.has("bodies"):
		report.append("[ClimateProfiles] unreadable derived data: %s" % path)
		return report
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var built: Dictionary = profiles_from(parsed, report)
	for key: String in built:
		var profile: ClimateProfile = built[key]
		var out: String = "%s/%s.tres" % [OUTPUT_DIR, key]
		var error := ResourceSaver.save(profile, out)
		if error != OK:
			report.append("[ClimateProfiles] %s: save failed (%d)" % [key, error])
		else:
			report.append("[ClimateProfiles] %s <- %s (air=%s, cells=%d, hadley=%.0f°, v10=%.1f m/s)" % [
				key, profile.body_name, profile.has_atmosphere, profile.cells, profile.hadley_edge_deg, profile.v10_scale_m_s])
	return report
