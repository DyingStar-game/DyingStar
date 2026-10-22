class_name WristDatapad
extends Node

## The owner's DataPad, read on the wrist (F3, and F2 for its chart). The left wrist comes up before the
## chest while the eyes go down to it; then, in ZOOM_TIME, the view closes in on its screen while the
## device eases round to face the eye -- eased, not cut (playtest 2026-10-15: "PAF, on me fixe l'écran")
## -- and the tablet (TerminalUI), drawn ON that screen (WristDatapadModel) from the start of the zoom,
## is open. It is used with a FREE cursor, like any menu: the mouse's own events are carried onto the
## screen along the ray through the cursor, and the eyes drift a little after the cursor (PARALLAX), so
## the wrist feels held rather than pinned. Not the crosshair of the world's consoles: on a 21:9 monitor
## steering a whole tablet with the view was too much (playtest 2026-10-15). The keys go to the tablet.
## Closing it, however it closes (F3, Escape, F2), plays it back: the view backs out and the device goes
## back on the arm while the arm goes down and the eyes return where they looked.
##
## Owner only -- the arm itself is the replicated Player.datapad_raised, raised on every avatar by
## CharacterAnimator/WristRaise, and the look is the replicated head pitch/yaw, so others see the head go
## down to the wrist too (and only the resting face on its screen).
##
## The sequence:  LOWERED -> RAISING -> ZOOMING -> OPEN -> LOWERING -> LOWERED.

enum Phase { LOWERED, RAISING, ZOOMING, OPEN, LOWERING }

## The wrist went up (true) or is all the way down again (false): the HUD's reticle has nothing to
## aim at in between, the view being the DataPad's (PlayerClient hides it).
signal up_changed(up: bool)

## How much of the view the screen fills once the view is closed in on it: all but a sliver, the tablet
## at nearly the size of the monitor, the device's edge just showing round it (playtest 2026-10-15).
const SCREEN_FILL: float = 0.97
## Time (s) the view takes to close in on the screen once the arm is up -- and to back out.
const ZOOM_TIME: float = 0.25
## How far the eyes drift after the cursor, as a share of the screen: the cursor in a corner turns the
## view a tenth of the screen towards it. A parallax, not a pointer: the cursor itself does the pointing.
const PARALLAX: float = 0.1
## How fast (1/s) the eyes catch up with the cursor's drift: smooth, never a jerk.
const PARALLAX_RATE: float = 6.0
## How far (m) the ray through the cursor looks for the wrist's screen.
const REACH_M: float = 2.0
## How far (rad) the body may turn under the reader before the held orientation lets go (_steady_body):
## a tenth of a milliradian, 0.03 mm at the wrist -- far below what a vehicle that actually turns does.
const STEADY_RAD: float = 1e-4

var phase: Phase = Phase.LOWERED

var _player  # the Player facade (untyped: typing Player would cycle, see PlayerClient)
var _terminal  # TerminalUI -- untyped so a test can hand in a stand-in
var _camera: Camera3D = null
var _animator  # CharacterAnimator (wrist_weight), or null: then the raise is timed
var _model  # WristDatapadModel, or null: then no look, no zoom, no pointer (the tests)
var _then: Callable = Callable()  # what opens the tablet once the arm is up (open, its chart, an app)
var _t: float = 0.0
var _look_from: Vector2 = Vector2.ZERO  # the look (pivot pitch, yaw) before the gesture, given back after
var _look_held: Vector2 = Vector2.ZERO  # the look when the arm started down, eased back to _look_from
var _zoom_fov: float = 0.0  # where the view closes in to (degrees)
var _zoom_held: float = 0.0  # where the view was when the arm started down, eased back out from
var _face_held: float = 0.0  # how far the device was turned to the eye then (0..1), eased back to 0
var _over_screen: bool = false  # the cursor is on the wrist's screen (it was told so)
var _held_basis: Basis = Basis.IDENTITY  # the body's orientation held while reading (_steady_body)
var _basis_held: bool = false
var _hidden_body: Array[GeometryInstance3D] = []  # our own body's meshes hidden while reading (_show_own_body)


func setup(player, terminal, camera: Camera3D, animator, model) -> void:
	_player = player
	_terminal = terminal
	_camera = camera
	_animator = animator
	_model = model
	_terminal.visibility_changed.connect(_on_terminal_visibility_changed)


## F3: up when down, down when up; pressed during the gesture, it takes the arm back down.
func toggle() -> void:
	match phase:
		Phase.LOWERED, Phase.LOWERING:
			open()
		Phase.RAISING, Phase.ZOOMING:
			_lower()
		Phase.OPEN:
			_terminal.close()  # the tablet hides, and that lowers the arm (_on_terminal_visibility_changed)


## Bring the DataPad up, on its chart if `navigation` (F2). Already open, F2 only switches to the chart.
func open(navigation: bool = false) -> void:
	open_with(_terminal.open_navigation if navigation else _terminal.open)


## Bring the DataPad up and, once the arm is up, run `then` to open the tablet where it is wanted (an
## app, a segment). Already up, `then` runs at once. Every way into the tablet comes through here: it
## is drawn on the wrist, so a tablet opened with the arm down would be open where nobody can read it.
func open_with(then: Callable) -> void:
	if phase == Phase.OPEN or phase == Phase.ZOOMING:
		then.call()
		return
	_then = then
	if phase == Phase.RAISING:
		return
	if phase == Phase.LOWERED:
		_look_from = _look()  # caught on the way down, the look to give back is still the first one
	_model_rest()  # caught backing out: the device starts over from the arm
	_camera.fov = _base_fov()
	var was_down: bool = phase == Phase.LOWERED
	phase = Phase.RAISING
	_t = 0.0
	_set_raised(true)
	if was_down:
		up_changed.emit(true)


## Close the DataPad from wherever the gesture is.
func close() -> void:
	if phase == Phase.OPEN:
		_terminal.close()
	elif phase == Phase.RAISING or phase == Phase.ZOOMING:
		_lower()


## True from the moment the wrist starts up until it is all the way down again.
func is_up() -> bool:
	return phase != Phase.LOWERED


## True while the gesture plays, up or down: it holds the controls the way the open tablet does
## (PlayerClient._modal_open), so nobody walks off with their wrist before their eyes, and the mouse
## does not fight the view easing in and out.
func is_busy() -> bool:
	return phase == Phase.RAISING or phase == Phase.ZOOMING or phase == Phase.LOWERING


func _process(delta: float) -> void:
	advance(delta)


## Step the sequence by `delta` seconds (the whole of it lives here, so a test can drive it).
func advance(delta: float) -> void:
	match phase:
		Phase.RAISING:
			_t += delta
			_look_at(_screen_point(Vector2(0.5, 0.5)), smoothstep(0.0, 1.0, _t / _raise_time()))
			if _raised():
				_begin_zoom()
		Phase.ZOOMING:
			_t += delta
			var k: float = smoothstep(0.0, 1.0, _t / ZOOM_TIME)
			_steady_body()
			_face_screen(k)
			_look_at(_screen_point(Vector2(0.5, 0.5)), 1.0)
			_camera.fov = lerpf(_base_fov(), _zoom_fov, k)
			if _t >= ZOOM_TIME:
				phase = Phase.OPEN
				_show_own_body(false)
		Phase.OPEN:
			# Every frame: the eyes drifting after the cursor. The device is not turned again: it was set
			# straight at the end of the zoom and nothing moves it on the body since (the arm's pose is
			# held and the clip too, see CharacterAnimator).
			_steady_body()
			_drift_after(_cursor_offset(), delta)
		Phase.LOWERING:
			_t += delta
			var out: float = 1.0 - smoothstep(0.0, 1.0, _t / ZOOM_TIME)
			_face_screen(_face_held * out)
			_camera.fov = lerpf(_base_fov(), _zoom_held, out)
			_set_look(_look_held.lerp(_look_from, smoothstep(0.0, 1.0, _t / _raise_time())))
			if _t >= maxf(_raise_time(), ZOOM_TIME):
				phase = Phase.LOWERED
				_model_rest()
				_camera.fov = _base_fov()
				up_changed.emit(false)


## While the tablet is open: the mouse's own events are carried onto the wrist's screen, at the point
## the ray through the cursor meets it -- hover, clicks, drags and the wheel alike. Only a PRESS is
## kept from the game behind it (a click must not also land on the HUD): motions and releases go on,
## for what follows the mouse in the window itself -- the star chart turns its view on the window's
## mouse motion while its orbit button is held, and lets go on its release (StarMap._input); swallowed,
## the chart stuck and only came back with the cursor off the screen (playtest 2026-10-15).
## The keys: Escape goes to the tablet (it backs out, TerminalUI._input) and so does whatever a focused
## field types; every other key goes on to the game -- the chart's own keys (StarMap._unhandled_input),
## F3, F2 -- instead of being eaten by a focused button's arrows and Enter.
func _input(event: InputEvent) -> void:
	if phase != Phase.OPEN or _model == null:
		return
	if event is InputEventMouse:
		var mouse := event as InputEventMouse
		var at: Variant = _model.gui.hit(_camera.project_ray_origin(mouse.position),
				_camera.project_ray_normal(mouse.position), REACH_M)
		if at != null:
			_model.gui.push_at(mouse, at)
			_over_screen = true
		elif _over_screen:
			_model.gui.pointer_left()  # off the screen, on the arm or past it: nothing hovered any more
			_over_screen = false
		if mouse is InputEventMouseButton and mouse.is_pressed():
			get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey):
		return
	if not (_terminal.is_typing() or event.is_action("ui_cancel") or event.is_action("pause")):
		return
	var screen: SubViewport = _model.viewport
	screen.push_input(event)
	if screen.is_input_handled():
		get_viewport().set_input_as_handled()


## The vertical field of view (degrees; Camera3D keeps the height) at which a screen of `screen_size`
## metres, `distance` metres away, fills `fill` of a view of `aspect` (width / height) -- whichever of
## its width or height reaches the edge first. Pure, for the tests.
static func zoom_fov(screen_size: Vector2, distance: float, aspect: float, fill: float) -> float:
	var half_height: float = maxf(screen_size.y * 0.5, screen_size.x * 0.5 / maxf(aspect, 0.01)) / maxf(fill, 0.01)
	return clampf(rad_to_deg(2.0 * atan(half_height / maxf(distance, 0.01))), 1.0, 179.0)


## The look (pitch, yaw) that puts `target` dead ahead of `eye`, both given in the axes of the camera
## pivot's parent (the body): the eyes going down to the wrist. Pure, for the tests.
static func look_towards(eye: Vector3, target: Vector3) -> Vector2:
	var d: Vector3 = target - eye
	return Vector2(atan2(d.y, Vector2(d.x, d.z).length()), atan2(-d.x, -d.z))


## Where on its screen the eyes rest for a cursor at `cursor` (-0.5..0.5 from the window's centre on
## each axis): the screen's centre, drawn PARALLAX of the way towards the cursor. Pure, for the tests.
static func parallax_uv(cursor: Vector2) -> Vector2:
	return Vector2(0.5, 0.5) + cursor.clamp(Vector2(-0.5, -0.5), Vector2(0.5, 0.5)) * PARALLAX


## The arm is up: the tablet opens on the screen and the view starts closing in on it. Reading the
## wrist is reading what it said: its notification light goes out.
func _begin_zoom() -> void:
	phase = Phase.ZOOMING
	_t = 0.0
	_zoom_fov = _base_fov()
	if _model != null:
		var viewport: Vector2 = _camera.get_viewport().get_visible_rect().size
		var distance: float = _camera.global_position.distance_to(_model.screen_global())
		_zoom_fov = minf(zoom_fov(_model.screen_size_m(), distance, viewport.x / maxf(viewport.y, 1.0), SCREEN_FILL),
				_base_fov())
		_model.set_live(true)
		_model.set_notified(false)
	if _then.is_valid():
		_then.call()
	_then = Callable()


func _on_terminal_visibility_changed() -> void:
	if (phase == Phase.OPEN or phase == Phase.ZOOMING) and not _terminal.is_open():
		_lower()


## Down from wherever the gesture is: the view backs out from where it got to, the device eases back on
## the arm from how far it had turned, the eyes go back where they looked.
func _lower() -> void:
	var was: Phase = phase
	_zoom_held = _camera.fov
	_face_held = 1.0 if was == Phase.OPEN else (smoothstep(0.0, 1.0, _t / ZOOM_TIME) if was == Phase.ZOOMING else 0.0)
	_look_held = _look()
	_basis_held = false
	phase = Phase.LOWERING  # before closing the tablet: its visibility_changed must not lower again
	_show_own_body(true)
	_t = 0.0
	if _model != null:
		_model.set_live(false)
		if _over_screen:
			_model.gui.pointer_left()
	_over_screen = false
	if _terminal.is_open():
		_terminal.close()  # stopped during the zoom: the tablet had already opened on the screen
	_set_raised(false)


## Our own body hidden from our own eyes while the view is closed in on the wrist, the device kept: the
## raised arm's upper half came into the bottom corner of the view, before the tablet, now and then
## (depending on the pose the arm was raised from: playtest 2026-10-22). Only the owner reads its own
## wrist, so the others still see the whole body. The meshes already hidden are left as they are.
func _show_own_body(on: bool) -> void:
	if on:
		for mesh: GeometryInstance3D in _hidden_body:
			if is_instance_valid(mesh):
				mesh.visible = true
		_hidden_body.clear()
		return
	var puppet: Node = _player.get("puppet") as Node if _player != null else null
	if puppet == null:
		return
	var device: Node = _model as Node if _model is Node else null
	for mesh: Node in puppet.find_children("*", "GeometryInstance3D", true, false):
		var geometry := mesh as GeometryInstance3D
		if not geometry.visible or (device != null and (device == geometry or device.is_ancestor_of(geometry))):
			continue
		geometry.visible = false
		_hidden_body.append(geometry)


## Hold the body's orientation while the view is closed in on the wrist. Seated, the body rides a
## vehicle that never holds perfectly still -- a parked truck rocks on its springs by micro-radians.
## Moving, the body carries the camera and the arm alike; TURNING it by a micro-radian, out where the
## world is (4e10 m, positions told apart by about 8 µm), rounds each of them a different way, and the arm
## hopped against the view by a step or two every frame (playtest 2026-10-16). Held, the rounding holds
## too; past STEADY_RAD the vehicle is really turning, and the body follows it again. Its position always
## follows: moving does not round the camera and the arm apart.
func _steady_body() -> void:
	var body: Node3D = _body()
	var now: Basis = body.global_basis
	if not _basis_held or (now * _held_basis.inverse()).get_rotation_quaternion().get_angle() > STEADY_RAD:
		_held_basis = now
		_basis_held = true
		return
	body.global_basis = _held_basis


## The cursor's place in the window, -0.5..0.5 from its centre on each axis.
func _cursor_offset() -> Vector2:
	var viewport: Viewport = _camera.get_viewport()
	var size: Vector2 = viewport.get_visible_rect().size
	return viewport.get_mouse_position() / Vector2(maxf(size.x, 1.0), maxf(size.y, 1.0)) - Vector2(0.5, 0.5)


## Ease the eyes towards where they rest for the cursor at `cursor` (parallax_uv), at PARALLAX_RATE.
func _drift_after(cursor: Vector2, delta: float) -> void:
	var target: Vector3 = _screen_point(parallax_uv(cursor))
	if target == Vector3.INF:
		return
	_set_look(_look().lerp(_look_towards_body(target), 1.0 - exp(-PARALLAX_RATE * delta)))


## Turn the wrist's screen `amount` of the way (0..1) to face the eye, level with the body
## (WristDatapadModel.face).
func _face_screen(amount: float) -> void:
	if _model == null:
		return
	var body: Node3D = _body()
	_model.face(_camera.global_position, body.global_basis.y.normalized(), amount)


func _model_rest() -> void:
	if _model != null:
		_model.rest()


## The point of the screen at `uv` (0..1), in the BODY's frame; INF without a model (the tests).
## Through the local transforms from the screen up to the body, never through the world (WristRaise.drive
## says why).
func _screen_point(uv: Vector2) -> Vector3:
	if _model == null:
		return Vector3.INF
	if not (_model is Node3D):  # a stand-in (the tests): its points are given in the world
		return _body().global_transform.affine_inverse() * _model.gui.point_at_uv(uv)
	var size: Vector2 = _model.screen_size_m()
	return WristRaise.local_to(_model.screen, _body()) * Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0.0)


## Turn the view `k` of the way (0..1) from where it looked towards `target` (body frame). INF: none.
func _look_at(target: Vector3, k: float) -> void:
	if target == Vector3.INF:
		return
	var to: Vector2 = _look_towards_body(target)
	_set_look(Vector2(lerp_angle(_look_from.x, to.x, k), lerp_angle(_look_from.y, to.y, k)))


## The look (pivot pitch, yaw) that puts `target` (body frame) dead ahead of the camera.
func _look_towards_body(target: Vector3) -> Vector2:
	return look_towards((_player.camera_pivot.transform * _camera.transform).origin, target)


## The body the camera pivot hangs from: the player.
func _body() -> Node3D:
	return _player.camera_pivot.get_parent() as Node3D


func _look() -> Vector2:
	var pivot: Node3D = _player.camera_pivot
	return Vector2(pivot.rotation.x, pivot.rotation.y)


func _set_look(look: Vector2) -> void:
	var pivot: Node3D = _player.camera_pivot
	pivot.rotation.x = look.x
	pivot.rotation.y = look.y


func _set_raised(raised: bool) -> void:
	_player.datapad_raised = raised  # the owner's own arm moves now; the server replicates it to the others
	_player.client_send_action_to_server({"action": "datapad", "on": raised})


func _raised() -> bool:
	if _animator != null:
		return _animator.wrist_weight() >= 1.0
	return _t >= _raise_time()


func _raise_time() -> float:
	return float(_player.datapad_raise_time)


func _base_fov() -> float:
	return SettingsManager.get_fov()
