extends GutTest
## Suite for the corundum DEFAULT biome rule ([method PlanetData.corundum_applies_to_zone],
## [method PlanetData.corundum_applies_at]).
##
## Corundum is what a planet is made of wherever nothing else is said. A populate
## zone that names a KNOWN biome displaces it — colour, detail and material. A
## zone that names no biome (rock_type or colour only) does not: it sits on the
## corundum. The crack CARVE follows a wider rule ([method PlanetData.cracks_apply_to_zone]):
## the default ground, and every zone whose rock is a corundum — in the mesh and
## in the collision alike. Asserted here on the rules themselves, without a chunk build.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_corundum_default.gd

const PlanetDataScript := preload("res://scenes/planet/planet_data.gd")

## A biome every planet ships (scenes/planet/biomes/outcrop-plateau.tres).
const KNOWN_BIOME := "outcrop-plateau"

var _pd: PlanetData


## The shared biome set is loaded once per process and announces itself with a
## print; on a machine without the OpenTelemetry bridge every print is also an
## engine error, which GUT counts against whichever test it lands in. Load it
## here, outside the tests.
func before_all() -> void:
	PlanetDataScript.new().warm_biome_cache()


func before_each() -> void:
	_pd = PlanetDataScript.new()
	_pd.planet_name = "testcorundum"
	_pd.radius = 6356000.0
	_pd.export_nside = 64
	_pd.corundum_default_biome = true


func test_flag_off_never_applies() -> void:
	_pd.corundum_default_biome = false
	assert_false(_pd.corundum_applies_to_zone({}),
			"with the flag off, corundum is not the default anywhere")
	assert_false(_pd.corundum_applies_at(Vector3(1, 0, 0)))


func test_no_zone_is_corundum() -> void:
	assert_true(_pd.corundum_applies_to_zone({}),
			"a vertex no zone contains is corundum by default")


func test_known_biome_zone_displaces_corundum() -> void:
	assert_true(_pd.get_biome_by_type(KNOWN_BIOME) != null, "the test needs a shipped biome")
	assert_false(_pd.corundum_applies_to_zone({"biome_type": KNOWN_BIOME}),
			"a zone naming a known biome is that biome, not corundum")


func test_zone_without_known_biome_keeps_corundum() -> void:
	assert_true(_pd.corundum_applies_to_zone({"rock_type": "emery", "color_hex": "#8a7080"}),
			"a rock_type / colour-only zone sits on the corundum")
	assert_true(_pd.corundum_applies_to_zone({"biome_type": "no-such-biome"}),
			"an unknown biome_type cannot displace anything")


func test_applies_at_follows_an_injected_zone() -> void:
	# A small polygon around lon=10°, lat=20°, injected into its export pixel
	# the way a Horizon-driven biome update is.
	var dir_in := RoadBridge.lonlat_to_dir(10.0, 20.0)
	var dir_out := RoadBridge.lonlat_to_dir(10.0, 30.0)
	var ipix := HEALPix.vec2pix_nest(_pd.export_nside, dir_in)
	_pd.inject_biome_feature(_pd.export_nside, ipix, {
		"action": "add",
		"biome_type": KNOWN_BIOME,
		"geometry": {"type": "polygon", "vertices": [
			[9.9, 19.9], [10.1, 19.9], [10.1, 20.1], [9.9, 20.1]]},
	})
	assert_false(_pd.corundum_applies_at(dir_in),
			"inside the biome's zone the ground is the biome's, uncarved")
	assert_true(_pd.corundum_applies_at(dir_out),
			"outside it the corundum default is back")


func test_cracks_carve_every_corundum_ground_and_nothing_else() -> void:
	assert_true(_pd.cracks_apply_to_zone({}), "the default ground")
	assert_true(_pd.cracks_apply_to_zone({"rock_type": "emery", "color_hex": "#8a7080"}),
			"a rock-only zone sits on the corundum")
	assert_true(_pd.cracks_apply_to_zone({"biome_type": KNOWN_BIOME, "rock_type": "corundum_blue"}),
			"an outcrop of blue corundum is corundum: it cracks like the plateau")
	assert_true(_pd.cracks_apply_to_zone({"biome_type": KNOWN_BIOME, "rock_type": "emery"}),
			"emery is impure corundum")
	assert_true(_pd.cracks_apply_to_zone({"biome_type": ArideDesertCorundumPlateauTerrain.BIOME_TYPE}),
			"the corundum plateau biome drawn explicitly")
	assert_false(_pd.cracks_apply_to_zone({"biome_type": KNOWN_BIOME, "rock_type": "hercynite_oxidised"}),
			"another rock's outcrop is left whole")
	assert_false(_pd.cracks_apply_to_zone({"biome_type": KNOWN_BIOME}),
			"a known biome with no corundum rock is not corundum")
	assert_false(_pd.cracks_apply_to_zone({"biome_type": PlanetData.CORUNDUM_SAND_DESERT_BIOME,
			"rock_type": "corundum_blue"}), "sand hides the cracks")
	assert_false(_pd.corundum_applies_to_zone({"biome_type": KNOWN_BIOME, "rock_type": "corundum_blue"}),
			"…but the outcrop keeps its own colour and material: the default rule is unchanged")
	_pd.corundum_default_biome = false
	assert_false(_pd.cracks_apply_to_zone({"rock_type": "corundum_blue"}),
			"no network without the planet's crack parameters")


func test_cracks_apply_at_follows_the_zone_rock() -> void:
	var dir_in := RoadBridge.lonlat_to_dir(40.0, -20.0)
	var ipix := HEALPix.vec2pix_nest(_pd.export_nside, dir_in)
	_pd.inject_biome_feature(_pd.export_nside, ipix, {
		"action": "add",
		"biome_type": KNOWN_BIOME,
		"rock_type": "corundum_red",
		"geometry": {"type": "polygon", "vertices": [
			[39.9, -20.1], [40.1, -20.1], [40.1, -19.9], [39.9, -19.9]]},
	})
	assert_false(_pd.corundum_applies_at(dir_in), "the outcrop displaces the default")
	assert_true(_pd.cracks_apply_at(dir_in), "yet its red corundum is carved")


func test_poi_spheres_keep_the_ground_whole_with_a_ramp_outside() -> void:
	var c := RoadBridge.lonlat_to_dir(50.0, 10.0)
	_pd.crack_poi_margin_m = 300.0
	_pd.set_crack_exclusions([{"dir": c, "radius": 1000.0}, {"dir": Vector3.ZERO, "radius": 5.0}])
	assert_eq(_pd._crack_pois.size(), 1, "a null direction is dropped")
	assert_eq(_pd.crack_clearance(c), 0.0, "the centre")
	var mpd := _pd.radius * PI / 180.0
	var at := func(off_m: float) -> Vector3:
		return RoadBridge.lonlat_to_dir(50.0, 10.0 + off_m / mpd)
	assert_eq(_pd.crack_clearance(at.call(900.0)), 0.0, "inside the sphere")
	var mid := _pd.crack_clearance(at.call(1150.0))
	assert_between(mid, 0.05, 0.95, "half-way through the margin: a ramp, not a step")
	assert_almost_eq(_pd.crack_clearance(at.call(1400.0)), 1.0, 1e-6, "past the margin: full depth")
	assert_eq(_pd.crack_clearance(at.call(50000.0)), 1.0)
	# The chunk subset: a chunk far from every POI loops over nothing.
	assert_eq(_pd.crack_pois_near(at.call(50000.0), 2000.0).size(), 0)
	assert_eq(_pd.crack_pois_near(at.call(2000.0), 2000.0).size(), 1)
	# Every carve path multiplies by it: the server's surface catch and the
	# bridges see no chasm at the centre of a POI.
	assert_eq(RoadBridge.chasm_depth_at(_pd, 50.0, 10.0), 0.0)
	var fp := _pd.crack_exclusion_fingerprint()
	assert_ne(fp, "", "exclusions re-key the chunk cache")
	_pd.set_crack_exclusions([])
	assert_eq(_pd.crack_exclusion_fingerprint(), "")
	assert_eq(_pd.crack_clearance(c), 1.0, "no POI, no hole")
