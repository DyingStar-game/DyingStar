@tool
extends EditorScript

## Generates the AtmosphereProfile resource of every body whose atmosphere the
## system JSON describes.
##
## Single responsibility: turn a composition into scattering constants. The JSON
## served by services/resourcesDynamic is the source of truth for what the air
## is made of; this script does the physics ONCE, at edit time, so the client
## never integrates anything at runtime. The written .tres files are derived --
## never hand-edit them, regenerate them (same rule as build_shared_materials).
##
## Run it from the script editor (File > Run, or Ctrl+Shift+X) after the system
## data changes.
##
## The Mie/haze parameters cannot be derived from a gas mix: they come from an
## offline Mie-scattering computation on the suspended dust, and are pinned in
## HAZE below, with the study that produced them.

## Physical constants, SI. N_REF is the Loschmidt number, the number density the
## published refractive indices are measured at (273.15 K, 101325 Pa) -- mixing an
## index measured there with a density taken at another temperature is a silent
## 5 % error, so the two must be quoted together.
const K_BOLTZMANN := 1.380649e-23
const R_GAS := 8.314462618
const N_REF := 2.6867811e25
const G_CONST := 6.67430e-11
const M_EARTH := 5.972e24
const R_SUN := 6.957e8
const L_SUN := 3.828e26
const T_SUN := 5772.0
const AU := 1.495978707e11

## RGB sampling wavelengths, micrometres.
const LAMBDA_R := 0.680
const LAMBDA_G := 0.550
const LAMBDA_B := 0.440

## Molar masses, kg/mol. A gas absent from this table cannot be handled: its
## refractivity is not sourced, and silently dropping it would renormalise the
## mix and produce a wrong beta. Bodies using one are skipped and reported.
const MOLAR_MASS := {
	"N2": 0.0280134,
	"O2": 0.0319988,
	"Ar": 0.0399480,
	"CO2": 0.0440095,
	"CH4": 0.0160425,
}

## Haze, ground albedo and star colour cannot be derived from the JSON. Keyed by
## the Godot planet name. See the atmosphere study for the derivation.
##
## Sandbox: mie_beta is calibrated so the vertical optical depth is 1.9037 with
## the capped density profile below, whose integral is haze_top = 3500 m. That
## depth is what pins the planet's published 0.32 albedo, so changing the profile
## means recomputing beta. mie_albedo is exactly 1.0 because corundum (Al2O3) has
## k close to 0 in the visible: the veil redistributes light, it never darkens.
const HAZE := {
	"tarsis_4": {
		"mie_beta": Vector3(5.544043e-04, 5.439069e-04, 5.322673e-04),
		"mie_g": 0.691,
		"mie_albedo": 1.0,
		"haze_top": 3500.0,
		"haze_falloff": 500.0,
		"ground_albedo": 0.15,
	},
}

## Earth air, used to validate the whole chain: everyone knows what a blue sky
## looks like, so a wrong model shows up here and not on an alien planet.
const EARTH_MIX := {"N2": 0.78084, "O2": 0.20946, "Ar": 0.00934, "CO2": 0.00036}
const EARTH_PRESSURE_BAR := 1.01325
const EARTH_TEMPERATURE := 288.15
const EARTH_GRAVITY := 9.80665
const EARTH_RADIUS := 6371000.0
const EARTH_ATMOSPHERE_TOP := 100000.0

const OUTPUT_DIR := "res://scenes/planet/atmospheres"

## The system JSON lives in the sibling `services` repository, outside res://.
## Resolved from the project folder so it follows the standard workspace layout.
const SYSTEM_JSON_RELATIVE := "../services/resourcesDynamic/data/system/tarsis.json"


## Outcome of a build pass, so the run reports without parsing logs.
class Report extends RefCounted:
	var written: PackedStringArray = []
	var skipped: PackedStringArray = []
	var warnings: PackedStringArray = []
	var errors: PackedStringArray = []


func _run() -> void:
	var report := Report.new()
	var system := _read_system_json(report)
	if not system.is_empty():
		_build_system(system, report)
	_build_earth_reference(report)
	_register_written_resources(report)
	_print_report(report)


## Registers the generated resources so they appear in the FileSystem dock.
func _register_written_resources(report: Report) -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	for path in report.written:
		filesystem.update_file(path)


func _read_system_json(report: Report) -> Dictionary:
	var project_dir := ProjectSettings.globalize_path("res://")
	var path := project_dir.path_join(SYSTEM_JSON_RELATIVE).simplify_path()
	if not FileAccess.file_exists(path):
		report.errors.append("System JSON not found at %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		report.errors.append("%s is not valid JSON." % path)
		return {}
	report.warnings.append("Read %s" % path)
	return parsed as Dictionary


func _build_system(system: Dictionary, report: Report) -> void:
	var flat: Dictionary = system.get("flat", {})
	var structured: Dictionary = system.get("structured", {})
	var star := _read_star(structured, report)
	if star.is_empty():
		return
	var planets: Array = structured.get("planets", [])
	for index in planets.size():
		_build_planet(planets[index], index, flat, star, report)


## Star constants shared by every body. temp_K is RE-DERIVED from luminosity and
## radius rather than trusted: Stefan-Boltzmann ties the three together, and a
## generator that gets the exponent wrong publishes a temperature contradicting
## its own luminosity. The luminosity is the figure the rest of the file agrees with.
func _read_star(structured: Dictionary, report: Report) -> Dictionary:
	var stars: Array = structured.get("stars", [])
	if stars.is_empty():
		report.errors.append("The system JSON declares no star.")
		return {}
	var star: Dictionary = stars[0]
	var luminosity_w: float = float(star.get("luminosity_W", 0.0))
	var radius_sun: float = float(star.get("radius_Sun", 0.0))
	if luminosity_w <= 0.0 or radius_sun <= 0.0:
		report.errors.append("The star has no usable luminosity/radius.")
		return {}
	var luminosity_lsun: float = luminosity_w / L_SUN
	var derived_temp: float = T_SUN * pow(luminosity_lsun / (radius_sun * radius_sun), 0.25)
	var published_temp: float = float(star.get("temp_K", 0.0))
	if published_temp > 0.0 and absf(derived_temp - published_temp) > 0.01 * derived_temp:
		report.warnings.append(
			"Star temp_K reads %.0f K, but its own luminosity and radius give %.0f K. Using %.0f K."
			% [published_temp, derived_temp, derived_temp]
		)
	return {
		"luminosity_w": luminosity_w,
		"radius_m": radius_sun * R_SUN,
		"temperature": derived_temp,
	}


func _build_planet(planet: Dictionary, index: int, flat: Dictionary, star: Dictionary, report: Report) -> void:
	var planet_name := "tarsis_%d" % (index + 1)
	var display_name := str(flat.get("P%d_Name" % (index + 1), planet_name))
	var atmosphere: Dictionary = planet.get("atmosphere", {})
	var gases: Dictionary = atmosphere.get("gases_pct", {})
	var thickness_km: float = float(atmosphere.get("thickness_km", 0.0))
	if gases.is_empty() or thickness_km <= 0.0:
		report.skipped.append("%s (%s): airless" % [planet_name, display_name])
		return
	var unknown := _unknown_gases(gases)
	if not unknown.is_empty():
		report.skipped.append(
			"%s (%s): no sourced refractivity for %s" % [planet_name, display_name, ", ".join(unknown)]
		)
		return
	var temperature: float = float(flat.get("P%d_T_Surface_K" % (index + 1), 0.0))
	if temperature <= 0.0:
		report.skipped.append("%s (%s): no surface temperature" % [planet_name, display_name])
		return

	var mix := _normalised_mix(gases, planet_name, display_name, report)
	var radius: float = float(planet.get("radius_km", 0.0)) * 1000.0
	var gravity: float = G_CONST * float(planet.get("mass_Me", 0.0)) * M_EARTH / (radius * radius)
	var distance: float = float(planet.get("semi_major_AU", 0.0)) * AU

	var profile := AtmosphereProfile.new()
	profile.planet_radius = radius
	profile.atmosphere_top = thickness_km * 1000.0
	profile.gravity = gravity
	profile.rayleigh_scale_height = _scale_height(mix, temperature, gravity)
	profile.rayleigh_beta = _rayleigh_beta(mix, float(atmosphere.get("pressure_bar", 0.0)), temperature)
	profile.star_temperature = star["temperature"]
	profile.star_irradiance = star["luminosity_w"] / (4.0 * PI * distance * distance)
	profile.star_angular_diameter = rad_to_deg(2.0 * atan(star["radius_m"] / distance))
	_apply_haze(profile, planet_name, display_name, report)
	_write_profile(profile, planet_name, report)


## Gas fractions, renormalised to 1. The JSON publishes percentages that do not
## always add up (Sandbox once shipped a mix summing to 106 %), and a mix that
## does not close is a data bug worth naming, not something to rescale in silence.
func _normalised_mix(gases: Dictionary, planet_name: String, display_name: String, report: Report) -> Dictionary:
	var total := 0.0
	for gas in gases:
		total += float(gases[gas])
	if absf(total - 100.0) > 0.5:
		report.warnings.append(
			"%s (%s): the gas mix adds up to %.2f %%, not 100 %%. Renormalised, but the data is wrong."
			% [planet_name, display_name, total]
		)
	var mix := {}
	for gas in gases:
		mix[gas] = float(gases[gas]) / total
	return mix


func _unknown_gases(gases: Dictionary) -> PackedStringArray:
	var unknown := PackedStringArray()
	for gas in gases:
		if not MOLAR_MASS.has(gas):
			unknown.append(str(gas))
	return unknown


## Molar mass of the mix, kg/mol.
func _molar_mass(mix: Dictionary) -> float:
	var mass := 0.0
	for gas in mix:
		mass += float(mix[gas]) * float(MOLAR_MASS[gas])
	return mass


## H = R T / (M g): the altitude over which pressure falls by a factor e.
func _scale_height(mix: Dictionary, temperature: float, gravity: float) -> float:
	return R_GAS * temperature / (_molar_mass(mix) * gravity)


## beta = N0 * sum(x_i * sigma_i), evaluated at 680 / 550 / 440 nm, in 1/m.
func _rayleigh_beta(mix: Dictionary, pressure_bar: float, temperature: float) -> Vector3:
	var number_density := pressure_bar * 1e5 / (K_BOLTZMANN * temperature)
	return Vector3(
		number_density * _cross_section_mix(mix, LAMBDA_R),
		number_density * _cross_section_mix(mix, LAMBDA_G),
		number_density * _cross_section_mix(mix, LAMBDA_B)
	)


func _cross_section_mix(mix: Dictionary, lambda_um: float) -> float:
	var total := 0.0
	for gas in mix:
		total += float(mix[gas]) * _cross_section(str(gas), lambda_um)
	return total


## Rayleigh cross-section of one gas, m^2:
##   sigma = 24 pi^3 (n^2-1)^2 / (lambda^4 N_ref^2 (n^2+2)^2) * F_king
func _cross_section(gas: String, lambda_um: float) -> float:
	var n := 1.0 + _refractivity(gas, lambda_um)
	var n2 := n * n
	var lambda_m := lambda_um * 1e-6
	var numerator := 24.0 * PI * PI * PI * pow(n2 - 1.0, 2.0)
	var denominator := pow(lambda_m, 4.0) * N_REF * N_REF * pow(n2 + 2.0, 2.0)
	return numerator / denominator * _king_factor(gas, lambda_um)


## n - 1 at 273.15 K / 101325 Pa. N2 and O2 carry their dispersion formula (they
## are most of the air and the wavelength dependence matters); the trace gases are
## flat, they are too light in the mix for the difference to show.
func _refractivity(gas: String, lambda_um: float) -> float:
	var inverse_um := 1.0 / lambda_um
	match gas:
		"N2":
			return (6855.200 + 3243157.0 / (144.0 - inverse_um * inverse_um)) * 1e-8
		"O2":
			var inverse_cm := 1.0 / (lambda_um * 1e-4)
			return (20564.8 + 2.480899e13 / (4.09e9 - inverse_cm * inverse_cm)) * 1e-8
		"Ar":
			return 2.825e-4
		"CO2":
			return 4.49e-4
		"CH4":
			return 4.41e-4
	return 0.0


## King correction factor: how much a molecule's anisotropy raises its scattering
## above the ideal isotropic case.
func _king_factor(gas: String, lambda_um: float) -> float:
	var l2 := lambda_um * lambda_um
	match gas:
		"N2":
			return 1.034 + 3.17e-4 / l2
		"O2":
			return 1.096 + 1.385e-3 / l2 + 1.448e-4 / (l2 * l2)
		"CO2":
			return 1.15
	return 1.0


func _apply_haze(profile: AtmosphereProfile, planet_name: String, display_name: String, report: Report) -> void:
	if not HAZE.has(planet_name):
		report.warnings.append(
			"%s (%s): no haze data, written with Rayleigh only." % [planet_name, display_name]
		)
		return
	var haze: Dictionary = HAZE[planet_name]
	profile.mie_beta = haze["mie_beta"]
	profile.mie_g = haze["mie_g"]
	profile.mie_albedo = haze["mie_albedo"]
	profile.haze_top = haze["haze_top"]
	profile.haze_falloff = haze["haze_falloff"]
	profile.ground_albedo = haze["ground_albedo"]


## Earth, through the exact same code path as any alien body. Its Rayleigh optical
## depth at 550 nm must come out at 0.0970 (Bodhaine 1999 measures 0.0973); if it
## does not, the model is wrong, and no amount of tuning Sandbox will fix that.
func _build_earth_reference(report: Report) -> void:
	var profile := AtmosphereProfile.new()
	profile.planet_radius = EARTH_RADIUS
	profile.atmosphere_top = EARTH_ATMOSPHERE_TOP
	profile.gravity = EARTH_GRAVITY
	profile.rayleigh_scale_height = _scale_height(EARTH_MIX, EARTH_TEMPERATURE, EARTH_GRAVITY)
	profile.rayleigh_beta = _rayleigh_beta(EARTH_MIX, EARTH_PRESSURE_BAR, EARTH_TEMPERATURE)
	# Haze and ozone are measured, not derived from a gas mix.
	profile.mie_beta = Vector3(2.1e-05, 2.1e-05, 2.1e-05)
	profile.mie_g = 0.76
	profile.mie_albedo = 0.9
	profile.mie_scale_height = 1200.0
	profile.absorption_beta = Vector3(0.650e-06, 1.881e-06, 0.085e-06)
	profile.ground_albedo = 0.15
	profile.star_temperature = T_SUN
	profile.star_irradiance = 1361.0
	profile.star_angular_diameter = 0.5334
	var optical_depth: float = profile.rayleigh_beta.y * profile.rayleigh_scale_height
	report.warnings.append(
		"Earth check: zenith Rayleigh optical depth at 550 nm = %.4f (Bodhaine 1999: 0.0973)."
		% optical_depth
	)
	_write_profile(profile, "earth_reference", report)


func _write_profile(profile: AtmosphereProfile, body_name: String, report: Report) -> void:
	var path := "%s/%s.tres" % [OUTPUT_DIR, body_name]
	var error := ResourceSaver.save(profile, path)
	if error != OK:
		report.errors.append("Could not write %s (error %d)." % [path, error])
		return
	report.written.append(path)


func _print_report(report: Report) -> void:
	print("--- atmosphere profiles ---")
	for line in report.warnings:
		print("  note:    ", line)
	for line in report.skipped:
		print("  skipped: ", line)
	for line in report.written:
		print("  written: ", line)
	for line in report.errors:
		printerr("  ERROR:   ", line)
	print("%d written, %d skipped, %d errors."
		% [report.written.size(), report.skipped.size(), report.errors.size()])
