class_name CaveExplorerInput
extends RefCounted
## Keyboard navigation for the separate authoring window. Native game actions also
## contain analog controller axes; these must not steer a mouse/keyboard placement camera.


var _held: Dictionary = {}


func handle_key(event: InputEventKey) -> void:
    var key := event.physical_keycode if event.physical_keycode != 0 else event.keycode
    if not event.pressed:
        _held.erase(key)
    elif not event.echo:
        _held[key] = event.duplicate()


func reset() -> void:
    _held.clear()


func physical_pressed(keycode: Key) -> bool:
    return _held.has(keycode)


func movement(enabled: bool) -> Vector2:
    if not enabled:
        return Vector2.ZERO
    return Vector2(float(keyboard_pressed("move_right")) - float(keyboard_pressed("move_left")),
        float(keyboard_pressed("move_back")) - float(keyboard_pressed("move_forward"))).limit_length(1.0)


## Read the configured keyboard bindings, not the shared action's analog or latched state.
func keyboard_pressed(action: String) -> bool:
    for key: InputEventKey in _held.values():
        if key.is_action(action):
            return true
    return false
