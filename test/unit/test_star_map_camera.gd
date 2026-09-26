extends GutTest

## The star chart's camera rules, exercised without a viewport, a world or a player.
##
## [StarMapCamera] was split out of [StarMap] precisely so these could be pinned. Three of the tests
## below pin real bugs that shipped:
##
## - clicking empty space put the camera INSIDE the star. The pick result was written straight into the
##   focus, a miss stored -1, -1 means "the origin", and the origin is the star — while the distance was
##   left untouched, because its reset sat inside the "something was hit" branch.
## - the distance floor was written in absolute units (0.01, ten thousand km) on a chart whose subjects
##   run from a 3 000 km moon to a 571 000 km star. No single absolute number can serve that range.
## - a click "framed" a body from forty of its radii, which left it filling 3 % of the screen. It read
##   as the click having done nothing.
##
## The input model these encode: SELECTING tells you about a thing and moves nothing; WATCHING is the
## journey, and only a double click, a search result or Reset starts one.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_camera.gd

## The star, in chart units (1 unit = 1e6 km). It is what the camera watches when nothing else has been
## chosen, so it is the one a bad floor buries you in.
const STAR_RADIUS_UNITS: float = 0.5714
## A terrestrial planet, three orders of magnitude smaller. The pair is the point: they cannot share an
## absolute floor.
const PLANET_RADIUS_UNITS: float = 0.006356
## A small moon. Three radii in the fixtures rather than two, because the thing being checked is that a
## definite altitude no longer depends on which of them is underneath.
const MOON_RADIUS_UNITS: float = 0.000743
## What the chart's camera sees. Read from the class under test rather than restated here: a copy would
## keep passing after the camera's field of view changed, which is the one thing this is checking.
const SCREEN_SPAN: float = StarMapCamera.SCREEN_SPAN
## The gap the camera keeps above the ground, in chart units.
##
## A DISTANCE rather than a fraction of the body, and that is the whole point: it is what lets "five
## hundred metres above the ground" mean the same thing over a planet and over a moon. As a ratio it
## meant 1.3 km over one and 700 m over the other, so any definite altitude the chart asked for was an
## altitude the floor might quietly refuse.
const CLEARANCE_UNITS: float = StarMapCamera.SURFACE_CLEARANCE_M * StarMapCamera.METRE

var _cam: StarMapCamera = null


func before_each() -> void:
	_cam = StarMapCamera.new()


# ---------------------------------------------------------------------------
# Selecting is not travelling
# ---------------------------------------------------------------------------

## A click answers "what is that?". Answering a question is no reason to throw away the view the
## question was asked from — which is what the first version did, and it cost you the place you had
## just spent a travel reaching.
func test_selecting_moves_nothing() -> void:
	_cam.watch(3, PLANET_RADIUS_UNITS, PLANET_RADIUS_UNITS, Vector3.ZERO)
	_cam.advance(StarMapCamera.TRANSITION_S)
	var was: float = _cam.distance()

	_cam.select(7, "tarsis_3_1")

	assert_eq(_cam.focus, 7, "the selection changed")
	assert_eq(_cam.anchor_body, 3, "but the camera still watches what it was watching")
	assert_eq(_cam.distance(), was, "and it has not moved an inch")


## Nor does dropping one. There is a Reset button and a right click for going home.
func test_dropping_a_selection_moves_nothing() -> void:
	_cam.watch(7, PLANET_RADIUS_UNITS, PLANET_RADIUS_UNITS, Vector3.ZERO)
	_cam.select(7, "tarsis_3_1")
	_cam.advance(StarMapCamera.TRANSITION_S)
	var was: float = _cam.distance()

	_cam.deselect()

	assert_eq(_cam.focus, -1, "nothing is selected any more")
	assert_eq(_cam.focus_key, "", "and no key is left behind to resurrect it on the next rebuild")
	assert_eq(_cam.anchor_body, 7, "the subject is unchanged")
	assert_eq(_cam.distance(), was, "and so is the distance")


## Reset is the one gesture that goes home, and it restores the opening view whole — subject, distance
## and orientation — rather than only part of it.
func test_reset_is_the_only_way_back_to_the_system_view() -> void:
	_cam.watch(7, PLANET_RADIUS_UNITS, PLANET_RADIUS_UNITS, Vector3.ZERO)
	_cam.select(7, "tarsis_3_1")
	_cam.orbit(Vector2(300.0, 90.0), 0.0)
	_cam.advance(StarMapCamera.TRANSITION_S)

	_cam.reset(Vector3(1.0, 0.0, 0.0))
	_cam.advance(StarMapCamera.TRANSITION_S)

	assert_eq(_cam.focus, -1)
	assert_eq(_cam.anchor_body, 0, "back onto entry zero, which is the star at the origin")
	assert_almost_eq(_cam.distance(), StarMapCamera.DEFAULT_ZOOM, 0.001)
	assert_eq(_cam.yaw, StarMapCamera.DEFAULT_YAW)
	assert_eq(_cam.pitch, StarMapCamera.DEFAULT_PITCH)


# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------

## Going to a body has to actually SHOW it. Written against the apparent size rather than against the
## constant, so the test states the intent and survives a retuning of the number.
func test_a_watched_body_fills_the_view() -> void:
	_cam.watch(3, PLANET_RADIUS_UNITS, PLANET_RADIUS_UNITS, Vector3.ZERO)
	_cam.advance(StarMapCamera.TRANSITION_S)

	var share: float = (2.0 * PLANET_RADIUS_UNITS) / (SCREEN_SPAN * _cam.distance())
	assert_gt(share, 0.55, "the body must dominate the view, not sit in it as a speck")
	assert_lt(share, 1.0, "and it must still fit on screen")


## "Centre on that town" on a sphere cannot mean moving the camera sideways: it means turning the globe
## until the town is the part facing you.
func test_aiming_turns_a_surface_point_towards_the_camera() -> void:
	var target: Vector3 = Vector3(0.3, 0.2, -0.9).normalized()
	_cam.aim_from(target)
	assert_true(_cam.is_travelling(), "the turn is animated, not a cut")
	_cam.advance(StarMapCamera.TRANSITION_S)
	var facing: Vector3 = _cam.direction()
	assert_almost_eq(facing.x, target.x, 0.001)
	assert_almost_eq(facing.y, target.y, 0.001)
	assert_almost_eq(facing.z, target.z, 0.001)


## A direction straight down the pole would put the camera on the axis, where the orbit rings collapse
## to lines. It is clamped like every other way of reaching that orientation.
func test_aiming_at_a_pole_still_stops_short_of_it() -> void:
	_cam.aim_from(Vector3.UP)
	_cam.advance(StarMapCamera.TRANSITION_S)
	assert_almost_eq(_cam.facing_pitch(), StarMapCamera.PITCH_LIMIT, 0.0001)


# ---------------------------------------------------------------------------
# The floor
# ---------------------------------------------------------------------------

## The floor knows what it is approaching, so it holds for a star and a planet alike. This is the
## guarantee a floor written as an absolute DISTANCE FROM THE CENTRE could not give.
func test_the_camera_can_never_be_inside_what_it_looks_at() -> void:
	for radius: float in [STAR_RADIUS_UNITS, PLANET_RADIUS_UNITS]:
		var floored: float = _cam.clamp_zoom(StarMapCamera.ZOOM_MIN, radius)
		assert_gt(floored, radius,
				"asking for the minimum distance must still leave the camera outside the surface")
		assert_almost_eq(floored, radius + CLEARANCE_UNITS, CLEARANCE_UNITS * 0.01,
				"and it should sit exactly at the clearance, not at some unrelated constant")


## The clearance, not the absolute minimum, has to be what stops you — otherwise a small moon can never
## fill the screen however hard you zoom, which is what ZOOM_MIN at 0.01 units did.
func test_the_clearance_and_not_the_absolute_floor_is_what_stops_you() -> void:
	assert_lt(StarMapCamera.ZOOM_MIN, PLANET_RADIUS_UNITS + CLEARANCE_UNITS,
			"a terrestrial planet must be stopped by its own surface, not by the absolute floor")


## Holding the zoom key, or spinning the wheel, must not be able to grind through a surface either: the
## clamp lives at the single point where a distance is written, not at the call sites.
func test_repeated_zooming_in_stops_at_the_clearance() -> void:
	_cam.set_zoom(StarMapCamera.DEFAULT_ZOOM, STAR_RADIUS_UNITS)
	for _i: int in range(300):
		_cam.scale_zoom(1.0 / StarMapCamera.ZOOM_STEP, STAR_RADIUS_UNITS)
	assert_almost_eq(_cam.distance(), STAR_RADIUS_UNITS + CLEARANCE_UNITS,
			CLEARANCE_UNITS * 0.01, "three hundred notches inward stop at the surface clearance")


## A DEFINITE altitude has to survive the floor, and on any body.
##
## This is what the old ratio refused. "Show me where I am" asks for five hundred metres above the
## ground; a clearance of 1.0002 radii is 1 271 m over Tarsis III, so the request was silently rounded
## up to two and a half times what was asked — and to a different number over every other body, which
## is the part that makes it impossible to reason about.
func test_a_definite_altitude_is_honoured_over_any_body() -> void:
	var wanted: float = 500.0 * StarMapCamera.METRE
	for radius: float in [STAR_RADIUS_UNITS, PLANET_RADIUS_UNITS, MOON_RADIUS_UNITS]:
		var asked: float = radius + wanted
		assert_almost_eq(_cam.clamp_zoom(asked, radius), asked, CLEARANCE_UNITS * 0.01,
				"five hundred metres above the ground must be five hundred metres, not a fraction "
				+ "of whatever happens to be underneath")


## And the floor still bites BELOW that: the guarantee is "never in the ground", not "never close".
func test_the_floor_still_stops_you_below_the_clearance() -> void:
	var radius: float = PLANET_RADIUS_UNITS
	assert_almost_eq(_cam.clamp_zoom(radius, radius), radius + CLEARANCE_UNITS, CLEARANCE_UNITS * 0.01,
			"asking to sit exactly on the ground must be lifted to the clearance")


## The floor has to hold when nobody writes a distance.
##
## clamp_zoom runs where a distance is WRITTEN, and that was taken for enough. Two gestures prove it is
## not: orbiting writes no distance, so turning from a plain onto a mountain raises the ground through
## a stationary camera; and a caller that frames something with no radius hands over a guard of zero,
## which is how "go to me" from the search box put the camera inside the planet under the player. Both
## end with the camera inside the world, and neither goes anywhere near clamp_zoom.
func test_the_floor_holds_when_the_ground_rises_under_a_still_camera() -> void:
	var radius: float = PLANET_RADIUS_UNITS
	_cam.set_zoom(radius + 500.0 * StarMapCamera.METRE, radius)
	# The camera has not moved; the ground beneath it has — a mountain a hundred km proud.
	var risen: float = radius * 1.016
	_cam.hold_above(risen)
	assert_almost_eq(_cam.distance(), risen + CLEARANCE_UNITS, CLEARANCE_UNITS * 0.01,
			"the camera must be lifted onto the new ground, not left inside it")


## And it never pulls the camera DOWN. A floor that also became a ceiling would fight every approach,
## dragging the view back out the moment it cleared a peak.
func test_holding_above_never_lowers_the_camera() -> void:
	var radius: float = PLANET_RADIUS_UNITS
	_cam.set_zoom(radius * 3.0, radius)
	_cam.hold_above(radius)
	assert_almost_eq(_cam.distance(), radius * 3.0, radius * 1.0e-6,
			"already clear of the ground, the camera stays where it is")


## With no body to clear — the chart still empty, say — the floor falls back to the absolute minimum
## rather than to zero, which would let the near plane collapse.
func test_an_unknown_subject_falls_back_to_the_absolute_floor() -> void:
	assert_eq(_cam.clamp_zoom(0.0, 0.0), StarMapCamera.ZOOM_MIN)


# ---------------------------------------------------------------------------
# Travelling
# ---------------------------------------------------------------------------

## A travel between two distances five orders of magnitude apart has to be blended in the log domain.
## Linearly, the move from 1200 units to 0.01 is still at 150 units when it is seven eighths done: the
## whole visible part of it would happen in the last two or three frames.
func test_a_travel_is_blended_in_the_log_domain() -> void:
	_cam.set_zoom(StarMapCamera.DEFAULT_ZOOM, 0.0)
	_cam.watch(3, PLANET_RADIUS_UNITS, PLANET_RADIUS_UNITS, Vector3.ZERO)
	_cam.advance(StarMapCamera.TRANSITION_S * 0.5)

	# Stated against the GOAL rather than against a distance in units, so retuning the opening view does
	# not quietly turn this into a test of nothing.
	var linear: float = lerpf(StarMapCamera.DEFAULT_ZOOM, _cam.zoom, 0.875)
	assert_gt(linear, _cam.zoom * 100.0,
			"sanity: seven eighths through, a linear blend is still a hundred times too far out")
	assert_lt(_cam.distance(), 1.0,
			"half way through, the view should already be near the planet, not still out at 150 units")


## However it is blended, it must land exactly on the goal — a travel that settles near the target
## leaves the framing subtly wrong for as long as the body stays in view.
func test_a_travel_settles_exactly_on_its_goal() -> void:
	_cam.watch(3, PLANET_RADIUS_UNITS, PLANET_RADIUS_UNITS, Vector3.ZERO)
	_cam.advance(StarMapCamera.TRANSITION_S * 2.0)
	assert_false(_cam.is_travelling(), "the travel is over")
	assert_eq(_cam.distance(), _cam.zoom, "and it ends on the goal, not close to it")
	assert_eq(_cam.look_point(Vector3(5.0, 1.0, 0.0)), Vector3(5.0, 1.0, 0.0),
			"once settled the camera reads the subject live again, so following a moving body works")


## Interrupting a travel must continue from where the view visibly IS. Starting the new move from the
## abandoned goal would teleport the camera forward before pulling it back.
func test_interrupting_a_travel_starts_from_where_the_view_is() -> void:
	_cam.watch(3, PLANET_RADIUS_UNITS, PLANET_RADIUS_UNITS, Vector3.ZERO)
	_cam.advance(StarMapCamera.TRANSITION_S * 0.3)
	var mid: float = _cam.distance()

	_cam.reset(Vector3.ZERO)
	assert_almost_eq(_cam.distance(), mid, mid * 0.001,
			"the new travel begins at the distance that was on screen a frame ago")


## Orbiting is clamped short of the poles: straight down the system axis the orbit rings collapse to
## straight lines and the chart stops being readable.
func test_pitch_stays_clear_of_the_poles() -> void:
	for _i: int in range(500):
		_cam.orbit(Vector2(0.0, 100.0), 0.0)
	assert_almost_eq(_cam.pitch, StarMapCamera.PITCH_LIMIT, 0.0001)
	for _i: int in range(1000):
		_cam.orbit(Vector2(0.0, -100.0), 0.0)
	assert_almost_eq(_cam.pitch, -StarMapCamera.PITCH_LIMIT, 0.0001)


## One pixel of mouse moves the same FRACTION OF THE SCREEN at every height.
##
## The property that says the rate is right, rather than merely decreasing. Orbiting sweeps
## radius·dθ of ground while the screen at that height shows about 1.53 times the height, and the rate
## follows the height — so the two cancel and a pixel is worth the same gesture up close as out in
## space. It also says the floor is not needed for usability, which is what it was justified by: at two
## thousandths it bound below 12.7 km up and turned 3.2 times too fast at 4 km, 13 times at 1 km, right
## where the chart now spends its time.
func test_one_pixel_is_worth_the_same_gesture_at_every_height() -> void:
	# Below one radius of height, where the rate follows the height. Above that it is deliberately
	# capped — see the test that follows — because out in space you are turning around the body, not
	# travelling over it.
	var share: Array[float] = []
	for altitude_units: float in [PLANET_RADIUS_UNITS * 0.5, PLANET_RADIUS_UNITS * 0.1,
			PLANET_RADIUS_UNITS * 0.001, PLANET_RADIUS_UNITS * 0.0001,
			PLANET_RADIUS_UNITS * 1.6e-5]:
		var cam := StarMapCamera.new()
		cam.set_zoom(PLANET_RADIUS_UNITS + altitude_units, PLANET_RADIUS_UNITS)
		var before: float = cam.yaw
		cam.orbit(Vector2(100.0, 0.0), PLANET_RADIUS_UNITS)
		# Ground swept, against the ground the screen holds at that height.
		var swept: float = absf(before - cam.yaw) * PLANET_RADIUS_UNITS
		share.append(swept / (1.53 * altitude_units))
	for i: int in range(1, share.size()):
		assert_almost_eq(share[i], share[0], share[0] * 0.01,
				"a pixel has to be worth the same fraction of the view at every height")


## And out in space the rate stops growing, because there the gesture is turning AROUND the body rather
## than travelling over it, and a rate that kept following the height would spin the view.
func test_the_rate_stops_growing_out_in_space() -> void:
	var turns: Array[float] = []
	for altitude_units: float in [PLANET_RADIUS_UNITS * 2.0, PLANET_RADIUS_UNITS * 40.0]:
		var cam := StarMapCamera.new()
		cam.set_zoom(PLANET_RADIUS_UNITS + altitude_units, PLANET_RADIUS_UNITS)
		var before: float = cam.yaw
		cam.orbit(Vector2(100.0, 0.0), PLANET_RADIUS_UNITS)
		turns.append(absf(before - cam.yaw))
	assert_almost_eq(turns[1], turns[0], turns[0] * 1.0e-6,
			"twenty times further out turns by exactly as much")


## Orbiting has to get FINER as you close in, or a small mouse move sweeps the ground out of view.
## The rate follows the gap to the surface rather than the distance, because it is the gap that decides
## how much ground a given turn sweeps.
func test_orbiting_gets_finer_as_you_approach() -> void:
	_cam.set_zoom(PLANET_RADIUS_UNITS * 40.0, PLANET_RADIUS_UNITS)
	_cam.orbit(Vector2(100.0, 0.0), PLANET_RADIUS_UNITS)
	var far_turn: float = absf(StarMapCamera.DEFAULT_YAW - _cam.yaw)

	_cam = StarMapCamera.new()
	_cam.set_zoom(PLANET_RADIUS_UNITS + CLEARANCE_UNITS, PLANET_RADIUS_UNITS)
	_cam.orbit(Vector2(100.0, 0.0), PLANET_RADIUS_UNITS)
	var near_turn: float = absf(StarMapCamera.DEFAULT_YAW - _cam.yaw)

	assert_gt(far_turn, 0.0, "sanity: orbiting does something out in space")
	assert_lt(near_turn, far_turn * 0.2,
			"hard against the surface, the same mouse travel must turn far less")
	assert_gt(near_turn, 0.0, "but it must not seize up altogether")


# ---------------------------------------------------------------------------
# Following a place
# ---------------------------------------------------------------------------

## Following carries the view by the rotation the GROUND underwent, rather than re-aiming at the place.
## Re-aiming would work and would be useless: it would undo the orbit gesture every frame, so a town
## could never be looked at from the side.
func test_following_carries_the_view_without_undoing_your_orbit() -> void:
	var place: Vector3 = Vector3(0.0, 0.0, 1.0)
	_cam.aim_from(place)
	_cam.advance(StarMapCamera.TRANSITION_S)
	# Look at it from off to one side, as a player would.
	_cam.orbit(Vector2(120.0, 0.0), 0.0)
	var offset: float = absf(angle_difference(_cam.yaw, atan2(place.x, place.z)))
	assert_gt(offset, 0.05, "sanity: we really are looking from an angle now")

	# The ground turns by a tenth of a radian about the pole, carrying the place with it.
	var turn := Quaternion(Vector3.UP, 0.1)
	_cam.turn_by(turn)

	# Measured against where the place has MOVED TO, not where it was: both have turned, and what has
	# to survive is the angle between them.
	var carried: Vector3 = turn * place
	var moved: float = absf(angle_difference(_cam.yaw, atan2(carried.x, carried.z)))
	assert_almost_eq(moved, offset, 0.001,
			"the angle you chose survives: the view moved exactly as much as the ground did")


## A turn in flight owns the wheel. Steering it a degree at a time from the tracking would fight it.
func test_following_does_not_fight_a_travel_in_flight() -> void:
	_cam.aim_from(Vector3(0.0, 0.0, 1.0))
	var mid_yaw: float = _cam.yaw
	_cam.turn_by(Quaternion(Vector3.UP, 0.5))
	assert_eq(_cam.yaw, mid_yaw, "the tracking stands aside while the travel runs")


# ---------------------------------------------------------------------------
# Zooming
# ---------------------------------------------------------------------------

## One notch changes the HEIGHT by one step, wherever you are. On the distance to the centre instead,
## a fifteen per cent step near a planet is 950 km: from a hundred km up, a single notch either pinned
## you to the floor or threw you out of sight.
func test_one_notch_changes_the_height_not_the_distance() -> void:
	var radius: float = PLANET_RADIUS_UNITS
	_cam.set_zoom(radius * 1.01, radius)
	var before: float = _cam.distance() - radius
	assert_gt(before, 0.0, "sanity: we start above the ground")

	_cam.scale_zoom(1.0 / StarMapCamera.ZOOM_STEP, radius)
	var after: float = _cam.distance() - radius

	assert_almost_eq(after, before / StarMapCamera.ZOOM_STEP, before * 0.001,
			"the height fell by exactly one step")


## Out in space the radius is nothing beside the distance, so the same rule has to give back the plain
## multiplication it replaces. A formula that only behaved near a surface would be two formulas.
func test_far_away_it_is_still_a_plain_step() -> void:
	var radius: float = PLANET_RADIUS_UNITS
	_cam.set_zoom(StarMapCamera.DEFAULT_ZOOM, radius)
	_cam.scale_zoom(StarMapCamera.ZOOM_STEP, radius)
	assert_almost_eq(_cam.distance(), StarMapCamera.DEFAULT_ZOOM * StarMapCamera.ZOOM_STEP,
			StarMapCamera.DEFAULT_ZOOM * 0.001)


## Approaching is geometric, so the floor is reached smoothly rather than in one jump — and it IS
## reached: a descent that stalled short of the ground would read as the wheel having stopped working.
func test_repeated_notches_settle_onto_the_floor() -> void:
	var radius: float = PLANET_RADIUS_UNITS
	_cam.set_zoom(radius * 2.0, radius)
	for _i: int in range(200):
		_cam.scale_zoom(1.0 / StarMapCamera.ZOOM_STEP, radius)
	assert_almost_eq(_cam.distance(), radius + CLEARANCE_UNITS, CLEARANCE_UNITS * 0.01)
