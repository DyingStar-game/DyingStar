extends GutTest

## "Locate on the chart" framed an inspection zone of M0001 on Tarsis III 15 degrees away from it
## (playtest 2026-11-28: the zone at 39.43 W 25.15 N, the chart at 26.30 W 13.29 N). The zone was right,
## planet-local as every service place; the chart turned it onto a sphere it had just built and not yet
## turned (StarMap._rebuild, then _frame_on_surface in the same breath), and once the body took its 15
## degree tilt and its spin the camera looked at another place. A reopened chart does exactly that.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_locate_frame.gd

const BODY := "tarsis_3"
## M0001's cargo depot and its inspection zone M0001-A, as the mission service wrote them (metres from the
## planet's centre, in its own frame: the universe simulator's village position, inspections.rs point_at).
const VILLAGE := Vector3(4450564.21, 2674089.9, 3675867.71)
const ZONE := Vector3(4448599.16471058, 2703480.72995589, 3657437.31945392)
## Where the HUD puts the two (HEALPix.vec2lonlat, degrees), and the 35 km the mission's title gives.
const VILLAGE_LONLAT := Vector2(-39.5544, 24.8565)
const ZONE_LONLAT := Vector2(-39.4255, 25.1468)
const ZONE_KM := 34.8
const TARSIS_RADIUS_KM := 6356.0


## The data: the zone is 35 km from its village, where the HUD reads both, not 15 degrees away.
func test_the_zone_is_where_the_service_says() -> void:
	var village: Vector2 = HEALPix.vec2lonlat(VILLAGE)
	var zone: Vector2 = HEALPix.vec2lonlat(ZONE)
	assert_almost_eq(village.x, VILLAGE_LONLAT.x, 0.001, "the village's longitude")
	assert_almost_eq(village.y, VILLAGE_LONLAT.y, 0.001, "and its latitude")
	assert_almost_eq(zone.x, ZONE_LONLAT.x, 0.001, "the zone's longitude")
	assert_almost_eq(zone.y, ZONE_LONLAT.y, 0.001, "and its latitude")
	assert_almost_eq(VILLAGE.angle_to(ZONE) * TARSIS_RADIUS_KM, ZONE_KM, 0.5, "35 km from the village")


## The chart: built afresh and asked at once, it frames the zone where the zone is on the turned body.
func test_a_chart_built_afresh_frames_the_place_it_is_asked_for() -> void:
	var chart := StarMap.new()
	add_child_autofree(chart)
	chart.open()
	var body: int = chart._index_of_key(BODY)
	assert_gt(body, -1, "sanity: %s is on the chart" % BODY)
	if body < 0:
		return
	assert_false(chart._dressed, "sanity: the bodies were just built and not yet turned, as on a reopening")
	assert_true(chart._focus_local_place(body, ZONE, StarMap.PLACE_FOCUS_ALTITUDE_M), "framed")
	var drawn: Basis = (chart._bodies[body]["sphere"] as MeshInstance3D).basis
	assert_lt(drawn.orthonormalized().y.dot(Vector3.UP), cos(deg_to_rad(10.0)),
			"sanity: the body is drawn tilted, which is what moved the place")
	# What the camera looks from, read back on the body as the cursor's readout reads it.
	var aimed: Vector2 = HEALPix.vec2lonlat(StarMap.body_local_offset(drawn, chart._camera_aim()))
	assert_almost_eq(aimed.x, ZONE_LONLAT.x, 0.01, "over the zone's longitude")
	assert_almost_eq(aimed.y, ZONE_LONLAT.y, 0.01, "and its latitude")
