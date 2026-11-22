extends GutTest
## CharacterAppearance: the replicated look. Its bytes must survive the trip, stay canonical (so two
## machines hash the same look the same), refuse what is not a look, keep every body adult, and draw the
## same random person from the same seed everywhere -- an NPC is drawn from its uuid on each client.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_character_appearance.gd -gexit


func test_round_trip_is_exact() -> void:
	for seed_value in 30:
		var a: CharacterAppearance = CharacterAppearance.random(seed_value)
		var text: String = a.encode()
		var b: CharacterAppearance = CharacterAppearance.decode(text)
		assert_not_null(b, "seed %d decodes" % seed_value)
		assert_true(a.equals(b), "seed %d: same look after the trip" % seed_value)
		assert_eq(b.encode(), text, "seed %d: same text after the trip" % seed_value)


func test_canonical_form_is_idempotent() -> void:
	var a := CharacterAppearance.new()
	a.macros["height"] = 1.7
	a.origins[0] = 4.0
	a.hair = 999
	a.garments = [[-4, 0], [100000, 3], [0, 999], [0, 1]]
	a.modifiers = {1: 0.0, 5: 2.0, 0: -0.5, 100000: 1.0}
	a.canonicalise()
	var once: PackedByteArray = a.to_bytes()
	a.canonicalise()
	assert_eq(a.to_bytes(), once, "canonicalising twice changes nothing")
	assert_gte(a.years(), 18.0, "adults only")
	assert_eq(a.macros["height"], 1.0)
	assert_eq(a.origins[0], 1.0)
	assert_eq(a.hair, CharacterAppearance.choice_count("hair") - 1)
	assert_eq(a.garments, [[0, 255]], "unknown garments and the second of a pair dropped, tint on a byte")
	assert_eq(a.modifiers.keys(), [0, 5], "zero and unknown sliders dropped, sorted")


func test_garbage_is_refused() -> void:
	for text in ["", "!!!!", "AAAA", "not base64 at all", "AQ", "A".repeat(400)]:
		assert_null(CharacterAppearance.decode(text), "'%s' is not a look" % text.left(20))
	var b: PackedByteArray = CharacterAppearance.random(1).to_bytes()
	b[0] = 99
	assert_null(CharacterAppearance.from_bytes(b), "unknown version refused")
	var short: PackedByteArray = CharacterAppearance.random(1).to_bytes()
	short.resize(short.size() - 1)
	assert_null(CharacterAppearance.from_bytes(short), "truncated slider list refused")


func test_a_version_4_look_still_reads() -> void:
	# Version 4 stored a cut of 10 bytes (no low hairline): the same look without its byte 46, at version 4.
	var a: CharacterAppearance = CharacterAppearance.random(7)
	a.hair = 1
	a.beard = 1
	a.cut.low_line = 0.0  # version 4 had none
	a.cut.flyaways = 0.0
	a.canonicalise()
	var v5: PackedByteArray = _without_garments(a)
	var v4: PackedByteArray = v5.slice(0, CharacterAppearance.HAIR_CUT_AT + HairCut.V4_BYTES) \
			+ v5.slice(CharacterAppearance.HAIR_CUT_AT + HairCut.BYTES)
	v4[0] = 4
	var back: CharacterAppearance = CharacterAppearance.from_bytes(v4)
	assert_not_null(back, "a version 4 look reads")
	assert_eq(back.cut.to_bytes(), a.cut.to_bytes(), "its hair")
	assert_eq(back.beard_cut.to_bytes(), a.beard_cut.to_bytes(), "its beard")
	assert_eq(back.modifiers, a.modifiers, "its sliders")
	assert_eq(back.cut.low_line, 0.0, "no low hairline")


func test_a_version_5_look_still_reads() -> void:
	# Version 5 stored a cut of 11 bytes (no flyaways): the same look without its byte 47, at version 5.
	var a: CharacterAppearance = CharacterAppearance.random(9)
	a.hair = 1
	a.beard = 1
	a.cut.low_line = 0.4
	a.cut.flyaways = 0.0
	a.canonicalise()
	var v6: PackedByteArray = _without_garments(a)
	var v5: PackedByteArray = v6.slice(0, CharacterAppearance.HAIR_CUT_AT + HairCut.V5_BYTES) \
			+ v6.slice(CharacterAppearance.HAIR_CUT_AT + HairCut.BYTES)
	v5[0] = 5
	var back: CharacterAppearance = CharacterAppearance.from_bytes(v5)
	assert_not_null(back, "a version 5 look reads")
	assert_eq(back.cut.to_bytes(), a.cut.to_bytes(), "its hair, its low hairline kept")
	assert_eq(back.beard_cut.to_bytes(), a.beard_cut.to_bytes(), "its beard")
	assert_eq(back.modifiers, a.modifiers, "its sliders")


## [param a]'s bytes with no garments after the sliders, as versions 6 and before ended (their version byte to set).
func _without_garments(a: CharacterAppearance) -> PackedByteArray:
	var b: PackedByteArray = a.to_bytes()
	return b.slice(0, b.size() - 1 - 3 * a.garments.size())


func test_wire_size_is_small() -> void:
	for seed_value in 50:
		var text: String = CharacterAppearance.random(seed_value).encode()
		# FLAME's 50 directions and 6 to 9 body sliders; plus the six skin details. A European face also carries the
		# nose's and jaw's sliders its types are made of (FaceTypes): 13 more.
		assert_lt(text.length(), 300, "a random look stays a short string (%d chars)" % text.length())


func test_random_is_deterministic_and_pinned() -> void:
	assert_eq(CharacterAppearance.random(42).encode(), CharacterAppearance.random(42).encode())
	assert_ne(CharacterAppearance.random(42).encode(), CharacterAppearance.random(43).encode())
	# Pinned: an NPC's face is drawn from its uuid on every client. If this string changes, every NPC and
	# every player without a saved look changes face -- only on purpose.
	assert_eq(CharacterAppearance.from_uuid("npc-0001").encode(), PINNED_NPC_0001)


func test_colours_do_not_change_the_shape() -> void:
	var a: CharacterAppearance = CharacterAppearance.random(5)
	var b: CharacterAppearance = a.duplicate_appearance()
	b.skin_tone = 0.9
	b.hair_eumelanin = 0.0
	b.hair_grey = 1.0
	b.eye_colour = 3
	assert_eq(a.shape_hash(), b.shape_hash(), "colours never rebuild a mesh")
	assert_ne(a.look_hash(), b.look_hash())
	b.garments = a.garments.map(func(g: Array) -> Array: return [g[0], 77])
	b.canonicalise()
	assert_eq(a.shape_hash(), b.shape_hash(), "a garment's tint never rebuilds a mesh")
	var other: String = "mh_male_casualsuit02" if CharacterAppearance.garment_index("mh_male_casualsuit01") in a.garments.map(
			func(g: Array) -> int: return g[0]) else "mh_male_casualsuit01"
	b.garments = [[CharacterAppearance.garment_index(other), 0]]
	b.canonicalise()
	assert_ne(a.shape_hash(), b.shape_hash(), "other garments are another mesh")


func test_random_looks_are_varied_and_plausible() -> void:
	var women: int = 0
	var bearded_men: int = 0
	var men: int = 0
	for seed_value in 200:
		var a: CharacterAppearance = CharacterAppearance.random(seed_value)
		assert_gte(a.years(), 18.0)
		if a.is_female():
			women += 1
			assert_eq(a.beard, 0, "no beard on women")
		else:
			men += 1
			bearded_men += 1 if a.beard > 0 else 0
	assert_between(women, 70, 130, "about half are women")
	assert_between(bearded_men, int(men * 0.25), int(men * 0.55), "about 40 % of men are bearded")


func test_a_look_of_the_first_body_is_refused() -> void:
	# Version 1 described the MakeHuman body: its sliders mean nothing on this one.
	var old := PackedByteArray()
	old.resize(25)
	old[0] = 1
	assert_null(CharacterAppearance.from_bytes(old))


func test_presets_are_a_man_and_a_woman() -> void:
	assert_false(CharacterAppearance.preset("default_male").is_female())
	assert_true(CharacterAppearance.preset("default_female").is_female())
	var woman: CharacterAppearance = CharacterAppearance.preset("default_female")
	assert_false(woman.garments.is_empty(), "dressed")
	for e: Dictionary in woman.worn_garments():
		assert_eq(e["gender"], "female", "%s suits a woman" % e["id"])


func test_garments_travel_with_their_tints() -> void:
	var a: CharacterAppearance = CharacterAppearance.random(3)
	assert_false(a.garments.is_empty(), "a random look is dressed")
	a.garments[0][1] = 200
	var back: CharacterAppearance = CharacterAppearance.decode(a.encode())
	assert_eq(back.garments, a.garments)


func test_a_version_6_look_wears_its_outfit_as_garments() -> void:
	# Version 6 had no garments: its outfit at byte 29, nothing after the sliders.
	var a: CharacterAppearance = CharacterAppearance.random(11)
	var v6: PackedByteArray = _without_garments(a)
	v6[0] = 6
	v6[29] = 4  # female_casual01
	var back: CharacterAppearance = CharacterAppearance.from_bytes(v6)
	assert_not_null(back, "a version 6 look reads")
	var ids: Array = back.worn_garments().map(func(e: Dictionary) -> String: return e["id"])
	assert_eq(ids, ["mh_female_casualsuit01", "mh_shoes04_female"], "the outfit's suit and shoes")
	assert_eq(back.modifiers, a.modifiers, "its sliders")


func test_garments_that_cannot_go_together_are_taken_off() -> void:
	var a := CharacterAppearance.new()
	var suit_a: int = CharacterAppearance.garment_index("mh_male_casualsuit01")
	var suit_b: int = CharacterAppearance.garment_index("mh_male_casualsuit02")
	var shoes: int = CharacterAppearance.garment_index("mh_shoes03")
	a.garments = [[suit_b, 0], [suit_a, 0], [shoes, 0]]
	a.canonicalise()
	var expected: Array = [[suit_b, 0], [shoes, 0]]
	expected.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	assert_eq(a.garments, expected, "two suits on the same place: the first given is kept")


func test_a_look_is_never_naked() -> void:
	var shoes: int = CharacterAppearance.garment_index("mh_shoes03")
	for female in [false, true]:
		var a := CharacterAppearance.new()
		a.macros["gender"] = 0.0 if female else 1.0
		a.garments = [[shoes, 0]]
		a.canonicalise()
		var once: PackedByteArray = a.to_bytes()
		assert_eq(CharacterAppearance.bare_zones(a.garments), [], "torso and legs covered")
		assert_true(a.garments.has([shoes, 0]), "what it wore kept")
		for e: Dictionary in a.worn_garments():
			if e["id"] != "mh_shoes03":
				assert_eq(e["gender"], "female" if female else "male", "%s suits the body" % e["id"])
		a.garments = []
		a.canonicalise()
		assert_eq(a.garments.size(), 1, "nothing worn: one suit put on, no shoes")
		a.garments.append([shoes, 0])
		a.canonicalise()
		assert_eq(a.to_bytes(), once, "the same suit every time")
	var dressed: Array = CharacterAppearance.dressed([[shoes, 0]], "male")
	assert_eq(CharacterAppearance.dressed(dressed, "male"), dressed, "dressing twice changes nothing")


func test_random_garments_suit_the_body() -> void:
	for seed_value in 40:
		var a: CharacterAppearance = CharacterAppearance.random(seed_value)
		var gender: String = "female" if a.is_female() else "male"
		var covered: Dictionary = {}
		for e: Dictionary in a.worn_garments():
			assert_true(e["gender"] == gender or e["gender"] == "any", "seed %d: %s suits the body" % [seed_value, e["id"]])
			for z: String in e["zones"]:
				covered[z] = true
		assert_true(covered.has("3") and covered.has("8"), "seed %d: torso and legs covered" % seed_value)


# 2026-11-20: a face of FLAME's 50 directions alone, no catalogue face slider (rated by eye: the drawn sliders made
# pouts and doll's eyes); its hair and outfit as before, its body sliders from the draws the face no longer takes.
# 2026-11-21: npc-0001 is an East Asian man: his face is now drawn from FFHQ's East Asian types (FaceTypes), the
# rest of the look as before.
# Then: East Asian types learnt again over the corrected origin features, the photo fit's own lean taken off.
const PINNED_NPC_0001 := "B95UegDdAAAAAAAAAAAAAE2CAAAK9SY7_wgAAP8AAG1rZ2BBFHCNhZ4ZdV0AAAAT_wAAADeZAABECN8TFhQBFSkWIBoBHQ85" \
		+ "EkL_Q_lEM0aiRyVI6VASXPZd-l7cXxRgBWEnYixj22TRZQNmMWdQaBZp72rRay1sMm0Lbt5vNnATccdy3XOvdNx12nYcd_d4LHkdevB7BHzTfTt-" \
		+ "6n84gOaB5ILvg8-EKoX-hqqHHIj3iQqKM4sxjJeNjo4mj_iQ-AIEAAAFAAA"
