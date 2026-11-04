extends GutTest
## On a village's common ground (VillageBed) a pad keeps its own level: the plane under it already
## follows the relief, and a level borrowed from neighbour to neighbour across a sloping village put
## walls 21 m under that plane and bollards 15 m above it (M0002, 2026-11-03). Off a village, a pad
## still stands at the level of the larger pad its apron touches.

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0
const FINEST := 8192
const LON := 10.0
const LAT := 45.0


## A pad [param hx] x [param hy] m at [param east_m] metres east of the test point, measured at [param z].
func _pad(uuid: String, east_m: float, hx: float, hy: float, z: float) -> Dictionary:
	var ls := cos(deg_to_rad(LAT))
	return {"uuid": uuid, "lon": LON + east_m / (MPD * ls), "lat": LAT, "yaw": 0.0, "hx": hx, "hy": hy,
		"apron_m": 2.0, "z_off": 0.0, "z": z, "talus_m": 5.0}


## A big pad and a small one whose aprons touch, measured 6 m apart, in a fresh index.
func _pair() -> Array:
	var idx := PadIndex.new(FINEST)
	idx.set_radius(RADIUS)
	var big := _pad("big", 0.0, 20.0, 20.0, 100.0)
	var small := _pad("small", 24.0, 2.0, 2.0, 106.0)
	idx.register(big)
	idx.register(small)
	var own := {"big": {"z": 100.0, "talus_m": 5.0}, "small": {"z": 106.0, "talus_m": 5.0}}
	return [idx, own]


func test_off_a_village_the_small_pad_takes_the_big_one_s_level() -> void:
	var p := _pair()
	var lvl := PadLevels.level(p[0], "small", p[1], {}, FINEST, MPD)
	assert_eq(float(lvl[0]), 100.0, "shared level, as before")


func test_on_a_village_bed_each_pad_keeps_its_own_level() -> void:
	var p := _pair()
	var bed := VillageBed.record("village:v", LON, LAT, 0.0, 200.0, 200.0)
	var lvl := PadLevels.level(p[0], "small", p[1], {}, FINEST, MPD, {}, [bed])
	assert_eq(float(lvl[0]), 106.0, "its own level, measured on the plane")
	assert_eq(float(lvl[1]), 5.0, "and its own talus")


func test_a_bed_elsewhere_changes_nothing() -> void:
	var p := _pair()
	var far := VillageBed.record("village:far", LON + 1.0, LAT, 0.0, 200.0, 200.0)
	var lvl := PadLevels.level(p[0], "small", p[1], {}, FINEST, MPD, {}, [far])
	assert_eq(float(lvl[0]), 100.0, "a pad off every bed still shares its neighbour's level")


func test_on_a_village_bed_a_pad_takes_the_level_of_its_layout_area() -> void:
	var p := _pair()
	var idx: PadIndex = p[0]
	var own: Dictionary = p[1]
	# The big pad is now a layout area (LayoutPads: its uuid carries the tag).
	var yard := _pad("village:v%syard" % LayoutPads.UUID_TAG, 0.0, 20.0, 20.0, 100.0)
	idx.unregister("big")
	idx.register(yard)
	own[yard["uuid"]] = {"z": 100.0, "talus_m": 5.0}
	var bed := VillageBed.record("village:v", LON, LAT, 0.0, 200.0, 200.0)
	var lvl := PadLevels.level(idx, "small", own, {}, FINEST, MPD, {}, [bed])
	assert_eq(float(lvl[0]), 100.0, "the building stands on the yard, not under it")
