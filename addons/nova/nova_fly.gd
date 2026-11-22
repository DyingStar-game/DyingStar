@tool
extends Node
## Nova's flight mode: move the editor's 3D view over the body like a game camera in god mode.
##
## Flying: Z Q S D (the W A S D positions of any keyboard layout) move along the ground the way the view
## faces, Space climbs, Ctrl or C descends, Shift goes faster. The speed follows the height: metres a second
## near the ground, the whole planet in view after a dozen seconds of Space. The view never goes under the
## ground.
##
## On foot ([member walking], key G): the view stands at a player's eye height, follows the relief and moves
## at walking pace, Shift to run. Space takes off again. No physics and no collision with what stands on the
## ground: only the ground itself is followed.
##
## Turning the view stays Godot's own: hold the right mouse button.
##
## Editor only, and nothing is saved: the body is rolled under the camera (PlanetTerrain.editor_fly), the way
## the "go to" buttons do, and the scene file never sees it.

## [member walking] changed (the G key or a take-off): for the dock's button.
signal walking_changed(on: bool)

## Positions of the keys, whatever the layout prints on them: W A S D here are Z Q S D on AZERTY.
const MOVES := {
	KEY_W: Vector3.FORWARD, KEY_S: Vector3.BACK, KEY_A: Vector3.LEFT, KEY_D: Vector3.RIGHT,
	KEY_SPACE: Vector3.UP, KEY_C: Vector3.DOWN, KEY_CTRL: Vector3.DOWN,
}
const WALK_KEY := KEY_G
## Flying speed as a share of the height above the ground, each second; never under MIN_SPEED m/s.
const SPEED_PER_HEIGHT := 0.8
const MIN_SPEED := 4.0
const SHIFT_FACTOR := 4.0
## Closest the flying view comes to the ground, metres.
const CLEARANCE := 2.0
## On foot: eye height, walking and running speeds (m, m/s).
const EYE_HEIGHT := 1.7
const WALK_SPEED := 5.0
const RUN_FACTOR := 3.0
## Godot's own free-look speed while the mode is on: its W A S D would move the view too, at the planet-scale
## speed PlanetTerrain tunes it to. The user's value is put back when the mode goes off.
const FREELOOK_SPEED := "editors/3d/freelook/freelook_base_speed"

## The body's terrain the view moves over (set by the dock), null when its scene is not open.
var terrain: Node
## On while the user wants to fly or walk.
var enabled := false:
	set(v):
		if v == enabled:
			return
		enabled = v
		var settings := EditorInterface.get_editor_settings()
		if enabled:
			_freelook_speed = settings.get_setting(FREELOOK_SPEED)
			settings.set_setting(FREELOOK_SPEED, 0.0)
		else:
			walking = false
			if _freelook_speed != null:
				settings.set_setting(FREELOOK_SPEED, _freelook_speed)
## On foot instead of flying. Turns [member enabled] on with it.
var walking := false:
	set(v):
		if v == walking:
			return
		walking = v
		if walking:
			enabled = true
		walking_changed.emit(walking)
## Move only while the mouse is over the 3D view (off for unattended checks).
var needs_hover := true

var _freelook_speed: Variant


func _exit_tree() -> void:
	enabled = false


## The mode's keys never reach the editor while it is on and the mouse is over the 3D view: Q, W, E are its
## select / move / rotate shortcuts, and Ctrl (descend) with Z, S or D would undo, save or duplicate.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if not enabled or key == null or key.alt_pressed or key.meta_pressed or not _over_view():
		return
	if key.physical_keycode == WALK_KEY:
		if key.pressed and not key.echo:
			walking = not walking
	elif not MOVES.has(key.physical_keycode):
		return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not enabled or terrain == null or not is_instance_valid(terrain) or not _over_view():
		return
	if Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META):
		return
	var wish := Vector3.ZERO
	for key: Key in MOVES:
		if Input.is_physical_key_pressed(key):
			wish += MOVES[key]
	if walking and wish.y > 0.0:
		walking = false  # Space: take off
	if wish == Vector3.ZERO and not walking:
		return
	var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	var fast := Input.is_key_pressed(KEY_SHIFT)
	var step := delta * (WALK_SPEED * (RUN_FACTOR if fast else 1.0) if walking else
			maxf(MIN_SPEED, float(terrain.editor_camera_height()) * SPEED_PER_HEIGHT) * (SHIFT_FACTOR if fast else 1.0))
	# Along the ground: the view's own right and forward. Looking straight down, "forward" is the top of the
	# screen. editor_fly keeps only what is level.
	var basis := cam.global_transform.basis
	var forward := -basis.z if absf(basis.z.dot(terrain.editor_camera_up())) < 0.95 else basis.y
	var move := (basis.x * wish.x + forward * -wish.z).limit_length(1.0) * step
	if walking:
		terrain.editor_fly(move, 0.0, EYE_HEIGHT, true)  # every frame: the view settles on the relief
	else:
		terrain.editor_fly(move, clampf(wish.y, -1.0, 1.0) * step, CLEARANCE)


## Is the mouse over the 3D view, with no text field holding the keyboard.
func _over_view() -> bool:
	if not needs_hover:
		return true
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	var hovered := get_viewport().gui_get_hovered_control()
	# The SubViewport's container and the controls laid over it share one parent: the editor's 3D view.
	var view := EditorInterface.get_editor_viewport_3d(0).get_parent().get_parent()
	return hovered != null and (hovered == view or view.is_ancestor_of(hovered))
