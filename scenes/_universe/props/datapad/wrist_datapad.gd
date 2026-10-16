class_name WristDatapadModel
extends Node3D

## The DataPad worn on the left forearm: a band, a housing, a 16:9 screen and, at its top right, a green
## light. A notification makes it beep, and while it is unread the light blinks and the beep comes back
## every REMIND_S, like a pager, until the DataPad is next read. Resting, the screen shows
## the ARES mark and the time; on its OWNER's wrist it also carries the full tablet (TerminalUI, F3),
## which draws into the same screen once the arm is raised before the eyes (WristDatapad). Everyone
## else's wrist only ever shows the resting face: what a player reads stays theirs.
##
## Built in the frame of Player.wrist_mount: +X along the forearm towards the hand, +Y out of the arm
## (the screen's normal), origin on the forearm's axis. Any model can replace this one as long as it
## keeps that frame and names its screen, viewport and Gui3D.

## How often (Hz) the notification light blinks, lit half of each beat.
const BLINK_HZ: float = 1.5
## The light's colour when lit: the green of ServiceStyle.GOOD, the tablet's own "something for you".
const LED_LIT := Color(0.4, 0.85, 0.5)
## How often (s) an unread notification beeps again: tutut ... three seconds ... tutut (playtest
## 2026-10-15).
const REMIND_S: float = 3.0

## The tablet's own layout size (px): TerminalUI is laid out for a 1920 x 1080 window, and gets exactly
## that, so nothing in it has to be laid out again for the wrist.
const TABLET_SIZE := Vector2i(1920, 1080)

## The screen: a 16:9 quad facing +Y, its picture drawn by `viewport` (through `gui`).
@export var screen: MeshInstance3D
## What the screen shows. Resting, drawn once, then again only when the minute turns: it costs nothing
## between. While the tablet is open on it, drawn every frame (set_live).
@export var viewport: SubViewport
## The Gui3D bridging the screen and the viewport: its material, and the pointer's hover and clicks.
@export var gui: Node3D
## The notification light, top right of the screen: dark until set_notified, then blinking.
@export var led: MeshInstance3D
## The notification beep, on the UI bus (the volume of the interface's other sounds). Empty = silent.
@export var beep_sound: AudioStream = preload("res://assets/_universe/audio/sfx/ui/notification.ogg")
## Set before the model enters the tree, on the OWNER's wrist only: the viewport is made tablet-sized,
## for PlayerClient to put the tablet in it (a CanvasLayer above the face). Others keep a small face.
var carries_tablet: bool = false

var _clock: Label = null
var _led_lit: StandardMaterial3D = null  # the light's glow, laid over its dark lens while it blinks
var _beeper: AudioStreamPlayer = null
var _remind: Timer = null  # the beep again, every REMIND_S while unread


func _ready() -> void:
	# Not a console of the world: the crosshair's screens (PlayerClient._point_screen) are things to walk
	# up to, and a screen on someone's arm is driven by its owner's gesture alone (WristDatapad), keys
	# included -- not by Gui3D's own key handler, which would push every keystroke into it twice.
	gui.remove_from_group(ScreenTarget.GROUP)
	gui.set_process_unhandled_input(false)
	if carries_tablet:
		viewport.size = TABLET_SIZE
	_led_lit = StandardMaterial3D.new()
	_led_lit.albedo_color = LED_LIT
	_led_lit.emission_enabled = true
	_led_lit.emission = LED_LIT
	_led_lit.emission_energy_multiplier = 3.0
	set_process(false)  # nothing to blink yet
	_beeper = AudioStreamPlayer.new()
	_beeper.bus = &"UI"
	_beeper.stream = beep_sound
	add_child(_beeper)
	_remind = Timer.new()
	_remind.wait_time = REMIND_S
	_remind.timeout.connect(beep)
	add_child(_remind)
	_build_face()
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_tick)
	add_child(timer)
	_tick()


## Something arrived the player has not read yet: beep now, then blink and beep again every REMIND_S
## (a new one starts the count over). False: read -- the light goes out, the beeping stops.
func set_notified(notified: bool) -> void:
	set_process(notified)
	if notified:
		beep()
		_remind.start()
	else:
		_remind.stop()
		led.material_override = null


## One beep (already sounding, it starts again rather than doubling up).
func beep() -> void:
	if _beeper.stream != null:
		_beeper.play()


func _process(_delta: float) -> void:
	var lit: bool = fmod(Time.get_ticks_msec() / 1000.0 * BLINK_HZ, 1.0) < 0.5
	led.material_override = _led_lit if lit else null


## Draw the screen every frame (the tablet is open on it) or only when the clock turns (resting).
func set_live(live: bool) -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live else SubViewport.UPDATE_ONCE


## Turn the whole device about its screen's centre, `amount` of the way (0 = as the arm holds it, 1 =
## the screen squarely facing `eye`, level with `up`): read on the owner's wrist, a screen the arm can
## only bring up a little askew (short arms, see WristRaise) is set straight -- eased in with the zoom,
## never snapped (playtest 2026-10-15). Recomputed from where the arm puts it, so it never builds up.
func face(eye: Vector3, up: Vector3, amount: float = 1.0) -> void:
	transform = Transform3D.IDENTITY  # back on the arm first
	if amount <= 0.0:
		return
	var centre: Vector3 = screen.global_position
	# looking_at points -Z away from the eye: the quad's face (+Z) towards it, its +Y up.
	var full: Quaternion = (Basis.looking_at(centre - eye, up)
			* screen.global_basis.orthonormalized().inverse()).get_rotation_quaternion()
	var turn := Basis(Quaternion.IDENTITY.slerp(full, clampf(amount, 0.0, 1.0)))
	global_transform = Transform3D(turn, centre - turn * centre) * global_transform


## Back on the arm as it holds the device: the arm went down.
func rest() -> void:
	transform = Transform3D.IDENTITY


## The screen's centre in this model's frame (on +Y, the side it faces).
func screen_centre() -> Vector3:
	return screen.position


## The screen's size (m), width along +X then height.
func screen_size_m() -> Vector2:
	return (screen.mesh as QuadMesh).size


## The screen's centre in world space, wherever the arm holds it right now.
func screen_global() -> Vector3:
	return screen.global_position


func _tick() -> void:
	var text: String = TerminalUI.clock_text()
	if _clock == null or text == _clock.text:
		return
	_clock.text = text
	if viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## The resting face: the tablet's mark above the time, on the tablet's own background (ServiceStyle),
## sized from the viewport's height so it reads the same on a small face and on the tablet-sized one.
func _build_face() -> void:
	var height: float = float(viewport.size.y)
	var background := ColorRect.new()
	background.color = ServiceStyle.BG
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(background)
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", int(height * 0.03))
	viewport.add_child(column)
	var logo: Control = TerminalUI.brand_logo()
	logo.custom_minimum_size = Vector2(height * 0.83, height * 0.26)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(logo)
	_clock = Label.new()
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	ServiceStyle.font_of(_clock, int(height * 0.36), true)
	column.add_child(_clock)
