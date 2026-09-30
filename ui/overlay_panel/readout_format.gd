class_name ReadoutFormat
extends RefCounted
## Number formats shared by the readouts, so the same kind of value reads the same way everywhere.


## "[color=…]60[/color] FPS": green at or above `good_min`, red below.
static func rated(value: float, good_min: float, unit: String) -> String:
	var colour : Color = SettingsStyle.GOOD_COLOR if value >= good_min else SettingsStyle.ALERT_COLOR
	return "[color=#%s]%d[/color] %s" % [colour.to_html(false), int(value), unit]


## "[color=…]45[/color] FPS" on three levels: green from `good`, yellow from `fair`, red below.
## `lower_is_better` for a cost (milliseconds): green up to `good`, yellow up to `fair`, red above.
## `decimals`: digits after the point.
static func graded(value: float, good: float, fair: float, unit: String, lower_is_better: bool = false,
		decimals: int = 0) -> String:
	var score : float = -value if lower_is_better else value
	var colour : Color = SettingsStyle.ALERT_COLOR
	if score >= (-good if lower_is_better else good):
		colour = SettingsStyle.GOOD_COLOR
	elif score >= (-fair if lower_is_better else fair):
		colour = SettingsStyle.FAIR_COLOR
	return "[color=#%s]%.*f[/color] %s" % [colour.to_html(false), decimals, value, unit]


## Metres under a kilometre, kilometres above it.
static func metres(v: float) -> String:
	return "%.2f km" % (v / 1000.0) if absf(v) >= 1000.0 else "%.0f m" % v


## Same, with an explicit sign: for a DIFFERENCE, "+0 m" says "standing on it" where a bare "0 m"
## reads like a missing value.
static func signed(v: float) -> String:
	return ("+" if v >= 0.0 else "") + metres(v)


## Text shown as-is inside a bbcode readout: a "[" from a name or a tag like "[son: oui]" would
## otherwise be read as markup.
static func escape(text: String) -> String:
	return text.replace("[", "[lb]")
