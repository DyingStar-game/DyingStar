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
	a.outfit = -4
	a.modifiers = {1: 0.0, 5: 2.0, 0: -0.5, 100000: 1.0}
	a.canonicalise()
	var once: PackedByteArray = a.to_bytes()
	a.canonicalise()
	assert_eq(a.to_bytes(), once, "canonicalising twice changes nothing")
	assert_gte(a.years(), 18.0, "adults only")
	assert_eq(a.macros["height"], 1.0)
	assert_eq(a.origins[0], 1.0)
	assert_eq(a.hair, CharacterAppearance.choice_count("hair") - 1)
	assert_eq(a.outfit, 0)
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
	var v5: PackedByteArray = a.to_bytes()
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
	var v6: PackedByteArray = a.to_bytes()
	var v5: PackedByteArray = v6.slice(0, CharacterAppearance.HAIR_CUT_AT + HairCut.V5_BYTES) \
			+ v6.slice(CharacterAppearance.HAIR_CUT_AT + HairCut.BYTES)
	v5[0] = 5
	var back: CharacterAppearance = CharacterAppearance.from_bytes(v5)
	assert_not_null(back, "a version 5 look reads")
	assert_eq(back.cut.to_bytes(), a.cut.to_bytes(), "its hair, its low hairline kept")
	assert_eq(back.beard_cut.to_bytes(), a.beard_cut.to_bytes(), "its beard")
	assert_eq(back.modifiers, a.modifiers, "its sliders")


func test_wire_size_is_small() -> void:
	for seed_value in 50:
		var text: String = CharacterAppearance.random(seed_value).encode()
		# FLAME's first 20 directions, and every face slider moves a little (those that would not show are
		# dropped): ~60 of them, up to ~65; plus the six skin details.
		assert_lt(text.length(), 256, "a random look stays a short string (%d chars)" % text.length())


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
	b.outfit = (a.outfit + 1) % CharacterAppearance.choice_count("outfit")
	assert_ne(a.shape_hash(), b.shape_hash(), "another outfit is another mesh")


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
	assert_eq(CharacterAppearance.catalogue()["assets"]["outfit"][CharacterAppearance.preset("default_female").outfit]["gender"], "female")


# Version 6; its hair drawn from hair_stats.json as re-measured with the level hairline and the low one, its flyaways
# from the late fields' own numbers, the nose's bridge (Nose_Dorsum_*) from the late face sliders' (the face as before).
const PINNED_NPC_0001 := "Bt5UegDdAAAAAAAAAAAAAE2CAAAK9SY7_wgAAP8CAFBbUWBRFHCNhZ4ZdV0AAAAT_wAAADeZAAAzAy0GKQjgCzQQGBEcEhcUGx8v" \
		+ "JNQm2SjNLOgtOC_pMBsxIjKvN9c5Czv5PAJA9UPVRORMek0dTy1Q51EhXx1g-2H9YhxjLGT2ZfFm4Ge3aP1pYWrjaxlsAW37bhlvB3DtcfZy3ZHQ"
