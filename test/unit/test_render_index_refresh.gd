extends GutTest
## RenderIndexRefresh: after a step of the planet, which past places of the camera the renderer's tree
## may still hold the instances at -- the ones the engine's relative tolerance let it skip.

const REFRESH := preload("res://scenes/player/render_index_refresh.gd")

## Tarsis 3 on 2026-11-18: where the camera stood, and what one step of the planet moved it by.
const EYE := Vector3(75609305484.0, -35114139273.0, -15075759256.0)
const STEP := Vector3(-23427.0, 11258.0, -134974.0)
const BODY := Vector3(75607233669.0, -35117480374.0, -15070624875.0)


## The body's transform [param steps] steps ago: it only slid along its orbit.
func _body(steps: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, BODY - STEP * steps)


func test_a_step_under_the_tolerance_is_looked_for_where_the_camera_stood() -> void:
	var history: Array[Transform3D] = [_body(1)]
	var centres := REFRESH.stale_centres(history, _body(0), EYE)
	assert_eq(centres.size(), 1, "137 km at 85 million km of the star: the tree may have skipped it")
	assert_almost_eq(centres[0].distance_to(EYE - STEP), 0.0, 0.01, "the same spot on the body, one step back")


func test_it_stops_at_the_first_step_the_engine_has_surely_seen() -> void:
	var history: Array[Transform3D] = []
	for steps in range(1, 11):
		history.append(_body(steps))
	var centres := REFRESH.stale_centres(history, _body(0), EYE)
	# 1e-5 of 84.7 million km is 847 km (932 km with the margin): six steps of 137 km, not seven.
	assert_eq(centres.size(), 6, "the steps within the tolerance, newest first")
	assert_almost_eq(centres[5].distance_to(EYE - STEP * 6.0), 0.0, 0.01, "the sixth step back is the last")


func test_a_body_at_the_origin_needs_no_mending() -> void:
	# A planet centred on the origin turning by one step (280 urad): 1.8 km at its surface, far over
	# the 69 m the engine tolerates there. The tree is right, nothing is filed again.
	var eye := Vector3(6300000.0, 0.0, 0.0)
	var history: Array[Transform3D] = [Transform3D.IDENTITY]
	var now := Transform3D(Basis(Vector3.UP, 280e-6), Vector3.ZERO)
	assert_eq(REFRESH.stale_centres(history, now, eye).size(), 0)


func test_the_tolerance_grows_with_the_distance_to_the_origin() -> void:
	assert_almost_eq(REFRESH.tolerance_m(Vector3(1000.0, 0.0, 0.0)), 0.011, 1e-6, "11 mm a kilometre out")
	assert_almost_eq(REFRESH.tolerance_m(EYE), 931890.0, 100.0, "932 km at Tarsis 3")


func test_the_carrying_body_is_the_nearest_planet_above() -> void:
	var planet: Planet = autofree(Planet.new())
	var moon: Planet = Planet.new()
	planet.add_child(moon)
	var on_planet := Node3D.new()
	planet.add_child(on_planet)
	var seat := Node3D.new()
	on_planet.add_child(seat)
	var on_moon := Node3D.new()
	moon.add_child(on_moon)
	assert_eq(REFRESH.carrying_body(seat), planet, "through a vehicle, a building")
	assert_eq(REFRESH.carrying_body(on_moon), moon, "a moon before its planet")
	var adrift: Node3D = autofree(Node3D.new())
	assert_null(REFRESH.carrying_body(adrift), "open space: nothing steps")
