extends DirectionalLight3D

## Simple day/night cycle: rotates this light (the sun) over `cycle_seconds`. A PhysicalSky
## reacts to the sun angle (sky colour, sunset, night) and the light dims as the sun drops
## below the horizon. Client-side visual only for now (not multiplayer-synced).

## Duration of a full day+night cycle, in seconds. Default 1800 = 30 minutes.
@export var cycle_seconds: float = 1800.0
## Lateral tilt of the sun's arc (degrees) so it doesn't pass straight overhead.
@export var tilt_deg: float = 20.0
## Where in the cycle to start: 0 = noon, 0.25 = sunset, 0.5 = midnight, 0.75 = sunrise.
@export_range(0.0, 1.0) var start_phase: float = 0.78
## Sun brightness at its peak (noon); scaled down to 0 as the sun sets.
@export var day_energy: float = 1.0
## Sun light colour sampled by elevation (0 = horizon, 1 = noon): warm at dawn/dusk, white at
## noon. Leave empty to use a built-in orange->white default.
@export var sun_tint: Gradient

var _phase: float = 0.0

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)  # purely visual — no need to spin the sun on the headless server
		return
	_phase = start_phase
	if sun_tint == null:
		sun_tint = _build_default_sun_tint()

func _process(delta: float) -> void:
	if cycle_seconds <= 0.0:
		return
	_phase = fmod(_phase + delta / cycle_seconds, 1.0)
	# Pitch sweeps a full turn over the cycle; a fixed yaw tilts the arc sideways.
	rotation = Vector3(deg_to_rad(-90.0 + _phase * 360.0), deg_to_rad(tilt_deg), 0.0)
	# basis.z.y = sun elevation (1 at noon, 0 at the horizon, <0 at night) -> dim when it sets.
	var elevation: float = clampf(basis.z.y, 0.0, 1.0)
	light_energy = elevation * day_energy
	# Warm the light near the horizon; the PhysicalSky tints the sun disk + sky to match, so the
	# sunrise/sunset reads clearly (and the volumetric fog picks up the colour too).
	light_color = sun_tint.sample(elevation)

## Default sun colour ramp (elevation 0 -> 1): deep orange at dawn/dusk fading to white at noon.
func _build_default_sun_tint() -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.12, 0.35, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 0.32, 0.12),
		Color(1.0, 0.55, 0.28),
		Color(1.0, 0.93, 0.84),
		Color(1.0, 1.0, 1.0),
	])
	return gradient
