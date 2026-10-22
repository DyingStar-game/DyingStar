extends GutTest

## The mission marker: how the chart is armed for one, how the wheel sizes it, and what it answers
## with. The rule this exists to pin down is the WIDTH — the marker's size step is the only part of
## the feature that is a pure function (the laying, the circle and the line all need a viewport), and
## it is the part a notch can quietly break: a point that grows to a metre is a point the player
## cannot see, and a zone that comes back as a zero is a POI the service refuses.
##
## Preloading the chart script is deliberate, as in test_star_map.gd: it forces the whole screen to
## compile, so a marker that no longer parses is a failure here rather than a surprise at F2.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_mission_repere.gd

const STAR_MAP := preload("res://scenes/ui/star_map/star_map.gd")
const GESTURES := preload("res://scenes/ui/star_map/star_map_gestures.gd")


# ---------------------------------------------------------------------------
# Arming: what a form handing the chart a place gets back
# ---------------------------------------------------------------------------

## The form's radius is the marker's STARTING width, and the mode is on from that call: the chart
## answers only while armed, and it never lays a marker of its own — the menu does that.
func test_arming_takes_the_radius_the_form_asked_with_and_lays_nothing() -> void:
	var chart = STAR_MAP.new()
	autofree(chart)
	chart.begin_poi_place(1500.0)
	assert_true(chart.is_placing_poi(), "arming is what makes the menu offer the marker at all")
	assert_eq(chart._mission_radius_m, 1500.0, "the form's width is where the wheel starts")
	assert_false(chart._has_mission_repere(), "arming never lays a marker — the player does")
	chart.end_poi_place()
	assert_false(chart.is_placing_poi(), "and the answer ends it, whatever the answer was")


## A form that asks for a place without a width (the points-of-interest form with a cleared field)
## arms just the same: a point is a legitimate marker, not a missing one.
func test_arming_without_a_radius_means_a_point_and_still_arms() -> void:
	var chart = STAR_MAP.new()
	autofree(chart)
	chart.begin_poi_place()
	assert_true(chart.is_placing_poi())
	assert_eq(chart._mission_radius_m, 0.0)


## A width out of the service's bounds cannot be armed (it would only be refused on arrival): the
## chart clamps it, the same bounds MissionPlacePicker validates.
func test_arming_clamps_a_radius_the_service_would_refuse() -> void:
	var chart = STAR_MAP.new()
	autofree(chart)
	chart.begin_poi_place(99999999.0)
	assert_eq(chart._mission_radius_m, STAR_MAP.MISSION_RADIUS_MAX_M)
	chart.begin_poi_place(-40.0)
	assert_eq(chart._mission_radius_m, 0.0, "a negative width is a point, not a smaller one")


# ---------------------------------------------------------------------------
# The wheel: the step every zoom gesture goes through
# ---------------------------------------------------------------------------

## The first notch on a point lands on something visible: a metre is a dot on a planet, and a marker
## the player cannot see is a marker they cannot size.
func test_a_point_grows_to_something_the_eye_can_see() -> void:
	assert_eq(STAR_MAP.mission_radius_after(0.0, true, STAR_MAP.MISSION_RADIUS_STEP),
			STAR_MAP.MISSION_RADIUS_START_M)


## Shrinking a point is a point: the wheel must not invent a negative zone on the way past none.
func test_shrinking_a_point_leaves_a_point() -> void:
	assert_eq(STAR_MAP.mission_radius_after(0.0, false, STAR_MAP.MISSION_RADIUS_STEP), 0.0)


## One notch, both ways: the ratio is the zoom's own, so the wheel means the same thing whatever it
## is sizing.
func test_one_notch_moves_by_the_step_in_both_directions() -> void:
	var step: float = STAR_MAP.MISSION_RADIUS_STEP
	assert_almost_eq(STAR_MAP.mission_radius_after(100.0, true, step), 115.0, 0.0001)
	assert_almost_eq(STAR_MAP.mission_radius_after(115.0, false, step), 100.0, 0.0001)


## Down to the last metre, the next notch is the POINT, not a fraction of one: 0.9 m of radius on a
## planet is the same statement as no zone at all, and the service refuses it.
func test_a_width_under_a_metre_reads_as_the_point_it_came_from() -> void:
	assert_eq(STAR_MAP.mission_radius_after(1.0, false, STAR_MAP.MISSION_RADIUS_STEP), 0.0,
			"1.0 m is the last legal width; its notch lands back on the point")
	assert_eq(STAR_MAP.mission_radius_after(1.5, false, 4.0), 0.0,
			"any step that would land under a metre is the point, not a truncation")


## The service's own ceiling: past it, further notches are still the ceiling — the map refuses what
## the service would, so no 400 comes back from a zone the player was never allowed to make.
func test_the_wheel_stops_where_the_service_stops() -> void:
	var top: float = STAR_MAP.MISSION_RADIUS_MAX_M
	assert_eq(STAR_MAP.mission_radius_after(top, true, STAR_MAP.MISSION_RADIUS_STEP), top)
	assert_almost_eq(STAR_MAP.mission_radius_after(900000.0, true, 1.5), top, 0.0001,
			"an overshoot lands ON the bound, not past it")


## The invariant behind all of the above: whatever the gesture, the answer is a point (0) or a width
## the service accepts. A result of 0.4 or 1000001 is a POI creation waiting to fail.
func test_every_step_leaves_a_point_or_a_legal_width() -> void:
	for radius: float in [0.0, 1.0, 9.5, 10.0, 1234.0, 999999.0, 1000000.0]:
		for up: bool in [true, false]:
			for factor: float in [STAR_MAP.MISSION_RADIUS_STEP, 6.0, 1.02]:
				var next: float = STAR_MAP.mission_radius_after(radius, up, factor)
				var legal: bool = next == 0.0 \
						or (next >= STAR_MAP.MISSION_RADIUS_MIN_M
						and next <= STAR_MAP.MISSION_RADIUS_MAX_M)
				assert_true(legal, "radius %s up=%s factor=%s gave %s"
						% [radius, up, factor, next])


# ---------------------------------------------------------------------------
# The frame: the place a marker makes is the BODY's own
# ---------------------------------------------------------------------------

## The place a marker lays down is compared with a player's presence, and every place in the game
## is the body's own: the client's [method PlayerLocation.presence_of] and the server's
## [method GameServer.mission_place_of] both answer `planet.to_local(...)`.
##
## The chart DRAWS a body turned on its axis and tipped over, so the offset it measures is in the
## universe. Handing that over as it stands compares two frames that differ by the body's own
## rotation — up to the whole radius, thousands of kilometres — and the mission's point was that
## far from the player who laid it. No radius ever matched it.
func test_a_marker_lands_in_the_body_frame_and_not_in_the_universe_one() -> void:
	var spin := Basis(Vector3.UP, PI * 0.5)  # a quarter turn: the worst kind of day for a place
	var drawn := spin * Vector3.RIGHT * 1000.0
	var place: Vector3 = STAR_MAP.body_local_offset(spin, drawn)
	assert_almost_eq(place.length(), 1000.0, 0.001, "the distance to the centre is the same either way")
	assert_almost_eq(place.dot(Vector3.RIGHT), 1000.0, 0.001,
			"the place is the body's own direction, not the universe's")
	assert_almost_eq(place.dot(spin * Vector3.RIGHT), 0.0, 0.001,
			"and not the universe's either")


## A body that never turns and is never tipped has an identity basis: the two frames are the same,
## and nothing is turned. A plain subtraction stays the answer.
func test_a_body_that_never_turns_keeps_its_own_frame() -> void:
	var offset := Vector3(120.0, 6000000.0, -35.0)
	assert_eq(STAR_MAP.body_local_offset(Basis.IDENTITY, offset), offset)


## And the turn is the other way round too: a place in the body's frame, drawn back into the
## universe, is where the chart drew it. That is the round trip the chart's own POI layer does.
func test_a_place_in_the_body_frame_draws_back_where_the_chart_drew_it() -> void:
	var spin := Basis(Vector3.BACK, deg_to_rad(23.0)) * Basis(Vector3.UP, PI * 0.75)
	var drawn := spin * Vector3(0.3, 0.9, -0.2).normalized() * 4500.0
	var place: Vector3 = STAR_MAP.body_local_offset(spin, drawn)
	var back: Vector3 = spin * place
	assert_almost_eq(back.dot(drawn), drawn.length(), 0.001,
			"the same spot, seen from the same side")


# ---------------------------------------------------------------------------
# The menu: what it may offer, and never twice under the same name
# ---------------------------------------------------------------------------

## The marker's two lines sit clear of the vanilla three's ids: an id that collided would lay a
## marker when the player asked to copy coordinates.
func test_the_menu_ids_do_not_collide_with_the_vanilla_items() -> void:
	assert_gt(GESTURES.MISSION_SET, 2, "the vanilla menu owns 0..2")
	assert_gt(GESTURES.MISSION_CLEAR, 2, "and so does everything below the marker's lines")
	assert_ne(GESTURES.MISSION_SET, GESTURES.MISSION_CLEAR)
