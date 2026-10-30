extends GutTest
## The atelier must ignore controller drift and stale shared action intent, while respecting key bindings.


func after_each() -> void:
    Input.action_release("move_right")


func test_analog_action_cannot_steer_the_authoring_camera() -> void:
    var navigation := CaveExplorerInput.new()
    Input.action_press("move_right", 0.6)
    assert_gt(Input.get_vector("move_left", "move_right", "move_forward", "move_back").x, 0.0,
        "native game action reproduces a controller steering right")
    assert_eq(navigation.movement(true), Vector2.ZERO,
        "the authoring camera only accepts configured keyboard keys")
    Input.action_release("move_right")


func test_keyboard_stops_on_release_and_focus_reset() -> void:
    var navigation := CaveExplorerInput.new()
    var binding: InputEventKey
    for event: InputEvent in InputMap.action_get_events("move_right"):
        if event is InputEventKey:
            binding = event.duplicate()
            break
    assert_not_null(binding)
    if binding == null:
        return
    binding.pressed = true
    navigation.handle_key(binding)
    assert_eq(navigation.movement(true), Vector2.RIGHT)
    assert_eq(navigation.movement(false), Vector2.ZERO, "UI focus disables movement")
    binding.pressed = false
    navigation.handle_key(binding)
    assert_eq(navigation.movement(true), Vector2.ZERO, "released key stops immediately")
    binding.pressed = true
    navigation.handle_key(binding)
    navigation.reset()
    assert_eq(navigation.movement(true), Vector2.ZERO, "focus reset clears a held key")
    binding.echo = true
    navigation.handle_key(binding)
    assert_eq(navigation.movement(true), Vector2.ZERO, "OS key repeat cannot resume a cleared command")


func test_existing_actions_and_controller_bindings_are_not_rewritten() -> void:
    var before := InputMap.action_get_events("move_right")
    CaveExplorerInput.new().movement(true)
    assert_eq(InputMap.action_get_events("move_right"), before)
