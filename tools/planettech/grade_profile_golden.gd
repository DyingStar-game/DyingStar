extends Node
## Writes tools/planettech/qgis/export/planet/grade_profile_golden.json: the longitudinal profiles the
## GAME's GradeProfile lays on a few synthetic terrains, for the QGIS road tools' Python twin
## (export/planet/grade_profile.py) to match bit for bit — test/unit/test_grade_profile_py.py.
## test/unit/test_grade_profile_golden.gd recomputes the file here and fails when GradeProfile
## changes without it: run this again, then port the change to the Python.
##
##   godot --headless --path . res://tools/planettech/grade_profile_golden.tscn
##
## The terrain is a function of the along-distance, linear between breakpoints (terrain_at): the
## same few float64 operations in both languages, where a sampler of directions would bring
## trigonometry that differs by an ulp between platforms. GradeProfile._knots and _segments are
## what is pinned — the rule; the along → direction mapping is plain interpolation.

## Where the fixture is written; test_grade_profile_py.py reads it from there.
const OUT_PATH := "res://tools/planettech/qgis/export/planet/grade_profile_golden.json"

## One case per behaviour of the rule. a0 / a1: along-range (absolute metres, the exporter's
## cumulative length — a line need not start at 0, nor end on a window); grade: rise / run;
## climb: the over-the-cap policy (true: climb at the grade, false: stay level).
const CASES := [
	{"name": "road_8deg_over_a_massif", "a0": 0.0, "a1": 6000.0, "grade_deg": 8.0, "climb": true,
		"terrain": [[0.0, 120.0], [1500.0, 260.0], [2600.0, 1150.0], [3000.0, 1210.0],
			[3400.0, 900.0], [4300.0, 180.0], [6000.0, 100.0]]},
	{"name": "railway_level_over_hills", "a0": 350.25, "a1": 4800.0, "grade": 0.04,
		"climb": false,
		"terrain": [[0.0, 50.0], [900.0, 70.0], [1300.0, 160.0], [1700.0, 40.0], [2600.0, -60.0],
			[3100.0, 20.0], [4800.0, 30.0]]},
	{"name": "railway_climbing_over_hills", "a0": 350.25, "a1": 4800.0, "grade": 0.04,
		"climb": true,
		"terrain": [[0.0, 50.0], [900.0, 70.0], [1300.0, 160.0], [1700.0, 40.0], [2600.0, -60.0],
			[3100.0, 20.0], [4800.0, 30.0]]},
	{"name": "narrow_dip_closed_by_the_skirts", "a0": 0.0, "a1": 1000.0, "grade_deg": 6.0,
		"climb": true,
		"terrain": [[0.0, 10.0], [490.0, 10.0], [500.0, 2.0], [510.0, 10.0], [1000.0, 10.0]]},
	{"name": "short_ridge_cut_not_bored", "a0": 0.0, "a1": 1200.0, "grade_deg": 4.0,
		"climb": true,
		"terrain": [[0.0, 0.0], [590.0, 0.0], [598.0, 30.0], [606.0, 0.0], [1200.0, 0.0]]},
	{"name": "two_tunnels_and_a_sliver", "a0": 0.0, "a1": 1600.0, "grade_deg": 3.0,
		"climb": true,
		"terrain": [[0.0, 0.0], [600.0, 0.0], [640.0, 60.0], [700.0, 60.0], [703.0, 9.0],
			[707.0, 60.0], [800.0, 60.0], [840.0, 0.0], [1600.0, 0.0]]},
	{"name": "short_last_window", "a0": 12.5, "a1": 1246.75, "grade_deg": 10.0, "climb": true,
		"terrain": [[0.0, 300.0], [400.0, 380.0], [900.0, 520.0], [1300.0, 515.0]]},
	{"name": "wide_valley_long_viaduct", "a0": 0.0, "a1": 5000.0, "grade_deg": 2.0,
		"climb": true,
		"terrain": [[0.0, 400.0], [1800.0, 400.0], [2000.0, 120.0], [3000.0, 110.0],
			[3200.0, 400.0], [5000.0, 400.0]]},
]


func _ready() -> void:
	var path := ProjectSettings.globalize_path(OUT_PATH)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[GradeProfileGolden] cannot write %s" % path)
		get_tree().quit(1)
		return
	f.store_string(JSON.stringify(golden(), "  ", true, true) + "\n")
	f.close()
	print("[GradeProfileGolden] written %s" % path)
	get_tree().quit()


## The fixture: every case with the profile GradeProfile lays on it.
static func golden() -> Dictionary:
	var cases: Array = []
	for c: Dictionary in CASES:
		cases.append(compute_case(c))
	return {
		"about": "GradeProfile knots and segments on synthetic terrains — written by "
				+ "tools/planettech/grade_profile_golden.gd, read by test_grade_profile_py.py",
		"constants": {
			"STATION_STEP_M": GradeSettings.STATION_STEP_M, "WINDOW_M": GradeSettings.WINDOW_M,
			"TUNNEL_MIN_COVER_M": GradeSettings.TUNNEL_MIN_COVER_M,
			"GORGE_MIN_M": GradeSettings.GORGE_MIN_M, "MIN_TUNNEL_M": GradeSettings.MIN_TUNNEL_M,
			"MIN_GORGE_BETWEEN_TUNNELS_M": GradeSettings.MIN_GORGE_BETWEEN_TUNNELS_M,
			"BED_THICKNESS_M": GradeSettings.BED_THICKNESS_M,
			"MIN_SPAN_M": GradeSettings.MIN_SPAN_M,
			"VIADUCT_MAX_SPAN_M": GradeSettings.VIADUCT_MAX_SPAN_M,
			"RAILWAY_MAX_GRADE": RailwaySettings.MAX_GRADE,
			"RAILWAY_CLIMB_AT_MAX_GRADE": RailwaySettings.CLIMB_AT_MAX_GRADE,
		},
		"cases": cases,
	}


## One case: its inputs and GradeProfile's profile of it — the same steps as GradeProfile.compute,
## the terrain read per along-distance.
static func compute_case(c: Dictionary) -> Dictionary:
	var bp: Array = c["terrain"]
	var terrain := func(a: float) -> float: return terrain_at(bp, a)
	var grade: float = float(c["grade"]) if c.has("grade") \
			else tan(deg_to_rad(float(c["grade_deg"])))
	var a0: float = c["a0"]
	var a1: float = c["a1"]
	var knots := GradeProfile._knots(a0, a1, terrain, grade, bool(c["climb"]))
	var sa := GradeProfile.station_alongs(a0, a1)
	var st := PackedFloat64Array()
	for a in sa:
		st.append(terrain_at(bp, a))
	var profile := {"along0": a0, "along1": a1, "knots_along": knots[0], "knots_z": knots[1],
		"stations_along": sa, "stations_terrain": st}
	var segs: Array = []
	for s: Dictionary in GradeProfile._segments(profile):
		segs.append({"kind": int(s["kind"]), "lo": s["lo"], "hi": s["hi"],
			"max_depth": s["max_depth"], "max_gap": s["max_gap"]})
	var out := c.duplicate(true)
	out["grade"] = grade
	out["knots_along"] = Array(knots[0])
	out["knots_z"] = Array(knots[1])
	out["stations"] = sa.size()
	out["segments"] = segs
	return out


## The terrain at [param a]: linear between the breakpoints [[along, h], …], flat past both ends —
## export/planet/grade_profile.py piecewise_terrain, operation for operation.
static func terrain_at(bp: Array, a: float) -> float:
	var n := bp.size()
	if a <= float(bp[0][0]):
		return float(bp[0][1])
	if a >= float(bp[n - 1][0]):
		return float(bp[n - 1][1])
	var i := 0
	while i + 1 < n and float(bp[i + 1][0]) <= a:
		i += 1
	var x0 := float(bp[i][0])
	var x1 := float(bp[i + 1][0])
	var h0 := float(bp[i][1])
	var h1 := float(bp[i + 1][1])
	var t := (a - x0) / (x1 - x0)
	return h0 + (h1 - h0) * t
