extends GutTest
## Suite for [GradeBed] — the ballast bed on the profile, its skirts, and
## the cutting rule that lowers terrain vertices to it.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_railway_bed.gd

const RADIUS := 6356000.0
const LAT := 24.8
const LON0 := -39.6
const MPD := RADIUS * PI / 180.0
const Kind := GradeSettings.Kind


func _road(length_m: float) -> Dictionary:
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	var n := int(length_m / 20.0) + 1
	for i in n:
		var d := float(i) * 20.0
		cl.append(Vector2(LON0 + d / (MPD * clat), LAT))
		cum.append(d)
	return {"feature_id": 3, "centerline": cl, "_cum_lengths": cum,
			"road_type": "railway", "tracks": 2}


static func _east_m(dir: Vector3) -> float:
	var lon := rad_to_deg(atan2(dir.z, dir.x))
	return (lon - LON0) * MPD * cos(deg_to_rad(LAT))


func _sampler(f: Callable) -> Callable:
	return func(dir: Vector3) -> float:
		return float(f.call(_east_m(dir)))


func _flat(_s: float) -> float:
	return 100.0


## A 1.5 m dip between 300 and 340 m: below the bed, above the skirts' reach.
func _dip(s: float) -> float:
	return 98.5 if (s >= 300.0 and s <= 340.0) else 100.0


## Ground 9 m above a level track from 500 m on: more than the grade can
## follow in a window (8 m), less than a tunnel's cover — a cutting.
func _step_up(s: float) -> float:
	return 109.0 if s >= 500.0 else 100.0


## Vertices are float32-snapped in a LOCAL frame, like a chunk's: at the
## planet's absolute radius float32 is 0.5 m coarse and would swamp every
## assertion below. Everything is built relative to this origin.
var _origin := PlanetChunk.snap_to_f32(
		RoadBridge.lonlat_to_dir(LON0 + 500.0 / (MPD * cos(deg_to_rad(LAT))), LAT)
		* (RADIUS + 100.0))


func _r(v: Vector3) -> float:
	return (v + _origin).length()


func _bed(f: Callable, want_visual := true, outward := true) -> Dictionary:
	var road := _road(1000.0)
	var prof := GradeProfile.compute(road, _sampler(f), false)
	assert_true(prof["ok"])
	return GradeBed.build_piece(road["centerline"], road["_cum_lengths"], prof, [],
			MPD, RADIUS, _sampler(f), 10.0, _origin, want_visual, outward)


func test_top_sits_on_the_profile_and_skirts_reach_under_the_ground() -> void:
	var bed := _bed(_flat)
	var verts: PackedVector3Array = bed["verts"]
	assert_gt(verts.size(), 0)
	assert_eq(verts.size() % 6, 0, "six vertices per station")
	var top := RADIUS + 100.0 + RoadTerrain.SURFACE_THICKNESS_M
	var bottom := RADIUS + 100.0 - GradeSettings.SKIRT_BURY_M
	for k in verts.size() / 6:
		assert_almost_eq(_r(verts[k * 6]), top, 0.01, "top left")
		assert_almost_eq(_r(verts[k * 6 + 1]), top, 0.01, "top right")
		assert_almost_eq(_r(verts[k * 6 + 3]), bottom, 0.01, "skirt bottom left")
		assert_almost_eq(_r(verts[k * 6 + 5]), bottom, 0.01, "skirt bottom right")
		# Bed width = 2 × 3.44 m for two tracks.
		assert_almost_eq(verts[k * 6].distance_to(verts[k * 6 + 1]), 6.88, 0.02)


func test_skirts_follow_the_ground_down_into_a_dip() -> void:
	var bed := _bed(_dip)
	var verts: PackedVector3Array = bed["verts"]
	var found := false
	for k in verts.size() / 6:
		var top_r := _r(verts[k * 6]) - RADIUS
		var bot_r := _r(verts[k * 6 + 3]) - RADIUS
		assert_almost_eq(top_r, 100.0 + RoadTerrain.SURFACE_THICKNESS_M, 0.01, "the top never leaves the profile")
		if absf(bot_r - (98.5 - GradeSettings.SKIRT_BURY_M)) < 0.02:
			found = true
	assert_true(found, "some skirt bottom reached the dip floor")


func test_collision_faces_match_the_visual_quads() -> void:
	var bed := _bed(_flat)
	var faces: PackedVector3Array = bed["faces"]
	var indices: PackedInt32Array = bed["indices"]
	assert_eq(faces.size() % 3, 0)
	assert_eq(faces.size(), indices.size(), "one collision triangle per visual triangle")
	var no_vis := _bed(_flat, false)
	assert_eq((no_vis["verts"] as PackedVector3Array).size(), 0)
	assert_eq((no_vis["faces"] as PackedVector3Array).size(), faces.size())


func test_winding_follows_the_outward_flag() -> void:
	var out_faces: PackedVector3Array = _bed(_flat, false, true)["faces"]
	var in_faces: PackedVector3Array = _bed(_flat, false, false)["faces"]
	var n_out := (out_faces[1] - out_faces[0]).cross(out_faces[2] - out_faces[0])
	var n_in := (in_faces[1] - in_faces[0]).cross(in_faces[2] - in_faces[0])
	var up := (out_faces[0] + _origin).normalized()
	assert_gt(n_out.dot(up), 0.0, "outward: the top's geometric normal points up")
	assert_lt(n_in.dot(up), 0.0, "inward: reversed")


func test_bed_is_deterministic() -> void:
	assert_eq(_bed(_dip)["faces"], _bed(_dip)["faces"])


func test_bed_stops_at_a_viaduct_exclusion() -> void:
	var road := _road(1000.0)
	var prof := GradeProfile.compute(road, _sampler(_flat), false)
	var whole := GradeBed.build_piece(road["centerline"], road["_cum_lengths"], prof, [],
			MPD, RADIUS, _sampler(_flat), 10.0, _origin, false, true)
	var cut := GradeBed.build_piece(road["centerline"], road["_cum_lengths"], prof,
			[Vector2(400.0, 600.0)], MPD, RADIUS, _sampler(_flat), 10.0, _origin,
			false, true)
	assert_lt((cut["faces"] as PackedVector3Array).size(),
			(whole["faces"] as PackedVector3Array).size())
	for v in (cut["faces"] as PackedVector3Array):
		var e := _east_m((v + _origin).normalized())
		assert_false(e > 401.0 and e < 599.0, "no bed inside the deck interval (at %.0f m)" % e)


# ── The cutting rule ─────────────────────────────────────────────────────

func test_cutting_lowers_the_ground_to_floor_then_wall() -> void:
	var road := _road(1000.0)
	var prof := GradeProfile.compute(road, _sampler(_step_up), false)
	var seg := GradeProfile.segment_at(prof, 700.0)
	assert_eq(int(seg["kind"]), Kind.GORGE)
	var hw_floor: float = float(prof["hw_m"]) + GradeSettings.GORGE_FLOOR_MARGIN_M
	assert_almost_eq(GradeBed.carved_height(109.0, prof, 700.0, 0.0), 100.0, 1e-6, "floor")
	assert_almost_eq(GradeBed.carved_height(109.0, prof, 700.0, -hw_floor), 100.0, 1e-6)
	assert_almost_eq(GradeBed.carved_height(109.0, prof, 700.0, hw_floor + 3.0), 103.0, 1e-6, "wall at 45°")
	assert_almost_eq(GradeBed.carved_height(109.0, prof, 700.0, hw_floor + 12.0), 109.0, 1e-6, "wall meets the ground")
	assert_almost_eq(GradeBed.carved_height(109.0, prof, 700.0, 60.0), 109.0, 1e-6, "outside the band")
	assert_almost_eq(GradeBed.carved_height(99.0, prof, 700.0, 0.0), 99.0, 1e-6, "never raised")
	# A wider margin pushes the wall's foot out by as much, and the margin
	# grows with the refined sub-cell so the triangulated wall never reaches
	# the bed.
	assert_almost_eq(GradeBed.carved_height(109.0, prof, 700.0, hw_floor + 3.0, 6.0), 100.0, 1e-6,
			"still on the floor with a 6 m margin")
	assert_almost_eq(GradeBed.floor_margin_m(16.0), 16.0 / GradeSettings.REFINE_K + 0.3, 1e-9)
	assert_almost_eq(GradeBed.floor_margin_m(4.0), GradeSettings.GORGE_FLOOR_MARGIN_M, 1e-9)
	# On level ground nothing is above the track: unchanged.
	assert_almost_eq(GradeBed.carved_height(100.0, prof, 100.0, 0.0), 100.0, 1e-6)


func test_apply_uses_the_nearest_piece() -> void:
	var road := _road(1000.0)
	var prof := GradeProfile.compute(road, _sampler(_step_up), false)
	var ctx := {"pieces": [road], "profiles": {3: prof}, "m_per_deg": MPD}
	var clat := cos(deg_to_rad(LAT))
	var on_track := Vector2(LON0 + 700.0 / (MPD * clat), LAT)
	assert_almost_eq(GradeBed.apply(109.0, on_track, ctx), 100.0, 1e-3)
	var far := Vector2(LON0 + 700.0 / (MPD * clat), LAT + 500.0 / MPD)
	assert_almost_eq(GradeBed.apply(109.0, far, ctx), 109.0, 1e-9)
	assert_almost_eq(GradeBed.apply(109.0, on_track, {}), 109.0, 1e-9, "empty ctx is a no-op")
