extends GutTest
## VehicleSpeedLimiter: past the chosen speed the engine stops pushing; it never brakes, and it only
## sends what changed.

var _l: VehicleSpeedLimiter = null


func before_each() -> void:
	_l = VehicleSpeedLimiter.new()
	_l.step_kmh = 5
	_l.min_kmh = 5
	_l.max_kmh = 130
	_l.taper_kmh = 3.0
	_l.cap_kmh = 30


func test_off_it_never_touches_the_force() -> void:
	assert_eq(_l.force_factor(1.0, 200.0), 1.0, "off = full force at any speed")


func test_on_it_pushes_fully_well_below_the_limit() -> void:
	_l.toggle()
	assert_eq(_l.force_factor(1.0, 20.0), 1.0, "10 km/h under: full force")


func test_on_it_stops_pushing_at_the_limit() -> void:
	_l.toggle()
	assert_eq(_l.force_factor(1.0, 30.0), 0.0, "at the limit: nothing")
	assert_eq(_l.force_factor(1.0, 45.0), 0.0, "downhill over it: still nothing, and no brake either")


func test_it_eases_off_just_below_the_limit() -> void:
	_l.toggle()
	assert_almost_eq(_l.force_factor(1.0, 28.5), 0.5, 1e-6, "half way through the taper")


func test_it_limits_reverse_too() -> void:
	_l.toggle()
	assert_eq(_l.force_factor(-1.0, -30.0), 0.0, "backing up at the limit")


func test_pushing_against_the_motion_is_never_limited() -> void:
	_l.toggle()
	assert_eq(_l.force_factor(-1.0, 50.0), 1.0, "that is braking into a reverse, not speeding up")


func test_no_throttle_no_limit() -> void:
	_l.toggle()
	assert_eq(_l.force_factor(0.0, 50.0), 1.0, "coasting is not the limiter's business")


func test_steps_are_five_kmh_and_bounded() -> void:
	_l.step(1)
	assert_eq(_l.cap_kmh, 35, "+5")
	_l.step(-1)
	_l.step(-1)
	assert_eq(_l.cap_kmh, 25, "-5 twice")
	for i in 20:
		_l.step(-1)
	assert_eq(_l.cap_kmh, 5, "never below the minimum")
	for i in 60:
		_l.step(1)
	assert_eq(_l.cap_kmh, 130, "never above the maximum")


func test_the_limit_survives_toggling() -> void:
	_l.step(1)
	_l.toggle()
	_l.toggle()
	assert_eq(_l.cap_kmh, 35, "off keeps the chosen limit, T brings the same one back")


func test_only_changes_go_on_the_wire() -> void:
	var first: Dictionary = {}
	_l.write_changes(first)
	assert_eq(first, {"limiter_on": false, "limiter_kmh": 30}, "everything the first time")
	var again: Dictionary = {}
	_l.write_changes(again)
	assert_true(again.is_empty(), "nothing when nothing changed")
	_l.toggle()
	var toggled: Dictionary = {}
	_l.write_changes(toggled)
	assert_eq(toggled, {"limiter_on": true}, "only the flag")


func test_a_received_state_is_not_sent_back() -> void:
	_l.read({"limiter_on": true, "limiter_kmh": 55.0})  # Horizon hands integers back as floats
	assert_true(_l.enabled, "applied")
	assert_eq(_l.cap_kmh, 55, "applied, as an int")
	var out: Dictionary = {}
	_l.write_changes(out)
	assert_true(out.is_empty(), "a restore is not an edit")


func test_over_the_limit_the_throttle_counts_as_closed() -> void:
	_l.toggle()
	assert_true(_l.overspeed(1.0, 50.0), "switched on at 50 with a 30 limit: the engine holds back")
	assert_false(_l.overspeed(1.0, 30.5), "inside the margin: just no push, no braking")
	assert_false(_l.overspeed(1.0, 20.0), "under the limit: a normal drive")


func test_overspeed_needs_the_limiter_and_the_pedal() -> void:
	assert_false(_l.overspeed(1.0, 50.0), "off: never")
	_l.toggle()
	assert_false(_l.overspeed(0.0, 50.0), "no pedal: ordinary coasting already applies")
	assert_false(_l.overspeed(-1.0, 50.0), "pushing against the motion is braking, not speeding")


func test_over_the_limit_reads_the_same_either_way() -> void:
	# The dashboard only has the unsigned replicated speed; the server has the signed one.
	_l.toggle()
	assert_true(_l.is_over(50.0), "forward")
	assert_true(_l.is_over(-50.0), "reverse")
	assert_false(_l.is_over(30.5), "inside the margin")
	_l.toggle()
	assert_false(_l.is_over(50.0), "off: never red")
