class_name UiScaleSettings
extends RefCounted
## Settings > General > Interface size: how big the menus and panels are drawn, on top of the
## project's own scaling (canvas_items, expand: the UI is laid out for 1080p and follows the window's
## height). On a big screen that makes text large; this lets each player take it down — or up.
##
## Same arrangement as LanguageSettings: our ConfigFile and our save call are handed in, so there is
## one settings file and one writer. It applies itself to the root window it is given.

signal changed(scale: float)

const MIN : float = 0.8
const MAX : float = 1.2
const STEP : float = 0.05
const DEFAULT : float = 1.0
const SECTION : String = "general"
const KEY : String = "ui_scale"

var _config : ConfigFile
var _save : Callable
var _window : Window


func _init(config: ConfigFile, save: Callable, window: Window = null) -> void:
	_config = config
	_save = save
	_window = window


## The stored size, kept within MIN..MAX on the STEP grid whatever the file says.
func value() -> float:
	return clean(float(_config.get_value(SECTION, KEY, DEFAULT)))


func set_value(scale: float) -> void:
	var v : float = clean(scale)
	_config.set_value(SECTION, KEY, v)
	_save.call()
	apply()
	changed.emit(v)


## Put the stored size on the window (at boot, and after each change).
func apply() -> void:
	if _window != null:
		_window.content_scale_factor = value()


static func clean(scale: float) -> float:
	return clampf(snappedf(scale, STEP), MIN, MAX)
