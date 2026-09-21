extends GutTest
## RockImpurity: the per-element concentration fields (mountain core, carve
## depth, strata) and the per-rock mixing rule read from the catalogue — the
## one shading every corundum gets, red, blue or milky.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_rock_impurity.gd

const RADIUS := 3467000.0
const DIR := Vector3(0.6, 0.48, -0.64)


func before_all() -> void:
	RockCatalogue.reload()
	RockImpurity.reset()


func _dirs(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in n:
		out.append(Vector3(sin(i * 0.37), cos(i * 0.53), sin(i * 0.11 + 1.0)).normalized())
	return out


func test_rules_come_from_the_catalogue_data() -> void:
	var blue := RockImpurity.rule_of("corundum_blue")
	assert_true(blue["pair"], "Fe + Ti: the charge-transfer pair")
	var red := RockImpurity.rule_of("corundum_red")
	assert_false(red["pair"])
	var els: PackedStringArray = red["elements"]
	var ws: PackedFloat64Array = red["weights"]
	assert_gt(ws[els.find("Cr")], ws[els.find("Fe")], "chromium rules a ruby despite fewer ppm")
	var orange := RockImpurity.rule_of("corundum_orange")
	els = orange["elements"]
	ws = orange["weights"]
	assert_gt(ws[els.find("Fe")], ws[els.find("Cr")], "iron rules an orange")
	var white := RockImpurity.rule_of("corundum_white")
	assert_eq((white["elements"] as PackedStringArray).size(), 0, "no impurity at all")
	assert_eq((RockImpurity.rule_of("corundum_milky")["elements"] as PackedStringArray).size(), 1)


func test_concentration_is_bounded_deterministic_and_rises_with_the_provenance() -> void:
	for slug in ["corundum_red", "corundum_blue", "corundum_white", "corundum_milky", "emery"]:
		var up := 0
		var n := 0
		for d in _dirs(120):
			var plain := RockImpurity.concentration(slug, d, RADIUS, 30.0, 0.0, 0.0)
			var crest := RockImpurity.concentration(slug, d, RADIUS, 30.0, 1.0, 0.0)
			var floor_ := RockImpurity.concentration(slug, d, RADIUS, 30.0, 0.0, 150.0)
			assert_between(plain, 0.0, 1.0)
			assert_between(crest, 0.0, 1.0)
			assert_eq(plain, RockImpurity.concentration(slug, d, RADIUS, 30.0, 0.0, 0.0), "pure")
			n += 1
			if slug != "corundum_white":
				if crest >= plain and floor_ >= plain:
					up += 1
			else:
				assert_eq(crest, plain, "a pure rock has no element to enrich")
		if slug != "corundum_white":
			assert_eq(up, n, "%s: a crest and a crevasse floor are never paler than the plain" % slug)


func test_the_pair_needs_titanium_and_the_source_bound_elements_follow_the_core() -> void:
	# Blue at the plain: sqrt(fe·ti) with the source-bound Ti low → paler than
	# a single-element iron rock at the same point; on the crest Ti is there.
	var d := DIR.normalized()
	var m := SurfaceNoise.mottle(d, RADIUS, RockCatalogue.BLOTCH_M, RockCatalogue.STREAK_M)
	var fe0 := RockImpurity.element_field("Fe", m, 0.0, 0.0)
	var ti0 := RockImpurity.element_field("Ti", m, 0.0, 0.0)
	var cr1 := RockImpurity.element_field("Cr", m, 1.0, 0.0)
	assert_lt(ti0, fe0, "titanium is source-bound, iron is everywhere")
	assert_gt(cr1 - RockImpurity.element_field("Cr", m, 0.0, 0.0),
			RockImpurity.element_field("Fe", m, 1.0, 0.0) - fe0,
			"the core lifts chromium more than iron")
	assert_almost_eq(RockImpurity.provenance(0.4, 75.0), 0.9, 1e-9)


func test_strata_band_and_blend() -> void:
	var lo := 1.0 - RockImpurity.STRATA_AMP
	var hi := 1.0 + RockImpurity.STRATA_AMP
	var d := DIR.normalized()
	var distinct := {}
	var prev := RockImpurity.strata(d, RADIUS, 0.0)
	var jumps := 0
	for i in 400:
		var h := float(i) * 2.0   # 800 m of relief, ~11 beds
		var v := RockImpurity.strata(d, RADIUS, h)
		assert_between(v, lo, hi)
		distinct[snappedf(v, 0.001)] = true
		if absf(v - prev) > 0.2:
			jumps += 1
		prev = v
	assert_gt(distinct.size(), 4, "several beds along the height")
	assert_eq(jumps, 0, "beds blend into each other, no hard step at 2 m pitch")


func test_tint_uses_the_rock_colours_and_the_dust_pales_the_flats_of_a_massif() -> void:
	var pair := RockCatalogue.colors_of("corundum_red")
	var d := DIR.normalized()
	var face := RockImpurity.tint("corundum_red", d, RADIUS, 200.0, 1.0, 0.0, 0.5)
	var flat := RockImpurity.tint("corundum_red", d, RADIUS, 200.0, 1.0, 0.0, 0.0)
	var plain_flat := RockImpurity.tint("corundum_red", d, RADIUS, 20.0, 0.0, 0.0, 0.0)
	# The face is a pure light→dark blend of the rock's own colours.
	var c := RockImpurity.concentration("corundum_red", d, RADIUS, 200.0, 1.0, 0.0)
	assert_eq(face, (pair[0] as Color).lerp(pair[1], c))
	assert_gt(flat.r + flat.g + flat.b, face.r + face.g + face.b, "dust pales the flat")
	assert_eq(RockImpurity.dust_weight(0.0, 0.0), 0.0, "no massif, no dust")
	assert_eq(plain_flat, (pair[0] as Color).lerp(pair[1],
			RockImpurity.concentration("corundum_red", d, RADIUS, 20.0, 0.0, 0.0)))
	assert_eq(RockImpurity.tint("nonexistent", d, RADIUS, 0.0, 0.0, 0.0, 0.0, Color.MAGENTA),
			Color.MAGENTA, "fallback for a rock without colours")


func test_ppm_places_the_field_in_the_declared_range() -> void:
	var d := DIR.normalized()
	var plain := RockImpurity.ppm("corundum_red", "Cr", d, RADIUS, 0.0, 0.0)
	var crest := RockImpurity.ppm("corundum_red", "Cr", d, RADIUS, 1.0, 0.0)
	assert_between(plain, 1500.0, 4500.0)
	assert_between(crest, 1500.0, 4500.0)
	assert_gt(crest, plain, "the crest is the richer ore")
	assert_eq(RockImpurity.ppm("corundum_red", "Ti", d, RADIUS, 1.0, 0.0), 0.0, "no titanium in a ruby")


func test_veins_enrich_the_mobile_elements_near_a_crack_wall_only() -> void:
	assert_eq(RockImpurity.vein_weight(INF), 0.0, "no crack network: no vein")
	assert_almost_eq(RockImpurity.vein_weight(0.0), 1.0, 1e-9, "on the wall")
	assert_almost_eq(RockImpurity.vein_weight(-5.0), 1.0, 1e-9, "inside the crack: the wall's value")
	assert_eq(RockImpurity.vein_weight(RockImpurity.VEIN_HALO_M), 0.0, "past the halo")
	assert_gt(RockImpurity.vein_weight(10.0), RockImpurity.vein_weight(30.0), "fades outward")
	var m := 0.4
	assert_gt(RockImpurity.element_field("Cr", m, 0.0, 0.0, 1.0),
			RockImpurity.element_field("Cr", m, 0.0, 0.0, 0.0), "chromium travels in the fluids")
	assert_gt(RockImpurity.element_field("Fe", m, 0.0, 0.0, 1.0),
			RockImpurity.element_field("Fe", m, 0.0, 0.0, 0.0), "iron too")
	assert_eq(RockImpurity.element_field("Ti", m, 0.0, 0.0, 1.0),
			RockImpurity.element_field("Ti", m, 0.0, 0.0, 0.0), "titanium is immobile")
	var d := DIR.normalized()
	for slug in ["corundum_red", "corundum_blue", "corundum_milky"]:
		assert_gte(RockImpurity.concentration(slug, d, RADIUS, 30.0, 0.0, 0.0, 0.0),
				RockImpurity.concentration(slug, d, RADIUS, 30.0, 0.0, 0.0, INF),
				"%s: the wall is never paler than the block" % slug)
	assert_eq(RockImpurity.concentration("corundum_white", d, RADIUS, 30.0, 0.0, 0.0, 0.0),
			RockImpurity.concentration("corundum_white", d, RADIUS, 30.0, 0.0, 0.0, INF),
			"nothing to carry in a pure rock")


func test_ore_richness_lifts_the_zone_target_with_the_provenance() -> void:
	assert_eq(RockImpurity.ore_richness(0.5, 0.0, 0.0), 0.5, "the plain keeps the zone's target")
	assert_gt(RockImpurity.ore_richness(0.5, 1.0, 0.0), 0.5, "a crest")
	assert_gt(RockImpurity.ore_richness(0.5, 0.0, 150.0), 0.5, "a crevasse floor")
	assert_gt(RockImpurity.ore_richness(0.5, 1.0, 150.0), RockImpurity.ore_richness(0.5, 1.0, 0.0),
			"a crevasse in a massif cumulates")
	assert_eq(RockImpurity.ore_richness(0.9, 1.5, 300.0), 1.0, "capped")
	assert_eq(RockImpurity.ore_richness(0.0, 0.0, 0.0), 0.0)


func test_iron_valence_slides_a_green_to_its_deep_hue_and_leaves_a_ruby_alone() -> void:
	assert_eq(RockCatalogue.core_colors_of("corundum_green").size(), 2, "green declares a deep hue")
	assert_eq(RockCatalogue.core_colors_of("corundum_red").size(), 0, "a ruby has one hue")
	assert_eq(RockImpurity.valence(0.0, 0.0), 0.0, "the plain is all Fe3+")
	assert_eq(RockImpurity.valence(1.0, 0.0), 1.0, "a crest is fully reduced")
	assert_between(RockImpurity.valence(0.3, 30.0), 0.0, 1.0)
	var d := DIR.normalized()
	var shallow := RockCatalogue.colors_of("corundum_green")
	var deep := RockCatalogue.core_colors_of("corundum_green")
	var c_plain := RockImpurity.concentration("corundum_green", d, RADIUS, 20.0, 0.0, 0.0)
	assert_eq(RockImpurity.tint("corundum_green", d, RADIUS, 20.0, 0.0, 0.0, 0.5),
			(shallow[0] as Color).lerp(shallow[1], c_plain), "the plain keeps the shallow hue")
	var c_crest := RockImpurity.concentration("corundum_green", d, RADIUS, 900.0, 1.0, 0.0)
	assert_eq(RockImpurity.tint("corundum_green", d, RADIUS, 900.0, 1.0, 0.0, 0.5),
			(deep[0] as Color).lerp(deep[1], c_crest), "the crest face is the deep hue")
	# Blue-green on the crest: more blue than green relative to the plain.
	var plain := RockImpurity.tint("corundum_green", d, RADIUS, 20.0, 0.0, 0.0, 0.5)
	var crest := RockImpurity.tint("corundum_green", d, RADIUS, 900.0, 1.0, 0.0, 0.5)
	assert_gt(crest.b / maxf(crest.g, 1e-6), plain.b / maxf(plain.g, 1e-6), "Fe2+ pulls it blue")
	var pair := RockCatalogue.colors_of("corundum_red")
	var c_red := RockImpurity.concentration("corundum_red", d, RADIUS, 900.0, 1.0, 0.0)
	assert_eq(RockImpurity.tint("corundum_red", d, RADIUS, 900.0, 1.0, 0.0, 0.5),
			(pair[0] as Color).lerp(pair[1], c_red), "a ruby only deepens")
