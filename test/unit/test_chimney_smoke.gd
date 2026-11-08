extends GutTest

## ChimneySmoke: the puffs rise, swell, follow the wind and fade, all from the clock; the smoke is drawn
## only when seen, near, and among the MAX_DRAWN nearest chimneys (ADR 0027).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_chimney_smoke.gd


func test_a_puff_rises_swells_and_fades() -> void:
	var m := ChimneySmokeModel.new()
	var young: Dictionary = m.puff_at(1.0, 5)
	var old: Dictionary = m.puff_at(9.0, 5)
	assert_gt((old["a"] as Vector4).y, (young["a"] as Vector4).y, "it rises")
	assert_gt((old["a"] as Vector4).w, (young["a"] as Vector4).w, "it swells")
	assert_lt((old["b"] as Vector4).x, (young["b"] as Vector4).x, "it fades")


func test_a_dead_or_unborn_puff_is_nothing() -> void:
	var m := ChimneySmokeModel.new()
	assert_eq(m.puff_at(-0.1, 1), {})
	assert_eq(m.puff_at(m.life_s, 1), {})


func test_the_wind_carries_the_smoke() -> void:
	var m := ChimneySmokeModel.new()
	m.wind = Vector2(4.0, 0.0)
	var calm := ChimneySmokeModel.new()
	assert_gt((m.puff_at(6.0, 3)["a"] as Vector4).x, (calm.puff_at(6.0, 3)["a"] as Vector4).x + 15.0)


func test_the_rise_slows_down() -> void:
	var m := ChimneySmokeModel.new()
	var y1: float = (m.puff_at(1.0, 2)["a"] as Vector4).y
	var y2: float = (m.puff_at(2.0, 2)["a"] as Vector4).y
	var y11: float = (m.puff_at(11.0, 2)["a"] as Vector4).y
	assert_gt(y1, (y11 - (m.puff_at(10.0, 2)["a"] as Vector4).y), "the first second climbs more than a late one")
	assert_lt(y2, m.rise_speed * m.rise_slow_s, "never above its ceiling")


func test_the_pool_is_full_and_bounded() -> void:
	var m := ChimneySmokeModel.new(VolcanoPlumeModel.COUNT)
	m.update(100.0)
	assert_between(m.count, ChimneySmokeModel.COUNT - 3, ChimneySmokeModel.COUNT, "almost every puff alive")
	for i: int in range(m.count):
		var s: Vector4 = m.a[i]
		assert_true(s.y + s.w <= m.high.y + 0.001 and s.y - s.w >= m.low.y - 0.001, "inside the box")


func test_the_same_clock_lays_out_the_same_smoke() -> void:
	var m1 := ChimneySmokeModel.new()
	var m2 := ChimneySmokeModel.new()
	m1.update(42.0)
	m2.update(42.0)
	assert_eq(m1.a, m2.a)


func test_drawn_only_when_seen_near_and_among_the_nearest() -> void:
	assert_true(ChimneySmoke.drawn(100.0, 0, true, 400.0))
	assert_false(ChimneySmoke.drawn(100.0, 0, false, 400.0), "out of view")
	assert_false(ChimneySmoke.drawn(450.0, 0, true, 400.0), "too far")
	assert_false(ChimneySmoke.drawn(100.0, ChimneySmoke.MAX_DRAWN, true, 400.0), "others nearer")


func test_nothing_on_the_dedicated_server() -> void:
	var smoke := ChimneySmoke.new()
	add_child_autofree(smoke)
	assert_false(smoke.is_processing(), "headless: no smoke")
	assert_eq(smoke.get_child_count(), 0, "no mesh made")
