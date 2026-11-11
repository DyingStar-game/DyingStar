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
##   units       inventory units of the good: the METAL it holds, in whole GAME kilograms (metal_kg) --
##               what is sold, what a mission counts, what refining gives. The barren rock of a crushed
##               crate weighs on the plate (mass_kg) and is worth nothing: purity pays
##   owner       who the goods belong to, for the plate: the player who extracted them (their login)
##   miner_id    service identity of the player who extracted it: the one the inventory credits
##   carrier_id  the player who took it off a warehouse shelf last (a transport), holding its goods
##   owner_type, owner_id  once shelved: the warehouse's owner (WarehouseOwner), `owner` its name
##   reserved_for  shelved, kept for a transport: {mission, title, name, ids} — who may take it off the shelf
##   for_mission  taken off a shelf for a transport, until it is delivered: {id, title, name, ids} — the plate
##               says MISSION, and TransportReservations counts it as on its way

const KIND_CRUSHED := "crushed"
const KIND_INGOT := "ingot"
## service-inventory vocabulary: crushed ore keeps MissionHeartbeat's "ore." prefix, ingots get theirs.
const INGOT_GOOD_PREFIX := "ingot."
## The owner shown when no player is known (a crate packed with nobody at the screen).
const OWNER_ARES := "ARES CORP."
## The hauling crate: its collision box is the volume one crate holds (crate_volume).
const CRATE_SCENE_PATH := "res://scenes/_universe/props/containers/hauling_box.tscn"

static var _crate_m3 := -1.0


## The fillable volume of one hauling crate (m3): its collision box, read from the scene once.
static func crate_volume() -> float:
	if _crate_m3 < 0.0:
		var crate: Node = (load(CRATE_SCENE_PATH) as PackedScene).instantiate()
		var cs := crate.get_node_or_null("CollisionShape3D") as CollisionShape3D
		_crate_m3 = 1.0
		if cs != null and cs.shape is BoxShape3D:
			var s: Vector3 = (cs.shape as BoxShape3D).size
			_crate_m3 = s.x * s.y * s.z
		crate.free()
	return _crate_m3


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
		"units": units_of_mass(game_mass(mineral, ore_m3, 0.0)),
		"owner": owner if owner != "" else OWNER_ARES,
		"miner_id": miner_id,
	}


## The ingots refined from a [param crushed_content] crate: the barren rock is gone, the ore and the
## owner and the miner stay — so the crate comes out lighter.
static func refined(crushed_content: Dictionary) -> Dictionary:
	var mineral := str(crushed_content.get("mineral", ""))
	var ore_m3 := float(crushed_content.get("ore_m3", 0.0))
	var out := {
		"kind": KIND_INGOT,
		"mineral": mineral,
		"ore_m3": ore_m3,
		"gangue_m3": 0.0,
		"gangue_kg": 0.0,
		"purity": 1.0,
		"mass_kg": game_mass(mineral, ore_m3, 0.0),
		"units": units_of_mass(game_mass(mineral, ore_m3, 0.0)),
		"owner": str(crushed_content.get("owner", OWNER_ARES)),
		"miner_id": str(crushed_content.get("miner_id", "")),
		"carrier_id": str(crushed_content.get("carrier_id", "")),
	}
	# A mission's ore gives a mission's ingots: the load keeps its mark through the refinery.
	if crushed_content.get("for_mission") is Dictionary:
		out["for_mission"] = crushed_content["for_mission"]
	return out


## A crate's goods as inventory units: its game mass in whole kilograms, at least 1 when it holds
## anything (a small partial crate of ingots still counts).
static func units_of_mass(mass_kg: float) -> int:
	return maxi(1, roundi(mass_kg)) if mass_kg > 0.0 else 0


## The metal a crate holds, in game kg: its ore without the barren rock (what refining it gives).
## The mission [param content] is kept or carried for: {id, title, name, ids}, {} for none. A shelved crate kept
## for a transport (reserved_for) or one taken for it and not delivered yet (for_mission).
static func mission_of(content: Dictionary) -> Dictionary:
	var carried: Variant = content.get("for_mission")
	if carried is Dictionary:
		return carried
	var kept: Variant = content.get("reserved_for")
	if kept is Dictionary:
		return {"id": str((kept as Dictionary).get("mission", "")), "title": str((kept as Dictionary).get("title", "")),
				"name": str((kept as Dictionary).get("name", "")), "ids": (kept as Dictionary).get("ids", [])}
	return {}


static func metal_kg(content: Dictionary) -> float:
	return game_mass(str(content.get("mineral", "")), float(content.get("ore_m3", 0.0)), 0.0)


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


## Whether [param content] is a crate of crushed ore (the Crusher's).
static func is_crushed(content: Dictionary) -> bool:
	return str(content.get("kind", "")) == KIND_CRUSHED

## Whether [param content] is a crate of ingots (the Refinery's).
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
