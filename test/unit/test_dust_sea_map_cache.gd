extends GutTest
## DustSeaMap's disk cache: a map built once for a planet's look is read back the next time, bit for bit,
## without building it again; another look builds again and drops the old file; a planet's file never
## takes another planet's along (tarsis_3 / tarsis_30).

const KEY := "gut_planet_3_0123456789abcdef"
const OTHER_PLANET := "gut_planet_30_0123456789abcdef"


func before_each() -> void:
	_clean()


func after_each() -> void:
	_clean()


func _clean() -> void:
	for f: String in DirAccess.get_files_at(DustSeaMap.CACHE_DIR):
		if f.begins_with("gut_planet_"):
			DirAccess.remove_absolute(DustSeaMap.CACHE_DIR + f)


## Builds a map with [param key] to the end, [param calls] counting the ground colours asked.
func _build(key: String, calls: Array) -> DustSeaMap:
	var map := DustSeaMap.new()
	var colour := func(d: Vector3) -> Color:
		calls[0] += 1
		return Color(absf(d.x), absf(d.y), absf(d.z))
	var deadline := Time.get_ticks_msec() + 60000
	while not map.update(colour, key) and Time.get_ticks_msec() < deadline:
		OS.delay_msec(5)
	return map


func test_a_built_map_is_read_back_without_building() -> void:
	var calls := [0]
	var first := _build(KEY, calls)
	assert_true(first.ready)
	assert_gt(calls[0], DustSeaMap.WIDTH * DustSeaMap.HEIGHT - 1, "the first map asks every texel's colour")
	assert_true(FileAccess.file_exists(DustSeaMap.cache_path(KEY)), "and is kept")
	calls[0] = 0
	var again := _build(KEY, calls)
	assert_true(again.ready)
	assert_eq(calls[0], 0, "the second one asks no colour at all")
	assert_eq(again.texture.get_image().get_data(), first.texture.get_image().get_data(), "the same texels")


func test_another_look_builds_again_and_drops_the_old_map() -> void:
	var calls := [0]
	_build(KEY, calls)
	_build(OTHER_PLANET, calls)
	var newer := "gut_planet_3_fedcba9876543210"
	calls[0] = 0
	_build(newer, calls)
	assert_gt(calls[0], 0, "a new look is built")
	assert_false(FileAccess.file_exists(DustSeaMap.cache_path(KEY)), "the planet's older map is gone")
	assert_true(FileAccess.file_exists(DustSeaMap.cache_path(OTHER_PLANET)), "another planet's map is not")


func test_no_key_no_file() -> void:
	var calls := [0]
	_build("", calls)
	assert_eq(DustSeaMap.cache_key(null), "")
	assert_false(DirAccess.get_files_at(DustSeaMap.CACHE_DIR).has(DustSeaMap.cache_path("").get_file()))
