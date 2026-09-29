extends GutTest
## TileServiceProbe: the menu stage builds its 3D scene only when the terrain tile service answers.
## The HTTP layer is replaced by a fetcher; each test uses its own base URL (the channel resolution
## is cached per URL).

const LATEST : String = '{"data_version": "abc", "tile_res": 64, "nside_min": 1, "nside_max": 512}'


func _answer(latest_code: int) -> Callable:
	return func(url: String) -> Array:
		if url.ends_with("latest.json"):
			return [latest_code, LATEST.to_utf8_buffer() if latest_code == 200 else PackedByteArray()]
		return [404, PackedByteArray()]  # no channel manifest: the per-body pointer is asked


func test_a_service_that_answers_is_reachable() -> void:
	assert_true(TileServiceProbe.check_now("tarsis_3", "https://probe-ok.test", _answer(200)))


func test_a_missing_body_or_a_dead_service_is_not() -> void:
	assert_false(TileServiceProbe.check_now("tarsis_3", "https://probe-404.test", _answer(404)), "404")
	assert_false(TileServiceProbe.check_now("tarsis_3", "https://probe-down.test", _answer(0)), "unreachable")


func test_no_configured_service_is_not_reachable() -> void:
	assert_false(TileServiceProbe.check_now("tarsis_3", ""), "no URL, no terrain")
	assert_false(TileServiceProbe.check_now("", "https://probe-noname.test", _answer(200)), "no planet")
