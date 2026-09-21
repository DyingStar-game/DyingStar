extends GutTest
## RockCatalogue reads rocks.json (written by export_rocks.py) and shades a
## zone between the rock's light and dark tints with a deterministic noise.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_rock_catalogue.gd

const RADIUS := 3467000.0


func before_all() -> void:
	RockCatalogue.reload()


func test_catalogue_loads_the_exported_rocks() -> void:
	assert_true(RockCatalogue.has("corundum_blue"), "corundum_blue exported")
	assert_true(RockCatalogue.has("emery"))
	assert_false(RockCatalogue.has("kryptonite"))
	assert_gt(RockCatalogue.slugs().size(), 10)


func test_colours_and_impurities_come_through() -> void:
	var pair := RockCatalogue.colors_of("corundum_blue")
	assert_eq(pair.size(), 2)
	assert_almost_eq((pair[0] as Color).r, Color.html("#82C8E5").r, 1e-6, "light tint")
	assert_almost_eq((pair[1] as Color).b, Color.html("#0F52BA").b, 1e-6, "dark tint")
	var rock := RockCatalogue.get_rock("corundum_blue")
	var elements: Array = []
	for imp in rock["impurities"]:
		elements.append(imp["element"])
	assert_has(elements, "Fe")
	assert_has(elements, "Ti")
	assert_eq(RockCatalogue.night_colors_of("corundum_chameleon").size(), 2, "chameleon has night tints")
	assert_eq(RockCatalogue.night_colors_of("corundum_blue").size(), 0)
	assert_eq(RockCatalogue.core_colors_of("corundum_blue").size(), 2, "blue has a deep hue")
	assert_eq(RockCatalogue.core_colors_of("corundum_yellow").size(), 0, "yellow is all Fe3+")


func test_hercynite_is_underground_only() -> void:
	assert_false(RockCatalogue.is_surface("hercynite_oxidised"))
	assert_true(RockCatalogue.is_surface("corundum_blue"))


func test_tint_stays_between_the_two_colours_and_is_deterministic() -> void:
	var pair := RockCatalogue.colors_of("corundum_blue")
	var lo: Color = pair[0]
	var hi: Color = pair[1]
	var seen_low := false
	var seen_high := false
	for i in 400:
		var dir := Vector3(sin(i * 0.37), cos(i * 0.53), sin(i * 0.11 + 1.0)).normalized()
		var c := RockCatalogue.tint(dir, RADIUS, "corundum_blue")
		for ch in 3:
			var a := minf(lo[ch], hi[ch]) - 1e-6
			var b := maxf(lo[ch], hi[ch]) + 1e-6
			assert_between(c[ch], a, b, "channel %d inside the range" % ch)
		# Same input, same output — no state, no RNG.
		assert_eq(c, RockCatalogue.tint(dir, RADIUS, "corundum_blue"))
		var t := (c.r - lo.r) / (hi.r - lo.r) if not is_equal_approx(hi.r, lo.r) else 0.5
		seen_low = seen_low or t < 0.4
		seen_high = seen_high or t > 0.6
	assert_true(seen_low and seen_high, "the zone shows both ends of the range, not one flat colour")


func test_unknown_rock_returns_the_fallback() -> void:
	assert_eq(RockCatalogue.tint(Vector3.UP, RADIUS, "nope", Color.RED), Color.RED)
