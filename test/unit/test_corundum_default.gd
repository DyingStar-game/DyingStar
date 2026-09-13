extends GutTest
## Suite for the corundum DEFAULT biome rule ([method PlanetData.corundum_applies_to_zone],
## [method PlanetData.corundum_applies_at]).
##
## Corundum is what a planet is made of wherever nothing else is said. A populate
## zone that names a KNOWN biome displaces it — colour, detail, and the crack
## carve, in the mesh and in the collision alike, both of which apply this one
## rule. A zone that names no biome (rock_type or colour only) does not: it sits
## on the corundum. Asserted here on the rule itself, without a chunk build.
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
