extends GutTest
## VehicleCruiseControl: set at the speed driven, held with the pedal released, overridden by the
## pedal, switched off by a pedal held backwards; one step of the wheel; exclusive with the limiter on
## the dashboard; and its two keys over the wire.

var _cruise: VehicleCruiseControl = null


func before_each() -> void:
	_cruise = VehicleCruiseControl.new()
	_cruise.step_kmh = 5
	_cruise.min_kmh = 5
	_cruise.max_kmh = 130


func test_it_is_set_at_the_speed_driven() -> void:
	_cruise.toggle(63.4)
	assert_true(_cruise.enabled)
	assert_eq(_cruise.set_kmh, 63)
	_cruise.toggle(80.0)
	assert_false(_cruise.enabled, "the same key switches it off")


func test_the_set_speed_stays_in_range() -> void:
	_cruise.toggle(5.4)
	assert_eq(_cruise.set_kmh, 5, "engaged at its lowest speed")
	_cruise.step(-1)
	assert_eq(_cruise.set_kmh, 5, "never under it")
	_cruise.cancel()
	_cruise.toggle(200.0)
	assert_eq(_cruise.set_kmh, 130)
	_cruise.step(1)
	assert_eq(_cruise.set_kmh, 130)
	_cruise.step(-1)
	assert_eq(_cruise.set_kmh, 125)


func test_it_pushes_below_the_set_speed_and_not_above() -> void:
	_cruise.toggle(50.0)
	assert_eq(_cruise.throttle(30.0), 1.0, "far below: full throttle")
	assert_almost_eq(_cruise.throttle(49.0), 0.3, 1e-6, "just below: what the shortfall needs")
	assert_eq(_cruise.throttle(50.0), 0.0)
	assert_eq(_cruise.throttle(60.0), 0.0, "downhill over the speed: it never brakes")


## A hold set backing up or standing still would drive the truck forward on its own (code review
## 2026-10-19): it refuses.
func test_it_does_not_engage_backing_up_or_standing_still() -> void:
	_cruise.toggle(-8.0)
	assert_false(_cruise.enabled, "backing up: no cruise")
	_cruise.toggle(0.0)
	assert_false(_cruise.enabled, "standing still: no cruise")
	_cruise.toggle(float(_cruise.min_kmh))
	assert_true(_cruise.enabled, "at its lowest set speed: on")


func test_off_it_does_nothing() -> void:
	assert_eq(_cruise.throttle(0.0), 0.0)
	assert_eq(_cruise.drive_throttle(0.4, 10.0), 0.4)


## Playtest 2026-10-19: accelerating hands the speed back to the pilot, like braking.
func test_accelerating_switches_it_off() -> void:
	_cruise.toggle(50.0)
	assert_eq(_cruise.drive_throttle(0.0, 50.0), _cruise.throttle(50.0), "released: the hold drives")
	assert_eq(_cruise.drive_throttle(1.0, 50.0), 1.0, "pressed: the pilot's throttle")
	assert_false(_cruise.enabled, "and the hold is off")


## Ctrl+T with the foot still down must not undo itself: the held pedal counts once let go.
func test_a_pedal_held_through_the_switch_on_counts_once_let_go() -> void:
	_cruise.toggle(50.0)
	assert_eq(_cruise.drive_throttle(1.0, 50.0), 1.0, "still held: drives over the hold")
	assert_true(_cruise.enabled, "the press from before is not a new one")
	assert_eq(_cruise.drive_throttle(0.0, 70.0), 0.0, "let go over the speed: coast back down")
	assert_true(_cruise.enabled)
	_cruise.drive_throttle(0.6, 48.0)
	assert_false(_cruise.enabled, "a new press switches it off")


func test_a_pedal_held_backwards_switches_it_off() -> void:
	_cruise.toggle(50.0)
	assert_eq(_cruise.drive_throttle(-1.0, 50.0), -1.0)
	assert_false(_cruise.enabled)


func test_the_dashboard_shows_the_cruise_green_and_the_limiter_as_before() -> void:
	assert_eq(VehicleDashboard.speed_colour(false, false, true), VehicleDashboard.GREEN)
	assert_eq(VehicleDashboard.speed_colour(true, true, false), VehicleDashboard.RED)
	assert_eq(VehicleDashboard.speed_colour(true, false, false), VehicleDashboard.AMBER)


func test_only_what_changed_is_sent() -> void:
	var data: Dictionary = {}
	_cruise.write_changes(data)
	assert_eq(data, {VehicleCruiseControl.KEY_ON: false, VehicleCruiseControl.KEY_KMH: 30}, "everything once")
	data = {}
	_cruise.write_changes(data)
	assert_eq(data, {})
	_cruise.toggle(72.0)
	_cruise.write_changes(data)
	assert_eq(data, {VehicleCruiseControl.KEY_ON: true, VehicleCruiseControl.KEY_KMH: 72})


func test_a_received_value_is_not_sent_back() -> void:
	_cruise.read({VehicleCruiseControl.KEY_ON: true, VehicleCruiseControl.KEY_KMH: 85.0})
	assert_true(_cruise.enabled)
	assert_eq(_cruise.set_kmh, 85, "ints come back as floats")
	var data: Dictionary = {}
	_cruise.write_changes(data)
	assert_eq(data, {})
