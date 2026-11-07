extends GutTest
## One player at a time on a world screen, the others watch (ScreenLock): the server gives the screen
## to the first who acts on it, refuses the others while they stay near it, frees it once they walk
## away; a watcher's client knows who is using it and shows the user's view.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_screen_lock.gd -gexit


## A screen's owner: the ScreenTarget contract, and a Gui3D stand-in in the screens' group.
class Screen extends Node3D:
	var gui := Node3D.new()

	func _ready() -> void:
		gui.add_to_group(ScreenTarget.GROUP)
		add_child(gui)

	func update_screen(_data: Dictionary) -> void:
		pass


## What the lock asks of a player: an id, a name, and the property channel announce writes to.
class Someone extends Node3D:
	var client_uuid := ""
	var sent: Array = []

	func server_send_properties_to_client(data: Dictionary) -> void:
		sent.append(data)

	func horizon_id() -> String:
		return client_uuid


## A screen UI with the view contract.
class Ui extends Node:
	var shown: Dictionary = {}

	func view_state() -> Dictionary:
		return {"page": 1}

	func apply_view_state(view: Dictionary) -> void:
		shown = view


var _screen: Screen
var _a: Someone
var _b: Someone


func before_each() -> void:
	_screen = Screen.new()
	add_child_autofree(_screen)
	_a = _someone("a", Vector3(0, 0, 2))
	_b = _someone("b", Vector3(1, 0, 2))


func _someone(id: String, at: Vector3) -> Someone:
	var p := Someone.new()
	p.client_uuid = id
	p.name = "player-" + id
	p.add_to_group("player")
	add_child_autofree(p)
	p.global_position = at
	return p


func test_the_first_to_act_holds_the_screen_and_the_other_is_refused() -> void:
	assert_true(ScreenLock.claim(_screen, _a), "free: A takes it")
	assert_eq(ScreenLock.holder(_screen), _a)
	assert_true(ScreenLock.claim(_screen, _a), "A again: still A's")
	assert_false(ScreenLock.claim(_screen, _b), "B is refused while A is at it")
	assert_eq(_a.sent.size(), 1, "the lock was told to the clients around, through A")


func test_walking_away_frees_the_screen() -> void:
	ScreenLock.claim(_screen, _a)
	_a.global_position = Vector3(0, 0, ScreenTarget.USE_RANGE_M + 2.0)
	assert_null(ScreenLock.holder(_screen), "out of reach: nobody holds it")
	ScreenLock.release_away(get_tree())
	var last: Dictionary = (_a.sent.back() as Dictionary)["screen_event"]
	assert_eq(str(last["holder"]), "", "the release is told too")
	assert_true(ScreenLock.claim(_screen, _b), "B may use it now")


func test_a_watcher_knows_who_uses_it_and_sees_their_view() -> void:
	var ui := Ui.new()
	_screen.gui.add_child(ui)
	ScreenLock.on_event(_screen, {"holder": "a", "holder_name": "player-a", "view": {"page": 3}}, "b")
	assert_eq(ScreenLock.used_by_other(_screen, "b"), "player-a", "B watches A")
	assert_eq(ui.shown, {"page": 3}, "and sees A's page")
	assert_eq(ScreenLock.used_by_other(_screen, "a"), "", "A is not blocked by A")
	assert_true(ScreenLock.is_mine(_screen, "a"))
	_a.global_position = Vector3(0, 0, ScreenTarget.USE_RANGE_M + 2.0)
	assert_eq(ScreenLock.used_by_other(_screen, "b"), "", "A walked off: not held, whatever was heard")
	ScreenLock.on_event(_screen, {"holder": ""}, "b")
	assert_false(ScreenLock.is_mine(_screen, "a"), "released")
