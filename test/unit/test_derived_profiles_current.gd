extends GutTest
## The climate and atmosphere profiles committed here are what their generators make TODAY from the
## services repository's data: the weather service's derived climate (build_climate_profiles.gd) and
## resourcesDynamic's system file (build_atmosphere_profiles.gd).
##
## Both are copies of another repository's data, and nothing else tells when that data moves: services #54
## changed Sandbox's albedo and air, and the game kept the old climate and the old sky for a month. Same
## idea as the shared material library check: build in memory, compare, name what moved and the button.
##
## The data is read beside the project (`../services`, where the CI clones its develop) or under
## DS_SERVICES_DIR. Without it the tests are pending: a checkout without services is not a failure.

## Relative gap under which two numbers are the same: the last digits move from one toolchain to another.
const TOLERANCE := 1e-9
const CLIMATE_TOOL := "res://addons/dyingstar/build_climate_profiles.gd"
const ATMOSPHERE_TOOL := "res://addons/dyingstar/build_atmosphere_profiles.gd"
const ATMOSPHERE_FIELDS := ["planet_radius", "atmosphere_top", "gravity", "surface_pressure_pa", "rayleigh_beta",
	"rayleigh_scale_height", "mie_beta", "mie_g", "mie_albedo", "haze_top", "haze_bottom", "haze_falloff",
	"ground_albedo", "star_irradiance", "star_angular_diameter", "star_temperature", "star_color"]


func test_the_climate_profiles_are_what_the_weather_service_derives() -> void:
	var tool: GDScript = load(CLIMATE_TOOL)
	var path: String = tool.derived_path()
	if not FileAccess.file_exists(path):
		pending("no services checkout beside the project (%s): nothing to compare with" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(parsed is Dictionary, "the derived climate reads")
	var report: Array[String] = []
	var built: Dictionary = tool.profiles_from(parsed, report)
	assert_gt(built.size(), 0, "bodies in the derived climate")
	var fields: Array = tool.FIELDS.duplicate()
	fields.append_array(["weather_seed", "thermal_inertia_tiu", "wind_scale_max_ms", "dust_tau_max"])
	for key: String in built:
		var committed_path := "%s/%s.tres" % [tool.OUTPUT_DIR, key]
		var committed: Resource = load(committed_path)
		assert_not_null(committed, "%s exists" % committed_path)
		if committed == null:
			continue
		var moved := _first_difference(built[key], committed, fields)
		assert_eq(moved, "", ("%s differs from the weather service's derived climate (%s). If services is up to date beside the "
				+ "project, rebuild them: DyingStar > Rebuild climate profiles (docs/WEATHER.md)") % [committed_path, moved])


func test_the_atmosphere_profiles_are_what_the_system_data_gives() -> void:
	var tool_script: GDScript = load(ATMOSPHERE_TOOL)
	var path: String = tool_script.system_json_path()
	if not FileAccess.file_exists(path):
		pending("no services checkout beside the project (%s): nothing to compare with" % path)
		return
	# The tool is an EditorScript, which only the editor may instantiate: its own source, compiled as a plain
	# script, run dry (it fills `built` instead of writing files).
	var source: String = FileAccess.get_file_as_string(ATMOSPHERE_TOOL).replace("extends EditorScript", "extends RefCounted")
	var plain := GDScript.new()
	plain.source_code = source
	assert_eq(plain.reload(), OK, "the generator compiles as a plain script")
	var tool: Object = plain.new()
	tool.set("dry_run", true)
	var report: Object = plain.get("Report").new()
	var system: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(system is Dictionary, "the system data reads")
	tool.call("_build_system", system, report)
	var built: Dictionary = tool.get("built")
	assert_gt(built.size(), 0, "bodies with air in the system data")
	for body_name: String in built:
		var committed_path := "%s/%s.tres" % [tool_script.OUTPUT_DIR, body_name]
		var committed: Resource = load(committed_path)
		assert_not_null(committed, "%s exists" % committed_path)
		if committed == null:
			continue
		var moved := _first_difference(built[body_name], committed, ATMOSPHERE_FIELDS)
		assert_eq(moved, "", ("%s differs from resourcesDynamic's system data (%s). If services is up to date beside the "
				+ "project, rebuild them: DyingStar > Rebuild atmosphere profiles") % [committed_path, moved])


func test_a_moved_value_is_named_and_toolchain_digits_are_not() -> void:
	var a := ClimateProfile.new()
	var b := ClimateProfile.new()
	a.t_eq_k = 217.41992521656323
	b.t_eq_k = 217.41992521656326
	assert_eq(_first_difference(a, b, ["t_eq_k"]), "", "the last digits of another toolchain")
	b.t_eq_k = 258.5573
	assert_string_contains(_first_difference(a, b, ["t_eq_k"]), "t_eq_k", "a value that moved is named")


## The first of [param fields] whose value differs between [param expected] and [param found] beyond
## TOLERANCE, as "field: found -> expected"; "" when they agree.
func _first_difference(expected: Object, found: Object, fields: Array) -> String:
	for field: String in fields:
		var want: Variant = expected.get(field)
		var have: Variant = found.get(field)
		if not _same(want, have):
			return "%s: %s committed, %s from the data" % [field, str(have), str(want)]
	return ""


func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) in [TYPE_FLOAT, TYPE_INT] and typeof(b) in [TYPE_FLOAT, TYPE_INT]:
		var scale := maxf(maxf(absf(float(a)), absf(float(b))), 1e-12)
		return absf(float(a) - float(b)) / scale <= TOLERANCE
	if a is Vector3 and b is Vector3:
		return _same(a.x, b.x) and _same(a.y, b.y) and _same(a.z, b.z)
	if a is Color and b is Color:
		return _same(a.r, b.r) and _same(a.g, b.g) and _same(a.b, b.b) and _same(a.a, b.a)
	return a == b
