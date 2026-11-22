extends GutTest
## In VR the 2D is a panel in the headset (XRScreen): in game the HUD follows the head with some
## leeway; a menu opening comes in front of the eyes and stays there while the laser points at it.

var _screen: XRScreen = null


func before_each() -> void:
	_screen = XRScreen.new()
	_screen._viewport = SubViewport.new()
	_screen._viewport.size = Vector2i(100, 100)
	_screen._build_nodes()


func after_each() -> void:
	_screen._layer.free()
	for hand: Node in _screen._pointers:
		hand.free()
	_screen._viewport.free()
	_screen.free()


## The panel's direction (deg, around the vertical) from the eyes at the origin.
func _bearing() -> float:
	var away: Vector3 = _screen._layer.position
	return rad_to_deg(atan2(-away.x, -away.z))


func _look(yaw_deg: float, menu: bool, seconds: float = 3.0) -> void:
	var head := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), Vector3.ZERO)
	var opening: bool = menu and not _screen._menu_was
	for i in int(seconds / 0.05):
		_screen._follow_head(head, 0.05, menu, opening and i == 0)
	_screen._menu_was = menu


func test_the_panel_starts_in_front_of_the_eyes() -> void:
	_look(0.0, false, 0.05)
	assert_almost_eq(_screen._layer.position,
			Vector3(0.0, -XRScreen.BELOW_EYES_M, -XRScreen.DISTANCE_M), Vector3.ONE * 1e-4)


func test_in_game_the_hud_follows_past_its_leeway() -> void:
	_look(0.0, false)
	_look(20.0, false)
	assert_almost_eq(_bearing(), 0.0, 0.5, "20 deg: within the leeway, it stays")
	_look(40.0, false)
	assert_almost_eq(_bearing(), 40.0, 0.5, "40 deg: it catches up")


func test_a_menu_opens_in_front_of_the_eyes_and_stays() -> void:
	_look(0.0, false)
	_look(20.0, true)
	assert_almost_eq(_bearing(), 20.0, 0.5, "opening: straight ahead, even within the HUD's leeway")
	_look(-25.0, true)
	assert_almost_eq(_bearing(), 20.0, 0.5, "45 deg away while pointing at it: it does not move")
	_look(-50.0, true)
	assert_almost_eq(_bearing(), -50.0, 0.5, "70 deg away: it comes back")
