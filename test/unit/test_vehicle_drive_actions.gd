extends GutTest
## Accelerate and slow down at the wheel are actions of the vehicle's own (Settings > Controls >
## Vehicle). The wheel read the walk's move_forward / move_back: a pad player could not put the throttle
## on the triggers without moving the walk off the stick, and the Vehicle tab had no line for it.

const DRIVE : Dictionary = {&"vehicle_accelerate": &"move_forward", &"vehicle_decelerate": &"move_back"}


func before_each() -> void:
	InputMap.load_from_project_settings()


func after_each() -> void:
	InputMap.load_from_project_settings()


func test_they_are_lines_of_the_vehicle_tab() -> void:
	var vehicle : Dictionary = MenuConfig.labels_of(MenuConfig.ACTION_GROUPS["%%KM_GROUP_VEHICLE"])
	for action: StringName in DRIVE:
		assert_true(vehicle.has(String(action)), "%s in the Vehicle tab" % action)


## Nothing changes for whoever never opens the page: the same key and the same stick as the walk.
func test_by_default_they_sit_on_the_walk_s_keys() -> void:
	for action: StringName in DRIVE:
		var walk : StringName = DRIVE[action]
		for kind: InputDevice.Kind in [InputDevice.Kind.KEYBOARD_MOUSE, InputDevice.Kind.GAMEPAD]:
			assert_eq(_names(action, kind), _names(walk, kind), "%s like %s" % [action, walk])


func test_the_throttle_on_a_trigger_leaves_the_walk_on_the_stick() -> void:
	var trigger := InputEventJoypadMotion.new()
	trigger.axis = JOY_AXIS_TRIGGER_RIGHT
	trigger.axis_value = 1.0
	var walk_before : Array = _names(&"move_forward", InputDevice.Kind.GAMEPAD)
	InputDevice.rebind(&"vehicle_accelerate", trigger)
	assert_eq(_names(&"vehicle_accelerate", InputDevice.Kind.GAMEPAD), [InputLabel.for_event(trigger)])
	assert_eq(_names(&"move_forward", InputDevice.Kind.GAMEPAD), walk_before, "the walk keeps its stick")


func _names(action: StringName, kind: InputDevice.Kind) -> Array:
	return InputDevice.bindings(action, kind).map(func(e: InputEvent) -> String: return InputLabel.for_event(e))
