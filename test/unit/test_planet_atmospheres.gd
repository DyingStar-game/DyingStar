extends GutTest
## Every planet the atmosphere generator wrote a profile for wears it: its sky, and the air its vehicles
## drive in (AtmosphereProfile.air_density), are its own wherever a player is sent. Only Tarsis 3 had
## one: a player teleported elsewhere got no air at all. Read from the files: loading a planet scene
## headless pulls its whole terrain.

const ATMOSPHERES := "res://scenes/planet/atmospheres/"
const SYSTEM := "res://scenes/systems/tarsis/"


func test_every_generated_profile_is_worn_by_its_planet() -> void:
	var checked := 0
	for file: String in DirAccess.get_files_at(ATMOSPHERES):
		if not (file.begins_with("tarsis_") and file.ends_with(".tres")):
			continue  # earth_reference: the model's check, not a body of the game
		var scene := SYSTEM + file.get_basename() + ".tscn"
		assert_true(FileAccess.file_exists(scene), "%s has a planet scene" % file)
		var text := FileAccess.get_file_as_string(scene)
		assert_string_contains(text, 'path="%s%s"' % [ATMOSPHERES, file], "%s wears %s" % [scene.get_file(), file])
		assert_string_contains(text, "atmosphere_profile = ExtResource(", "%s: on its PlanetData" % scene.get_file())
		checked += 1
	assert_gte(checked, 8, "the eight planets of Tarsis")


func test_each_profile_carries_its_pressure() -> void:
	for file: String in DirAccess.get_files_at(ATMOSPHERES):
		if file.ends_with(".tres"):
			var air := load(ATMOSPHERES + file) as AtmosphereProfile
			assert_gt(air.surface_pressure_pa, 0.0, "%s: regenerated with its surface pressure" % file)
			assert_gt(air.air_density(0.0), 0.0, "%s: air to drive in" % file)
