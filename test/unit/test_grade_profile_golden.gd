extends GutTest
## The longitudinal profile the QGIS road tools show is computed by a Python twin of GradeProfile
## (tools/planettech/qgis/export/planet/grade_profile.py), pinned to the file
## tools/planettech/qgis/export/planet/grade_profile_golden.json. This test recomputes that file
## with the game's GradeProfile: when it fails, the game's rule changed without the twin — run
##     godot --headless --path . res://tools/planettech/grade_profile_golden.tscn
## then port the change to grade_profile.py until test/unit/test_grade_profile_py.py passes.

const GOLDEN_PATH := "res://tools/planettech/qgis/export/planet/grade_profile_golden.json"
## Godot's JSON reader does not round its decimals correctly: a double written with 17 digits
## comes back off by an ulp. The comparison here allows a few (a rule change moves metres); the
## Python test, whose reader is exact, compares bit for bit.
const ULPS := 4.0
const Golden := preload("res://tools/planettech/grade_profile_golden.gd")

var _file: Dictionary = {}


func before_all() -> void:
	var text := FileAccess.get_file_as_string(GOLDEN_PATH)
	var parsed: Variant = JSON.parse_string(text)
	_file = parsed if parsed is Dictionary else {}


func test_the_golden_file_is_there() -> void:
	assert_false(_file.is_empty(), "%s missing or unreadable" % GOLDEN_PATH)
	assert_eq((_file.get("cases", []) as Array).size(), Golden.CASES.size(),
			"one profile per case of grade_profile_golden.gd")


func test_constants_are_the_game_s() -> void:
	var now: Dictionary = Golden.golden()["constants"]
	var then: Dictionary = _file.get("constants", {})
	for key: String in now:
		assert_true(_close(float(then.get(key, NAN)), float(now[key])), "constant %s" % key)


func test_every_case_profiles_as_the_file_says() -> void:
	var cases: Array = _file.get("cases", [])
	for i in mini(cases.size(), Golden.CASES.size()):
		var want: Dictionary = cases[i]
		var got := Golden.compute_case(Golden.CASES[i])
		var name: String = got["name"]
		assert_eq(str(want.get("name")), name)
		assert_eq(int(want["stations"]), int(got["stations"]), "%s stations" % name)
		_same_floats(want["knots_along"], got["knots_along"], "%s knots_along" % name)
		_same_floats(want["knots_z"], got["knots_z"], "%s knots_z" % name)
		var ws: Array = want["segments"]
		var gs: Array = got["segments"]
		assert_eq(ws.size(), gs.size(), "%s segment count" % name)
		for k in mini(ws.size(), gs.size()):
			assert_eq(int(ws[k]["kind"]), int(gs[k]["kind"]), "%s segment %d kind" % [name, k])
			for key: String in ["lo", "hi", "max_depth", "max_gap"]:
				assert_true(_close(float(ws[k][key]), float(gs[k][key])),
						"%s segment %d %s: %s vs %s"
						% [name, k, key, str(float(ws[k][key])), str(float(gs[k][key]))])


func test_the_cases_exercise_every_kind_and_absorption() -> void:
	var kinds := {}
	for c: Dictionary in _file.get("cases", []):
		for s: Dictionary in c["segments"]:
			kinds[int(s["kind"])] = true
	for kind in [GradeSettings.Kind.GROUND, GradeSettings.Kind.GORGE, GradeSettings.Kind.TUNNEL,
			GradeSettings.Kind.BRIDGE]:
		assert_true(kinds.has(kind), "a case yields kind %d" % kind)


func _same_floats(want: Array, got: Array, what: String) -> void:
	assert_eq(want.size(), got.size(), "%s size" % what)
	for k in mini(want.size(), got.size()):
		if not _close(float(want[k]), float(got[k])):
			fail_test("%s[%d]: %s vs %s" % [what, k, str(float(want[k])), str(float(got[k]))])
			return
	pass_test(what)


func _close(a: float, b: float) -> bool:
	return absf(a - b) <= ULPS * 2.220446049250313e-16 * maxf(1.0, maxf(absf(a), absf(b)))
