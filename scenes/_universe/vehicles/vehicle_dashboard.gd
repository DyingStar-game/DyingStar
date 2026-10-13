@tool
class_name VehicleDashboard
extends Panel

## In-cab dashboard rendered on a vehicle's 3D screen (through a SubViewport). Pure display: it
## finds its owning Vehicle in the tree and shows the generic Vehicle data each frame. Reusable
## by any vehicle — it only reads the public Vehicle accessors, and the Vehicle knows nothing
## about it (the screen is just another child). Put this script on the UI scene's root.
##
## Laid out to the SCREEN's shape: the truck's is a strip 54 x 8 cm, about 6.5:1, and an interface
## drawn at 1921 x 1112 was squashed almost four times into it, unreadable (2026-10-13). The
## viewport takes the screen's aspect at SCREEN_HEIGHT_PX (Gui3D.surface_size), and the layout is
## one strip read left to right, pictograms in place of words:
##   driving   the speed, big; the odometer under it
##   status    the warning lights on two lines: headlights, handbrake, doors; speed limiter, load;
##             under them one box per component bay, showing what is fitted there
##   energy    the drive (4x4) over the motor, the power used and the rpm, each battery's charge
## A light that is off stays in place, faint: the eye always finds a light where it was.
## Colours follow the real dashboards: green = on, amber = caution, red = danger.
##
## @tool only for the editor's sake: the strip is built in code, so the scene showed an empty panel
## there. In the editor it builds a still preview with sample values (_preview) and does nothing else;
## its nodes have no owner, so nothing of it is saved into a scene.

## Height of the viewport (px): the width follows the screen's aspect.
const SCREEN_HEIGHT_PX: int = 400
## The screen the editor preview is drawn for: the truck's (m).
const PREVIEW_SURFACE_M := Vector2(0.54, 0.083)
## The drawing of the warning lights and the energy column.
const ICON_DIR: String = "res://assets/_universe/vehicles/ui/dashboard_icons/"
const FONT_PATH: String = "res://assets/fonts/Xolonium/Xolonium-Regular.ttf"
## The maker's mark, small in the top-left corner over the layout (it was on the old screen too).
const LOGO_PATH: String = "res://assets/textures/decals/ares_logo/ares_logo_decal_alpha.png"
## The drawn part of the logo's 1024 x 1024 texture: shown whole, it was a speck in an empty square.
const LOGO_REGION := Rect2(51, 67, 415, 131)
const LOGO_SIZE := Vector2(190, 60)
const BG_COLOR := Color(0.09, 0.095, 0.11)
const OFF_COLOR := Color(1.0, 1.0, 1.0, 0.16)
const WHITE := Color(0.92, 0.93, 0.95)
const GREEN := Color(0.46, 0.97, 0.0)
const AMBER := Color(1.0, 0.73, 0.03)
const ORANGE := Color(1.0, 0.5, 0.08)
const RED := Color(1.0, 0.16, 0.26)
## Sizes on the SCREEN_HEIGHT_PX-high strip (px).
const SPEED_FONT: int = 210
const UNIT_FONT: int = 60
const SMALL_FONT: int = 48
const ICON_PX: int = 110
const SMALL_ICON_PX: int = 76
## A component bay's box (px), and the part's icon inside it.
const BAY_BOX_PX: int = 74
const BAY_ICON_PX: int = 56
## A free bay's frame.
const BAY_FREE_COLOR := Color(1.0, 1.0, 1.0, 0.35)
## The handbrake blinks (twice a second) while the truck is pushed against it. An open door blinks to
## the beat of its beep (DoorAlarm).
const BLINK_HZ: float = 2.0
const MOVING_KMH: float = 1.0
## A battery row: the one in use at full strength, the others dimmed.
const BATTERY_IDLE_ALPHA := 0.45
## Width of the energy column's figures (px): the rpm and the percentages stay put whatever they read.
const FIGURE_WIDTH_PX: int = 300
## Cells of the energy grid: the motor's row, then each battery's.
const ENERGY_CELLS: int = 3
const BATTERY_CELLS: int = 3

## Beyond this distance (m) from the player's view the screen stops rendering and its labels stop
## updating: it keeps its last image, unreadable from there anyway. Every truck carried a 1921x1112
## screen redrawn every frame wherever it stood — eleven of them around the spawn.
@export var max_distance: float = 30.0

@export_group("Door alarm")
## The beep of an open door (DoorAlarm): slow with a door open, quicker and quicker as the speed nears
## the one at which the wind shuts it. Played at the screen. Empty: silent, the light still blinks.
@export var sfx_door_alarm: AudioStream
## Loudness in decibels (0 = the sample's own level, negative = quieter). Low: a reminder, not a siren.
@export_range(-40.0, 12.0, 0.5) var sfx_door_alarm_db: float = -14.0
## Reference distance (m) at which the beep has its nominal volume; past it, it starts fading.
@export_range(0.5, 200.0, 0.5) var sfx_door_alarm_falloff: float = 2.0
## Distance (m) past which the beep is no longer audible at all: the cab and just around it.
@export_range(1.0, 500.0, 1.0) var sfx_door_alarm_distance: float = 12.0
## How the beep fades with distance.
@export var sfx_door_alarm_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

var _vehicle: Vehicle = null
## The SubViewport this panel is drawn into (the cab screen's texture). Null when shown elsewhere.
var _screen: SubViewport = null
## Last applied state, to touch the SubViewport only on a change: "live", "off", "far".
var _state: String = ""
var _door_alarm := DoorAlarm.new()

var _speed: Label
var _odometer: Label
var _lights: TextureRect
var _handbrake: TextureRect
var _limiter: TextureRect
var _limiter_cap: Label
var _load: TextureRect
var _load_text: Label
var _doors: TextureRect
var _drive: Label
var _power: ProgressBar
var _rpm: Label
## The energy column: icon | bar | figure, one row for the motor and one per battery, so every bar
## has the same length and every figure the same width.
var _energy_grid: GridContainer
## One box per component bay, in bay order (VehicleComponentBays.all), each showing its part's icon.
var _bay_boxes: HBoxContainer


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		_preview()
		return
	# Nobody looks at a screen on the server: it only cost a frame of work per truck there.
	if GameOrchestrator.is_server():
		set_process(false)
		return
	_vehicle = _find_vehicle()
	_screen = get_viewport() as SubViewport
	_fit_screen()
	_build(self)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _vehicle == null or not is_instance_valid(_vehicle):
		return
	if _far_from_view():
		_door_alarm.step(delta, 0.0)
		_set_state("far")
		return
	# Engine off, or no charge left: the screen goes dark (matches the rear-view screens). Multiplying
	# by black keeps the panel opaque, so the cab screen reads as a powered-off display rather than a
	# frozen dash. It draws nothing from the batteries, but it needs one with some charge.
	if not _vehicle.is_engine_on() or not _vehicle.energy.has_energy():
		_door_alarm.step(delta, 0.0)
		modulate = Color(0, 0, 0, 1)
		_set_state("off")
		return
	modulate = Color(1, 1, 1, 1)
	_set_state("live")
	var speed: float = _vehicle.get_display_speed_kmh()
	_speed.text = "%.0f" % absf(speed)
	_odometer.text = "%s km" % _km_text(_vehicle.odometer.km())
	_lights.modulate = light_colour(_vehicle.is_headlights_on())
	_handbrake.modulate = handbrake_colour(_vehicle.is_handbraked(), speed, Time.get_ticks_msec() * 0.001)
	var limiter: VehicleSpeedLimiter = _vehicle.limiter
	_limiter.modulate = limiter_colour(limiter.enabled, limiter.is_over(speed))
	_limiter_cap.text = "%d" % limiter.cap_kmh
	_limiter_cap.modulate = _limiter.modulate if limiter.enabled else OFF_COLOR
	_load.modulate = load_colour(_vehicle.is_overloaded())
	_load_text.text = "%.0f / %.0f kg" % [_vehicle.get_cargo_mass(), _vehicle.max_payload]
	_load_text.modulate = _load.modulate
	var doors: Vector2 = _vehicle.open_doors_wind_kmh()
	if _door_alarm.step(delta, DoorAlarm.period(doors.x > 0.0, speed, doors.y)):
		_beep()
	_doors.modulate = door_colour(doors.x > 0.0, speed, doors.y, _door_alarm.lit())
	_drive.text = _vehicle.get_drive_mode_name()
	_power.value = _vehicle.get_power_share() * 100.0
	_rpm.text = tr("%%HUD_RPM") % _vehicle.get_engine_rpm()
	_show_batteries(_vehicle.energy.levels())
	_show_bays(_vehicle.bays.all())


## The editor's still preview: the strip at the truck screen's shape, filled with sample values.
func _preview() -> void:
	# In a panel of its own: sizing or styling the scene's root here would be saved with the scene.
	var host := Panel.new()
	host.size = Vector2(viewport_size_for(PREVIEW_SURFACE_M))
	add_child(host)
	_build(host)
	_speed.text = "47"
	_odometer.text = "1 234.5 km"
	_drive.text = "4x4"
	_rpm.text = "2400 rpm"
	_power.value = 60.0
	_limiter_cap.text = "60"
	_load_text.text = "800 / 4000 kg"
	_lights.modulate = GREEN
	_doors.modulate = ORANGE
	_show_batteries([{"fraction": 0.8, "active": true}, {"fraction": 0.35, "active": false}] as Array[Dictionary])
	for icon_name: String in ["motor", "battery", "battery", ""]:
		var box := _bay_box()
		_bay_boxes.add_child(box)
		_show_bay(box, load(ICON_DIR + icon_name + ".png") if icon_name != "" else null)


## How far (px) to raise a [param small]-size label set at the bottom of a [param big]-size one in
## [param font] so both stand on one baseline: the difference of their descents.
static func baseline_lift(font: Font, big: int, small: int) -> int:
	if font == null:
		return 0
	return maxi(roundi(font.get_descent(big) - font.get_descent(small)), 0)


## The headlights' light: green on, faint off.
static func light_colour(on: bool) -> Color:
	return GREEN if on else OFF_COLOR


## The handbrake's light: red while it holds, blinking at BLINK_HZ while the truck moves against it
## ([param speed_kmh]) at [param time_s]; faint when released.
static func handbrake_colour(on: bool, speed_kmh: float, time_s: float) -> Color:
	if not on:
		return OFF_COLOR
	return blink(RED, BLINK_HZ, time_s) if absf(speed_kmh) > MOVING_KMH else RED


## [param colour] blinking at [param hz] at [param time_s]: lit the first half of each period, faint the other.
static func blink(colour: Color, hz: float, time_s: float) -> Color:
	return colour if fmod(time_s * hz, 1.0) < 0.5 else OFF_COLOR


## The speed limiter's light: amber while it is on, red while it holds the truck back over its limit,
## faint while it is off.
static func limiter_colour(enabled: bool, over_limit: bool) -> Color:
	if over_limit:
		return RED
	return AMBER if enabled else OFF_COLOR


## The doors' light: faint with every door shut, orange with one open, red once the speed
## ([param speed_kmh]) nears the one at which the wind shuts it ([param shut_kmh], DoorAlarm.urgent);
## faint too in the dark half of the alarm's beat ([param lit]).
static func door_colour(any_open: bool, speed_kmh: float, shut_kmh: float, lit: bool) -> Color:
	if not any_open or not lit:
		return OFF_COLOR
	return RED if DoorAlarm.urgent(speed_kmh, shut_kmh) else ORANGE


## One beep of the door alarm, at the screen (the Gui3D holding it), else at the vehicle.
func _beep() -> void:
	var host: Node3D = _screen.get_parent() as Node3D if _screen != null else null
	Sfx3D.play(host if host != null else _vehicle, sfx_door_alarm, sfx_door_alarm_db,
			sfx_door_alarm_falloff, sfx_door_alarm_distance, sfx_door_alarm_attenuation)


## The load's light: white, red once over the payload.
static func load_colour(overloaded: bool) -> Color:
	return RED if overloaded else WHITE


## The viewport size for a screen of [param surface] (m): SCREEN_HEIGHT_PX high, as wide as its aspect.
static func viewport_size_for(surface: Vector2) -> Vector2i:
	if surface.x <= 0.0 or surface.y <= 0.0:
		return Vector2i(SCREEN_HEIGHT_PX * 16 / 9, SCREEN_HEIGHT_PX)
	return Vector2i(roundi(SCREEN_HEIGHT_PX * surface.x / surface.y), SCREEN_HEIGHT_PX)


## Lay the viewport out to the screen it is shown on (the Gui3D holding it), not to a fixed 16:9.
func _fit_screen() -> void:
	if _screen == null:
		return
	# The Gui3D holding the viewport (scenes/interactables/gui_3d.gd) measures its screen mesh.
	var holder: Node = _screen.get_parent()
	if holder != null and holder.has_method("surface_size") and holder.get("node_quad") != null:
		_screen.size = viewport_size_for(holder.call("surface_size"))
	# Anchored full-rect, the panel takes the viewport's new size by itself (setting size as well only
	# drew Godot's "size overridden" warning, once per truck).
	set_anchors_preset(Control.PRESET_FULL_RECT)


## Lay the strip out in [param host] (this panel, or the editor preview's own).
func _build(host: Control) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	host.add_theme_stylebox_override("panel", bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	host.add_child(margin)
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 36)
	margin.add_child(strip)
	strip.add_child(_zone(_driving(), 3.0))
	strip.add_child(VSeparator.new())
	strip.add_child(_zone(_status(), 3.0))
	strip.add_child(VSeparator.new())
	strip.add_child(_zone(_energy(), 4.0))
	if ResourceLoader.exists(LOGO_PATH):
		var logo := TextureRect.new()
		var drawn := AtlasTexture.new()
		drawn.atlas = load(LOGO_PATH)
		drawn.region = LOGO_REGION
		logo.texture = drawn
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		logo.position = Vector2(20, 14)
		logo.size = LOGO_SIZE
		logo.modulate = Color(1, 1, 1, 0.55)
		host.add_child(logo)


## Left: the speed, big, and the odometer.
func _driving() -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	_speed = _label("0", SPEED_FONT, WHITE)
	line.add_child(_speed)
	var unit := _label("km/h", UNIT_FONT, WHITE * Color(1, 1, 1, 0.7))
	# On the speed's baseline: the bottom of each label is its font's descent under the baseline, larger
	# for the big digits, so the unit is raised by the difference (it sat under the figures).
	var lift := MarginContainer.new()
	lift.size_flags_vertical = Control.SIZE_SHRINK_END
	lift.add_theme_constant_override("margin_bottom", baseline_lift(_speed.get_theme_font("font"), SPEED_FONT, UNIT_FONT))
	lift.add_child(unit)
	line.add_child(lift)
	box.add_child(line)
	_odometer = _label("", SMALL_FONT, WHITE * Color(1, 1, 1, 0.6))
	_odometer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_odometer)
	return box


## Centre: the warning lights, always in the same places, on two lines: headlights, handbrake and doors
## on top, the speed limiter and the load under them with their figures beside. One line of five took
## the width the energy column needs.
func _status() -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 14)
	var top := HBoxContainer.new()
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_theme_constant_override("separation", 48)
	_lights = _icon("headlights", ICON_PX)
	_handbrake = _icon("handbrake", ICON_PX)
	_doors = _icon("door", ICON_PX)
	for icon: TextureRect in [_lights, _handbrake, _doors]:
		top.add_child(icon)
	box.add_child(top)
	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 40)
	_limiter = _icon("limiter", ICON_PX)
	_limiter_cap = _label("", SMALL_FONT, AMBER)
	bottom.add_child(_side_cell(_limiter, _limiter_cap))
	_load = _icon("load", ICON_PX)
	_load_text = _label("", SMALL_FONT, WHITE)
	bottom.add_child(_side_cell(_load, _load_text))
	box.add_child(bottom)
	_bay_boxes = HBoxContainer.new()
	_bay_boxes.alignment = BoxContainer.ALIGNMENT_CENTER
	_bay_boxes.add_theme_constant_override("separation", 16)
	box.add_child(_bay_boxes)
	return box


## One framed box per bay ([param slots], VehicleComponentSlot): green with the fitted part's icon in
## green while it works, grey and empty when the bay is free. Only touched when it changes.
func _show_bays(slots: Array) -> void:
	while _bay_boxes.get_child_count() < slots.size():
		_bay_boxes.add_child(_bay_box())
	for i in _bay_boxes.get_child_count():
		var part: Node = slots[i].occupant if i < slots.size() else null
		_show_bay(_bay_boxes.get_child(i) as PanelContainer, bay_icon(part))


## One bay's box showing [param texture] (null: free), framed and tinted by bay_colour.
static func _show_bay(box: PanelContainer, texture: Texture2D) -> void:
	var icon := box.get_child(0) as TextureRect
	if icon.texture == texture:
		return
	icon.texture = texture
	var colour: Color = bay_colour(texture != null)
	icon.modulate = colour
	(box.get_theme_stylebox("panel") as StyleBoxFlat).border_color = colour


## The icon of a fitted [param part]: the pictogram painted on it (its spec's icon, the same drawing
## as the warning lights); null for an empty bay.
static func bay_icon(part: Node) -> Texture2D:
	var component := part as VehicleComponent if is_instance_valid(part) else null
	if component == null or component.spec == null:
		return null
	return component.spec.icon


## A bay's frame and icon: green with a part fitted (it works: wear will dim it later), grey when free.
static func bay_colour(fitted: bool) -> Color:
	return GREEN if fitted else BAY_FREE_COLOR


static func _bay_box() -> PanelContainer:
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(BAY_BOX_PX, BAY_BOX_PX)
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color(1, 1, 1, 0.04)
	frame.border_color = BAY_FREE_COLOR
	frame.set_border_width_all(3)
	frame.set_corner_radius_all(6)
	box.add_theme_stylebox_override("panel", frame)
	box.add_child(_icon("", BAY_ICON_PX))
	return box


## Right: the drive (4x4) over the motor, the power used and the rpm; then each battery's charge.
func _energy() -> Control:
	_energy_grid = GridContainer.new()
	_energy_grid.columns = 3
	_energy_grid.add_theme_constant_override("h_separation", 18)
	_energy_grid.add_theme_constant_override("v_separation", 10)
	_energy_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var motor_cell := VBoxContainer.new()
	motor_cell.add_theme_constant_override("separation", 0)
	_drive = _label("", SMALL_FONT * 3 / 4, WHITE)
	_drive.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	motor_cell.add_child(_drive)
	var motor := _icon("motor", SMALL_ICON_PX)
	motor.modulate = WHITE  # always shown: what drives the truck, not a warning
	motor_cell.add_child(motor)
	_power = _bar(GREEN)
	_rpm = _figure()
	for node: Control in [motor_cell, _power, _rpm]:
		_energy_grid.add_child(node)
	return _energy_grid


## One row of the energy grid per battery, in bay order (VehicleEnergy.levels): its icon, its charge as
## a bar in the battery's own gauge colour, the percentage; the one in use at full strength, the others
## dimmed. The motor's row comes first (ENERGY_CELLS cells), then BATTERY_CELLS per battery.
func _show_batteries(levels: Array[Dictionary]) -> void:
	while battery_rows() < levels.size():
		_add_battery_row()
	while battery_rows() > levels.size():
		for _i in BATTERY_CELLS:
			var extra: Node = _energy_grid.get_child(_energy_grid.get_child_count() - 1)
			_energy_grid.remove_child(extra)
			extra.queue_free()
	for i in levels.size():
		var first: int = ENERGY_CELLS + i * BATTERY_CELLS
		var fraction: float = float(levels[i]["fraction"])
		var bar := _energy_grid.get_child(first + 1) as ProgressBar
		bar.value = fraction * 100.0
		(bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = VehicleBattery.gauge_color(fraction)
		(_energy_grid.get_child(first + 2) as Label).text = EnergyFormat.percent(fraction)
		var alpha: float = 1.0 if bool(levels[i]["active"]) else BATTERY_IDLE_ALPHA
		for c in BATTERY_CELLS:
			(_energy_grid.get_child(first + c) as CanvasItem).modulate.a = alpha


## How many battery rows the energy grid shows.
func battery_rows() -> int:
	return (_energy_grid.get_child_count() - ENERGY_CELLS) / BATTERY_CELLS


func _add_battery_row() -> void:
	var icon := _icon("battery", SMALL_ICON_PX)
	icon.modulate = WHITE
	_energy_grid.add_child(icon)
	_energy_grid.add_child(_bar(GREEN))
	_energy_grid.add_child(_figure())


## A figure of the energy column: a fixed width, right-aligned, so it never moves its bar.
static func _figure() -> Label:
	var label := _label("", SMALL_FONT, WHITE)
	label.custom_minimum_size = Vector2(FIGURE_WIDTH_PX, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return label


static func _zone(content: Control, stretch: float) -> Control:
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_stretch_ratio = stretch
	return content


## A warning light with its figure beside it (the limiter's limit, the load).
static func _side_cell(icon: TextureRect, figure: Label) -> Control:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 12)
	cell.add_child(icon)
	figure.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cell.add_child(figure)
	return cell


## A pictogram of ICON_DIR, [param px] square and faint (off); [param icon_name] "" for an empty one.
static func _icon(icon_name: String, px: int) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = load(ICON_DIR + icon_name + ".png") if icon_name != "" else null
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(px, px)
	icon.modulate = OFF_COLOR
	return icon


static func _bar(fill: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 34)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var back := StyleBoxFlat.new()
	back.bg_color = Color(1, 1, 1, 0.1)
	bar.add_theme_stylebox_override("background", back)
	var front := StyleBoxFlat.new()  # its own: a battery's is recoloured per refresh
	front.bg_color = fill
	bar.add_theme_stylebox_override("fill", front)
	return bar


static func _label(text: String, font_size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", colour)
	if ResourceLoader.exists(FONT_PATH):
		label.add_theme_font_override("font", load(FONT_PATH))
	return label


## "12 345.6": thousands grouped like every other figure in the game, one decimal (100 m).
static func _km_text(km: float) -> String:
	var tenths: int = int(round(km * 10.0))
	return "%s.%d" % [Globals.format_thousands(floorf(tenths / 10.0)), tenths % 10]


## Live: drawn whenever the cab screen is on screen (the engine default, like the teleporter's).
## Off: one frame to show the dark panel, then nothing. Far: nothing, the last image stays.
func _set_state(state: String) -> void:
	if state == _state or _screen == null:
		return
	_state = state
	match state:
		"live":
			_screen.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		"off":
			_screen.render_target_update_mode = SubViewport.UPDATE_ONCE
		_:
			_screen.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _far_from_view() -> bool:
	var camera: Camera3D = get_tree().root.get_camera_3d()
	if camera == null:
		return false
	return camera.global_position.distance_squared_to(_vehicle.global_position) > max_distance * max_distance


## Walk up the tree (through the SubViewport) to the owning Vehicle.
func _find_vehicle() -> Vehicle:
	var n: Node = get_parent()
	while n != null and not (n is Vehicle):
		n = n.get_parent()
	return n as Vehicle
