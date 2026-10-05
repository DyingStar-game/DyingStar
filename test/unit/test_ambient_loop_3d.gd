extends GutTest
## AmbientLoop3D plays its sound in a loop as soon as it is in the tree, through Sfx3D: on the SFX bus,
## with max_db pinned to its loudness, and without making the shared sample loop elsewhere.


func test_it_loops_on_the_sfx_bus_as_soon_as_it_stands() -> void:
	var sample := _one_second_of_silence()
	var hum := AmbientLoop3D.new()
	hum.stream = sample
	hum.volume_db = -9.0
	add_child_autofree(hum)
	var player := hum.player()
	assert_not_null(player, "a player is built where sound is heard")
	if player == null:
		return
	assert_true(player.playing, "it plays without being asked")
	assert_eq(player.bus, Sfx3D.SFX_BUS, "the SFX volume slider moves it")
	assert_eq(player.max_db, -9.0, "max_db pinned: the knob is the loudness, never more")
	assert_eq((player.stream as AudioStreamWAV).loop_mode, AudioStreamWAV.LOOP_FORWARD, "it loops")
	assert_eq(sample.loop_mode, AudioStreamWAV.LOOP_DISABLED, "the shared sample is left as it was")
	assert_eq(hum.get_child_count(), 0, "the player is internal: never saved into a scene")


func test_without_a_sound_it_stays_quiet() -> void:
	var hum := AmbientLoop3D.new()
	add_child_autofree(hum)
	assert_null(hum.player())


func _one_second_of_silence() -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 48000
	var data := PackedByteArray()
	data.resize(48000 * 2)
	wav.data = data
	return wav
