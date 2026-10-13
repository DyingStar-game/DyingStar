extends GutTest
## DoorAlarm: the open-door beat shared by the dashboard's door light and its beep.


func test_the_beat_follows_the_doors() -> void:
	assert_eq(DoorAlarm.period(false, 50.0, 40.0), 0.0, "every door shut: silent")
	assert_eq(DoorAlarm.period(true, 10.0, 40.0), DoorAlarm.SLOW_S, "a door open: the slow beat")
	assert_eq(DoorAlarm.period(true, 90.0, INF), DoorAlarm.SLOW_S, "a hatch the wind never shuts: slow")
	assert_eq(DoorAlarm.period(true, 32.0, 40.0), DoorAlarm.FAST_S, "at the warning speed: fast")
	assert_almost_eq(DoorAlarm.period(true, 36.0, 40.0), (DoorAlarm.FAST_S + DoorAlarm.FASTEST_S) / 2.0, 0.001,
			"halfway to the shutting speed: halfway quicker")
	assert_eq(DoorAlarm.period(true, 60.0, 40.0), DoorAlarm.FASTEST_S, "at or past it: the fastest")


func test_it_beeps_at_once_then_on_every_beat() -> void:
	var alarm := DoorAlarm.new()
	assert_false(alarm.step(0.1, 0.0), "doors shut: no beep")
	assert_false(alarm.lit())
	assert_true(alarm.step(0.016, 1.0), "a door opens: a beep at once")
	assert_true(alarm.lit(), "and the light on")
	var beeps: int = 0
	for i in 100:  # 2 s at 1 s a beat
		if alarm.step(0.02, 1.0):
			beeps += 1
	assert_eq(beeps, 2, "one beep a beat")
	alarm.step(0.016, 0.0)
	assert_false(alarm.lit(), "shut again: the light off")
