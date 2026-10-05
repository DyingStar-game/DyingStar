class_name VehicleDashboard
extends Panel

## In-cab dashboard rendered on a vehicle's 3D screen (through a SubViewport). Pure display: it
## finds its owning Vehicle in the tree and shows the generic Vehicle data each frame. Reusable
## by any vehicle — it only reads the public Vehicle accessors, and the Vehicle knows nothing
## about it (the screen is just another child). Put this script on the UI scene's root.
##
## Expects these child Labels (rename here if your scene differs):
## Speed, RPM, Load, Overloaded, Powertrain, Transmission, Handbrake, Light, Limiter, Odometer;
## and a BatteryBars container, filled with one row per battery fitted (bar + percentage).

## The speed limiter: green while it is on, red while it is holding the truck back over its limit
## (engine braking), dimmed while it is off. The chosen step stays readable in every state, only the
## colour tells them apart.
const LIMITER_ON_COLOR := Color(0.4627451, 0.96862745, 0.0)  # the green of the other "on" lights
const LIMITER_BRAKING_COLOR := Color(1.0, 0.0, 0.25882354)  # the red of the overload warning
const LIMITER_OFF_COLOR := Color(1.0, 1.0, 1.0, 0.45)
## A battery row: the one in use at full strength, the others dimmed.
const BATTERY_IDLE_ALPHA := 0.45
## Size of a battery bar on the screen (px) and of its percentage.
const BATTERY_BAR_SIZE := Vector2(520.0, 40.0)
const BATTERY_FONT_SIZE := 44

## Beyond this distance (m) from the player's view the screen stops rendering and its labels stop
## updating: it keeps its last image, unreadable from there anyway. Every truck carried a 1921x1112
## screen redrawn every frame wherever it stood — eleven of them around the spawn.
@export var max_distance: float = 30.0

var _vehicle: Vehicle = null
## The SubViewport this panel is drawn into (the cab screen's texture). Null when shown elsewhere.
var _screen: SubViewport = null
## Last applied state, to touch the SubViewport only on a change: "live", "off", "far".
var _state: String = ""

@onready var _speed: Label = $Speed
@onready var _rpm: Label = $RPM
@onready var _load: Label = $Load
@onready var _overloaded: Label = $Overloaded
@onready var _powertrain: Label = $Powertrain
@onready var _transmission: Label = $Transmission
@onready var _handbrake: Label = $Handbrake
@onready var _light: Label = $Light
@onready var _limiter: Label = $Limiter
@onready var _odometer: Label = $Odometer
@onready var _battery_bars: VBoxContainer = $BatteryBars

func _ready() -> void:
	# Nobody looks at a screen on the server: it only cost a frame of work per truck there.
	if GameOrchestrator.is_server():
		set_process(false)
		return
	_vehicle = _find_vehicle()
	_screen = get_viewport() as SubViewport

func _process(_delta: float) -> void:
	if _vehicle == null or not is_instance_valid(_vehicle):
		return
	if _far_from_view():
		_set_state("far")
		return
	# Engine off, or no charge left: the screen goes dark (matches the rear-view screens). Multiplying
	# by black keeps the panel opaque, so the cab screen reads as a powered-off display rather than a
	# frozen dash. It draws nothing from the batteries, but it needs one with some charge.
	if not _vehicle.is_engine_on() or not _vehicle.energy.has_energy():
		modulate = Color(0, 0, 0, 1)
		_set_state("off")
		return
	modulate = Color(1, 1, 1, 1)
	_set_state("live")
	_speed.text = "%.0f km/h" % _vehicle.get_display_speed_kmh()
	_rpm.text = tr("%%HUD_RPM") % _vehicle.get_engine_rpm()
	_load.text = "%.0f / %.0f kg" % [_vehicle.get_cargo_mass(), _vehicle.max_payload]
	_overloaded.text = "%%HUD_OVERLOADED" if _vehicle.is_overloaded() else ""
	_powertrain.text = _vehicle.get_propulsion_name()
	_transmission.text = _vehicle.get_drive_mode_name()
	_handbrake.text = "%%HUD_HANDBRAKE" if _vehicle.is_handbraked() else ""
	_light.text = "%%HUD_LIGHTS" if _vehicle.is_headlights_on() else ""
	var limiter: VehicleSpeedLimiter = _vehicle.limiter
	_limiter.text = "%s  %d km/h" % [tr("%%HUD_LIMITER"), limiter.cap_kmh]
	_limiter.modulate = _limiter_color(limiter, _vehicle.get_display_speed_kmh())
	_odometer.text = "%s  %s km" % [tr("%%HUD_ODOMETER"), _km_text(_vehicle.odometer.km())]
	_show_batteries(_vehicle.energy.levels())


## One row per battery, in bay order (VehicleEnergy.levels): its charge as a bar, the percentage at
## its end, the one in use at full strength and the others dimmed.
func _show_batteries(levels: Array[Dictionary]) -> void:
	while _battery_bars.get_child_count() < levels.size():
		_battery_bars.add_child(_battery_row())
	while _battery_bars.get_child_count() > levels.size():
		var extra: Node = _battery_bars.get_child(_battery_bars.get_child_count() - 1)
		_battery_bars.remove_child(extra)
		extra.queue_free()
	for i in levels.size():
		var row: HBoxContainer = _battery_bars.get_child(i)
		var level: Dictionary = levels[i]
		var bar := row.get_child(0) as ProgressBar
		bar.value = float(level["fraction"]) * 100.0
		# The battery's own gauge colour (green, red when low), so the dash and the part agree.
		(bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = VehicleBattery.gauge_color(float(level["fraction"]))
		(row.get_child(1) as Label).text = EnergyFormat.percent(float(level["fraction"]))
		row.modulate.a = 1.0 if bool(level["active"]) else BATTERY_IDLE_ALPHA


## A battery row: a bar and its percentage.
static func _battery_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "BatteryRow"
	row.add_theme_constant_override("separation", 16)
	var bar := ProgressBar.new()
	bar.name = "Charge"
	bar.custom_minimum_size = BATTERY_BAR_SIZE
	bar.show_percentage = false
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_theme_stylebox_override("fill", StyleBoxFlat.new())  # its own, coloured per refresh
	row.add_child(bar)
	var percent := Label.new()
	percent.name = "Percent"
	percent.add_theme_font_size_override("font_size", BATTERY_FONT_SIZE)
	row.add_child(percent)
	return row


static func _limiter_color(limiter: VehicleSpeedLimiter, speed_kmh: float) -> Color:
	if limiter.is_over(speed_kmh):
		return LIMITER_BRAKING_COLOR
	return LIMITER_ON_COLOR if limiter.enabled else LIMITER_OFF_COLOR


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
