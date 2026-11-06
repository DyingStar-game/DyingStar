class_name CrateContent
extends RefCounted

## The `content` of a hauling crate — the ONE place that knows its format. Machines build it, the crate
## shows it on its plate, the mission heartbeat reads its good type. It travels as a plain Dictionary
## (Horizon whitelists `content` on crate_container, nothing else), so every reader goes through here.
##
## Keys:
##   kind        "crushed" (Crusher output: ore + barren rock) or "ingot" (Refinery output: pure metal)
##   mineral     mineral id ("iron") — ONE mineral per crate
##   ore_m3      ore volume (m3)
##   gangue_m3   barren rock volume (m3), 0 for ingots
##   gangue_kg   barren rock PHYSICAL mass (kg) — host rocks differ in density, so it is banked as mass
##   purity      ore_m3 / (ore_m3 + gangue_m3), 0..1
##   mass_kg     GAME mass (kg): physical mass / RockMining.WEIGHT_REDUCTION_FACTOR, like every rock
##   units       inventory units of the good (litres of ore)
##   owner       who the goods belong to, for the plate: the player who extracted them (their login)
##   miner_id    service identity of the player who extracted it: the one the inventory credits
##   carrier_id  the player who took it off a warehouse shelf last (a transport), holding its goods

const KIND_CRUSHED := "crushed"
const KIND_INGOT := "ingot"
## service-inventory vocabulary: crushed ore keeps MissionHeartbeat's "ore." prefix, ingots get theirs.
const INGOT_GOOD_PREFIX := "ingot."
## The owner shown when no player is known (a crate packed with nobody at the screen).
const OWNER_ARES := "ARES CORP."


## A crate of crushed ore: [param ore_m3] of [param mineral] mixed with [param gangue_m3] of barren rock
## weighing [param gangue_kg] (physical), extracted by [param miner_id] whose name is [param owner].
static func crushed(mineral: String, ore_m3: float, gangue_m3: float, gangue_kg: float,
		miner_id: String, owner: String = "") -> Dictionary:
	var total := ore_m3 + gangue_m3
	return {
		"kind": KIND_CRUSHED,
		"mineral": mineral,
		"ore_m3": ore_m3,
		"gangue_m3": gangue_m3,
		"gangue_kg": gangue_kg,
		"purity": ore_m3 / total if total > 0.0 else 0.0,
		"mass_kg": game_mass(mineral, ore_m3, gangue_kg),
		"units": MissionHeartbeat.units_of_volume(ore_m3),
		"owner": owner if owner != "" else OWNER_ARES,
		"miner_id": miner_id,
	}


## The ingots refined from a [param crushed_content] crate: the barren rock is gone, the ore and the
## owner and the miner stay — so the crate comes out lighter.
static func refined(crushed_content: Dictionary) -> Dictionary:
	var mineral := str(crushed_content.get("mineral", ""))
	var ore_m3 := float(crushed_content.get("ore_m3", 0.0))
	return {
		"kind": KIND_INGOT,
		"mineral": mineral,
		"ore_m3": ore_m3,
		"gangue_m3": 0.0,
		"gangue_kg": 0.0,
		"purity": 1.0,
		"mass_kg": game_mass(mineral, ore_m3, 0.0),
		"units": MissionHeartbeat.units_of_volume(ore_m3),
		"owner": str(crushed_content.get("owner", OWNER_ARES)),
		"miner_id": str(crushed_content.get("miner_id", "")),
		"carrier_id": str(crushed_content.get("carrier_id", "")),
	}


## Game mass (kg) of [param ore_m3] of [param mineral] plus [param gangue_kg] of barren rock.
static func game_mass(mineral: String, ore_m3: float, gangue_kg: float) -> float:
	var density := 0.0
	if mineral != "" and MineralRegistry.ALL.has(StringName(mineral)):
		density = MineralRegistry.get_mineral(StringName(mineral)).density_kg_m3
	return (ore_m3 * density + gangue_kg) / RockMining.WEIGHT_REDUCTION_FACTOR


## The output purity of the Crusher: the input purity [param input_purity] shifted by up to
## ±[param spread] (absolute), kept inside [0.01, 1]. [param roll] in [-1, 1] makes it testable.
static func crushed_purity(input_purity: float, roll: float, spread: float = 0.05) -> float:
	return clampf(input_purity + roll * spread, 0.01, 1.0)


## Whose inventory holds the crate's goods: the last player who loaded it off a shelf, else its
## miner. "" when nobody does (a crate of the admin fill).
static func holder_of(content: Dictionary) -> String:
	var carrier := str(content.get("carrier_id", ""))
	return carrier if carrier != "" else str(content.get("miner_id", ""))


static func is_crushed(content: Dictionary) -> bool:
	return str(content.get("kind", "")) == KIND_CRUSHED

static func is_ingot(content: Dictionary) -> bool:
	return str(content.get("kind", "")) == KIND_INGOT


## service-inventory good type ("ore.iron" / "ingot.iron"), or "" for an empty / unknown crate.
static func good_type(content: Dictionary) -> String:
	var mineral := str(content.get("mineral", "")).strip_edges()
	if mineral == "":
		return ""
	if is_crushed(content):
		return MissionHeartbeat.good_type_for_mineral(mineral)
	if is_ingot(content):
		return INGOT_GOOD_PREFIX + mineral
	return ""


## The name of each mineral a crate can hold, spelt out so the localisation test sees every key. Ore or
## ingots is the plate's TYPE line already: the content line names the mineral only.
const MINERAL_KEYS := {"gold": "%%MINERAL_GOLD", "iron": "%%MINERAL_IRON", "cryptonite": "%%MINERAL_CRYPTONITE"}


## Translation key of the mineral the crate holds ("%%MINERAL_GOLD" = "Gold"); the bare mineral id for a
## mineral with no key yet, "" for an empty crate.
static func content_key(content: Dictionary) -> String:
	var mineral := str(content.get("mineral", ""))
	return str(MINERAL_KEYS.get(mineral, mineral))
