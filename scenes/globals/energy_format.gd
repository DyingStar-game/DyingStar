class_name EnergyFormat
extends RefCounted
## How an amount of energy is written for the player, in one place: kilowatt-hours, the unit
## batteries are sold in. The game counts in joules (1 kWh = 3.6 MJ); only the display converts.

const J_PER_KWH : float = 3.6e6


## [param joules] in kWh, one decimal: "35.1".
static func kwh(joules: float) -> String:
	return "%.1f" % (joules / J_PER_KWH)


## A charge out of a capacity: "35.1 / 50.0 kWh".
static func charge(joules: float, capacity_j: float) -> String:
	return "%s / %s kWh" % [kwh(joules), kwh(capacity_j)]


## [param fraction] (0..1) as a whole percentage: "87 %".
static func percent(fraction: float) -> String:
	return "%d %%" % roundi(clampf(fraction, 0.0, 1.0) * 100.0)
