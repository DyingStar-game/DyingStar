extends GutTest

## NativeScript.load_usable: a C# twin is used only when an instance of it really has the methods its
## caller will call — so a missing or STALE assembly falls back to the GDScript instead of failing on
## the first call, as it did with MountainZoneNative on 2026-09-23.
##
## Booleans rather than assert_null / assert_not_null: GUT cannot print a C# script and fails trying.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_native_script.gd

const VORONOI: String = "res://scenes/planet/native/CrackVoronoiNative.cs"


func test_a_missing_file_is_not_usable() -> void:
	assert_true(NativeScript.load_usable("res://scenes/planet/native/NoSuchTwin.cs", ["X"]) == null)


func test_a_complete_twin_is_usable() -> void:
	assert_true(NativeScript.load_usable(VORONOI, ["EdgeDn"]) != null,
			"built assembly, method present: the twin is used")


## What a stale assembly looks like from here: the file loads, the instance lacks a method.
func test_a_twin_lacking_a_method_is_not_usable() -> void:
	assert_true(NativeScript.load_usable(VORONOI, ["EdgeDn", "AMethodNotBuiltYet"]) == null,
			"one method missing is enough to keep the GDScript")


func test_a_script_of_another_shape_is_not_usable() -> void:
	assert_true(NativeScript.load_usable("res://scenes/planet/native/native_script.gd", ["EdgeDn"]) == null)


## And the three real twins load with the methods their callers use — with the assembly built.
func test_the_real_twins_are_usable() -> void:
	assert_true(PlanetData.TileFrame.native_available(), "TileFrameNative")
	assert_true(MountainRelief.native_available(), "the mountain twins")
	assert_true(CrackNoise.plain().native != null, "CrackVoronoiNative")
