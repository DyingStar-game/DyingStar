extends GutTest

## The town hall's market board: the simulator's market as rows (the resource's name in the player's language,
## price, how it moved over the day, its curve), and the curve as a line.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_market_board.gd

const MARKET := {"currency": "credits", "items": [
	{"code": "ore.gold", "name": "Crushed gold ore", "nameFr": "Minerai d'or concassé", "unit": "kg",
		"unitPrice": 11.0, "previousPrice": 10.0, "points": [10.0, 10.5, 11.0], "supply": 4200, "demand": 900},
	{"code": "ingot.gold", "name": "Gold ingots", "nameFr": null, "unit": "kg",
		"unitPrice": 45.0, "previousPrice": 50.0, "points": [], "supply": 0, "demand": 3000},
]}


func test_the_market_reads_as_rows_by_name_in_the_players_language() -> void:
	var rows := MarketBoard.rows_of(MARKET, "fr_FR")
	assert_eq(rows.size(), 2)
	assert_false(rows[0].has("ticker"), "a resource reads by its name, never its code")
	assert_eq(str(rows[0]["name"]), "Gold ingots", "no French name: the name")
	assert_eq(str(rows[1]["name"]), "Minerai d'or concassé")
	assert_eq(str(MarketBoard.rows_of(MARKET, "en")[0]["name"]), "Crushed gold ore", "by name, in English")
	assert_almost_eq(float(rows[1]["change_pct"]), 10.0, 0.001, "10 -> 11")
	assert_almost_eq(float(rows[0]["change_pct"]), -10.0, 0.001, "50 -> 45")
	assert_eq(MarketBoard.rows_of({}, "en"), [], "no market: no row")


func test_a_price_reads_up_down_or_flat() -> void:
	assert_string_contains(MarketBoard.change_text(2.44), "+2.4")
	assert_true(MarketBoard.change_text(2.44).begins_with("▲"))
	assert_true(MarketBoard.change_text(-1.2).begins_with("▼"))
	assert_true(MarketBoard.change_text(0.01).begins_with("="), "under the threshold: flat")
	assert_eq(MarketBoard.trend_colour(3.0), MarketBoard.UP)
	assert_eq(MarketBoard.trend_colour(-3.0), MarketBoard.DOWN)
	assert_eq(MarketBoard.change_pct(0.0, 5.0), 0.0, "from nothing: no change to tell")


func test_the_curve_spans_the_control_lowest_at_the_bottom() -> void:
	var line := MarketBoard.PriceCurve.polyline(PackedFloat32Array([10.0, 12.0, 11.0]), Vector2(200, 100))
	assert_eq(line.size(), 3)
	assert_eq(line[0].x, 0.0)
	assert_eq(line[2].x, 200.0)
	assert_gt(line[0].y, line[1].y, "the lowest price is the lowest point (y grows down)")
	assert_eq(MarketBoard.PriceCurve.polyline(PackedFloat32Array([10.0]), Vector2(200, 100)).size(), 0)
	var flat := MarketBoard.PriceCurve.polyline(PackedFloat32Array([5.0, 5.0]), Vector2(200, 100))
	assert_eq(flat[0].y, 50.0, "a price that does not move: a line through the middle")


func test_the_board_builds_and_shows_its_rows() -> void:
	var board: MarketBoard = MarketBoard.new()
	add_child_autofree(board)
	board.show_rows(MarketBoard.rows_of(MARKET, "en"), "credits")
	assert_eq(board._list.get_child_count(), 2)
	assert_eq(board._viewport.render_target_update_mode, SubViewport.UPDATE_DISABLED, "drawn only when seen")


func test_the_market_state_is_told_apart_from_the_trend() -> void:
	# The preprod board of 2026-11-11: a flooded ore, rising since the day before, read all green.
	assert_eq(MarketBoard.state_of(5_500, 4_000), MarketBoard.State.SATURATED, "more ore than asked for")
	assert_eq(MarketBoard.state_of(270, 1_100), MarketBoard.State.SHORTAGE, "ingots are missing")
	assert_eq(MarketBoard.state_of(1_000, 1_050), MarketBoard.State.BALANCED, "within the band")
	assert_eq(MarketBoard.state_of(1_000, 960), MarketBoard.State.BALANCED)
	assert_eq(MarketBoard.state_of(0, 0), MarketBoard.State.SATURATED, "nothing asked for")
	assert_eq(MarketBoard.state_of(0, 50), MarketBoard.State.SHORTAGE, "nothing in stock")
	assert_eq(MarketBoard.state_colour(MarketBoard.State.SATURATED), MarketBoard.DOWN, "no bargain to sell into")
	assert_eq(MarketBoard.state_colour(MarketBoard.State.SHORTAGE), MarketBoard.UP)
	assert_eq(MarketBoard.trend_colour(208.0), MarketBoard.UP, "the trend keeps its own colour")
	var keys: Array = []
	for state: MarketBoard.State in [MarketBoard.State.SHORTAGE, MarketBoard.State.BALANCED, MarketBoard.State.SATURATED]:
		keys.append(MarketBoard.state_key(state))
		assert_ne(TranslationServer.translate(MarketBoard.state_key(state)), MarketBoard.state_key(state), "translated")
	assert_eq(keys.size(), 3)
