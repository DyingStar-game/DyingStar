extends GutTest
## A rock piece one can carry wears no fault line: RockMining drops its planes not cut yet (the line the shader draws)
## and keeps its cut history (playtest 2026-11-11: blocks fallen from a mine face showed both the carry prompt and a
## crack line).


func _rock(fractures: Array) -> RockMining:
	var rock := RockMining.new()
	autofree(rock)
	rock.fractures = fractures
	return rock


func test_uncut_planes_go_cut_ones_stay() -> void:
	var rock := _rock([{"seq": 0, "fractured": true, "keep_side": 1}, {"seq": 1, "fractured": false}])
	rock._drop_uncut_planes()
	assert_eq(rock.fractures.size(), 1)
	assert_true(bool(rock.fractures[0].get("fractured", false)), "the cut stays: the geometry replays it")


func test_nothing_to_drop_leaves_the_list_as_is() -> void:
	var cuts := [{"seq": 0, "fractured": true}]
	var rock := _rock(cuts)
	rock._drop_uncut_planes()
	assert_same(rock.fractures, cuts, "untouched, not replicated again")


func test_a_rock_with_no_history_has_none_to_drop() -> void:
	var rock := _rock([{"seq": 0, "fractured": false}])
	rock._drop_uncut_planes()
	assert_eq(rock.fractures.size(), 0)
