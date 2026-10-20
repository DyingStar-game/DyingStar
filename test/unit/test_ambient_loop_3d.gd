extends GutTest
## AmbientLoop3D plays its sound (a LoopSound) in a loop as soon as it is in the tree, through Sfx3D:
## on the SFX bus, with max_db pinned to its loudness, and without making the shared sample loop
## elsewhere.


func test_it_loops_on_the_sfx_bus_as_soon_as_it_stands() -> void:
	var sample := _one_second_of_silence()
	var hum := AmbientLoop3D.new()
	hum.sound = _sound(sample, -9.0, 25.0)
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
	var empty := AmbientLoop3D.new()
	empty.sound = LoopSound.new()  # a LoopSound with no sample yet
	add_child_autofree(empty)
	assert_null(empty.player(), "a sound with no sample: quiet too")
	empty.set_running(true)  # nothing to play: no error


## The loop is built from its LoopSound: one resource shared by several loops (the vehicle lift's
## alarm at both landings) tunes them all alike.
func test_the_player_takes_its_loop_sound() -> void:
	var sound := _sound(_one_second_of_silence(), -3.0, 70.0)
	var hum := AmbientLoop3D.new()
	hum.sound = sound
	hum.autoplay = false
	add_child_autofree(hum)
	if Sfx3D.muted():
		return  # headless on a server build: no player to look at
	assert_eq(hum.player().max_distance, 70.0, "the LoopSound's distance")
	assert_false(hum.player().playing, "not autoplay: silent until set_running")
	hum.set_running(true)
	assert_true(hum.player().playing)


func _sound(stream: AudioStream, volume_db: float, distance: float) -> LoopSound:
	var sound := LoopSound.new()
	sound.stream = stream
	sound.volume_db = volume_db
	sound.distance = distance
	return sound


func _one_second_of_silence() -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 48000
	var data := PackedByteArray()
	data.resize(48000 * 2)
	wav.data = data
	return wav
