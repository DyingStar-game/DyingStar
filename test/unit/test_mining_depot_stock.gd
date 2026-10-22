extends GutTest
## The mining depot's ore bookkeeping, unit-tested as pure functions.
##
## A crate of ore is a good somebody can be paid in, and for that it has to be ONE good: the depot
## used to bank a single blended `ore_volume`, which cannot say what a crate contains. It now banks
## per mineral (server-side, [code]_stock[/code]) and packs the first one that can fill a crate.
##
## The volume conversion matters just as much. A hauling box holds ≈0.0657 m3 — which rounds to ZERO
## in whole metres, so an extract would have minted nothing at all. Goods are counted in litres.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_mining_depot_stock.gd -gexit

const MINING_DEPOT := preload("res://scenes/_universe/structures/industrial/mines/mining_depot.gd")
const MISSION_HEARTBEAT := preload("res://server/mission_heartbeat.gd")

## The crate collision box, so the tests speak the same number the scene does.
const CRATE_M3: float = 0.3953384826854745 * 0.4112716205195284 * 0.4039184679659229


## A rock the depot can read: carries a MineralDef, the way rock_mining.gd stores it.
class RockDouble extends Node3D:
	var mineral: Resource = null


func _rock(mineral_id: String) -> RockDouble:
	var rock := RockDouble.new()
	if mineral_id != "":
		rock.mineral = MineralRegistry.get_mineral(StringName(mineral_id))
	add_child_autofree(rock)
	return rock


func _crate_units() -> int:
	return MISSION_HEARTBEAT.units_of_volume(CRATE_M3)


# ── Which mineral a rock carries ─────────────────────────────────────────────────────────────────

func test_the_depot_names_the_mineral_a_rock_carries() -> void:
	assert_eq(MINING_DEPOT.mineral_id_of(_rock("gold")), "gold")
	assert_eq(MINING_DEPOT.mineral_id_of(_rock("cryptonite")), "cryptonite")


func test_a_rock_with_no_mineral_names_nothing() -> void:
	# A rock that never had its mineral applied. Crediting it would bank ore under an empty id and
	# the goodType would come out as "ore.".
	assert_eq(MINING_DEPOT.mineral_id_of(_rock("")), "")
	var bare := Node3D.new()
	add_child_autofree(bare)
	assert_eq(MINING_DEPOT.mineral_id_of(bare), "")


# ── Which mineral a crate is packed from ─────────────────────────────────────────────────────────

func test_a_full_stock_packs_that_mineral() -> void:
	assert_eq(MINING_DEPOT.mineral_to_pack({"gold": CRATE_M3}, _crate_units()), "gold")


func test_a_stock_just_short_of_a_crate_packs_nothing() -> void:
	# The button is gated on this same answer, so a depot that said yes and then refused would look
	# broken rather than merely empty.
	assert_eq(MINING_DEPOT.mineral_to_pack({"gold": CRATE_M3 * 0.5}, _crate_units()), "")


func test_a_blended_stock_packs_the_mineral_that_is_full() -> void:
	# THE case per-mineral tracking exists for: 0.4 m3 of gold and 0.4 m3 of iron clears the crate
	# volume in TOTAL, but neither mineral fills a crate on its own.
	var blended := {"gold": CRATE_M3 * 0.5, "iron": CRATE_M3}
	assert_eq(MINING_DEPOT.mineral_to_pack(blended, _crate_units()), "iron")


func test_a_blended_stock_with_nothing_full_packs_nothing() -> void:
	# ... and the depot must refuse rather than blend, which the old single total could not tell.
	var blended := {"gold": CRATE_M3 * 0.5, "iron": CRATE_M3 * 0.49}
	assert_eq(MINING_DEPOT.mineral_to_pack(blended, _crate_units()), "")


func test_the_mineral_packed_does_not_depend_on_dictionary_order() -> void:
	# Two servers fed the same depot must pack the same mineral, so the choice is alphabetical and
	# not the insertion order GDScript dictionaries happen to have.
	var forward := {"gold": CRATE_M3, "iron": CRATE_M3}
	var backward := {"iron": CRATE_M3, "gold": CRATE_M3}
	assert_eq(MINING_DEPOT.mineral_to_pack(forward, _crate_units()), "gold")
	assert_eq(MINING_DEPOT.mineral_to_pack(backward, _crate_units()), "gold")


func test_an_empty_stock_packs_nothing() -> void:
	assert_eq(MINING_DEPOT.mineral_to_pack({}, _crate_units()), "")


func test_spending_the_credited_units_leaves_the_pool_exact() -> void:
	# handle_extract() subtracts the LITRES it credits, not the float volume, so a depot run does
	# not leak a fraction of a litre out of the player's stack on every extract.
	var units := _crate_units()
	var stock := {"gold": CRATE_M3 * 10.0}
	var spent := 0
	for _crate in 150:
		if MINING_DEPOT.mineral_to_pack(stock, units) == "":
			break
		stock["gold"] = float(stock["gold"]) - units / MISSION_HEARTBEAT.LITRES_PER_M3
		spent += units
	assert_gt(spent, 0)
	assert_eq(stock["gold"], CRATE_M3 * 10.0 - spent / MISSION_HEARTBEAT.LITRES_PER_M3)