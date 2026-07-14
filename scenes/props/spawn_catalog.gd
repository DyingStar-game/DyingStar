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
const ENTRIES := {
	"rock": {
		"label": "S", "scene": "res://scenes/props/rock/rock_mining_small.tscn",
		"type": "miningrock", "distance": 5.5, "origin_height": 0.6,
	},
	"rock_medium": {
		"label": "M", "scene": "res://scenes/props/rock/rock_mining_medium.tscn",
		"type": "miningrock", "distance": 6.0, "origin_height": 2.0,
	},
	"rock_large": {
		"label": "L", "scene": "res://scenes/props/rock/rock_mining_large.tscn",
		"type": "miningrock", "distance": 9.0, "origin_height": 5.0,
	},
	"box": {
		"label": "50cm", "scene": "res://scenes/props/testbox/box_50cm.tscn",
		"type": "box", "distance": 2.0, "origin_height": 0.3,
	},
	"palette_container": {
		"label": "Ares", "scene": "res://scenes/props/cargo/palette_container.tscn",
		"type": "palette_container", "distance": 3.0, "origin_height": 0.8,
	},
	"pallet_plate": {
		"label": "Palet", "scene": "res://scenes/props/cargo/pallet_plate.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.6,
	},
	"pallet_crate": {
		"label": "Cube", "scene": "res://scenes/props/cargo/pallet_crate.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.8,
	},
	"pallet_benne": {
		"label": "Benne", "scene": "res://scenes/props/cargo/pallet_benne.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.8,
	},
	"pallet_liquid": {
		"label": "Liquid", "scene": "res://scenes/props/cargo/pallet_liquid.tscn",
		"type": "box", "distance": 3.0, "origin_height": 0.8,
	},
	"hauling_box": {
		# The crate a mining depot packs its ore into (see mining_depot.gd). Replicates as the
		# "palette_container" type: that is the def whose channels carry `content` (the ore volume).
		"label": "Hauling", "scene": "res://scenes/props/cargo/hauling_box.tscn",
		"type": "palette_container", "distance": 2.0, "origin_height": 0.3,
	},
	"truck": {
		"label": "Camion", "scene": "res://scenes/vehicles/trucks/truck.tscn",
		"type": "vehicle", "distance": 8.0, "origin_height": 1.0,
	},
}

## The wheel layout: a top-level entry is either a catalogue key (a leaf) or a category holding keys.
## Only KEYS live here — the labels come from ENTRIES, so there is nothing to keep in sync.
const WHEEL := [
	{"text": "Rocher", "keys": ["rock", "rock_medium", "rock_large"]},
	{"text": "Caisse", "keys": ["box", "hauling_box", "palette_container", "pallet_plate",
			"pallet_crate", "pallet_benne", "pallet_liquid"]},
	{"key": "truck"},
]

## The entry for a wheel key, or an empty Dictionary when the key is unknown (the server treats that
## as a refusal — see PlayerServer's "spawn_prop").
static func entry(key: String) -> Dictionary:
	return ENTRIES.get(key, {})

## The options tree for the RadialMenu (see scenes/ui/radial_menu.gd), built from WHEEL + ENTRIES.
static func build_wheel() -> Array:
	var options: Array = []
	for item in WHEEL:
		if item.has("key"):
			options.append({"text": ENTRIES[item["key"]]["label"], "data": item["key"]})
			continue
		var children: Array = []
		for key in item["keys"]:
			children.append({"text": ENTRIES[key]["label"], "data": key})
		options.append({"text": item["text"], "submenu": children})
	return options
