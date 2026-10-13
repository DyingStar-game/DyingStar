@tool
class_name PhotocellTuning
extends Resource
## When the twilight switches (Photocell) turn their lamps on and off, and how long each waits: ONE
## resource every lamp shares (photocell_tuning.tres), tuned in the Inspector in lux, the unit the dev
## panel's "light" line reads. A lamp that needs its own takes its own copy (Make Unique).

## Illuminance of a clear noon (lux) a daylight of 1 stands for (Planet.daylight_at is a share of it).
const CLEAR_NOON_LUX := 100000.0

## Under this light on the ground (lux) the lamps come on at dusk. 1900 lux is the star at +2.9° over a
## village at 5130 m, the median of Tarsis 3's villages: tuned in game (2026-10-13), 1100 lux (+2°) came on
## too late.
@export_range(0.0, 20000.0, 10.0, "suffix:lux") var on_below_lux: float = 1900.0:
	set(value):
		on_below_lux = value
		emit_changed()
## Over this light (lux) they go off at dawn: 3100 lux, the star at +4° over that village. Kept above
## on_below_lux, or a lamp at the threshold blinks.
@export_range(0.0, 20000.0, 10.0, "suffix:lux") var off_above_lux: float = 3100.0:
	set(value):
		off_above_lux = value
		emit_changed()
## Longest wait (s) between the light crossing a threshold and a lamp switching: each lamp draws its own
## wait in that range, so a village comes on one lamp at a time.
@export_range(0.0, 600.0, 1.0, "suffix:s") var max_delay_s: float = 120.0


## The dusk threshold as a daylight share (Planet.daylight_at's unit).
func on_below_light() -> float:
	return on_below_lux / CLEAR_NOON_LUX


## The dawn threshold as a daylight share.
func off_above_light() -> float:
	return off_above_lux / CLEAR_NOON_LUX


## The illuminance (lux) a [param daylight] (Planet.daylight_at) stands for.
static func lux_of(daylight: float) -> float:
	return daylight * CLEAR_NOON_LUX
