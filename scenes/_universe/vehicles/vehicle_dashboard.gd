class_name VehicleDashboard
extends Panel

## In-cab dashboard rendered on a vehicle's 3D screen (through a SubViewport). Pure display: it
## finds its owning Vehicle in the tree and shows the generic Vehicle data each frame. Reusable
## by any vehicle — it only reads the public Vehicle accessors, and the Vehicle knows nothing
## about it (the screen is just another child). Put this script on the UI scene's root.
##
## Expects these child Labels (rename here if your scene differs):
## speed, RPM, Load, Overloaded, Elec_THerm, Transmission, hanbreak, Light.

var _vehicle: Vehicle = null

@onready var _speed: Label = $speed
@onready var _rpm: Label = $RPM
@onready var _load: Label = $Load
@onready var _overloaded: Label = $Overloaded
@onready var _powertrain: Label = $Elec_THerm
@onready var _transmission: Label = $Transmission
@onready var _handbrake: Label = $hanbreak
@onready var _light: Label = $Light

func _ready() -> void:
	_vehicle = _find_vehicle()

func _process(_delta: float) -> void:
	if _vehicle == null or not is_instance_valid(_vehicle):
		return
	# Engine off: the screen goes dark (matches the rear-view screens). Multiplying by black keeps
	# the panel opaque, so the cab screen reads as a powered-off display rather than a frozen dash.
	if not _vehicle.is_engine_on():
		modulate = Color(0, 0, 0, 1)
		return
	modulate = Color(1, 1, 1, 1)
	_speed.text = "%.0f km/h" % _vehicle.get_display_speed_kmh()
	_rpm.text = "%.0f rpm" % _vehicle.get_engine_rpm()
	_load.text = "%.0f / %.0f kg" % [_vehicle.get_cargo_mass(), _vehicle.max_payload]
	_overloaded.text = "OVERLOADED" if _vehicle.is_overloaded() else ""
	_powertrain.text = _vehicle.get_propulsion_name()
	_transmission.text = _vehicle.get_drive_mode_name()
	_handbrake.text = "HANDBRAKE" if _vehicle.is_handbraked() else ""
	_light.text = "LIGHTS" if _vehicle.is_headlights_on() else ""

## Walk up the tree (through the SubViewport) to the owning Vehicle.
func _find_vehicle() -> Vehicle:
	var n: Node = get_parent()
	while n != null and not (n is Vehicle):
		n = n.get_parent()
	return n as Vehicle
