extends Node
## Writes tools/planettech/qgis/export/planet/village_snaps_golden.json: where the GAME puts a few
## points of a village layout on the planet, for test_village_snaps.py to check the QGIS road export
## (village_snaps.py) against. That export re-implements in Python what the game does — HEALPix's
## lonlat2vec, Godot's YXZ Euler, PoiVillages._stand_on_ground's tangent frame — and the fixture is
## what keeps the two from drifting apart. Run it again after changing any of them:
##
##   godot --headless --path . res://tools/planettech/village_snaps_golden.tscn
##
## The village really is stood on its ground by PoiVillages._stand_on_ground, on a stand-in planet
## whose ground is a sphere of RADIUS_M (FlatPlanet, FlatTerrain): the same frame as the Python's,
## with no terrain to stream. A scene and not a SceneTree script: the game's classes need the autoloads.

## Where the fixture is written; test_village_snaps.py reads it from beside itself.
const OUT_PATH := "res://tools/planettech/qgis/export/planet/village_snaps_golden.json"
## Radius of the stand-in planet's ground (m): Sandbox's, the body the villages stand on.
const RADIUS_M := 6356000.0
## The planet's own pose in the world: far off and turned, as a planet in orbit is, so the fixture
## also proves the export only ever needs the planet-local pose Horizon stores.
const PLANET_ORIGIN_M := Vector3(3.1e10, -2.0e9, 4.0e9)
## Village poses on the planet: where Horizon stores it (lon, lat in degrees; height above the ground
## in m, which _stand_on_ground drops) and its Node3D rotation (rad, YXZ). None has its +Z along the
## radial, where the game falls back on another axis and the Python has no fallback.
const POSES := [
	{"name": "equator", "lon": 0.0, "lat": 0.0, "alt_m": 0.0, "rotation": Vector3.ZERO},
	{"name": "south", "lon": 12.5, "lat": -33.0, "alt_m": 1250.0, "rotation": Vector3(0.0, 1.1, 0.0)},
	{"name": "north", "lon": -170.0, "lat": 61.0, "alt_m": -300.0, "rotation": Vector3(0.4, -2.3, 0.25)},
]
## Points of the layout, (x, z) in metres: its origin, the edges of a footprint, a snap and its
## approach point, one far out (a lead-in's ring corner).
const POINTS_M := [
	Vector2(0.0, 0.0), Vector2(100.0, 0.0), Vector2(0.0, 60.0), Vector2(-37.5, 81.25),
	Vector2(-100.0, -60.0), Vector2(250.0, -400.0),
]
## Directions for HEALPix.lonlat2vec alone (lon, lat in degrees).
const LONLATS := [Vector2(0.0, 0.0), Vector2(12.5, -33.0), Vector2(-170.0, 61.0), Vector2(90.0, 89.5)]


func _ready() -> void:
	var path := ProjectSettings.globalize_path(OUT_PATH)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[VillageSnapsGolden] cannot write %s" % path)
		get_tree().quit(1)
		return
	f.store_string(JSON.stringify(golden(), "  ", true, true) + "\n")
	f.close()
	print("[VillageSnapsGolden] written %s" % path)
	get_tree().quit()


## The fixture: the game's lonlat2vec, Euler and village frames, and its kind names.
func golden() -> Dictionary:
	var vecs: Array = []
	for ll: Vector2 in LONLATS:
		vecs.append({"lon": ll.x, "lat": ll.y, "vec": _arr(HEALPix.lonlat2vec(ll.x, ll.y))})
	var villages: Array = []
	for pose: Dictionary in POSES:
		villages.append(_village(pose))
	var road_kinds: Array = []
	for k: int in VillageRoad.SNAP_KINDS:
		road_kinds.append(RoadSnap.KIND_NAMES[VillageRoad.SNAP_KINDS[k]])
	return {"radius_m": RADIUS_M, "lonlat2vec": vecs, "villages": villages,
			"snap_kinds": RoadSnap.KIND_NAMES.values(), "village_road_kinds": road_kinds}


## One village stood on the stand-in planet's ground by the game itself, and the [lon, lat] of each
## of POINTS_M in its layout — composed with the village's pose as PoiVillages composes its items.
func _village(pose: Dictionary) -> Dictionary:
	var planet := FlatPlanet.new()
	planet.transform = Transform3D(Basis.from_euler(Vector3(0.2, 0.7, -0.1)), PLANET_ORIGIN_M)
	var terrain := FlatTerrain.new()
	terrain.name = "PlanetTerrain"
	terrain.planet_data = PlanetData.new()  # no chunk_heightmaps_dir: the height is always "ready"
	planet.add_child(terrain)
	var village: Node3D = load("res://scenes/_universe/structures/urban/poi_villages.gd").new()
	var stored := HEALPix.lonlat2vec(pose["lon"], pose["lat"]) * (RADIUS_M + float(pose["alt_m"]))
	village.position = stored
	village.rotation = pose["rotation"]
	planet.add_child(village)
	add_child(planet)
	planet.planet_terrain = terrain  # after _ready: its @onready lookup must not win
	village.call("_stand_on_ground")
	var to_planet := planet.global_transform.affine_inverse()
	var points: Array = []
	for p: Vector2 in POINTS_M:
		var local := to_planet * (village.global_transform * Vector3(p.x, 0.0, p.y))
		var ll := HEALPix.vec2lonlat(local)
		points.append({"x": p.x, "z": p.y, "lonlat": [ll.x, ll.y]})
	var out := {"name": pose["name"], "position": _arr(stored), "rotation": _arr(pose["rotation"]),
			"euler_z": _arr(Basis.from_euler(pose["rotation"]).z), "points": points}
	planet.free()
	return out


## [param v] as a JSON array.
static func _arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


## A Planet that only stands for its frame: none of its own start-up runs (spawn position, orbit).
class FlatPlanet:
	extends Planet

	## Replaces Planet's: no group, no registry entry.
	func _enter_tree() -> void:
		pass

	## Replaces Planet's: the transform is the one the tool set.
	func _ready() -> void:
		pass

	## Replaces Planet's: the planet stays where it was put.
	func _physics_process(_delta: float) -> void:
		pass


## A PlanetTerrain whose ground is the sphere of RADIUS_M: no tile to stream nor to wait for.
class FlatTerrain:
	extends PlanetTerrain

	## The ground straight under [param dir] (planet frame): on the sphere.
	func surface_point_for_direction(dir: Vector3) -> Vector3:
		return dir.normalized() * RADIUS_M

	## Replaces PlanetTerrain's: no chunk to build.
	func _physics_process(_delta: float) -> void:
		pass

	## Replaces PlanetTerrain's: no worker, no cache to save.
	func _exit_tree() -> void:
		pass
