class_name ReadoutFormat
extends RefCounted
## Number formats shared by the readouts, so the same kind of value reads the same way everywhere.


## "[color=…]60[/color] FPS": green at or above `good_min`, red below.
static func rated(value: float, good_min: float, unit: String) -> String:
	var colour : Color = SettingsStyle.GOOD_COLOR if value >= good_min else SettingsStyle.ALERT_COLOR
	return "[color=#%s]%d[/color] %s" % [colour.to_html(false), int(value), unit]


## Metres under a kilometre, kilometres above it.
static func metres(v: float) -> String:
	return "%.2f km" % (v / 1000.0) if absf(v) >= 1000.0 else "%.0f m" % v


## Same, with an explicit sign: for a DIFFERENCE, "+0 m" says "standing on it" where a bare "0 m"
## reads like a missing value.
static func signed(v: float) -> String:
	return ("+" if v >= 0.0 else "") + metres(v)
