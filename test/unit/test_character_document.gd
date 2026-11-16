extends GutTest

## CharacterDocument (the named JSON a character is kept as) and CharacterMigrations (its versions).

const SAMPLE_V1: String = "res://test/data/character/v1.json"
## The look test/data/character/v1.json was written from (CharacterAppearance.random(6)), as its replicated string.
const SAMPLE_V1_LOOK: String = "BuI4mwAAAADdAAAAAAAAAGl7mwAM5yYA_woAAf8AAChSL0l4gVUlJItRAB8FAhgA___Jh2SZ_wA1COcJ5A0UDy8QExEYFOsZ" \
		+ "LR8wJOcmIygVLOgtJzAgMug1FDYPN_VDfETsRSpKKk3cTuZP21DmURVWIllbWhpcGV7lX9Rg72HqYvVjAmTLZSxmHWcYaOBpO2r7awZsEm3pb" \
		+ "tFvKHABce1yJQ"


func _sample() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(SAMPLE_V1))


func test_the_version_and_the_migrations_agree() -> void:
	assert_eq(CharacterDocument.VERSION, 1 + CharacterMigrations.steps().size(), "one step per version past the first")


func test_a_look_comes_back_exactly_through_its_document() -> void:
	for s in range(1, 501):
		var look: CharacterAppearance = CharacterAppearance.random(s)
		var text: String = CharacterDocument.stringify(CharacterDocument.to_document(look))
		var back: Dictionary = CharacterDocument.parse(text)
		assert_eq(back["error"], "", "seed %d read" % s)
		assert_eq(back["warnings"], [], "seed %d: every name known" % s)
		if back["look"] == null or (back["look"] as CharacterAppearance).encode() != look.encode():
			fail_test("seed %d does not come back the same" % s)
			return
	pass_test("500 random looks come back byte for byte")


func test_the_frozen_version_1_document_still_reads() -> void:
	var back: Dictionary = CharacterDocument.from_document(_sample())
	assert_eq(back["error"], "")
	assert_eq(back["from"], 1)
	assert_eq(back["warnings"], [])
	assert_eq((back["look"] as CharacterAppearance).encode(), SAMPLE_V1_LOOK, "the same character as when it was written")


func test_choices_are_kept_by_name_not_position() -> void:
	var doc: Dictionary = _sample()
	assert_eq(doc["hair"]["style"], "crest")
	assert_eq(doc["outfit"], "male_casual01")
	assert_true((doc["sliders"] as Dictionary).has("Waist_GluteSize"), "a slider by its key")
	assert_true((doc["origins"] as Dictionary).has("Race_MiddleEastern"), "an origin by its name")
	assert_eq(doc["hair"]["cut"]["part"], "CREST", "a parting by its name")


func test_unknown_names_are_skipped_with_a_warning() -> void:
	var doc: Dictionary = _sample()
	doc["sliders"]["Removed_Slider"] = 0.5
	doc["outfit"] = "retired_outfit"
	doc["hair"]["cut"]["tie"] = "BRAID"
	doc["origins"]["Race_Martian"] = 1.0
	var back: Dictionary = CharacterDocument.from_document(doc)
	assert_eq(back["error"], "", "still read")
	assert_eq((back["warnings"] as Array).size(), 4, str(back["warnings"]))
	var look: CharacterAppearance = back["look"]
	assert_eq(look.outfit, 0, "an unknown outfit: the first one")
	assert_eq(look.cut.tie, HairCut.Tie.LOOSE, "an unknown tie: the default one")


func test_missing_fields_take_their_defaults() -> void:
	var back: Dictionary = CharacterDocument.from_document({"format": CharacterDocument.FORMAT, "version": 1})
	assert_eq(back["error"], "")
	var plain := CharacterAppearance.new()
	plain.canonicalise()
	assert_eq((back["look"] as CharacterAppearance).encode(), plain.encode(), "an empty document is the default look")


func test_other_formats_and_newer_versions_are_refused() -> void:
	assert_ne(CharacterDocument.from_document({"version": 1})["error"], "", "no format")
	assert_ne(CharacterDocument.from_document([1, 2])["error"], "", "not a dictionary")
	assert_ne(CharacterDocument.from_document({"format": CharacterDocument.FORMAT})["error"], "", "no version")
	var newer: Dictionary = _sample()
	newer["version"] = CharacterDocument.VERSION + 1
	var back: Dictionary = CharacterDocument.from_document(newer)
	assert_string_contains(back["error"], "newer")
	assert_null(back["look"], "never cut down what a newer game wrote")
	assert_ne(CharacterDocument.parse("{not json")["error"], "")
	assert_ne(CharacterDocument.parse("@@@")["error"], "")


func test_old_look_codes_import_as_they_are() -> void:
	var back: Dictionary = CharacterDocument.parse("  %s\n" % SAMPLE_V1_LOOK)
	assert_eq(back["error"], "")
	assert_eq(back["from"], "compact v%d" % CharacterAppearance.VERSION)
	assert_eq((back["look"] as CharacterAppearance).encode(), SAMPLE_V1_LOOK)


func test_a_migration_renames_and_remaps() -> void:
	# A made-up version 2: a slider renamed, an outfit retired onto another, a field rescaled.
	var to_v2 := func(doc: Dictionary) -> Dictionary:
		var sliders: Dictionary = doc.get("sliders", {})
		if sliders.has("Old_Name"):
			sliders["Waist_GluteSize"] = sliders["Old_Name"]
			sliders.erase("Old_Name")
		if doc.get("outfit") == "gone_outfit":
			doc["outfit"] = "male_casual02"
		doc["skin"]["tone"] = float(doc["skin"]["tone"]) * 0.5
		return doc
	var old: Dictionary = _sample()
	old["sliders"]["Old_Name"] = old["sliders"]["Waist_GluteSize"]
	old["sliders"].erase("Waist_GluteSize")
	old["outfit"] = "gone_outfit"
	old["skin"]["tone"] = 0.8
	var steps: Array[Callable] = [to_v2]
	var migrated: Dictionary = CharacterMigrations.migrate(old, steps)
	assert_eq(migrated["from"], 1)
	assert_eq(migrated["to"], 2)
	assert_eq(migrated["doc"]["version"], 2)
	assert_eq(old["outfit"], "gone_outfit", "the document given is left as it was")
	var back: Dictionary = CharacterDocument.from_document(old, steps)
	assert_eq(back["warnings"], [], "every name found after the step")
	var look: CharacterAppearance = back["look"]
	assert_eq(CharacterDocument._asset("outfit", look.outfit), "male_casual02")
	assert_almost_eq(look.skin_tone, 0.4, 0.003)
	var ref: CharacterAppearance = CharacterAppearance.decode(SAMPLE_V1_LOOK)
	var glute: int = CharacterAppearance.modifier_id("Waist_GluteSize")
	assert_eq(look.modifiers[glute], ref.modifiers[glute], "the renamed slider's value")
