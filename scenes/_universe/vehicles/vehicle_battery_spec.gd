@tool
class_name VehicleBatterySpec
extends VehicleComponentSpec

## What a battery IS: how much energy it holds, how fast it takes a charge, and what the motors
## cost it. The numbers come from the "Calculateur Batterie" sheet of the motor & battery sizing
## workbook (T1: 180 MJ, 1000 A, 500 V); the discharge coefficient is the design's own, to be
## validated in game.
##
## Pure data and arithmetic, no scene, no state: the charge a part HOLDS lives on the part
## (VehicleBattery), what draws on it lives on the vehicle (VehicleEnergy).

## Energy held when full (J). 180 MJ = 50 kWh for a T1.
@export var capacity_j: float = 180.0e6
## Highest current the battery takes on charge (A). With the nominal voltage it sets the charging
## power, and so the recharge time. Not a limit on discharge in the MVP.
@export var max_current_a: float = 1000.0
## Nominal voltage (V): the T1 motor's 100 kW at its 200 A nominal current.
@export var nominal_voltage_v: float = 500.0
## Share of the electric power that reaches the wheels (0..1): the work done on the road costs
## 1 / efficiency of it. A heavy load, a slope, a launch ask for more work, so more energy.
@export_range(0.1, 1.0, 0.01) var motor_efficiency: float = 0.9
## What a motor straining costs on top of its work, per N·m of torque asked, per second
## (J / (N·m·s)): its windings heat even when the wheels barely turn (a truck stuck against a
## slope still empties its battery). A tenth of the 127 the first model charged for the whole draw.
@export var loss_j_per_nm_s: float = 12.7
## Below this charge (0..1) the battery charges slower (the 0-20 % band of the sheet).
@export_range(0.0, 1.0, 0.01) var slow_low_fraction: float = 0.2
## Above this charge (0..1) the battery charges slower (the 80-100 % band of the sheet).
@export_range(0.0, 1.0, 0.01) var slow_high_fraction: float = 0.8
## How many times slower the charge goes in those two bands. 1 = a linear charge throughout.
@export_range(1.0, 10.0, 0.1) var slow_factor: float = 2.0


func _init() -> void:
	kind = Kind.BATTERY


## Charging power at full rate (W): voltage x current.
func charge_power_w() -> float:
	return nominal_voltage_v * max_current_a


## Charging power (W) at [param fraction] of full charge: the full rate between the two bands,
## [member slow_factor] times slower below [member slow_low_fraction] and above [member slow_high_fraction].
func charge_rate_w(fraction: float) -> float:
	var slow: bool = fraction < slow_low_fraction or fraction >= slow_high_fraction
	return charge_power_w() / (slow_factor if slow else 1.0)


## Seconds to charge from empty to full, bands included (504 s for a T1, as the sheet's "Temps3").
func full_charge_time_s() -> float:
	var linear_s: float = capacity_j / charge_power_w()
	var slow_share: float = slow_low_fraction + (1.0 - slow_high_fraction)
	return linear_s * ((1.0 - slow_share) + slow_share * slow_factor)


## Power drawn (W) to put [param wheel_power_w] on the road (driving force x speed; 0 or less when
## coasting or pushing against the motion -- no regeneration) while the motors are asked for
## [param torque_nm].
func draw_w(wheel_power_w: float, torque_nm: float) -> float:
	return maxf(wheel_power_w, 0.0) / motor_efficiency + loss_j_per_nm_s * maxf(torque_nm, 0.0)
