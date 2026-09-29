class_name StageLayout
extends RefCounted
## The menu stage, as data: what stands where, and where the camera stands for each menu screen.
## Tweak the stage here, never in code — the same idea as GraphicsOptions.
##
## Everything is placed from the ANCHOR (the Teleporter of tarsis_3.tscn, the city 5.6 km up) by a
## distance along the ground and a bearing in degrees measured from the LINE: the direction from the
## anchor to the CargoDepot, 7.6 km away over known ground. So "bearing 0" looks down the valley of
## distances, and "90" is the cargo yard on its right.
##
## The scene tells a small story: an outpost at sunrise. A lamp-lit path leads from the teleporter to a
## cargo yard where a truck idles with its headlights on; workers chat by it, one mines a boulder,
## one sits on the crates, one walks the rounds, one dances under a lamp. Down the line, buildings
## stand at every distance the graphics options have to be judged at — 200 m, 1, 3, 8, 15 and 20 km.
##
## Prop entry:      {scene, distance, bearing, facing, lift?, headlights?}
## Driver entry:    see DRIVERS
## Mannequin entry: {clip, distance, bearing, facing, walk_radius?}
## Station entry:   {key, label?, eye: [distance, bearing, height], look: [distance, bearing, height]}

const ANCHOR : String = "Teleporter"
const LINE_TOWARD : String = "CargoDepot"
## Sunrise: the sun just clear of the horizon in the morning — long shadows, a warm sky, the lamps
## still on. Set by the sun's height rather than an hour, which could fall in the dark in winter.
const MENU_SUN_ELEVATION_DEG : float = 5.0

const _CONTAINER_A : String = "res://scenes/_universe/props/containers/container_standard_a_1200x240x240.tscn"
const _CONTAINER_B : String = "res://scenes/_universe/props/containers/container_standard_b_1200x240x240.tscn"
const _LIQUID : String = "res://scenes/_universe/props/containers/container_liquid_1200x240x240.tscn"
const _LAMP : String = "res://scenes/_universe/props/furniture/furn_lamppost_outdoor_2.2m.tscn"
const _APARTMENT : String = "res://scenes/_universe/structures/buildings/apartment_ares_worker_001.tscn"
const _WAREHOUSE : String = "res://scenes/_universe/props/containers/storagewarehouse.tscn"
const _TRUCK : String = "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const _ROCK : String = "res://scenes/_universe/environment/terrain/rocks/rock_sm.tscn"

const PROPS : Array[Dictionary] = [
	# ── The lamp-lit path, teleporter -> yard ──
	{"scene": _LAMP, "distance": 8.0, "bearing": 70.0, "facing": 250.0},
	{"scene": _LAMP, "distance": 14.0, "bearing": 80.0, "facing": 260.0},
	{"scene": _LAMP, "distance": 20.0, "bearing": 86.0, "facing": 266.0},
	{"scene": _LAMP, "distance": 27.0, "bearing": 98.0, "facing": 278.0},
	# ── The cargo yard ──
	{"scene": _TRUCK, "distance": 24.0, "bearing": 108.0, "facing": 300.0, "headlights": true},
	{"scene": _CONTAINER_A, "distance": 34.0, "bearing": 88.0, "facing": 0.0},
	{"scene": _CONTAINER_B, "distance": 34.0, "bearing": 88.0, "facing": 0.0, "lift": 2.6},
	{"scene": _LIQUID, "distance": 37.0, "bearing": 96.0, "facing": 0.0},
	{"scene": _CONTAINER_B, "distance": 40.0, "bearing": 104.0, "facing": 12.0},
	{"scene": "res://scenes/_universe/props/containers/pallet_crate_120x80x100.tscn",
		"distance": 22.0, "bearing": 92.0, "facing": 20.0},
	{"scene": "res://scenes/_universe/props/containers/pallet_crate_120x80x100.tscn",
		"distance": 22.5, "bearing": 95.0, "facing": 35.0},
	{"scene": "res://scenes/_universe/props/containers/pallet_liquid_120x80x100.tscn",
		"distance": 23.0, "bearing": 89.0, "facing": 5.0},
	{"scene": "res://scenes/_universe/props/containers/crate_container.tscn",
		"distance": 29.0, "bearing": 118.0, "facing": 40.0},
	{"scene": "res://scenes/_universe/props/containers/crate_canister.tscn",
		"distance": 27.5, "bearing": 121.0, "facing": 10.0},
	# ── The rocks being mined (rock_sm: the only one at a real scale — the large ones are
	# mountains at this distance) ──
	{"scene": _ROCK, "distance": 18.0, "bearing": -48.0, "facing": 0.0},
	{"scene": _ROCK, "distance": 18.8, "bearing": -44.5, "facing": 130.0},
	{"scene": _ROCK, "distance": 17.2, "bearing": -51.0, "facing": 250.0},
	{"scene": _ROCK, "distance": 13.0, "bearing": -62.0, "facing": 45.0},
	{"scene": _ROCK, "distance": 21.0, "bearing": -36.0, "facing": 300.0},
	# ── The line of distances: one landmark per band the options are judged at ──
	{"scene": _APARTMENT, "distance": 200.0, "bearing": 14.0, "facing": 180.0},
	{"scene": _WAREHOUSE, "distance": 1000.0, "bearing": -6.0, "facing": 170.0},
	{"scene": _APARTMENT, "distance": 3000.0, "bearing": 4.0, "facing": 190.0},
	{"scene": _WAREHOUSE, "distance": 8000.0, "bearing": 3.0, "facing": 180.0},
	{"scene": _APARTMENT, "distance": 15000.0, "bearing": -2.0, "facing": 180.0},
	{"scene": _WAREHOUSE, "distance": 20000.0, "bearing": 1.5, "facing": 180.0},
]

const MANNEQUINS : Array[Dictionary] = [
	# Two drivers chatting by the truck's open side.
	{"clip": &"Idle_Talking", "distance": 21.5, "bearing": 112.0, "facing": 200.0},
	{"clip": &"Idle_FoldArms", "distance": 22.5, "bearing": 116.5, "facing": 20.0},
	# The miner at the boulder.
	{"clip": &"Mining", "distance": 16.0, "bearing": -44.0, "facing": 318.0},
	# Break time on the pallets.
	{"clip": &"GroundSit_Idle", "distance": 21.0, "bearing": 90.0, "facing": 150.0},
	# On the phone under the path's second lamp.
	{"clip": &"Idle_TalkingPhone", "distance": 14.5, "bearing": 74.0, "facing": 200.0},
	# The night watch walking its rounds by the containers.
	{"clip": &"Walk", "distance": 30.0, "bearing": 70.0, "facing": 0.0, "walk_radius": 3.5},
	# And somebody who has finished for the day.
	{"clip": &"Dance", "distance": 10.0, "bearing": 35.0, "facing": 200.0},
	# Looking out over the valley, at the far end of the line.
	{"clip": &"Idle_LookAround", "distance": 6.0, "bearing": -8.0, "facing": 0.0},
]

## Trucks driving big loops around the outpost, headlights on: something moves in every shot.
## {scene, centre: [distance, bearing] of the loop's centre, radius, speed_kmh, start (deg), clockwise}
const DRIVERS : Array[Dictionary] = [
	{"scene": _TRUCK, "centre": [30.0, 90.0], "radius": 140.0, "speed_kmh": 32.0, "start": 0.0,
		"clockwise": true},
	{"scene": _TRUCK, "centre": [60.0, 40.0], "radius": 260.0, "speed_kmh": 45.0, "start": 200.0,
		"clockwise": false},
]

## Menu screens first (MainPage.screen_changed keys), then the tuning scene's fixed viewpoints.
const STATIONS : Array[Dictionary] = [
	# Home: a high three-quarter view, the whole outpost and the valley behind it.
	{"key": &"home", "eye": [58.0, 200.0, 16.0], "look": [20.0, 80.0, 3.0]},
	# Settings: down among the crates, the workers and the truck's headlights.
	{"key": &"settings", "eye": [13.0, 100.0, 1.9], "look": [24.0, 108.0, 1.4]},
	# Graphics: behind the outpost, the line of distances running to the horizon.
	{"key": &"settings_graphics", "eye": [40.0, -40.0, 14.0], "look": [3000.0, 0.0, 40.0]},
	# ── Tuning scene ──
	{"key": &"tune_distances", "label": "%%SHOWCASE_VIEW_DISTANCES",
		"eye": [40.0, -40.0, 14.0], "look": [3000.0, 0.0, 40.0]},
	{"key": &"tune_shadows", "label": "%%SHOWCASE_VIEW_SHADOWS",
		"eye": [9.0, 55.0, 2.0], "look": [22.0, 95.0, 0.8]},
	{"key": &"tune_teleporter", "label": "%%SHOWCASE_VIEW_TELEPORTER",
		"eye": [16.0, -35.0, 3.2], "look": [0.0, 0.0, 3.5]},
	{"key": &"tune_crowd", "label": "%%SHOWCASE_VIEW_CROWD",
		"eye": [9.0, 130.0, 1.7], "look": [21.5, 110.0, 1.5]},
	{"key": &"tune_horizon", "label": "%%SHOWCASE_VIEW_HORIZON",
		"eye": [0.0, 0.0, 320.0], "look": [20000.0, 0.0, 0.0]},
]


static func station(key: StringName) -> Dictionary:
	for entry in STATIONS:
		if entry["key"] == key:
			return entry
	return {}


static func tuning_stations() -> Array[Dictionary]:
	return STATIONS.filter(func(s: Dictionary) -> bool: return s.has("label"))
