extends GutTest
## The truck's horn (H) is a sample held as long as the key: an Ogg, which loops without a gap (an MP3
## starts with its encoder's silence and ticks at every turn), looped by Sfx3D whatever its import says.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"
const HORN := "res://assets/_universe/audio/sfx/vehicles/ground/truck-horn-loop.ogg"


func test_the_truck_honks_its_looping_sample() -> void:
	var state := (load(TRUCK) as PackedScene).get_state()
	var horn: AudioStream = null
	for i in state.get_node_property_count(0):
		if state.get_node_property_name(0, i) == &"sfx_horn":
			horn = state.get_node_property_value(0, i) as AudioStream
	assert_not_null(horn, "the truck's scene sets sfx_horn")
	if horn == null:
		return
	assert_eq(horn.resource_path, HORN)
	assert_true(horn is AudioStreamOggVorbis, "an Ogg: no tick where the loop turns")
	assert_true(FileAccess.file_exists(HORN.get_basename() + ".txt"), "with its credit beside it")
	var held: AudioStream = Sfx3D.as_looping(horn)
	assert_true(bool(held.get("loop")), "held, it keeps going")
	assert_false(bool(horn.get("loop")), "and the sample itself is left as imported")
