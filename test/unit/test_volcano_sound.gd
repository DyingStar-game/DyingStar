extends GutTest

## The sounds of a volcano (VolcanoSound, VolcanoAcoustics): heard late, by the speed of sound, muffled by
## the distance, and silent without air.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_volcano_sound.gd

const Acoustics := preload("res://scenes/audio/volcano/volcano_acoustics.gd")
const Sound := preload("res://scenes/audio/volcano/volcano_sound.gd")
const SoundSet := preload("res://scenes/audio/volcano/volcano_sound_set.gd")
const DIR := "res://assets/_universe/audio/sfx/environment/volcano/"
const LOOPS: Array[String] = ["volcano-deep-rumble-loop", "geothermal-steam-loop", "rock-cracking-rumble-loop"]
const BLASTS: Array[String] = ["eruption-explosion-far-1", "eruption-explosion-far-2"]

## An eruption of 40 minutes that starts at 1000 s: the smoke forms for 45 s, then the blast.
const WINDOW := {"start_unix": 1000.0, "length_s": 2400.0, "strength": 1.2, "ramp_up_s": 45.0, "ramp_down_s": 30.0}
const BLAST := 1045.0


func _sounds() -> SoundSet:
	return load(Sound.SOUNDS_PATH) as SoundSet


func test_a_volcano_40_km_away_is_heard_two_minutes_late() -> void:
	assert_almost_eq(Acoustics.delay_s(40000.0, 340.0), 117.6, 0.1)
	assert_almost_eq(Acoustics.delay_s(1000.0, 340.0), 2.9, 0.1, "three seconds a kilometre")
	assert_almost_eq(Acoustics.heard_time(5000.0, 40000.0, 340.0), 4882.4, 0.1, "the listener hears its past")
	assert_eq(Acoustics.delay_s(0.0, 340.0), 0.0)


func test_the_distance_takes_the_level_down_to_silence() -> void:
	var s := _sounds()
	var near: float = Acoustics.gain_db(500.0, s.explosion_full_m, s.explosion_range_m, s.far_db)
	var mid: float = Acoustics.gain_db(10000.0, s.explosion_full_m, s.explosion_range_m, s.far_db)
	var far: float = Acoustics.gain_db(40000.0, s.explosion_full_m, s.explosion_range_m, s.far_db)
	assert_eq(near, 0.0, "full level next to the volcano")
	assert_lt(mid, near)
	assert_lt(far, mid)
	assert_gt(far, -24.0, "40 km away the blast is still clearly heard")
	assert_eq(Acoustics.gain_db(s.explosion_range_m, s.explosion_full_m, s.explosion_range_m, s.far_db),
			Acoustics.SILENT_DB, "nothing beyond its range")
	assert_lt(Acoustics.gain_db(s.explosion_range_m * 0.99, s.explosion_full_m, s.explosion_range_m, s.far_db), -60.0,
			"and no step at the edge")


func test_a_far_volcano_is_muffled_and_reverberated() -> void:
	var s := _sounds()
	assert_almost_eq(Acoustics.cutoff_hz(200.0, s.muffle_near_m, s.muffle_far_m, s.muffle_far_hz),
			Acoustics.OPEN_CUTOFF_HZ, 1.0, "clear close by")
	var mid: float = Acoustics.cutoff_hz(10000.0, s.muffle_near_m, s.muffle_far_m, s.muffle_far_hz)
	assert_between(mid, s.muffle_far_hz, Acoustics.OPEN_CUTOFF_HZ)
	assert_almost_eq(Acoustics.cutoff_hz(60000.0, s.muffle_near_m, s.muffle_far_m, s.muffle_far_hz), s.muffle_far_hz,
			1.0, "a dull rumble from afar")
	assert_gt(Acoustics.reverb_wet(40000.0, s.muffle_near_m, s.muffle_far_m, s.reverb_near, s.reverb_far),
			Acoustics.reverb_wet(500.0, s.muffle_near_m, s.muffle_far_m, s.reverb_near, s.reverb_far))


func test_the_blast_comes_when_the_stones_start() -> void:
	assert_eq(Sound.blast_time(WINDOW), BLAST)
	var short := {"start_unix": 0.0, "length_s": 60.0, "ramp_up_s": 45.0, "ramp_down_s": 30.0}
	assert_almost_eq(Sound.blast_time(short), 21.0, 0.001, "as VolcanoEvent.emission_envelope delays them")


func test_the_blast_is_played_once_as_it_passes() -> void:
	assert_eq(Sound.blast_due(WINDOW, BLAST - 0.1, NAN, 3.0, 0.0, 7), -1, "not before its time")
	assert_eq(Sound.blast_due(WINDOW, BLAST + 0.1, NAN, 3.0, 0.0, 7), 0)
	assert_eq(Sound.blast_due(WINDOW, BLAST + 0.2, BLAST, 3.0, 0.0, 7), -1, "each one once")
	assert_eq(Sound.blast_due(WINDOW, BLAST + 600.0, NAN, 3.0, 0.0, 7), -1, "not to who arrives in the middle of it")
	assert_eq(Sound.blast_due({}, BLAST, NAN, 3.0, 0.0, 7), -1)


func test_the_blasts_go_on_while_the_eruption_lasts() -> void:
	var previous: float = BLAST
	for index: int in range(1, 40):
		var at: float = Sound.blast_time_of(WINDOW, index, 35.0, 7)
		assert_gt(at, previous, "blast %d comes after the one before" % index)
		assert_almost_eq(at, BLAST + float(index) * 35.0, 35.0 * 0.36, "around its even place")
		previous = at
	var fifth: float = Sound.blast_time_of(WINDOW, 5, 35.0, 7)
	assert_eq(Sound.blast_index(WINDOW, fifth + 0.1, 35.0, 7), 5)
	assert_eq(Sound.blast_index(WINDOW, fifth - 0.1, 35.0, 7), 4)
	assert_eq(Sound.blast_due(WINDOW, fifth + 0.1, NAN, 3.0, 35.0, 7), 5, "who arrives late hears the next ones")
	assert_eq(Sound.blast_due(WINDOW, fifth + 0.2, fifth, 3.0, 35.0, 7), -1, "each one once")
	assert_eq(Sound.blast_index(WINDOW, 3400.0 - 10.0, 35.0, 7), -1, "none while the eruption falls")
	assert_eq(Sound.blast_time_of(WINDOW, 3, 35.0, 7), Sound.blast_time_of(WINDOW, 3, 35.0, 7), "the same on every client")
	assert_eq(Sound.blast_drop_db(0, 9.0, 7), 0.0, "the first one is the loudest")
	assert_between(Sound.blast_drop_db(3, 9.0, 7), -9.0, -2.0)


func test_the_ground_shakes_the_view_near_the_volcano_only() -> void:
	var s := _sounds()
	assert_eq(Sound.tremor_share(500.0, s.tremor_full_m, s.tremor_range_m), 1.0, "on the slopes")
	assert_between(Sound.tremor_share((s.tremor_full_m + s.tremor_range_m) * 0.5, s.tremor_full_m, s.tremor_range_m),
			0.1, 0.9)
	assert_eq(Sound.tremor_share(s.tremor_range_m, s.tremor_full_m, s.tremor_range_m), 0.0, "not from afar")
	for i: int in 200:
		assert_between(Sound.wobble(float(i) * 0.137, 7.3), -1.0, 1.0)
	var still: int = 0
	var shaking: int = 0
	for i: int in 600:
		var wave: float = Sound.swell(float(i) * 0.2)
		assert_between(wave, 0.0, 1.0)
		still += int(wave <= 0.0)
		shaking += int(wave >= 0.5)
	assert_gt(still, 200, "the tremor comes in waves: the ground is still most of the time")
	assert_gt(shaking, 60, "and shakes for a while")
	assert_lt(Acoustics.delay_s(3000.0, s.ground_speed_m_s) + 5.0, Acoustics.delay_s(3000.0, s.sound_speed_m_s),
			"a blast is felt in the feet seconds before it is heard")
	assert_eq(Sound.steady_share(12.0), 0.0, "the DataPad read on the wrist does not shake")
	assert_eq(Sound.steady_share(75.0), 1.0, "the walking view does")


func test_rumble_and_cracks_rise_before_the_blast() -> void:
	assert_eq(Sound.rumble_level(WINDOW, BLAST - 61.0, 60.0, 0.5, 10.0), 0.0, "calm a minute before")
	assert_almost_eq(Sound.rumble_level(WINDOW, BLAST - 30.0, 60.0, 0.5, 10.0), 0.25, 0.001)
	assert_almost_eq(Sound.rumble_level(WINDOW, BLAST + 10.0, 60.0, 0.5, 10.0), 1.0, 0.001, "full once it has burst")
	assert_almost_eq(Sound.rumble_level(WINDOW, 3400.0 - 15.0, 60.0, 0.5, 10.0), 0.5, 0.001, "falls with the eruption")
	assert_eq(Sound.rumble_level({}, BLAST, 60.0, 0.5, 10.0), 0.0)
	assert_almost_eq(Sound.cracks_level(WINDOW, BLAST - 30.0, 60.0, 20.0), 0.5, 0.001)
	assert_almost_eq(Sound.cracks_level(WINDOW, BLAST, 60.0, 20.0), 1.0, 0.001)
	assert_eq(Sound.cracks_level(WINDOW, BLAST + 20.0, 60.0, 20.0), 0.0, "the rock has given way")


func test_the_coming_eruption_is_seen_from_the_schedule() -> void:
	var profile := VolcanoActivityProfile.new()
	profile.random_enabled = false
	var event := VolcanoEvent.new()
	event.start_unix = 1000.0
	event.duration_s = 2400.0
	profile.events = [event]
	assert_true(Sound.window_at(profile, 900.0, 60.0, 1, "k", false).is_empty(), "too early")
	assert_eq(Sound.window_at(profile, 950.0, 60.0, 1, "k", false).get("start_unix"), 1000.0, "the one to come")
	assert_eq(Sound.window_at(profile, 2000.0, 60.0, 1, "k", false).get("start_unix"), 1000.0, "the one under way")
	assert_true(Sound.window_at(null, 2000.0, 60.0, 1, "k", false).is_empty())


func test_no_air_no_sound() -> void:
	assert_eq(Sound.level_db(0.0, -6.0, 1.0, 0.0), Acoustics.SILENT_DB, "space, or a body without air")
	assert_eq(Sound.level_db(0.0, -6.0, 0.0, 1.0), Acoustics.SILENT_DB, "a sound that is not due")
	assert_almost_eq(Sound.level_db(-4.0, -6.0, 1.0, 1.0), -10.0, 0.001)
	assert_almost_eq(Sound.level_db(-4.0, -6.0, 0.5, 1.0), -16.0, 0.1)
	assert_gt(Sound.strength_db(1.6), Sound.strength_db(0.8), "a stronger eruption is louder")


func test_each_voice_has_its_bus_under_sfx() -> void:
	var bus: StringName = Sound.ensure_bus(0)
	var idx: int = AudioServer.get_bus_index(bus)
	assert_gt(idx, -1)
	assert_eq(AudioServer.get_bus_send(idx), Sfx3D.SFX_BUS, "the SFX slider holds the volcanoes")
	assert_true(AudioServer.get_bus_effect(idx, 0) is AudioEffectLowPassFilter)
	assert_true(AudioServer.get_bus_effect(idx, 1) is AudioEffectReverb)
	assert_true(AudioServer.get_bus_effect(idx, 2) is AudioEffectDelay, "the slopes answer")
	assert_true(AudioServer.get_bus_effect(idx, 3) is AudioEffectHardLimiter, "pushed levels never clip")
	assert_eq(Sound.ensure_bus(0), bus)
	assert_eq(AudioServer.get_bus_index(bus), idx, "made once")
	AudioServer.remove_bus(idx)


func test_the_sound_set_is_complete() -> void:
	var s := _sounds()
	assert_not_null(s)
	assert_not_null(s.steam)
	assert_not_null(s.rumble)
	assert_not_null(s.cracks)
	assert_eq(s.explosions.size(), 2)
	assert_gt(s.explosion_range_m, 40000.0, "a volcano 40 km away is heard")


func test_the_files_are_loud_enough_looped_in_ogg_and_credited() -> void:
	for base: String in LOOPS + BLASTS:
		var stream := load(DIR + base + ".ogg") as AudioStreamOggVorbis
		assert_not_null(stream, "%s: an Ogg (an MP3 loop ticks at every turn)" % base)
		assert_gt(_peak_db(stream), -15.0, "%s is no whisper" % base)
		assert_true(FileAccess.file_exists(DIR + base + ".txt"), "%s has its credit" % base)
	for base: String in LOOPS:
		assert_true((Sfx3D.as_looping(load(DIR + base + ".ogg")) as AudioStreamOggVorbis).loop, "%s loops" % base)


## The peak (dB) of the first seconds of [param stream], decoded here.
func _peak_db(stream: AudioStreamOggVorbis) -> float:
	var playback := stream.instantiate_playback() as AudioStreamPlaybackOggVorbis
	playback.start(0.0)
	var peak: float = 0.0
	for _i: int in 200:
		for frame: Vector2 in playback.mix_audio(1.0, 1024):
			peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	return linear_to_db(maxf(peak, 0.000001))
