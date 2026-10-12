extends GutTest
## Buildings whose aprons touch share one level: the smaller pad stands at the level of the larger one
## (PlanetData._settle_pad_levels). A mining depot measured on its own sat metres off the cargo depot
## next to it, and the two aprons ramped into each other — neither was flat.

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0


func _data() -> PlanetData:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	data.relief_signature = "relief-test"
	return data


## A pad [param north_m] north of the cargo depot, measured at [param z].
func _pad(uuid: String, north_m: float, hx: float, hy: float, z: float) -> Dictionary:
	var rec := PadBed.record(uuid, 0.0, north_m / MPD, 0.0, hx, hy, 8.0, 0.0)
	rec["settled"] = {"z": z, "span": 0.0, "talus_m": 6.0}
	return rec


func _depot() -> Dictionary:
	return _pad("prop:depot", 0.0, 10.4, 48.5, 100.0)


## 16 × 16 m, its footprint 6 m past the depot's end: the aprons overlap.
func _mining(z: float = 90.6) -> Dictionary:
	return _pad("prop:mining", 62.5, 8.0, 8.0, z)


func test_aprons_touch_is_symmetric_and_bounded() -> void:
	var a := PadBed.quantise(_depot())
	var b := PadBed.quantise(_mining())
	assert_true(PadBed.aprons_touch(a, b, MPD))
	assert_true(PadBed.aprons_touch(b, a, MPD))
	var far := PadBed.quantise(_pad("prop:far", 82.0, 8.0, 8.0, 0.0))  # 17.5 m between the aprons
	assert_false(PadBed.aprons_touch(a, far, MPD))


func test_the_smaller_pad_takes_the_larger_one_s_level() -> void:
	for order: Array in [[_depot(), _mining()], [_mining(), _depot()]]:
		var data := _data()
		for r: Dictionary in order:
			data.register_pad(r)
		assert_eq(data.pad_altitude(PadBed.quantise(_mining())), 100.0, "whatever the order")
		assert_eq(data.pad_altitude(PadBed.quantise(_depot())), 100.0, "the larger one keeps its own")


func test_the_shared_apron_is_flat() -> void:
	var data := _data()
	data.register_pad(_depot())
	data.register_pad(_mining())
	var pads := data.pads_for_chunk(1 << 14, HEALPix.vec2pix_nest(1 << 14, HEALPix.lonlat2vec(0.0, 0.0)))
	for n: float in [48.6, 51.0, 53.0, 54.4, 56.0]:
		assert_almost_eq(PadBed.apply(130.0, Vector2(0.0, n / MPD), pads, MPD), 100.0, 1e-6, "%.1f m north" % n)


func test_the_measure_stays_the_pad_s_own() -> void:
	var data := _data()
	data.register_pad(_depot())
	data.register_pad(_mining())
	assert_almost_eq(float(data.pad_settled_entry("prop:mining")["z"]), 90.6, 1e-6,
			"what is persisted is what was measured, not the borrowed level")


func test_removing_the_larger_pad_gives_the_level_back() -> void:
	var data := _data()
	data.register_pad(_depot())
	data.register_pad(_mining())
	data.take_caught_up_pads()
	data.unregister_pad("prop:depot")
	assert_eq(data.pad_altitude(PadBed.quantise(_mining())), 90.6)
	assert_has(data.take_caught_up_pads(), "prop:mining", "its building is told to sit back down")


func test_a_late_larger_pad_re_seats_the_smaller_building() -> void:
	var data := _data()
	data.register_pad(_mining())
	data.take_caught_up_pads()
	var dirty := data.register_pad(_depot())
	assert_has(data.take_caught_up_pads(), "prop:mining")
	var mining_pix := data.pad_pixels(data._pads.get_rec("prop:mining"))
	for ip: int in mining_pix:
		assert_true(dirty.has(ip), "the smaller pad's ground is rebuilt too")


func test_equal_footprints_keep_their_own_levels() -> void:
	var data := _data()
	data.register_pad(_pad("prop:hab1", 0.0, 8.0, 8.0, 100.0))
	data.register_pad(_pad("prop:hab2", 20.0, 8.0, 8.0, 93.0))
	assert_eq(data.pad_altitude(PadBed.quantise(_pad("prop:hab1", 0.0, 8.0, 8.0, 0.0))), 100.0)
	assert_eq(data.pad_altitude(PadBed.quantise(_pad("prop:hab2", 20.0, 8.0, 8.0, 0.0))), 93.0,
			"a row of identical buildings down a slope keeps its terraces")


func test_the_level_follows_a_chain_of_sizes() -> void:
	var data := _data()
	data.register_pad(_pad("prop:small", 75.0, 4.0, 4.0, 80.0))  # touches only the mining depot
	data.register_pad(_mining())
	data.register_pad(_depot())
	assert_eq(data.pad_altitude(PadBed.quantise(_pad("prop:small", 75.0, 4.0, 4.0, 0.0))), 100.0)
