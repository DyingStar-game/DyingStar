extends GutTest
## ScreenTarget: a 3D screen is aimed at, named in the action, and found again by the server within
## reach — no proximity box in front of it any more (they froze the view of anyone walking past).

var _building: Node3D
var _screen: Node3D
var _gui: Node3D
var _field: LineEdit


func before_each() -> void:
	_building = Node3D.new()
	var sync: Node = load("res://scenes/globals/prop_sync.gd").new()
	sync.name = "PropSync"
	sync.uuid = "building-uuid"
	_building.add_child(sync)
	var owner_script := GDScript.new()
	owner_script.source_code = ("extends Node3D\nvar events: int = 0\n"
			+ "func update_screen(_data: Dictionary) -> void:\n\tpass\n"
			+ "func screen_event(_event: Dictionary) -> void:\n\tevents += 1\n")
	owner_script.reload()
	_screen = Node3D.new()
	_screen.name = "Console"
	_screen.set_script(owner_script)
	_screen.position = Vector3(0, 0, -10)
	_building.add_child(_screen)
	_gui = Node3D.new()
	_gui.set_script(load("res://scenes/interactables/gui_3d.gd"))
	var viewport := SubViewport.new()
	_field = LineEdit.new()
	viewport.add_child(_field)
	_gui.add_child(viewport)
	_gui.node_viewport = viewport
	_screen.add_child(_gui)
	add_child_autofree(_building)
	ScreenTarget._last_at.clear()


func test_a_screen_is_named_by_its_networked_node_and_path() -> void:
	assert_true(ScreenTarget.owner_of(_gui) == _screen, "the Gui3D's owner is the node with update_screen()")
	assert_true(ScreenTarget.gui_of(_screen) == _gui, "and its Gui3D is found from it")
	assert_eq(ScreenTarget.address_of(_screen), {"target_uuid": "building-uuid", "screen": "Console"})


func test_a_machine_networked_on_its_own_is_named_by_itself_and_inside_a_building_by_the_building() -> void:
	var own: Node = load("res://scenes/globals/prop_sync.gd").new()
	own.name = "PropSync"
	_screen.add_child(own)
	assert_eq(ScreenTarget.address_of(_screen), {"target_uuid": "building-uuid", "screen": "Console"},
			"no uuid of its own (placed in a garage): the building names it")
	assert_true(MarkerSpawn.building_of(_gui) == _building, "and it belongs to the building")
	own.uuid = "machine-uuid"
	assert_eq(ScreenTarget.address_of(_screen), {"target_uuid": "machine-uuid", "screen": "."},
			"spawned by a village layout: it is its own networked node")


func test_an_event_said_again_is_handled_once() -> void:
	var event: Dictionary = {"target_uuid": "building-uuid", "screen": "Console", "at": 100.0}
	ScreenTarget.receive(get_tree(), event)
	ScreenTarget.receive(get_tree(), event.duplicate())
	assert_eq(_screen.events, 1, "Horizon sends it again with each turn of the head: the fan must not restart")
	event["at"] = 101.0
	ScreenTarget.receive(get_tree(), event)
	assert_eq(_screen.events, 2, "a new delivery is a new event")


func test_the_server_finds_it_only_within_reach() -> void:
	var data: Dictionary = ScreenTarget.address_of(_screen)
	assert_true(ScreenTarget.resolve(_building, data, Vector3(0, 1.7, -8)) == _screen, "2 m away: found")
	assert_true(ScreenTarget.resolve(_building, data, Vector3(0, 1.7, 5)) == null, "15 m away: refused")
	assert_true(ScreenTarget.resolve(_building, {"screen": "Nothing"}, Vector3(0, 1.7, -8)) == null, "no such screen")
	assert_true(ScreenTarget.resolve(null, data, Vector3(0, 1.7, -8)) == null, "no such building")


func test_its_keyboard_is_given_back() -> void:
	_field.grab_focus()
	assert_true(_field.has_focus())
	_gui.release_keyboard()
	assert_false(_field.has_focus(), "a click while typing, or walking away, frees the keys")


func test_an_announced_delivery_is_joined_at_the_right_second() -> void:
	var event: Dictionary = {"at": 100.0}
	assert_eq(ScreenTarget.time_left(event, 5.0, 102.0), 3.0, "2 s in: 3 s left")
	assert_eq(ScreenTarget.time_left(event, 5.0, 200.0), 0.0, "long over: nothing to show (a re-broadcast)")
	assert_eq(ScreenTarget.time_left(event, 5.0, 99.0), 5.0, "a clock a little behind: never more than it lasts")
