extends GutTest
## The editor's asset library (bottom panel tab "Library") lists the project's assets by kind and by tag
## with nothing to configure: the kind is the resource's class, the tags come from the folders and from
## the family of a shared material. These checks pin that reading, and the filter the grid applies.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_asset_catalog.gd -gexit

const Catalog := preload("res://addons/dyingstar/asset_library/asset_catalog.gd")

const GARAGE := "res://assets/_universe/structures/industrial/garage.glb"
const RUSTY := "res://assets/_universe/_shared/materials/mat_metal_yellow_rusty/mat_metal_yellow_rusty.tres"
const RUSTY_ALBEDO := "res://assets/_universe/_shared/materials/mat_metal_yellow_rusty/tex_metal_yellow_rusty_albedo.png"
const STEP := "res://assets/_universe/audio/sfx/footsteps/metal/step_metal_01.ogg"
const CRATE := "res://scenes/_universe/props/crate/crate.tscn"


func _entries() -> Array:
	return [
		Catalog.make_entry(GARAGE, &"PackedScene"),
		Catalog.make_entry(RUSTY, &"StandardMaterial3D"),
		Catalog.make_entry(RUSTY_ALBEDO, &"CompressedTexture2D"),
		Catalog.make_entry(STEP, &"AudioStreamOggVorbis"),
		Catalog.make_entry(CRATE, &"PackedScene"),
	]


func _names(entries: Array) -> Array:
	return entries.map(func(entry: Dictionary) -> String: return entry["name"])


func test_the_kind_is_the_resource_s_class() -> void:
	assert_eq(Catalog.category_of(&"CompressedTexture2D", "res://a.png"), Catalog.TEXTURE)
	assert_eq(Catalog.category_of(&"StandardMaterial3D", "res://a.tres"), Catalog.MATERIAL)
	assert_eq(Catalog.category_of(&"ShaderMaterial", "res://a.tres"), Catalog.MATERIAL)
	assert_eq(Catalog.category_of(&"AudioStreamOggVorbis", "res://a.ogg"), Catalog.SOUND)
	assert_eq(Catalog.category_of(&"ArrayMesh", "res://a.mesh"), Catalog.MODEL)
	assert_eq(Catalog.category_of(&"Shader", "res://a.gdshader"), Catalog.SHADER)


func test_a_scene_imported_from_a_model_file_is_a_model() -> void:
	assert_eq(Catalog.category_of(&"PackedScene", GARAGE), Catalog.MODEL)
	assert_eq(Catalog.category_of(&"PackedScene", "res://assets/ship.GLB"), Catalog.MODEL, "whatever the case")
	assert_eq(Catalog.category_of(&"PackedScene", CRATE), Catalog.SCENE)


func test_what_is_not_an_asset_is_left_out() -> void:
	for type: StringName in [&"Resource", &"FontFile", &"GDScript", &"", &"NotAClass"]:
		assert_eq(Catalog.category_of(type, "res://assets/thing.res"), &"", String(type))
	assert_eq(Catalog.make_entry("res://assets/font.ttf", &"FontFile"), {})


func test_planets_and_systems_are_not_assets_to_place() -> void:
	assert_eq(Catalog.make_entry("res://scenes/systems/tarsis/tarsis_3.tscn", &"PackedScene"), {})
	assert_eq(Catalog.make_entry("res://scenes/planet/atmospheres/tarsis_3.tres", &"Resource"), {})
	assert_eq(Catalog.make_entry("res://scenes/planet/pad/pad_blend.png", &"CompressedTexture2D"), {})
	assert_false(Catalog.make_entry(CRATE, &"PackedScene").is_empty(), "the rest of scenes/ is listed")


func test_the_tags_are_the_folders_the_asset_sits_in() -> void:
	assert_eq(Catalog.tags_of(GARAGE), PackedStringArray(["structures", "industrial"]))
	assert_eq(Catalog.tags_of(STEP), PackedStringArray(["audio", "sfx", "footsteps", "metal"]), "every level")
	assert_eq(Catalog.tags_of("res://assets/_universe/_shared/rocks.json"), PackedStringArray(),
			"the root and the grouping folders (_universe, _shared) filter nothing")
	assert_eq(Catalog.tags_of(CRATE), PackedStringArray(["props"]), "a folder named after its asset says nothing")
	assert_eq(Catalog.tags_of("res://assets/logo.png"), PackedStringArray(), "nothing but the root")


func test_a_shared_material_is_tagged_with_its_family() -> void:
	assert_eq(Catalog.tags_of(RUSTY), PackedStringArray(["materials", "metal"]))
	assert_eq(Catalog.tags_of(RUSTY_ALBEDO), PackedStringArray(["materials", "metal"]), "its maps too, from its folder")
	assert_eq(Catalog.tags_of("res://assets/_universe/_shared/materials/mat_broken.tres"),
			PackedStringArray(["materials"]), "no family in the name: none invented")


func test_an_entry_says_what_the_grid_shows() -> void:
	var entry := Catalog.make_entry(GARAGE, &"PackedScene")
	assert_eq(entry["path"], GARAGE)
	assert_eq(entry["name"], "garage")
	assert_eq(entry["type"], "PackedScene")
	assert_eq(entry["category"], Catalog.MODEL)


func test_the_grid_is_filtered_by_category_tag_and_search() -> void:
	var entries := _entries()
	assert_eq(Catalog.filter(entries, Catalog.ALL, "", "").size(), 5)
	assert_eq(_names(Catalog.filter(entries, Catalog.MODEL, "", "")), ["garage"])
	assert_eq(_names(Catalog.filter(entries, Catalog.ALL, "metal", "")),
			["mat_metal_yellow_rusty", "tex_metal_yellow_rusty_albedo", "step_metal_01"])
	assert_eq(_names(Catalog.filter(entries, Catalog.TEXTURE, "metal", "")), ["tex_metal_yellow_rusty_albedo"])
	assert_eq(_names(Catalog.filter(entries, Catalog.ALL, "", "RUSTY albedo")), ["tex_metal_yellow_rusty_albedo"],
			"every word, whatever the case")
	assert_eq(_names(Catalog.filter(entries, Catalog.ALL, "", "industrial")), ["garage"], "a tag is searched too")
	assert_eq(_names(Catalog.filter(entries, Catalog.ALL, "", "footsteps")), ["step_metal_01"], "and the path")
	assert_eq(Catalog.filter(entries, Catalog.ALL, "", "nothing like it").size(), 0)


func test_each_category_counts_its_assets() -> void:
	var counts := Catalog.counts(_entries())
	assert_eq(counts[Catalog.ALL], 5)
	assert_eq(counts[Catalog.MODEL], 1)
	assert_eq(counts[Catalog.SCENE], 1)
	assert_false(counts.has(Catalog.SHADER), "none of them: no entry")


func test_the_tags_of_a_category_come_most_used_first() -> void:
	var entries := _entries()
	assert_eq(Catalog.tag_counts(entries, Catalog.ALL).slice(0, 2), [["metal", 3], ["materials", 2]])
	assert_eq(Catalog.tag_counts(entries, Catalog.MODEL), [["industrial", 1], ["structures", 1]], "then by name")


func test_the_tag_field_completes_what_is_typed() -> void:
	var tags := [["structures", 9], ["industrial", 4], ["metal", 3], ["audio", 2], ["trim_metal", 1]]
	var names := func(pairs: Array) -> Array: return pairs.map(func(pair: Array) -> String: return pair[0])
	assert_eq(names.call(Catalog.matching_tags(tags, "")), ["audio", "industrial", "metal", "structures", "trim_metal"],
			"nothing typed: every tag, in alphabetical order")
	assert_eq(names.call(Catalog.matching_tags(tags, "me")), ["metal", "trim_metal"], "what starts with it first")
	assert_eq(names.call(Catalog.matching_tags(tags, " IND ")), ["industrial"], "whatever the case and the spaces")
	assert_eq(names.call(Catalog.matching_tags(tags, "me", "audio")), ["audio", "metal", "trim_metal"],
			"the tag in use stays, and comes first")
	assert_eq(Catalog.matching_tags(tags, "zzz"), [])


func test_a_level_of_detail_is_named_by_its_suffix() -> void:
	assert_eq(Catalog.lod_of("railing_type01_lod2"), {"base": "railing_type01", "level": 2})
	assert_eq(Catalog.lod_of("Rail_LOD0"), {"base": "Rail", "level": 0}, "whatever the case")
	assert_eq(Catalog.lod_of("garage"), {"base": "garage", "level": -1})
	assert_eq(Catalog.lod_of("shell_lod"), {"base": "shell_lod", "level": -1}, "no number: not a level")
	assert_eq(Catalog.lod_of("lodestar_alan"), {"base": "lodestar_alan", "level": -1})


func test_the_levels_of_detail_of_an_asset_are_one_entry() -> void:
	var folder := "res://assets/_universe/structures/industrial/vehicle_lift/rail/"
	var entries := [
		Catalog.make_entry(folder + "rail_head_lod1.mesh", &"ArrayMesh"),
		Catalog.make_entry(folder + "rail_head_lod0.mesh", &"ArrayMesh"),
		Catalog.make_entry(folder + "rail_head_lod2.mesh", &"ArrayMesh"),
		Catalog.make_entry(folder + "kiosk_base_lod0.mesh", &"ArrayMesh"),
		Catalog.make_entry("res://assets/_universe/structures/buildings/habitat_lod1.glb", &"PackedScene"),
		Catalog.make_entry("res://assets/_universe/structures/buildings/habitat.glb", &"PackedScene"),
		Catalog.make_entry(GARAGE, &"PackedScene"),
	]
	var grouped := Catalog.group_lods(entries)
	assert_eq(_names(grouped), ["rail_head", "kiosk_base_lod0", "habitat", "garage"],
			"one entry an asset, under its name; a lone level keeps its own")
	var levels: Array = grouped[0]["lods"]
	assert_eq(_names(levels), ["rail_head_lod0", "rail_head_lod1", "rail_head_lod2"], "the finest first")
	assert_eq(grouped[0]["path"], folder + "rail_head_lod0.mesh", "the entry is its finest level")
	assert_eq(_names(grouped[2]["lods"]), ["habitat", "habitat_lod1"], "the asset itself is the finest")
	assert_eq((grouped[3]["lods"] as Array).size(), 0, "no level: nothing to show")


func test_icons_and_markers_are_listed_apart_from_textures() -> void:
	assert_eq(Catalog.category_of(&"CompressedTexture2D", "res://assets/textures/map_markers/antenna.png"), Catalog.ICON)
	assert_eq(Catalog.category_of(&"CompressedTexture2D", "res://assets/_universe/vehicles/ui/dashboard_icons/fuel.png"),
			Catalog.ICON)
	assert_eq(Catalog.category_of(&"CompressedTexture2D", "res://assets/textures/poi/mine.png"), Catalog.ICON)
	assert_eq(Catalog.category_of(&"CompressedTexture2D", RUSTY_ALBEDO), Catalog.TEXTURE, "a surface texture")
	assert_eq(Catalog.category_of(&"PackedScene", "res://scenes/ui/menu.tscn"), Catalog.SCENE, "textures only")


## The rule of tools/generate_credits.py, which the pull request check applies.
func test_only_sounds_models_and_textures_under_assets_need_a_credit() -> void:
	assert_true(Catalog.needs_credit(GARAGE))
	assert_true(Catalog.needs_credit(STEP))
	assert_true(Catalog.needs_credit(RUSTY_ALBEDO))
	assert_false(Catalog.needs_credit(RUSTY), "a .tres is generated")
	assert_false(Catalog.needs_credit(CRATE), "a scene, and outside assets")
	assert_false(Catalog.needs_credit("res://scenes/_universe/props/crate/crate.png"), "outside assets")


func test_a_credit_is_a_text_file_of_the_asset_s_name_beside_it() -> void:
	var folders := {
		"res://assets/_universe/structures/industrial": PackedStringArray(["garage.glb", "garage.txt", "depot.glb"]),
		"res://assets/_universe/characters": PackedStringArray(["man_teeth.png", "man_tongue.png", "man.txt", "readme.txt"]),
	}
	var files_in := func(folder: String) -> PackedStringArray: return folders.get(folder, PackedStringArray())
	assert_eq(Catalog.credit_source(GARAGE, files_in), "res://assets/_universe/structures/industrial/garage.txt")
	assert_eq(Catalog.credit_source("res://assets/_universe/structures/industrial/depot.glb", files_in), "",
			"another asset's credit is not this one's")
	assert_eq(Catalog.credit_source("res://assets/_universe/characters/man_teeth.png", files_in),
			"res://assets/_universe/characters/man.txt", "one <prefix>.txt for a set of <prefix>_* files")
	assert_eq(Catalog.credit_source("res://assets/_universe/characters/woman.png", files_in), "",
			"a readme credits nothing")


func test_a_material_manifest_or_a_library_licence_credits_too() -> void:
	var folders := {
		"res://assets/_universe/_shared/materials/mat_metal_yellow_rusty": PackedStringArray(
				["material.json", "tex_metal_yellow_rusty_albedo.png"]),
		"res://assets/library": PackedStringArray(["LICENSE.txt"]),
		"res://assets/library/rocks/big": PackedStringArray(["rock.glb"]),
	}
	var files_in := func(folder: String) -> PackedStringArray: return folders.get(folder, PackedStringArray())
	assert_eq(Catalog.credit_source(RUSTY_ALBEDO, files_in),
			"res://assets/_universe/_shared/materials/mat_metal_yellow_rusty/material.json")
	assert_eq(Catalog.credit_source("res://assets/library/rocks/big/rock.glb", files_in), "res://assets/library/LICENSE.txt",
			"a library's licence, folders above")


func test_the_grid_can_show_only_what_lacks_its_credit() -> void:
	var entries := _entries()
	entries[0]["credit"] = "res://assets/_universe/structures/industrial/garage.txt"
	assert_eq(_names(Catalog.filter(entries, Catalog.ALL, "", "", true)), ["tex_metal_yellow_rusty_albedo", "step_metal_01"],
			"the credited model and what needs no credit are left out")
