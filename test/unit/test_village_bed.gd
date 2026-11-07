extends GutTest
## The village's common ground (VillageBed): one gently tilted plane over a village's footprint, so its
## buildings level their pads on common ground instead of each on the raw relief under it — on a bumpy
## hillside the neighbours sat metres apart and the talus between them was a cliff (2026-11-02).
## The plane must fit the relief, stay drivable, meet the relief again without a step or a crease, and
## be the ground the pads of the village measure their altitude on, whichever registers first.

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0
const LAYOUT := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"

var _bed: Dictionary


func before_each() -> void:
	# 200 × 120 m, on the equator at lon 0, rising 0.05 m per metre east.
	_bed = VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0)
	_bed["z0"] = 100.0
	_bed["gx"] = 0.05
	_bed["gy"] = 0.0


## A point [param east_m] east and [param north_m] north of the bed's centre.
func _at(east_m: float, north_m: float = 0.0) -> Vector2:
	return Vector2(east_m / MPD, north_m / MPD)


# ── The fit ──────────────────────────────────────────────────────────────

func test_the_plane_fits_a_planar_relief() -> void:
	var relief := func(dir: Vector3) -> float:
		var p := PadBed.local_m(_bed, HEALPix.vec2lonlat(dir), MPD)
		return 80.0 + 0.03 * p.x - 0.02 * p.y
	var fitted := VillageBed.fit(_bed, relief, MPD)
	assert_almost_eq(float(fitted["z0"]), 80.0, 0.01)
	assert_almost_eq(float(fitted["gx"]), 0.03, 1e-4)
	assert_almost_eq(float(fitted["gy"]), -0.02, 1e-4)


func test_the_plane_stays_drivable_on_a_steep_slope() -> void:
	var cliff := func(dir: Vector3) -> float:
		return 0.6 * PadBed.local_m(_bed, HEALPix.vec2lonlat(dir), MPD).x  # 31°
	var fitted := VillageBed.fit(_bed, cliff, MPD)
	var slope := Vector2(float(fitted["gx"]), float(fitted["gy"])).length()
	assert_almost_eq(slope, tan(deg_to_rad(VillageBed.MAX_SLOPE_DEG)), 1e-5, "capped, a truck still drives up")


func test_a_bump_does_not_tilt_the_plane() -> void:
	var bumpy := func(dir: Vector3) -> float:
		var p := PadBed.local_m(_bed, HEALPix.vec2lonlat(dir), MPD)
		return 50.0 + 6.0 * sin(p.x * 0.3) * cos(p.y * 0.3)
	var fitted := VillageBed.fit(_bed, bumpy, MPD)
	assert_lt(absf(float(fitted["gx"])), 0.02)
	assert_lt(absf(float(fitted["gy"])), 0.02)


# ── The ground ───────────────────────────────────────────────────────────

func test_inside_the_footprint_the_ground_is_the_plane() -> void:
	for e: float in [-99.0, -40.0, 0.0, 40.0, 99.0]:
		assert_almost_eq(VillageBed.apply(300.0, _at(e, 20.0), [_bed], MPD), 100.0 + 0.05 * e, 1e-6,
				"%.0f m east" % e)


func test_the_band_meets_the_relief_without_a_step_or_a_crease() -> void:
	var h := 70.0                          # the relief, 35 m under the plane's east edge
	var edge := 100.0
	var band := clampf(PadBed.talus_width(105.0 - h), VillageBed.BAND_M, PadSettings.TALUS_MAX_M)
	assert_almost_eq(VillageBed.apply(h, _at(edge), [_bed], MPD), 105.0, 1e-6, "the plane at the edge")
	assert_almost_eq(VillageBed.apply(h, _at(edge + band), [_bed], MPD), h, 1e-6, "the relief at the band's end")
	var prev := 105.0
	var step := 0.25
	var e := edge
	while e < edge + band + 10.0:
		e += step
		var y := VillageBed.apply(h, _at(e), [_bed], MPD)
		assert_lte(absf(y - prev) / step, PadSettings.TALUS_SLOPE + 1e-6, "walkable at %.2f m" % e)
		prev = y


func test_past_the_band_the_relief_is_untouched() -> void:
	assert_eq(VillageBed.apply(123.0, _at(100.0 + PadSettings.TALUS_MAX_M + 1.0), [_bed], MPD), 123.0)
	assert_true(is_nan(VillageBed.floor_at(_at(101.0), [_bed], MPD)), "no floor outside the footprint")


func test_two_beds_do_not_depend_on_the_order() -> void:
	var other := VillageBed.record("village:b", 0.0, 0.0, 0.0, 40.0, 40.0)
	other["z0"] = 90.0
	other["gx"] = 0.0
	other["gy"] = 0.0
	other = PadBed.quantise(other)
	for e: float in [-30.0, 0.0, 30.0, 120.0]:
		assert_eq(VillageBed.apply(80.0, _at(e), [_bed, other], MPD),
				VillageBed.apply(80.0, _at(e), [other, _bed], MPD), "%.0f m east" % e)


# ── The village's pads stand on it ───────────────────────────────────────

func _data() -> PlanetData:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	data.relief_signature = "relief-test"
	return data


## A 10 × 10 m pad [param east_m] east of the village centre.
func _pad(uuid: String, east_m: float) -> Dictionary:
	return PadBed.record(uuid, east_m / MPD, 0.0, 0.0, 5.0, 5.0, 4.0, 0.0)


func test_a_pad_of_the_village_is_measured_on_its_ground() -> void:
	var data := _data()
	data.register_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	assert_true(data.has_village_beds())
	var bed: Dictionary = data.village_beds_for_chunk(1 << 14, HEALPix.vec2pix_nest(1 << 14,
			HEALPix.lonlat2vec(0.0, 0.0)))[0]
	data.register_pad(_pad("prop:house", 40.0))
	var want := VillageBed.plane_at(bed, Vector2(40.0, 0.0))
	assert_almost_eq(data.pad_altitude(PadBed.quantise(_pad("prop:house", 40.0))), want, 0.002)


func test_a_pad_registered_before_the_village_comes_down_onto_it() -> void:
	var data := _data()
	var early := _pad("prop:house", 40.0)
	early["settled"] = {"z": 250.0, "span": 0.0, "talus_m": 6.0}  # measured on another ground
	data.register_pad(early)
	data.register_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	var bed: Dictionary = data.village_beds_for_chunk(1 << 14, HEALPix.vec2pix_nest(1 << 14,
			HEALPix.lonlat2vec(0.0, 0.0)))[0]
	assert_almost_eq(data.pad_altitude(PadBed.quantise(_pad("prop:house", 40.0))),
			VillageBed.plane_at(bed, Vector2(40.0, 0.0)), 0.002, "measured again on the village's ground")
	assert_true(data.take_caught_up_pads().has("prop:house"), "its building is re-seated")


## uuid -> [the level its ground is drawn at, its talus].
func _levels(data: PlanetData) -> Dictionary:
	var out := {}
	for rec: Dictionary in data._pads.all():
		out[rec["uuid"]] = [rec["z"], rec["talus_m"]]
	return out


func test_a_street_registered_before_its_village_ends_where_it_does_after() -> void:
	# The pads already standing are measured again in one pass when the village comes (touching aprons
	# share a level, PadLevels): the same ground as pads registered on the village one at a time.
	var street: Array = []
	for i in 8:
		street.append(_pad("prop:%d" % i, -70.0 + 18.0 * float(i)))
	var before := _data()
	for rec: Dictionary in street:
		var early: Dictionary = rec.duplicate()
		early["settled"] = {"z": 250.0 + float(_index_of(rec)), "span": 0.0, "talus_m": 6.0}
		before.register_pad(early)
	before.register_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	var after := _data()
	after.register_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	for rec: Dictionary in street:
		after.register_pad(rec)
	assert_eq(_levels(before).size(), 8)
	assert_eq(_levels(before), _levels(after))
	var caught := before.take_caught_up_pads()
	for rec: Dictionary in street:
		assert_true(caught.has(str(rec["uuid"])), "%s re-seated" % rec["uuid"])


func _index_of(rec: Dictionary) -> int:
	return int(str(rec["uuid"]).trim_prefix("prop:"))


# ── The ground prepared on a worker (submit_village_bed) ────────────────

## Publish what the workers prepared, waiting for them (at most 10 s): [[uuid, stale pixels], …].
func _collect(data: PlanetData) -> Array:
	var out: Array = []
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		out.append_array(data.collect_village_beds())
		if data._bed_jobs.is_empty():
			break
		OS.delay_msec(1)
	return out


func _street(data: PlanetData) -> void:
	for i in 8:
		data.register_pad(_pad("prop:%d" % i, -70.0 + 18.0 * float(i)))


func test_a_ground_prepared_on_a_worker_is_the_ground_registered_at_once() -> void:
	var at_once := _data()
	_street(at_once)
	var dirty := at_once.register_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	var worker := _data()
	_street(worker)
	assert_true(worker.submit_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0)))
	var done := _collect(worker)
	assert_eq(done.size(), 1)
	assert_eq_deep(worker._village_beds, at_once._village_beds)
	assert_eq(_levels(worker), _levels(at_once))
	assert_eq_deep(done[0][1], dirty)


func test_a_chunk_under_a_ground_being_prepared_waits_for_it() -> void:
	var data := _data()
	var finest := 1 << 14
	var under := HEALPix.vec2pix_nest(finest, HEALPix.lonlat2vec(0.0, 0.0))
	var far := HEALPix.vec2pix_nest(finest, HEALPix.lonlat2vec(10.0, 10.0))
	data.submit_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	assert_true(data.village_bed_pending_for_chunk(finest, under))
	assert_true(data.village_bed_pending_for_chunk(finest >> 2, under >> 4), "and its coarser parent")
	assert_false(data.village_bed_pending_for_chunk(finest, far))
	_collect(data)
	assert_false(data.village_bed_pending_for_chunk(finest, under), "no longer once it is published")


func test_a_pad_registered_while_its_ground_is_prepared_stands_on_it() -> void:
	var data := _data()
	data.submit_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	data.register_pad(_pad("prop:house", 40.0))  # measured on the relief: the village is not there yet
	_collect(data)
	var bed: Dictionary = data._village_beds[0]
	assert_almost_eq(data.pad_altitude(PadBed.quantise(_pad("prop:house", 40.0))),
			VillageBed.plane_at(bed, Vector2(40.0, 0.0)), 0.002, "measured again on the village's ground")


func test_a_ground_published_meanwhile_is_not_lost() -> void:
	var data := _data()
	_street(data)
	data.submit_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	data.register_village_bed(VillageBed.record("village:b", 0.0, 0.01, 0.0, 40.0, 40.0))
	_collect(data)
	var both := _data()
	_street(both)
	both.register_village_bed(VillageBed.record("village:b", 0.0, 0.01, 0.0, 40.0, 40.0))
	both.register_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	assert_eq(data._village_beds.size(), 2)
	assert_eq_deep(data._village_beds, both._village_beds)
	assert_eq(_levels(data), _levels(both))


func test_a_village_moved_while_prepared_ends_where_it_was_moved() -> void:
	var data := _data()
	data.submit_village_bed(VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0))
	assert_true(data.submit_village_bed(VillageBed.record("village:a", 0.0, 0.02, 0.0, 100.0, 60.0)))
	_collect(data)
	assert_eq(data._village_beds.size(), 1)
	assert_almost_eq(float(data._village_beds[0]["lat"]), 0.02, 1e-6)


func test_the_same_village_again_changes_nothing() -> void:
	var data := _data()
	var rec := VillageBed.record("village:a", 0.0, 0.0, 0.0, 100.0, 60.0)
	assert_false(data.register_village_bed(rec).is_empty(), "the first time, its chunks are rebuilt")
	assert_true(data.register_village_bed(rec).is_empty(), "the second time, nothing to do")


# ── The footprint of a layout ────────────────────────────────────────────

func test_the_mining_village_footprint_covers_its_buildings() -> void:
	var fp := LayoutFootprint.of(LAYOUT)
	assert_false(fp.is_empty())
	var centre: Vector2 = fp["centre"]
	var half: Vector2 = fp["half"]
	var layout: Node = (load(LAYOUT) as PackedScene).instantiate()
	for item in layout.get_children():
		if item is Node3D and PropSync.of(item) != null:
			var o := (item as Node3D).position
			assert_lte(absf(o.x - centre.x), half.x, "%s inside, along x" % item.name)
			assert_lte(absf(o.z - centre.y), half.y, "%s inside, along z" % item.name)
	layout.free()
	KnownEngineErrors.forgive_floor_material(self)
