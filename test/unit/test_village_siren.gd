extends GutTest

## The village siren's loudspeaker (VillageSiren): it plays through its own bus, under SFX, whose
## reverberation gives a sounding its tail, and fades out when the alarm stops it mid-sound.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_village_siren.gd


func test_the_bus_reverberates_under_sfx_and_is_made_once() -> void:
	var bus := VillageSiren.ensure_bus()
	var idx: int = AudioServer.get_bus_index(bus)
	assert_ne(idx, -1)
	assert_eq(AudioServer.get_bus_send(idx), Sfx3D.SFX_BUS, "the SFX volume slider still moves it")
	var reverb := AudioServer.get_bus_effect(idx, 0) as AudioEffectReverb
	assert_not_null(reverb)
	assert_eq(reverb.dry, 1.0, "the siren itself kept whole")
	assert_between(reverb.wet, 0.05, 0.5, "a light reverberation")
	var count: int = AudioServer.bus_count
	VillageSiren.ensure_bus()
	assert_eq(AudioServer.bus_count, count, "made once")


func test_the_speaker_plays_on_that_bus() -> void:
	var siren := VillageSiren.new()
	add_child_autofree(siren)
	var speaker := siren.get_node("Speaker") as AudioStreamPlayer3D
	assert_eq(speaker.bus, VillageSiren.BUS)


func test_stopping_mid_sound_fades_out_then_stops() -> void:
	var siren := VillageSiren.new()
	add_child_autofree(siren)
	var speaker := siren.get_node("Speaker") as AudioStreamPlayer3D
	siren.show_alarm(VillageAlarm.DURING, Globals.reference_time())
	speaker.play()
	siren.show_alarm(VillageAlarm.OFF, Globals.reference_time())
	assert_true(speaker.playing, "still sounding while it fades")
	await wait_seconds(VillageSiren.STOP_FADE_S + 0.3)
	assert_false(speaker.playing, "stopped once faded")
