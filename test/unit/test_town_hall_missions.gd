extends GutTest
## The town hall's missions: a giant board at the back and four kiosks by the entrance, sharing one
## feed; a mission as a tile in its giver's colours; a kiosk's filters and its sheet; and the DataPad
## opening on a mission just taken.

const TOWN_HALL := "res://scenes/_universe/structures/buildings/civic/town_hall.tscn"
const KIOSK := "res://scenes/_universe/structures/missions/mission_kiosk.tscn"
const ORE := {"id": "a", "title": "Ore run", "category": "mining", "giverFaction": "ares",
		"giverDivision": "mining", "rewards": [{"type": "credits", "currency": "credits", "amount": 500}],
		"expiresAt": null, "createdAt": "2026-11-01T10:00:00.000Z"}
const CRATE := {"id": "b", "title": "Crate", "category": "delivery", "giverFaction": "ares",
		"giverDivision": "hauling", "rewards": [], "expiresAt": "2026-11-04T23:00:00.000Z",
		"createdAt": "2026-11-03T10:00:00.000Z"}


func test_the_town_hall_has_a_board_and_four_kiosks_on_one_feed() -> void:
	var hall := (load(TOWN_HALL) as PackedScene).instantiate() as Node3D
	add_child_autofree(hall)
	var feeds := hall.find_children("*", "MissionFeed", false, false)
	assert_eq(feeds.size(), 1, "one request for the whole building")
	var board := hall.get_node_or_null("MissionBoard") as MissionBoard
	assert_not_null(board, "the giant screen")
	var kiosks := hall.find_children("MissionKiosk*", "MissionKiosk", false, false)
	assert_eq(kiosks.size(), 4, "four kiosks")
	for kiosk: Node in kiosks:
		assert_eq(MissionFeed.near(kiosk.get_node("%MissionKioskUI")), feeds[0], "the kiosks share it")
	assert_eq(MissionFeed.near(board), feeds[0], "and the board")
	# The board faces the entrance (the door is at -Z), across the hall; the kiosks stand inside.
	assert_lt(board.global_basis.z.z, -0.9, "the board looks toward the door")
	var screen: Vector2 = ((board.get_node("Screen") as MeshInstance3D).mesh as QuadMesh).size
	assert_gt(screen.y, 6.0, "a wall of ads, nearly floor to ceiling")
	assert_true(board.position.y - screen.y / 2 > 0.5 and board.position.y + screen.y / 2 < 8.6, "within the wall")
	assert_lt(screen.x, 47.0, "and within its width")
	assert_gte(MissionBoard.columns_for(board.get_node("SubViewport").size.x, board.tile_zoom), 7,
			"many ads across")
	for kiosk: Node3D in kiosks:
		assert_true(absf(kiosk.position.z) < 10.7 and absf(kiosk.position.x) < 23.7, "inside the walls")
		# to the right of the board, seen from the hall (facing +Z, the right is -X), facing the hall
		assert_lt(kiosk.position.x, -8.3, "beside the board, not in front of it")
		assert_gt(kiosk.position.z, 8.0, "along the back wall")
		assert_lt(kiosk.global_basis.z.z, -0.9, "its screen turned to the hall")


func _many(count: int) -> Array:
	var out: Array = []
	for i: int in range(count):
		var m: Dictionary = ORE.duplicate()
		m["id"] = "m%02d" % i
		m["createdAt"] = "2026-11-01T%02d:%02d:00.000Z" % [10 + i / 60, i % 60]
		out.append(m)
	return out


func test_the_board_rolls_its_ads_without_end() -> void:
	var hall := (load(TOWN_HALL) as PackedScene).instantiate() as Node3D
	add_child_autofree(hall)
	var board := hall.get_node("MissionBoard") as MissionBoard
	board.show_missions(_many(80))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(board._grid.get_child_count(), 80, "every mission, no pages")
	assert_true(board.rolls(), "eighty do not fit: the board rolls")
	board.set_process(false)  # the test moves the roll itself
	board._offset = 0.0
	var top: Node = board._grid.get_child(0)
	board.advance(board._row_px() * 1.5)
	assert_eq(top.get_index(), board._grid.get_child_count() - board._grid.columns,
			"the row gone out at the top came back at the bottom")
	assert_almost_eq(board._offset, board._row_px() * 0.5, 0.01, "and the roll goes on from there")
	board.set_process(true)
	board.show_missions(_many(3))
	await get_tree().process_frame
	assert_false(board.rolls(), "a few fit: still")


func test_only_a_new_mission_lights_up_and_the_others_stay() -> void:
	var hall := (load(TOWN_HALL) as PackedScene).instantiate() as Node3D
	add_child_autofree(hall)
	var board := hall.get_node("MissionBoard") as MissionBoard
	var first: Array = _many(10)
	board.show_missions(first)
	assert_false((board._grid.get_child(0) as MissionTile).is_highlighted(), "the first reading is not news")
	board._feed._loaded = true
	var kept: Node = board._grid.get_child(3)
	var fresh: Dictionary = ORE.duplicate()
	fresh["id"] = "fresh"
	board.show_missions(first + [fresh])
	assert_true(is_instance_valid(kept) and kept.get_parent() == board._grid, "the others were kept, not rebuilt")
	var lit: Array = board._grid.get_children().filter(func(c: Node) -> bool: return (c as MissionTile).is_highlighted())
	assert_eq(lit.size(), 1, "the new one lights up, alone")
	assert_eq((lit[0] as MissionTile).mission["id"], "fresh")
	var named: Array = first.duplicate(true) + [fresh]
	named[0]["creatorName"] = "Kira"
	var at: int = (board._tiles[MissionBoard.key_of(first[0])] as Node).get_index()
	board.show_missions(named)
	var remade: Node = board._tiles[MissionBoard.key_of(named[0])]
	assert_false((remade as MissionTile).is_highlighted(), "a name arriving is not news")
	assert_eq(remade.get_index(), at, "and the tile keeps its place")
	board.show_missions([])
	assert_true(board._empty.visible, "says when there is nothing")


func test_a_tile_wears_its_giver_and_its_category() -> void:
	var tile := MissionTile.new().setup(ORE, 1.0, 0.0)
	add_child_autofree(tile)
	assert_eq(tile.giver.colour(), AresBrand.colour(AresBrand.Subsidiary.MINING))
	assert_eq((tile.find_child("Title", true, false) as Label).text, "Ore run")
	assert_eq((tile.find_child("Giver", true, false) as Label).text, "ARES MINING")
	assert_eq((tile.find_child("Deadline", true, false) as Label).text, TranslationServer.translate("%%MISSION_NO_DEADLINE"))
	assert_eq((tile.find_child("CategoryIcon", true, false) as TextureRect).texture,
			MissionCategories.icon("mining"), "the category's pictogram (or the fallback)")
	var got: Array = []
	tile.picked.connect(func(m: Dictionary) -> void: got.append(m))
	tile.pressed.emit()
	assert_eq(got, [ORE], "a press picks its mission")


func test_a_kiosk_filters_with_what_is_on_offer() -> void:
	var kiosk := (load(KIOSK) as PackedScene).instantiate() as MissionKiosk
	add_child_autofree(kiosk)
	var ui := kiosk.get_node("%MissionKioskUI") as MissionKioskUI
	assert_eq(ScreenTarget.owner_of(ScreenTarget.gui_of(kiosk)), kiosk, "a screen the crosshair points at")
	ui.show_missions([ORE, CRATE])
	assert_eq(ui._category_chips._options.size(), 2, "mining, delivery: no \"all\" chip")
	assert_eq(ui._giver_chips._options.size(), 2, "ARES MINING, ARES HAULING")
	assert_eq(ui._sort_chips.get_child_count(), MissionQuery.SORT_KEYS.size())
	ui._set_category("delivery")
	assert_eq(ui.shown(), [CRATE])
	ui.show_missions([ORE])
	assert_eq(ui._category, "", "a filter on what is gone falls back to all")
	assert_eq(ui.shown(), [ORE])


func test_pressing_the_chosen_order_again_turns_it_round() -> void:
	var kiosk := (load(KIOSK) as PackedScene).instantiate() as MissionKiosk
	add_child_autofree(kiosk)
	var ui := kiosk.get_node("%MissionKioskUI") as MissionKioskUI
	ui.show_missions([ORE, CRATE])
	assert_eq(ui.shown(), [ORE, CRATE], "best paid first")
	assert_string_contains((ui._sort_chips.get_child(0) as Button).text, "↓")
	ui._set_sort(MissionQuery.Sort.REWARD)
	assert_eq(ui.shown(), [CRATE, ORE], "turned round")
	assert_string_contains((ui._sort_chips.get_child(0) as Button).text, "↑")
	ui._set_sort(MissionQuery.Sort.NEWEST)
	assert_false(ui._reverse, "another order starts its own way round")


func test_the_kiosk_sleeps_until_pressed_and_goes_back_to_its_list() -> void:
	var kiosk := (load(KIOSK) as PackedScene).instantiate() as MissionKiosk
	add_child_autofree(kiosk)
	var ui := kiosk.get_node("%MissionKioskUI") as MissionKioskUI
	assert_true(ui._attract.visible, "asleep at first")
	ui._attract.wake()
	ui.show_missions([ORE])
	ui._open_sheet(ORE)
	assert_true(ui._sheet_view.visible)
	ui._set_category("mining")
	ui._set_sort(MissionQuery.Sort.REWARD)
	ui._attract.sleep()
	assert_false(ui._sheet_view.visible, "asleep again: back to the list for the next one")
	assert_eq(ui._category, "", "no filter left for the next one")
	assert_eq([ui._sort, ui._reverse], [MissionQuery.Sort.REWARD, false], "the default order")


func test_every_dispenser_sleeps_behind_its_brand_and_starts_over() -> void:
	for path: String in ["res://scenes/_universe/structures/dispenser/vehicle_terminal.tscn",
			"res://scenes/_universe/structures/dispenser/food_dispenser.tscn",
			"res://scenes/_universe/structures/dispenser/tool_dispenser.tscn",
			"res://scenes/_universe/structures/dispenser/component_dispenser.tscn"]:
		var machine := (load(path) as PackedScene).instantiate() as ItemDispenser
		add_child_autofree(machine)
		var ui := machine.get_node("%ItemDispenserUI") as ItemDispenserUI
		var attract := ui.find_children("*", "ScreenAttract", false, false)
		assert_eq(attract.size(), 1, "%s has its screen saver" % path.get_file())
		var rows: Array = ui._rows.get_children()
		if rows.size() > 1:
			(rows[1] as Button).button_pressed = true
			(attract[0] as ScreenAttract).sleep()
			assert_eq(ui.chosen(), (rows[0] as Button).get_meta("spec_path"), "back to the first item")


func test_logos_on_the_kiosks_are_not_stretched() -> void:
	for path: String in [KIOSK, "res://scenes/_universe/structures/dispenser/vehicle_terminal.tscn"]:
		var machine := (load(path) as PackedScene).instantiate() as Node3D
		for logo: Node in machine.find_children("*", "Sprite3D", true, false):
			var scale: Vector3 = (logo as Sprite3D).transform.basis.get_scale()
			assert_almost_eq(scale.x, scale.y, 0.001, "%s %s: as wide as high" % [path.get_file(), logo.name])
			assert_almost_eq(scale.y, scale.z, 0.001)
		machine.free()


func test_an_objective_line_counts_and_marks_a_bonus() -> void:
	assert_eq(MissionKioskUI.objective_line({"title": "Deliver ore", "targetQuantity": 12}), "Deliver ore  ×12")
	assert_eq(MissionKioskUI.objective_line({"title": "Go", "targetQuantity": 1}), "Go")
	assert_string_contains(MissionKioskUI.objective_line({"title": "Extra", "isBonus": true}), "(")


func test_the_next_datapad_opening_lands_once_where_it_was_asked() -> void:
	var terminal := TerminalUI.new()
	add_child_autofree(terminal)
	var landed: Array = []
	terminal.open_next(func() -> void: landed.append(1))
	terminal.open()
	terminal.open()
	assert_eq(landed, [1], "once")
