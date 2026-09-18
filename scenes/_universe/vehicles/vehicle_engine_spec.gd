@tool
class_name VehicleEngineSpec
extends VehicleComponentSpec

## What an ENGINE is: everything the drive model needs from ONE motor, and nothing about the
## chassis it is bolted into. The wheel radius, the transmission and the drag all belong to the
## Vehicle — an engine knows only what it can produce.
##
## The design spreadsheet's whole "Paramètres du moteur T1" block is the first three fields
## below. Engines fitted side by side simply SUM their torque and their power, which is why the
## model works the same for one motor or for fifty.
##
## The propulsion type follows the ENGINE, not the chassis: fitting a thermal engine brings its
## own gearbox with it. A vehicle whose fitted engines disagree is out of scope for now.

## ELECTRIC = single-speed, instant torque. THERMAL = gearbox with automatic shifting.
enum Propulsion {ELECTRIC, THERMAL}

@export var propulsion: Propulsion = Propulsion.ELECTRIC
## Electrical power drawn (W). Together with the torque it fixes the motor's angular speed, and
## therefore the vehicle's top speed: omega_max = mech power / mech torque.
@export var power_w: float = 100000.0
## Shaft torque (Nm). Engines in parallel ADD their torque — that is what makes a second motor
## pull harder WITHOUT going any faster.
@export var torque_nm: float = 600.0
## Motor efficiency (0-1). It lives on the motor so a better tier can be more efficient without
## touching the chassis; the pump and hydraulic efficiencies stay on the Vehicle.
@export_range(0.0, 1.0, 0.01) var efficiency: float = 0.9

@export_group("Thermal gearbox")
## Torque multiplier per gear, lowest gear first. THERMAL only.
@export var gear_ratios: Array[float] = [2.5, 1.7, 1.25, 1.0, 0.8]
@export var shift_up_rpm: float = 3400.0
@export var shift_down_rpm: float = 1400.0
@export var reverse_ratio: float = 2.5
@export var idle_rpm: float = 800.0
@export var redline_rpm: float = 4000.0

## Mechanical power (W) this engine delivers to the transmission, its own losses taken out.
## The chassis then applies ITS losses (pump, hydraulics) on top — see VehicleDriveSpec.
func shaft_power_w() -> float:
	return power_w * efficiency

func _validate_property(property: Dictionary) -> void:
	# Hide the gearbox settings on an electric motor: they would read as if they did something.
	if propulsion == Propulsion.ELECTRIC and property.name in [
			"gear_ratios", "shift_up_rpm", "shift_down_rpm", "reverse_ratio", "idle_rpm", "redline_rpm"]:
		property.usage = PROPERTY_USAGE_NO_EDITOR
