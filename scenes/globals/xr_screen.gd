class_name XRScreen
extends Node
## The game's 2D, in VR: a headset shows only the 3D world, and the menus, the HUD, the pause menu, every
## overlay are 2D. Built by XRManager in VR only.
##
## - What the main window would draw in 2D is drawn into a SubViewport instead: every CanvasLayer of the
##   main viewport renders there (custom_viewport), and the SubViewport shares the main viewport's World2D,
##   so the Controls that sit on its default canvas (the player's HUD) come along. No screen is touched.
## - The SubViewport is shown by an OpenXR quad composition layer: the headset's compositor draws it, sharp
##   and over the world, on any OpenXR runtime (quad layers are core OpenXR). In game (the HUD) it floats
##   in front of the head and catches up when the head turns away (a panel stuck to the eyes is tiring).
##   A menu opening (the mouse let free) puts it straight in front of the eyes, and there it stays while
##   the laser points at it: it moves again only if the head turns well away (MENU_FOLLOW_ANGLE).
## - A laser from the hand points at it while the game frees the mouse (a menu is open): it moves the
##   mouse and the trigger clicks. The events go into the main viewport, where the Controls still live
##   and take their input: the desktop mouse keeps working the same way.
##
## Names no gameplay class (built by an autoload).

## Share (each side) of the main viewport's size the panel is drawn at: 0.5 = a quarter of the video memory
## for text still sharp at arm's length.
const PIXEL_SHARE := 0.5
## Distance (m) from the eyes to the panel.
const DISTANCE_M := 1.4
## Width (m) of the panel; its height follows the main viewport's shape (in VR, the headset's square render size).
const WIDTH_M := 1.2
## How far (m) below the eyes the panel's centre sits: reading slightly down is restful.
const BELOW_EYES_M := 0.1
## The panel catches up once the head looks this far (rad) away from it.
const FOLLOW_ANGLE := deg_to_rad(30.0)
## While a menu is open, the panel stays put until the head looks this far (rad) away from it.
const MENU_FOLLOW_ANGLE := deg_to_rad(60.0)
## How fast (1/s) the panel glides to its new place.
const FOLLOW_RATE := 5.0
## Laser length (m) when it hits nothing.
const LASER_REACH_M := 3.0
## The trigger clicks past this pull (0..1) and lets go under TRIGGER_RELEASE. Read from its analog
## value, not its "click": some triggers click only at the end of their travel, some have no click at all.
const TRIGGER_PRESS := 0.6
## The pull (0..1) under which a held click is let go (below TRIGGER_PRESS: no chatter in between).
const TRIGGER_RELEASE := 0.4
## Radius (px of the panel) of the cursor drawn where the laser meets the panel.
const CURSOR_RADIUS_PX := 9.0
## Seconds between two wheel notches while the stick is pushed (menus scroll).
const SCROLL_REPEAT_S := 0.12
## The stick must go this far (0..1) to scroll.
const SCROLL_DEADZONE := 0.5

var _viewport: SubViewport = null
var _layer: OpenXRCompositionLayerQuad = null
var _origin_id: int = 0  # instance id of the origin the panel hangs on (it may be freed under us)
var _target: Vector3 = Vector3.ZERO
var _placed: bool = false
var _menu_was: bool = false  # the mouse was free (a menu open) last frame
var _pointers: Array[XRController3D] = []
var _lasers: Array[MeshInstance3D] = []
var _trigger_was: Array[bool] = [false, false]
var _hand: int = 1  # the pointing hand: 0 left, 1 right; the last trigger pulled takes it
var _button_down: bool = false
var _mouse_at: Vector2 = Vector2(-1.0, -1.0)
var _scroll_wait: float = 0.0
var _adopted: Array[int] = []  # instance ids of the CanvasLayers drawing into the panel
var _cursor: XRScreenCursor = null
var _profiles: Array[String] = ["", ""]  # the interaction profile each hand last reported (logged on change)


## The dot where the laser meets the panel. The panel is drawn by the headset's compositor OVER the
## whole 3D view, the laser included: without a dot drawn in the 2D, nothing shows what is aimed at.
class XRScreenCursor:
	extends Control

	func _draw() -> void:
		draw_circle(Vector2.ZERO, CURSOR_RADIUS_PX + 3.0, Color(0.0, 0.0, 0.0, 0.6))
		draw_circle(Vector2.ZERO, CURSOR_RADIUS_PX, Color(0.4, 0.85, 1.0))


func _ready() -> void:
	var main := get_tree().root
	_viewport = SubViewport.new()
	_viewport.name = "XRScreenViewport"
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.gui_disable_input = true  # the Controls take their input in the main viewport
	_viewport.world_2d = main.world_2d
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	_fit_to_window()
	main.size_changed.connect(_fit_to_window)
	for layer: Node in main.find_children("*", "CanvasLayer", true, false):
		_adopt(layer)
	get_tree().node_added.connect(_on_node_added)
	var top := CanvasLayer.new()
	top.name = "XRScreenCursorLayer"
	top.layer = 128  # over every screen of the game
	add_child(top)
	top.custom_viewport = _viewport
	# Our child leaves the tree before our _exit_tree runs: it lets go of the panel on its own way out.
	top.tree_exiting.connect(func() -> void: top.custom_viewport = get_tree().root)
	_cursor = XRScreenCursor.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	top.add_child(_cursor)

	_build_nodes()


## The CanvasLayers go back to the main window before the panel's viewport is freed (quitting): left
## pointing at a freed viewport, each one errors as it leaves the tree.
func _exit_tree() -> void:
	for id: int in _adopted:
		var layer := instance_from_id(id) as CanvasLayer
		if layer != null and layer.custom_viewport == _viewport:
			layer.custom_viewport = get_tree().root  # 4.7 refuses null: name the main viewport itself
	_adopted.clear()


func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d() as XRCamera3D
	var origin: XROrigin3D = cam.get_parent() as XROrigin3D if cam != null else null
	if origin == null:
		return
	if origin.get_instance_id() != _origin_id or not is_instance_valid(_layer):
		_hang_on(origin)
	# Shown only while the runtime shows the game (session visible or focused). Headset off the head, the
	# frames are not rendered but the layer still took an image every frame and never gave it back:
	# 898 "image_acquired" errors in 900 frames (2026-11-22).
	var state: int = (XRMode.interface() as OpenXRInterface).get_session_state()
	_layer.visible = state == OpenXRInterface.SESSION_STATE_VISIBLE or state == OpenXRInterface.SESSION_STATE_FOCUSED
	if not _layer.visible:
		return
	var menu := _mouse_free()
	_follow_head(cam.transform, delta, menu, menu and not _menu_was)
	_menu_was = menu
	_point(delta)


## The SubViewport the 2D is drawn into (tests, and whoever must know where the UI is drawn).
func viewport() -> SubViewport:
	return _viewport


## The panel and the pointers live under the XROrigin3D the headset looks from: the menu's, then the
## player's (a composition layer must be a child of the origin).
func _hang_on(origin: XROrigin3D) -> void:
	_origin_id = origin.get_instance_id()
	if not is_instance_valid(_layer) or not is_instance_valid(_pointers[0]) or not is_instance_valid(_pointers[1]):
		_build_nodes()  # freed with the origin they hung on (the player left, its rig with it)
	for node: Node3D in [_layer, _pointers[0], _pointers[1]]:
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		origin.add_child(node)
	_placed = false
	print("[XR] 2D panel on %s (%dx%d px, %.2f x %.2f m, composited by the runtime: %s)" % [origin.get_path(),
			_viewport.size.x, _viewport.size.y, _layer.quad_size.x, _layer.quad_size.y, _layer.is_natively_supported()])


## Keep the panel in front of [param head] (the camera, in the origin's space): it moves only when the
## head has turned FOLLOW_ANGLE away from it -- MENU_FOLLOW_ANGLE in a [param menu] -- then glides there.
## A menu [param opening] brings it in front of the eyes at once. Upright in the origin's frame.
func _follow_head(head: Transform3D, delta: float, menu: bool = false, opening: bool = false) -> void:
	var forward := -head.basis.z
	forward.y = 0.0
	if forward.length_squared() < 1e-4:
		forward = -_layer.transform.basis.z if _placed else Vector3.FORWARD
	forward = forward.normalized()
	var wanted := head.origin + forward * DISTANCE_M + Vector3.DOWN * BELOW_EYES_M
	if not _placed:
		_target = wanted
		_layer.position = wanted
		_placed = true
	else:
		var now := _layer.position - head.origin
		now.y = 0.0
		var leeway: float = MENU_FOLLOW_ANGLE if menu else FOLLOW_ANGLE
		if opening or now.length_squared() < 1e-4 or now.normalized().angle_to(forward) > leeway:
			_target = wanted
		_layer.position = _layer.position.lerp(_target, 1.0 - exp(-FOLLOW_RATE * delta))
	var away := _layer.position - head.origin
	away.y = 0.0
	if away.length_squared() > 1e-6:
		# The quad shows its +Z side: -Z points away from the eyes.
		_layer.basis = Basis.looking_at(away.normalized(), Vector3.UP)


## The laser and the mouse it drives, while the game lets the mouse free (a menu, a screen in use).
func _point(delta: float) -> void:
	var free := _mouse_free()
	for i in 2:
		_log_profile(i)
		var pull := maxf(_pointers[i].get_float(&"trigger"), 1.0 if _pointers[i].is_button_pressed(&"trigger_click") else 0.0)
		var pulled := pull > TRIGGER_PRESS or (_trigger_was[i] and pull > TRIGGER_RELEASE)
		if pulled and not _trigger_was[i]:
			_hand = i
		_trigger_was[i] = pulled
		_lasers[i].visible = free and i == _hand and _pointers[i].get_has_tracking_data()
	if not free:
		_release()
		return
	var hand := _pointers[_hand]
	var from := hand.global_position
	var along := -hand.global_basis.z.normalized()
	var uv := _layer.intersects_ray(from, along)
	var reach := LASER_REACH_M
	if uv.x >= 0.0:
		var at := uv * Vector2(_viewport.size_2d_override)  # the 2D's own coordinates, not the texture's
		reach = from.distance_to(_layer.global_transform * Vector3(
				(uv.x - 0.5) * _layer.quad_size.x, (0.5 - uv.y) * _layer.quad_size.y, 0.0))
		_move_mouse(at)
		_cursor.position = at
		_cursor.visible = true
		_click(_trigger_was[_hand], at)
		_scroll(hand.get_vector2(&"primary").y, at, delta)
	else:
		_release()
	_aim_laser(_lasers[_hand], reach)


## The game lets the mouse free: a menu, a panel, a 3D screen in use.
static func _mouse_free() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_VISIBLE or Input.mouse_mode == Input.MOUSE_MODE_CONFINED


## Which controller the runtime says a hand holds, logged when it changes: the bindings that apply are
## that profile's (xr/openxr_action_map.tres).
func _log_profile(i: int) -> void:
	var tracker := XRServer.get_tracker(_pointers[i].tracker) as XRControllerTracker
	var profile: String = tracker.profile if tracker != null else ""
	if profile != _profiles[i]:
		_profiles[i] = profile
		print("[XR] %s: %s" % [_pointers[i].tracker, profile if profile != "" else "(none)"])


func _move_mouse(at: Vector2) -> void:
	if at == _mouse_at:
		return
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.relative = at - _mouse_at if _mouse_at.x >= 0.0 else Vector2.ZERO
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT if _button_down else 0
	_mouse_at = at
	InputDevice.pointer = true  # pointed at, like a mouse: the menu shows no focus frame (InputDevice)
	get_viewport().push_input(motion, true)


func _click(pulled: bool, at: Vector2) -> void:
	if pulled == _button_down:
		return
	_button_down = pulled
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = pulled
	button.position = at
	button.global_position = at
	button.button_mask = MOUSE_BUTTON_MASK_LEFT if pulled else 0
	get_viewport().push_input(button, true)
	if pulled:
		print("[XR] laser click at (%.0f, %.0f)" % [at.x, at.y])  # one line per click: rare


func _scroll(stick_y: float, at: Vector2, delta: float) -> void:
	_scroll_wait -= delta
	if absf(stick_y) < SCROLL_DEADZONE or _scroll_wait > 0.0:
		return
	_scroll_wait = SCROLL_REPEAT_S
	for pressed: bool in [true, false]:
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP if stick_y > 0.0 else MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = pressed
		wheel.position = at
		wheel.global_position = at
		get_viewport().push_input(wheel, true)


## The laser left the panel or the mouse went back to the game: a held click is let go where it was.
func _release() -> void:
	if _button_down:
		_click(false, _mouse_at)
	_mouse_at = Vector2(-1.0, -1.0)
	_cursor.visible = false


func _aim_laser(laser: MeshInstance3D, reach: float) -> void:
	laser.position = Vector3(0.0, 0.0, -reach * 0.5)
	laser.scale = Vector3(1.0, 1.0, reach)


## The panel and the two pointing hands with their lasers, not yet in the tree (see _hang_on).
func _build_nodes() -> void:
	_layer = OpenXRCompositionLayerQuad.new()
	_layer.name = "XRScreenLayer"
	_layer.layer_viewport = _viewport
	_layer.alpha_blend = true
	_layer.quad_size = _quad_size()
	_pointers.clear()
	_lasers.clear()
	for tracker: StringName in [&"left_hand", &"right_hand"]:
		var hand := XRController3D.new()
		hand.name = "XRScreenPointer_" + tracker
		hand.tracker = tracker
		hand.pose = &"aim"  # the aim_pose action: Godot drops the "_pose" on the tracker
		var laser := _laser()
		hand.add_child(laser)
		_pointers.append(hand)
		_lasers.append(laser)


static func _laser() -> MeshInstance3D:
	var beam := BoxMesh.new()
	beam.size = Vector3(0.003, 0.003, 1.0)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(0.4, 0.85, 1.0)
	beam.material = glow
	var laser := MeshInstance3D.new()
	laser.name = "Laser"
	laser.mesh = beam
	laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	laser.visible = false
	return laser


func _on_node_added(node: Node) -> void:
	if node is CanvasLayer:
		_adopt(node as CanvasLayer)


## A CanvasLayer of the main viewport draws into the panel. One inside another viewport (a 3D screen's)
## stays where it is.
func _adopt(layer: CanvasLayer) -> void:
	if layer.custom_viewport == null and layer.get_viewport() == get_tree().root:
		layer.custom_viewport = _viewport
		_adopted.append(layer.get_instance_id())


## The panel draws the 2D at the size the main viewport lays it out (its stretched size).
func _fit_to_window() -> void:
	# Laid out at the main viewport's size, drawn at a share of it: in VR the main viewport is the
	# headset's (2048 px square on SteamVR), and the runtime keeps three images of the panel in video memory.
	var layout := Vector2i(get_tree().root.get_visible_rect().size)
	_viewport.size_2d_override = layout
	_viewport.size_2d_override_stretch = true
	_viewport.size = Vector2i((Vector2(layout) * PIXEL_SHARE).round())
	if is_instance_valid(_layer):
		_layer.quad_size = _quad_size()


func _quad_size() -> Vector2:
	var size := Vector2(_viewport.size)
	return Vector2(WIDTH_M, WIDTH_M * size.y / maxf(size.x, 1.0))
