class_name ScreenAttract
extends Control

## A machine's screen saver: its brand's facets slowly moving, its logo, its name, and "touch the
## screen to start" pulsing — over the whole screen until someone presses it. A press unlocks it: a
## soft chime from the machine and a ring that fills for LOAD_S, then the screen. Back by itself after
## IDLE_S without a pointer on the screen (the crosshair hovering it counts), and the screen under it
## is told ([signal slept]) so it can go back to its start. Put it last in the screen's interface;
## the screen keeps working under it, only hidden.

signal woke
signal slept

## How long (s) the screen waits, nobody pointing at it, before it sleeps again.
const IDLE_S: float = 40.0
const LOGO_PX: float = 150.0
const TITLE_PX: int = 52
const PROMPT_PX: int = 30
## How long (s) the screen "loads" once unlocked.
const LOAD_S: float = 1.0
const RING_PX: float = 140.0
const UNLOCK_SOUND: AudioStream = preload("res://assets/_universe/audio/sfx/ui/screen-unlock.ogg")
const UNLOCK_DB: float = -24.0
## How far (m) from the camera a sleeping screen still moves. Sleeping is every machine's usual state,
## and a town's worth of them redrawing for nobody took 55 ms a frame.
const ANIMATE_RANGE_M: float = 12.0
## How often (s) a sleeping screen asks whether anyone can see it.
const SEEN_CHECK_S: float = 0.25

## Whether the camera is near this screen and has it in view; it stands still otherwise.
var _seen: bool = false
## When (s of _t) to ask again; each screen starts at its own moment, so they do not all ask together.
var _next_seen_check_s: float = randf() * SEEN_CHECK_S
var _pattern: FacetPattern
var _prompt: Label
## The saver's face (logo, name, prompt), and the loading ring shown instead once unlocked.
var _face: Control
var _loading: Control
var _ring: LoadRing
## When (s of _t) the loading ends; < 0 when not loading.
var _loaded_at: float = -1.0
var _last_input_s: float = 0.0
var _t: float = 0.0


## Build it for [param subsidiary] (AresBrand), naming the machine [param title_key]; asleep.
func setup(subsidiary: AresBrand.Subsidiary, title_key: String) -> ScreenAttract:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.035, 0.045)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_pattern = FacetPattern.new()
	_pattern.colour = AresBrand.colour(subsidiary).darkened(0.62)
	_pattern.seed_text = title_key
	_pattern.columns = 8
	_pattern.rows = 5
	_pattern.paused = true
	_pattern.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pattern.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pattern)
	var centre := VBoxContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.add_theme_constant_override("separation", 24)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	_face = centre
	_build_loading(subsidiary)
	var logo := AresBrand.logo_control(subsidiary, LOGO_PX)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(logo)
	var title := AresBrand.screen_label(title_key, TITLE_PX, Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(title)
	_prompt = AresBrand.screen_label("%%SCREEN_TOUCH_TO_START", PROMPT_PX, AresBrand.colour(subsidiary).lightened(0.3))
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(_prompt)
	sleep()
	return self


## Show the saver over the screen.
func sleep() -> void:
	visible = true
	_loaded_at = -1.0
	_face.visible = true
	_loading.visible = false
	_pattern.drift = 0.5
	slept.emit()


## Unlock it: the chime, then the ring fills for LOAD_S, then the screen (woke). Once.
func wake() -> void:
	if not visible or is_loading():
		return
	_loaded_at = _t + LOAD_S
	_face.visible = false
	_loading.visible = true
	_ring.progress = 0.0
	_chime()


## Whether it is between the press and the screen.
func is_loading() -> bool:
	return _loaded_at >= 0.0


func _reveal() -> void:
	_loaded_at = -1.0
	visible = false
	_pattern.drift = 0.0
	_last_input_s = _t
	woke.emit()


## The chime, from the machine whose screen this is, so it is heard where the screen is.
func _chime() -> void:
	if Sfx3D.muted():
		return
	var machine: Node3D = _machine()
	if machine != null:
		Sfx3D.play(machine, UNLOCK_SOUND, UNLOCK_DB, 1.5, 10.0, Sfx3D.Attenuation.VERY_SHORT)


## The first 3D node holding this screen's viewport; null when the screen is not in a 3D world.
func _machine() -> Node3D:
	if get_viewport() == null:
		return null
	var at: Node = get_viewport().get_parent()
	while at != null and not (at is Node3D):
		at = at.get_parent()
	return at as Node3D


## Moves only when near the camera and in its view. A screen not in a 3D world is on show as it is;
## with no camera at all (the dedicated server) nobody is looking.
func _update_seen() -> void:
	_next_seen_check_s = _t + SEEN_CHECK_S
	var machine: Node3D = _machine()
	_seen = true
	if machine != null:
		_seen = ScreenVisibility.sees(machine.get_viewport().get_camera_3d(), machine.global_position, ANIMATE_RANGE_M)
	_pattern.paused = not _seen


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		wake()


## Anything pointed or pressed on this screen (its viewport) keeps it awake.
func _input(event: InputEvent) -> void:
	if not visible and (event is InputEventMouse or event is InputEventKey):
		_last_input_s = _t


func _process(delta: float) -> void:
	_t += delta
	if is_loading():
		_ring.progress = clampf(1.0 - (_loaded_at - _t) / LOAD_S, 0.0, 1.0)
		_ring.spin = _t
		if _t >= _loaded_at:
			_reveal()
	elif visible:
		if _t >= _next_seen_check_s:
			_update_seen()
		if _seen:
			_prompt.modulate.a = 0.55 + 0.45 * sin(_t * 3.0)
	elif _t - _last_input_s > IDLE_S:
		sleep()


func _build_loading(subsidiary: AresBrand.Subsidiary) -> void:
	_loading = VBoxContainer.new()
	_loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	(_loading as VBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	_loading.add_theme_constant_override("separation", 24)
	_loading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading.visible = false
	add_child(_loading)
	_ring = LoadRing.new()
	_ring.colour = AresBrand.colour(subsidiary).lightened(0.2)
	_ring.custom_minimum_size = Vector2.ONE * RING_PX
	_ring.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading.add_child(_ring)
	var word := AresBrand.screen_label("%%SCREEN_LOADING", PROMPT_PX, Color(1, 1, 1, 0.8))
	word.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading.add_child(word)


## The loading ring: a faint circle, filled clockwise as [member progress] goes 0 -> 1, a bright
## segment running round it.
class LoadRing:
	extends Control

	var colour: Color = Color.WHITE
	var progress: float = 0.0:
		set(value):
			progress = value
			queue_redraw()
	var spin: float = 0.0
	const WIDTH: float = 10.0

	func _draw() -> void:
		var centre: Vector2 = size * 0.5
		var radius: float = minf(size.x, size.y) * 0.5 - WIDTH
		draw_arc(centre, radius, 0.0, TAU, 96, Color(colour, 0.15), WIDTH, true)
		if progress > 0.0:
			draw_arc(centre, radius, -PI * 0.5, -PI * 0.5 + TAU * progress, 96, colour, WIDTH, true)
		var head: float = spin * TAU * 1.5
		draw_arc(centre, radius + WIDTH * 1.6, head, head + 0.6, 24, Color(colour, 0.6), WIDTH * 0.4, true)
