extends GutTest
## The ore chain, unit-tested as pure functions: the Crusher packs crates of crushed ore (ore + barren
## rock, the purity only roughly filtered), the Refinery turns one into ingots (rock gone, lighter
## crate, same owner), and CrateContent is the one format both write and the crate's plate reads.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_ore_processing.gd -gexit

## The crate collision box, so the tests speak the same number the scene does.
const CRATE_M3: float = 0.3953384826854745 * 0.4112716205195284 * 0.4039184679659229
const GRANITE_KG_M3 := 2700.0


## A rock the Crusher can read: carries a MineralDef, the way rock_mining.gd stores it.
class RockDouble extends Node3D:
	var mineral: Resource = null


func _stock_at(mineral: String, purity: float, crates: float = 1.0) -> Dictionary:
	var stock := {}
	var total := CRATE_M3 * crates
	Crusher.bank(stock, mineral, total * purity, total * (1.0 - purity), total * (1.0 - purity) * GRANITE_KG_M3)
	return stock


# ── Crusher ───────────────────────────────────────────────────────────────────────────────────────

func test_the_crusher_names_the_mineral_a_rock_carries() -> void:
	var rock := RockDouble.new()
	rock.mineral = MineralRegistry.get_mineral(&"gold")
	add_child_autofree(rock)
	assert_eq(Crusher.mineral_id_of(rock), "gold")
	var bare := RockDouble.new()
	add_child_autofree(bare)
	assert_eq(Crusher.mineral_id_of(bare), "", "a rock with no mineral names nothing")


func test_a_stock_just_short_of_a_crate_packs_nothing() -> void:
	var stock := _stock_at("gold", 0.1, 0.5)
	assert_eq(Crusher.mineral_to_pack(stock, CRATE_M3), "")
	assert_true(Crusher.pack(stock, CRATE_M3, 0.0, "p1").is_empty())


func test_barren_rock_alone_never_makes_a_crate() -> void:
	var stock := {}
	Crusher.bank(stock, "gold", 0.0, CRATE_M3 * 2.0, 0.0)
	assert_eq(Crusher.mineral_to_pack(stock, CRATE_M3), "")


func test_the_mineral_packed_does_not_depend_on_dictionary_order() -> void:
	var stock := _stock_at("iron", 0.2)
	stock.merge(_stock_at("gold", 0.2))
	assert_eq(Crusher.mineral_to_pack(stock, CRATE_M3), "gold", "alphabetical")


func test_ten_percent_rock_gives_crates_between_five_and_fifteen_percent() -> void:
	for roll: float in [-1.0, -0.3, 0.0, 0.6, 1.0]:
		var crate := Crusher.pack(_stock_at("gold", 0.1, 2.0), CRATE_M3, roll, "p1")
		assert_almost_eq(float(crate["purity"]), 0.1 + roll * 0.05, 0.0001, "roll %.1f" % roll)
		assert_almost_eq(float(crate["ore_m3"]) + float(crate["gangue_m3"]), CRATE_M3, 0.0001, "a full crate")


func test_a_crate_takes_out_of_the_stock_exactly_what_it_holds() -> void:
	var stock := _stock_at("iron", 0.3, 3.0)
	var before: Dictionary = stock["iron"].duplicate()
	var crate := Crusher.pack(stock, CRATE_M3, 0.4, "p1")
	assert_almost_eq(before["ore_m3"] - stock["iron"]["ore_m3"], float(crate["ore_m3"]), 0.000001)
	assert_almost_eq(before["gangue_m3"] - stock["iron"]["gangue_m3"], float(crate["gangue_m3"]), 0.000001)
	assert_almost_eq(before["gangue_kg"] - stock["iron"]["gangue_kg"], float(crate["gangue_kg"]), 0.0001)


func test_a_crushed_crate_belongs_to_the_miner_who_extracted_it() -> void:
	var crate := Crusher.pack(_stock_at("iron", 0.3), CRATE_M3, 0.0, "p1", "kira")
	assert_eq(crate["owner"], "kira")
	assert_eq(crate["miner_id"], "p1")
	assert_eq(Crusher.pack(_stock_at("iron", 0.3), CRATE_M3, 0.0, "")["owner"], "ARES CORP.", "nobody at the screen")
	assert_true(CrateContent.is_crushed(crate))


# ── CrateContent / Refinery ───────────────────────────────────────────────────────────────────────

func test_the_mass_is_the_game_mass_of_ore_plus_rock() -> void:
	var iron: float = MineralRegistry.get_mineral(&"iron").density_kg_m3
	var crate := CrateContent.crushed("iron", 0.01, 0.05, 135.0, "p1")
	assert_almost_eq(float(crate["mass_kg"]), (0.01 * iron + 135.0) / RockMining.WEIGHT_REDUCTION_FACTOR, 0.0001)


func test_refining_drops_the_rock_and_keeps_ore_and_owner() -> void:
	var crushed := Crusher.pack(_stock_at("iron", 0.3), CRATE_M3, 0.0, "p1")
	var ingots := CrateContent.refined(crushed)
	assert_true(CrateContent.is_ingot(ingots))
	assert_eq(ingots["ore_m3"], crushed["ore_m3"])
	assert_eq(ingots["gangue_m3"], 0.0)
	assert_eq(ingots["miner_id"], "p1")
	assert_eq(ingots["owner"], crushed["owner"], "refining keeps the owner")
	assert_lt(float(ingots["mass_kg"]), float(crushed["mass_kg"]), "a lighter crate")


func test_good_types_tell_crushed_ore_from_ingots() -> void:
	var crushed := CrateContent.crushed("iron", 0.01, 0.05, 135.0, "p1")
	assert_eq(CrateContent.good_type(crushed), "ore.iron")
	assert_eq(CrateContent.good_type(CrateContent.refined(crushed)), "ingot.iron")
	assert_eq(CrateContent.good_type({}), "", "an empty crate is no good")


func test_every_crate_content_has_its_translation() -> void:
	for mineral: String in ["gold", "iron", "cryptonite"]:
		var crushed := CrateContent.crushed(mineral, 0.01, 0.05, 135.0, "")
		for content: Dictionary in [crushed, CrateContent.refined(crushed)]:
			var key := CrateContent.content_key(content)
			assert_ne(tr(key), key, "%s is translated" % key)


func test_the_refinery_reads_only_crushed_crates() -> void:
	assert_true(CrateContent.is_crushed(CrateContent.crushed("iron", 0.01, 0.05, 1.0, "")))
	var not_a_crate := Node3D.new()
	add_child_autofree(not_a_crate)
	assert_true(Refinery.crate_content_of(not_a_crate).is_empty())


func test_the_plate_lays_out_both_kinds() -> void:
	var crushed := CrateContent.crushed("iron", 0.01, 0.05, 135.0, "p1")
	for content: Dictionary in [crushed, CrateContent.refined(crushed)]:
		var plate := CratePlate.build_layout(content)
		add_child_autofree(plate)
		assert_not_null(plate)


func test_the_crusher_fill_is_the_crate_its_extract_packs() -> void:
	var stock := _stock_at("iron", 0.2, 0.6)
	stock.merge(_stock_at("gold", 0.2, 1.2))
	assert_almost_eq(Crusher.fill_of(stock, CRATE_M3), 1.2, 0.0001, "gold fills a crate: its fill")
	var partial := _stock_at("iron", 0.2, 0.3)
	partial.merge(_stock_at("gold", 0.2, 0.6))
	assert_almost_eq(Crusher.fill_of(partial, CRATE_M3), 0.6, 0.0001, "none full: the fullest")


func _crushed(mineral: String, ore_m3: float, miner: String) -> Dictionary:
	return CrateContent.crushed(mineral, ore_m3, CRATE_M3 - ore_m3, 0.0, miner, miner)


func test_the_refinery_gathers_crates_until_a_crate_of_metal() -> void:
	var stock := {}
	for i: int in range(4):
		Refinery.add_to_stock(stock, _crushed("gold", CRATE_M3 * 0.3, "p1"))
	assert_almost_eq(Refinery.fill_of(stock, CRATE_M3), 1.2, 0.0001, "four 30 % crates")
	var ingots := Refinery.take_crate(stock, CRATE_M3)
	assert_true(CrateContent.is_ingot(ingots))
	assert_almost_eq(float(ingots["ore_m3"]), CRATE_M3, 0.0001, "a full crate of metal")
	assert_eq(str(ingots["miner_id"]), "p1", "the stock holder's ingots")
	assert_almost_eq(Refinery.fill_of(stock, CRATE_M3), 0.2, 0.0001, "the rest stays in")
	var partial := Refinery.take_crate(stock, CRATE_M3)
	assert_almost_eq(float(partial["ore_m3"]), CRATE_M3 * 0.2, 0.0001, "EXTRACT before 100 %: a partial crate")
	assert_true(stock.is_empty(), "empty: forgets its mineral and holder")
	assert_true(Refinery.take_crate(stock, CRATE_M3).is_empty())


func test_the_refinery_stock_is_the_first_crate_s_mineral_and_holder() -> void:
	var stock := {}
	Refinery.add_to_stock(stock, _crushed("gold", 0.01, "p1"))
	Refinery.add_to_stock(stock, _crushed("gold", 0.02, "p1"))
	assert_eq(str(stock["mineral"]), "gold")
	assert_eq(str(stock["holder"]), "p1")
	assert_almost_eq(float(stock["ore_m3"]), 0.03, 0.0001, "ore only, the barren rock is gone")


# ── Dev spawn wheel test crates ───────────────────────────────────────────────────────────────────

func test_the_wheel_spawns_full_test_crates_of_both_kinds() -> void:
	var crushed := SpawnCatalog.test_crate(SpawnCatalog.entry("crate_crushed"), "p1")
	var ingot := SpawnCatalog.test_crate(SpawnCatalog.entry("crate_ingot"), "p1")
	assert_true(CrateContent.is_crushed(crushed))
	assert_true(CrateContent.is_ingot(ingot))
	assert_eq(crushed["miner_id"], "p1")
	assert_gt(int(ingot["units"]), 0)
	assert_true(SpawnCatalog.test_crate(SpawnCatalog.entry("hauling_box"), "p1").is_empty(), "an empty box stays empty")


func test_a_crate_counts_its_plate_weight_in_whole_kilograms() -> void:
	var crate := CrateContent.crushed("gold", CRATE_M3 * 0.1, CRATE_M3 * 0.9, CRATE_M3 * 0.9 * GRANITE_KG_M3, "p1")
	assert_eq(int(crate["units"]), roundi(float(crate["mass_kg"])), "what the plate weighs is what counts")
	assert_eq(CrateContent.units_of_mass(0.2), 1, "a small partial crate still counts")
	assert_eq(CrateContent.units_of_mass(0.0), 0)
