class_name SpawnCatalog
extends RefCounted

## What the dev spawn wheel (key T) can spawn — the SINGLE source of truth, read by both sides:
##   - the CLIENT builds the wheel from it (build_wheel), so a label and a key can never drift apart;
##   - the SERVER validates the key the client sends against it (entry) and takes the scene, the type
##     and the placement FROM HERE. The client never sends a scene path or a position: it only names
##     a catalogue key, so a tampered client cannot ask for an arbitrary scene.
##
## Adding a spawnable prop = one line in ENTRIES (+ its key in WHEEL to show it on the wheel).
## The prop's `type` must have a definition in horizonserver (ds_genericprops/props/<type>_def.json),
## or Horizon silently drops the object.

## Per entry:
##   label        — what the wheel shows.
##   scene        — full res:// path of the scene to instance.
##   type         — GORC object type (must match a *_def.json on Horizon).
##   distance     — how far IN FRONT of the player it is placed, in metres.
##   origin_height— how high the prop's ORIGIN sits above the ground, in metres (roughly half its
##                  height for a body centred on its origin, 0 for a building whose origin is at its
##                  base). A dynamic body only needs to be about right: it settles by itself.
##   crate        — optional, a hauling crate spawned FULL: "crushed" or "ingot" (see test_crate).
const ENTRIES := {
	"rock": {
		"label": "S", "scene": "res://scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn",
		"type": "miningrock", "distance": 5.5, "origin_height": 0.6,
	},
	"rock_medium": {
		"label": "M", "scene": "res://scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn",
		"type": "miningrock", "distance": 6.0, "origin_height": 2.0,
	},
	"rock_large": {
		"label": "L", "scene": "res://scenes/_universe/environment/terrain/rocks/rock_mining_lg.tscn",
		"type": "miningrock", "distance": 9.0, "origin_height": 5.0,
	},
	"box": {
		"label": "50cm", "scene": "res://scenes/_universe/props/containers/box_50cm.tscn",
		"type": "box", "distance": 2.0, "origin_height": 0.3,
	},
	"crate_container": {
		"label": "Ares", "scene": "res://scenes/_universe/props/containers/crate_container.tscn",
		"type": "crate_container", "distance": 3.0, "origin_height": 0.8,
	},
	"pallet_plate": {
		"label": "%%SPAWN_PALLET", "scene": "res://scenes/_universe/props/containers/pallet_plate.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.6,
	},
	"pallet_crate": {
		"label": "%%SPAWN_CUBE", "scene": "res://scenes/_universe/props/containers/pallet_crate.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.8,
	},
	"pallet_benne": {
		"label": "%%SPAWN_TIPPER", "scene": "res://scenes/_universe/props/containers/pallet_benne.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.8,
	},
	"pallet_liquid": {
		"label": "%%SPAWN_LIQUID", "scene": "res://scenes/_universe/props/containers/pallet_liquid.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.8,
	},
	"hauling_box": {
		# The crate the ore machines pack into (see ore_processor.gd). Replicates as the
		# "crate_container" type: that is the def whose channels carry `content` (the ore volume).
		"label": "%%SPAWN_HAULING", "scene": "res://scenes/_universe/props/containers/hauling_box.tscn",
		"type": "crate_container", "distance": 2.0, "origin_height": 0.3,
	},
	"crate_crushed": {
		"label": "%%SPAWN_CRATE_CRUSHED", "scene": "res://scenes/_universe/props/containers/hauling_box.tscn",
		"type": "crate_container", "distance": 2.0, "origin_height": 0.3, "crate": CrateContent.KIND_CRUSHED,
	},
	"crate_ingot": {
		"label": "%%SPAWN_CRATE_INGOT", "scene": "res://scenes/_universe/props/containers/hauling_box.tscn",
		"type": "crate_container", "distance": 2.0, "origin_height": 0.3, "crate": CrateContent.KIND_INGOT,
	},
	"engine_t1": {
		"label": "%%SPAWN_ENGINE_T1", "scene": "res://scenes/_universe/props/vehicles/engine_t1.tscn",
		"type": "vehicle_component", "distance": 2.0, "origin_height": 0.3,
	},
	"battery_t1": {
		"label": "%%SPAWN_BATTERY_T1", "scene": "res://scenes/_universe/props/vehicles/battery_t1.tscn",
		"type": "vehicle_component", "distance": 2.0, "origin_height": 0.3,
	},
	"mining_tool": {
		# The perforator the cargo depot's ARES Mining machine hands out, without the trip to fetch it.
		"label": "%%SPAWN_MINING_TOOL", "scene": "res://scenes/_universe/props/tools/mining_tool_prop.tscn",
		"type": "tool", "distance": 1.5, "origin_height": 0.4,
	},
	# Not a prop: an action (action_of). Stocks the depot the player stands in with crates of crushed ore,
	# as if delivered -- something for a transport to load (CargoDepot.server_stock_ore).
	"stock_ore": {"label": "%%SPAWN_STOCK_ORE", "action": "stock_ore"},
	"truck": {
		"label": "%%SPAWN_TRUCK", "scene": "res://scenes/_universe/vehicles/ground/trucks/truck.tscn",
		"type": "vehicle", "distance": 8.0, "origin_height": 1.0,
	},
}

## The wheel layout: a top-level entry is either a catalogue key (a leaf) or a category holding keys.
## Only KEYS live here — the labels come from ENTRIES, so there is nothing to keep in sync.
const WHEEL := [
	{"text": "%%SPAWN_ROCK", "keys": ["rock", "rock_medium", "rock_large"]},
	{"text": "%%SPAWN_CRATE", "keys": ["box", "hauling_box", "crate_crushed", "crate_ingot", "stock_ore", "crate_container",
			"pallet_plate", "pallet_crate", "pallet_benne", "pallet_liquid"]},
	{"text": "%%SPAWN_COMPONENTS_T1", "keys": ["engine_t1", "battery_t1"]},
	{"key": "truck"},
	{"key": "mining_tool"},
]

## Admin entries of the wheel, shown only to a player whose token holds an admin role
## (AdminRoles.grants_admin): wheel key -> {label, action}. Picking one sends `action` (a
## PlayerServer.ADMIN_ACTIONS action), not a spawn — and the server checks the role again, on the roles
## Horizon verified.
const ADMIN_ENTRIES := {
	"admin_fill_shelves": {"label": "%%SPAWN_FILL_SHELVES", "action": "admin_fill_shelves"},
}
## How many crates of crushed ore the stock entry puts in a depot (CargoDepot.server_stock_ore).
const STOCK_CRATES := 20

## Test crates of the ore chain: one crate of TEST_MINERAL at TEST_PURITY, as the Crusher packs it.
const TEST_MINERAL := "gold"
const TEST_PURITY := 0.3
## Host rock density of the test crate's barren part (kg/m3, granite).
const TEST_GANGUE_KG_M3 := 2700.0


## The `content` of a test crate for [param entry] ({} when it is no crate), mined by [param miner_id]
## whose name is [param miner_name], filled to [param fill] of the crate (1: full).
static func test_crate(entry: Dictionary, miner_id: String, miner_name: String = "", fill: float = 1.0) -> Dictionary:
	var kind := str(entry.get("crate", ""))
	if kind == "":
		return {}
	var crate_m3 := CrateContent.crate_volume() * clampf(fill, 0.0, 1.0)
	var gangue_m3 := crate_m3 * (1.0 - TEST_PURITY)
	var crushed := CrateContent.crushed(TEST_MINERAL, crate_m3 * TEST_PURITY, gangue_m3,
		gangue_m3 * TEST_GANGUE_KG_M3, miner_id, miner_name)
	return CrateContent.refined(crushed) if kind == CrateContent.KIND_INGOT else crushed


## The entry for a wheel key, or an empty Dictionary when the key is unknown (the server treats that
## as a refusal — see PlayerServer's "spawn_prop").
static func entry(key: String) -> Dictionary:
	return ENTRIES.get(key, {})

## The action a wheel key stands for (an admin entry, or a dev entry that is no prop), or "" for a spawn key.
static func action_of(key: String) -> String:
	return str(ADMIN_ENTRIES.get(key, ENTRIES.get(key, {})).get("action", ""))

## The options tree for the RadialMenu (see scenes/ui/radial_menu.gd), built from WHEEL + ENTRIES, plus
## an Admin category of ADMIN_ENTRIES when [param admin].
static func build_wheel(admin: bool = false) -> Array:
	var options: Array = []
	for item in WHEEL:
		if item.has("key"):
			options.append({"text": ENTRIES[item["key"]]["label"], "data": item["key"]})
			continue
		var children: Array = []
		for key in item["keys"]:
			children.append({"text": ENTRIES[key]["label"], "data": key})
		options.append({"text": item["text"], "submenu": children})
	if admin:
		var admin_children: Array = []
		for key in ADMIN_ENTRIES:
			admin_children.append({"text": ADMIN_ENTRIES[key]["label"], "data": key})
		options.append({"text": "%%SPAWN_ADMIN", "submenu": admin_children})
	return options
