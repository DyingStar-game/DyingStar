extends GutTest
## The truck's horn (H) is a sample held as long as the key, a tap giving a short honk: an Ogg, which
## loops without a gap (an MP3 starts with its encoder's silence and ticks at every turn), looped by Sfx3D
## whatever its import says.

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


## A tap: the press and its release reach the server together, and the "on" has to last long enough
## to be sent to the clients -- or the tap makes no sound at all (playtest 2026-11-18).
func test_a_tap_honks_for_a_short_while() -> void:
	var truck := Vehicle.new()
	autofree(truck)
	truck.set_horn(true)
	truck.set_horn(false)
	assert_true(truck._horn_on, "released at once: the horn still blows")
	truck._hold_horn(Vehicle.HORN_MIN_HOLD_S * 0.5)
	assert_true(truck._horn_on, "for its short while")
	truck._hold_horn(Vehicle.HORN_MIN_HOLD_S)
	assert_false(truck._horn_on, "then it stops by itself")


func test_a_held_horn_blows_until_the_key_comes_up() -> void:
	var truck := Vehicle.new()
	autofree(truck)
	truck.set_horn(true)
	truck._hold_horn(Vehicle.HORN_MIN_HOLD_S * 4.0)
	assert_true(truck._horn_on, "held: it goes on past the tap's time")
	truck.set_horn(false)
	assert_false(truck._horn_on, "and stops with the key")


func test_a_second_press_during_a_tap_s_honk_holds_the_horn() -> void:
	var truck := Vehicle.new()
	autofree(truck)
	truck.set_horn(true)
	truck.set_horn(false)
	truck.set_horn(true)  # pressed again, and kept down
	truck._hold_horn(Vehicle.HORN_MIN_HOLD_S * 2.0)
	assert_true(truck._horn_on, "the first tap's release no longer stops it")
