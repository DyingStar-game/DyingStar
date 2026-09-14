extends GutTest
## Suite for [method PlanetChunk.road_surface_for_zone]: which surface a road
## piece gets from the FIRST populate zone under it, and the tint baked into
## a corundum highway — the ground's own colour rule, case by case.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_surface_rule.gd

const PlanetDataScript := preload("res://scenes/planet/planet_data.gd")
const KNOWN_BIOME := "outcrop-plateau"
const DIR := Vector3(0.6, 0.48, -0.64)

var _pd: PlanetData


func before_all() -> void:
	PlanetDataScript.new().warm_biome_cache()


func before_each() -> void:
	_pd = PlanetDataScript.new()
	_pd.planet_name = "testroadsurface"
	_pd.radius = 6356000.0
	_pd.export_nside = 64
	_pd.corundum_default_biome = true


func test_highway_on_the_corundum_default_is_iron_tinted() -> void:
	var surf := PlanetChunk.road_surface_for_zone(_pd, "highway", {})
	assert_eq(surf["mat_path"], RoadTerrain.CORUNDUM_HIGHWAY_MATERIAL_PATH)
	assert_eq(int(surf["uv_mode"]), RoadRibbon.UvMode.LANE)
	assert_true(surf["tinted"])
	var bd := _pd.get_biome_by_type(RoadTerrain.CORUNDUM_BIOME_TYPE)
	assert_not_null(bd, "the corundum biome ships")
	var want := ArideDesertCorundumPlateauTerrain.iron_tint(DIR.normalized(), _pd.radius, bd.color)
	assert_eq((surf["tint"] as Callable).call(DIR.normalized()), want, "the terrain's own tint")


func test_highway_in_a_corundum_rock_outcrop_takes_the_rock_tint() -> void:
	var zone := {"biome_type": KNOWN_BIOME, "rock_type": "corundum_white"}
	var surf := PlanetChunk.road_surface_for_zone(_pd, "highway", zone)
	assert_eq(surf["mat_path"], RoadTerrain.CORUNDUM_HIGHWAY_MATERIAL_PATH,
			"an outcrop of a corundum variety is corundum ground")
	assert_true(surf["tinted"])
	var bd := _pd.get_biome_by_type(KNOWN_BIOME)
	var d := DIR.normalized()
	assert_eq((surf["tint"] as Callable).call(d),
			RockCatalogue.tint(d, _pd.radius, "corundum_white", bd.color),
			"the zone's rock tint, as the ground vertices get it")


func test_highway_in_a_foreign_zone_is_asphalt() -> void:
	var surf := PlanetChunk.road_surface_for_zone(_pd, "highway",
			{"biome_type": KNOWN_BIOME, "rock_type": "hercynite_oxidised"})
	assert_eq(surf["mat_path"], RoadTerrain.ASPHALT_MATERIAL_PATH)
	assert_false(surf["tinted"])
	assert_eq(int(surf["uv_mode"]), RoadRibbon.UvMode.FLOW)
	assert_false((surf["tint"] as Callable).is_valid())


func test_road_and_flag_off_stay_asphalt() -> void:
	var road := PlanetChunk.road_surface_for_zone(_pd, "road", {})
	assert_eq(road["mat_path"], RoadTerrain.ASPHALT_MATERIAL_PATH, "a road: asphalt on corundum")
	_pd.corundum_default_biome = false
	var off := PlanetChunk.road_surface_for_zone(_pd, "highway", {})
	assert_eq(off["mat_path"], RoadTerrain.ASPHALT_MATERIAL_PATH,
			"no default corundum, no zone: asphalt")
	var rock := PlanetChunk.road_surface_for_zone(_pd, "highway",
			{"biome_type": KNOWN_BIOME, "rock_type": "emery"})
	assert_true(rock["tinted"], "but a corundum-rock zone is corundum on any planet")


func test_tint_is_resolved_per_vertex_from_the_chunk_zones() -> void:
	# An emery outcrop covering lon 10..11 only; the piece's midpoint (lon
	# 10.5) is inside, so the surface is corundum — and a vertex at lon 12,
	# outside every zone, must still take the corundum default tint, not the
	# midpoint's emery (a coarse chunk's piece can be kilometres long).
	var emery := {"biome_type": KNOWN_BIOME, "rock_type": "emery", "coverage": "partial",
			"vertices": [[10.0, 19.0], [11.0, 19.0], [11.0, 21.0], [10.0, 21.0]]}
	var surf := PlanetChunk.road_surface_for_zone(_pd, "highway", emery, null, [emery])
	assert_true(surf["tinted"])
	var tint: Callable = surf["tint"]
	var inside := RoadBridge.lonlat_to_dir(10.5, 20.0)
	var outside := RoadBridge.lonlat_to_dir(12.0, 20.0)
	var bd := _pd.get_biome_by_type(KNOWN_BIOME)
	var cor_bd := _pd.get_biome_by_type(RoadTerrain.CORUNDUM_BIOME_TYPE)
	assert_eq(tint.call(inside), RockCatalogue.tint(inside, _pd.radius, "emery", bd.color),
			"inside the outcrop: the emery tint")
	assert_eq(tint.call(outside),
			ArideDesertCorundumPlateauTerrain.iron_tint(outside, _pd.radius, cor_bd.color),
			"outside it: the corundum default tint, like the ground there")
	# Without the chunk's zones every vertex takes the midpoint zone's tint.
	var flat := PlanetChunk.road_surface_for_zone(_pd, "highway", emery)
	assert_eq((flat["tint"] as Callable).call(outside),
			RockCatalogue.tint(outside, _pd.radius, "emery", bd.color))

