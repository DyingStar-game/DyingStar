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
## Energy drawn per N·m of torque the motors are asked for, per second (J / (N·m·s)). The battery
## follows the torque REQUESTED, not the speed: a slope, a load or a bad road ask for more torque
## for the same distance. 127 is the design's starting value, to be validated in game.
@export var discharge_j_per_nm_s: float = 127.0
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


## Power drawn (W) for [param torque_nm] of torque requested from the motors.
func draw_w(torque_nm: float) -> float:
	return discharge_j_per_nm_s * maxf(torque_nm, 0.0)
