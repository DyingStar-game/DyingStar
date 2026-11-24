class_name VrComfortSettings
extends RefCounted
## Settings > General > VR comfort, shown in VR only (`--xr-mode on`): how the right stick turns, the
## dark edges while moving, the hand that aims, where the stick walks, seated or standing. Read by the
## VR rig (VrInput, VrBody, VrPointer, VrVignette) and the menus' laser (XRScreen) as they play.
##
## Same arrangement as UiScaleSettings: our ConfigFile and our save call are handed in, one settings
## file, one writer. Names no gameplay class (built by an autoload).

signal changed

const SECTION := "vr"
## Turning: in steps (comfortable: no motion the inner ear does not feel) or smooth.
const TURN_SNAP := "snap"
const TURN_SMOOTH := "smooth"
## The hand that aims and turns: the other one walks.
const HAND_RIGHT := "right"
const HAND_LEFT := "left"
## The stick walks towards where the head looks, or where the walking hand points.
const WALK_HEAD := "head"
const WALK_HAND := "hand"
## A step of the snap turn (deg).
const SNAP_MIN := 15.0
const SNAP_MAX := 90.0
const SNAP_STEP := 15.0
## The smooth turn's speed, stick pushed all the way (deg/s).
const SMOOTH_MIN := 30.0
const SMOOTH_MAX := 180.0
const SMOOTH_STEP := 15.0
const DEFAULTS := {
	"turn": TURN_SNAP,
	"snap_deg": 30.0,
	"smooth_deg_s": 90.0,
	"vignette": true,
	"hand": HAND_RIGHT,
	"walk": WALK_HEAD,
	"seated": false,
}

var _config: ConfigFile
var _save: Callable


func _init(config: ConfigFile, save: Callable) -> void:
	_config = config
	_save = save


## The stored [param key] (one of DEFAULTS), kept to what it may be whatever the file says.
func value(key: String) -> Variant:
	return clean(key, _config.get_value(SECTION, key, DEFAULTS.get(key)))


func set_value(key: String, v: Variant) -> void:
	if not DEFAULTS.has(key):
		push_error("VrComfortSettings: no setting %s" % key)
		return
	_config.set_value(SECTION, key, clean(key, v))
	_save.call()
	changed.emit()


func snap_turn() -> bool:
	return value("turn") == TURN_SNAP


func snap_deg() -> float:
	return value("snap_deg")


func smooth_deg_s() -> float:
	return value("smooth_deg_s")


func vignette() -> bool:
	return value("vignette")


func left_handed() -> bool:
	return value("hand") == HAND_LEFT


func walk_by_hand() -> bool:
	return value("walk") == WALK_HAND


func seated() -> bool:
	return value("seated")


## [param v] for [param key] as the game can use it: a known choice, a number on its grid and in its
## range, a bool; the default otherwise (a hand-edited file).
static func clean(key: String, v: Variant) -> Variant:
	var fallback: Variant = DEFAULTS.get(key)
	match key:
		"turn":
			return v if v in [TURN_SNAP, TURN_SMOOTH] else fallback
		"hand":
			return v if v in [HAND_RIGHT, HAND_LEFT] else fallback
		"walk":
			return v if v in [WALK_HEAD, WALK_HAND] else fallback
		"snap_deg":
			return clampf(snappedf(float(v), SNAP_STEP), SNAP_MIN, SNAP_MAX) if _is_number(v) else fallback
		"smooth_deg_s":
			return clampf(snappedf(float(v), SMOOTH_STEP), SMOOTH_MIN, SMOOTH_MAX) if _is_number(v) else fallback
		"vignette", "seated":
			return v if v is bool else fallback
	return fallback


static func _is_number(v: Variant) -> bool:
	return v is float or v is int or (v is String and (v as String).is_valid_float())
