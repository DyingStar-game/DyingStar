extends GutTest
## The electric truck's engine: one power sound for switching it on and off, at the running note's
## level rather than far above it, and a running note that rises from silence instead of bursting in.

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"


func test_the_note_rises_from_silence_to_its_level() -> void:
	assert_lt(Vehicle._rise_db(0.0), -50.0, "at the start: silent")
	assert_almost_eq(Vehicle._rise_db(0.5), -6.02, 0.01, "half way: half the amplitude")
	assert_eq(Vehicle._rise_db(1.0), 0.0, "risen: its own level")


func test_the_truck_switches_on_and_off_with_one_sound_not_above_its_note() -> void:
	var truck := (load(TRUCK) as PackedScene).instantiate() as Vehicle
	assert_not_null(truck.sfx_engine_start)
	assert_eq(truck.sfx_engine_stop, truck.sfx_engine_start, "the same sound, on and off")
	assert_lte(truck.sfx_engine_start_db, truck.sfx_engine_idle_db, "no louder than the running note")
	assert_eq(truck.sfx_engine_stop_db, truck.sfx_engine_start_db)
	assert_gt(truck.sfx_engine_idle_fade_in_s, 0.0, "the note spools up")
	truck.free()
