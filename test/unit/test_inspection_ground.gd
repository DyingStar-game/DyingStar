extends GutTest

## The simulator's inspection sites, laid on the ground by the game server (InspectionGround): a site
## keeps its direction from the planet's centre and takes the ground's distance there.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_inspection_ground.gd


func test_a_site_goes_to_the_ground_under_it() -> void:
	var position := Vector3(3.0e6, 4.0e6, 0.0)  # 5 000 km from the centre
	var ground := InspectionGround.on_ground(position, func(_direction: Vector3) -> float: return 5.002e6)
	assert_almost_eq(ground.length(), 5.002e6, 1.0, "at the ground's distance: 2 km up")
	assert_almost_eq(ground.normalized().dot(position.normalized()), 1.0, 1.0e-9, "straight above where it was")


func test_the_ground_is_asked_for_the_sites_direction() -> void:
	var asked: Array = []
	InspectionGround.on_ground(Vector3(0.0, 0.0, -7.0e6), func(direction: Vector3) -> float:
		asked.append(direction)
		return 1.0)
	assert_eq(asked, [Vector3(0.0, 0.0, -1.0)])
	assert_eq(InspectionGround.on_ground(Vector3.ZERO, func(_d: Vector3) -> float: return 1.0), Vector3.ZERO)


func test_a_site_of_no_known_planet_or_without_a_place_is_left() -> void:
	var item := {"id": "a", "scene": "tarsis_3", "position": {"x": 1.0, "y": 2.0, "z": 3.0}}
	assert_null(InspectionGround.ground_of(item, []), "its planet is not here")
	assert_null(InspectionGround.ground_of({"id": "a", "scene": "tarsis_3", "position": {"x": 1.0, "y": null, "z": 3.0}}, []))
	assert_null(InspectionGround.ground_of({"id": "a", "scene": "tarsis_3"}, []))
	assert_null(InspectionGround.ground_of(null, []))
