extends GutTest
## Regression suite for listing celestial bodies in an EXPORTED build.
##
## SystemScenes.body_files() listed `res://scenes/systems/<system>` with DirAccess and kept only the
## names ending in .tscn or .scn. That works in the editor and matches NOTHING once exported: Godot
## moves the binary scene under res://.godot/exported/ and leaves a `<name>.tscn.remap` in its place.
##
## Measured in the shipped client PCK (2630 entries): scenes/systems/tarsis holds nineteen
## `tarsis_*.tscn.remap`, zero .tscn and zero .scn. Every body vanished, then every system with them
## — systems() only counts a directory that holds a body — and the teleporter screen read
## "No system scenes found under res://scenes/systems." while the editor showed the full list. The
## star chart (StarMap) went empty the same way, for the same reason.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://test/unit -gtest=test_system_scenes.gd

## A system that exists on disk, for the non-regression checks.
const KNOWN_SYSTEM := "tarsis"
## One body of that system. Deliberately one name rather than a count: adding a planet must not turn
## this suite red.
##
## ⚠️ Not tarsis_3: its scene pulls scenes/planet/atmospheres/tarsis_3.tres, and loading that headless
## logs "invalid UID … using text path instead" — the uid cache is not populated in a `-s` script run.
## The load still succeeds, but GUT counts any engine error as a failure of the test in flight.
const KNOWN_BODY := "tarsis_1"


## What an exported build actually offers. This is the case that shipped broken.
func test_remap_entry_keeps_the_editor_name() -> void:
	assert_eq(SystemScenes.scene_name_of("tarsis_4.tscn.remap"), "tarsis_4.tscn")


func test_plain_scene_name_passes_through() -> void:
	assert_eq(SystemScenes.scene_name_of("tarsis_4.tscn"), "tarsis_4.tscn")


## body_files() accepts a binary scene, so the normaliser has to as well.
func test_binary_scene_passes_through() -> void:
	assert_eq(SystemScenes.scene_name_of("tarsis_4.scn"), "tarsis_4.scn")
	assert_eq(SystemScenes.scene_name_of("tarsis_4.scn.remap"), "tarsis_4.scn")


## A script or a data file sitting beside the scenes is not a body — raw or remapped.
func test_non_scene_entries_are_rejected() -> void:
	assert_eq(SystemScenes.scene_name_of("system_scenes.gd"), "")
	assert_eq(SystemScenes.scene_name_of("system_scenes.gd.remap"), "")
	assert_eq(SystemScenes.scene_name_of("tarsis_4_poi.json"), "")
	assert_eq(SystemScenes.scene_name_of(""), "")


## ⚠️ The second trap, and why the suffix is STRIPPED rather than merely accepted: a key is the
## file basename, and it has to come out "tarsis_3_1". Keeping the raw entry would give
## "tarsis_3_1.tscn", and body_properties() would then look for "tarsis_3_1.tscn.tscn" — nothing.
func test_key_survives_the_round_trip() -> void:
	assert_eq(SystemScenes.scene_name_of("tarsis_3_1.tscn.remap").get_basename(), "tarsis_3_1")


## Non-regression in the editor, where the files are plain .tscn: the listing still works.
func test_editor_listing_still_finds_the_bodies() -> void:
	var keys: PackedStringArray = SystemScenes.body_keys(KNOWN_SYSTEM)
	assert_false(keys.is_empty(), "no body listed under %s" % SystemScenes.system_dir(KNOWN_SYSTEM))
	assert_true(keys.has(KNOWN_BODY), "%s missing from %s" % [KNOWN_BODY, keys])
	assert_true(SystemScenes.systems().has(KNOWN_SYSTEM), "%s not listed as a system" % KNOWN_SYSTEM)


## body_properties() rebuilds the path from the key instead of keeping the file name, so it is worth
## pinning that it still reaches the scene at all.
func test_body_properties_reach_the_scene() -> void:
	var props: Dictionary = SystemScenes.body_properties(KNOWN_SYSTEM, KNOWN_BODY)
	assert_false(props.is_empty(), "no saved property read for %s" % KNOWN_BODY)
	assert_true(props.has("display_name"), "display_name missing from %s" % KNOWN_BODY)
