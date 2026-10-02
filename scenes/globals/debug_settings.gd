class_name DebugSettings
extends RefCounted
## The debug switches of Settings > Debug: one table of on / off values under [general].
##
## Split out of SettingsManager like RenderSettings and LanguageSettings: eight switches were sixteen
## identical setter / getter pairs and eight signals there, and a ninth went over the linter's
## public-method ceiling. Same contract as theirs — the ConfigFile and the save call are handed in,
## so there is still one settings file and one writer. A new switch is one line in DEFAULTS.

## A switch moved, saved or previewed: what the debug panel follows (DebugToggles).
signal changed(key: StringName, on: bool)

const SECTION : String = "general"
## Every switch, by its key in settings.ini, with its value before the player ever touched it.
const DEFAULTS : Dictionary = {
	# Shown by default: we are in early alpha, so the in-game debug panels are on out of the box.
	&"show_debug": true,
	# Shown by default: it is the driver's only dashboard until the in-cab one exists (GDD).
	&"vehicle_hud": true,
	# Draw a green envelope around items REALLY locked into a vehicle bed.
	&"cargo_debug": false,
	# Labelled markers pointing at the star and every planet / moon (orientation aid).
	&"celestial_gizmos": false,
	# Speed, walk tier, animation clip, vault / step probe.
	&"movement_debug": false,
	# The ground under your feet: taxonomy family, how it was decided, footstep sample.
	&"surface_debug": false,
	# Which track plays, from which playlist, and which line of the MusicTable decided it.
	&"music_debug": false,
	# What the star map draws: bodies, focus, zoom, simulated time, relief tiles.
	&"star_map_debug": false,
}
## Switches a dedicated server reads from its own ini ([section, key]), since it never loads
## settings.ini: the movement trace is the server's to give, collision being server-only.
const SERVER_INI : Dictionary = {
	&"movement_debug": ["debug", "movement"],
}

var _config : ConfigFile
var _save : Callable
## (section, key) -> bool, read from the server's ini. Resolved once per switch, then cached here.
var _server_flag : Callable
var _server_cache : Dictionary = {}
## key -> listeners (on: bool) -> void, see watch().
var _watchers : Dictionary = {}


func _init(config: ConfigFile, save: Callable, server_flag: Callable) -> void:
	_config = config
	_save = save
	_server_flag = server_flag


func is_on(key: StringName) -> bool:
	assert(DEFAULTS.has(key), "unknown debug switch %s" % key)
	if OS.has_feature("dedicated_server") and SERVER_INI.has(key):
		if not _server_cache.has(key):
			_server_cache[key] = bool(_server_flag.callv(SERVER_INI[key]))
		return _server_cache[key]
	return bool(_config.get_value(SECTION, key, DEFAULTS[key]))


func set_on(key: StringName, on: bool) -> void:
	assert(DEFAULTS.has(key), "unknown debug switch %s" % key)
	_config.set_value(SECTION, key, on)
	_save.call()
	_announce(key, on)


## Announce [param on] WITHOUT saving it, for a moment: the F8 bug-report capture shows the debug
## panels for one frame, then previews the stored value back.
func preview(key: StringName, on: bool) -> void:
	_announce(key, on)


## Call [param listener] (on: bool) whenever [param key] moves. A listener whose object was freed is
## dropped on the next change: a vehicle despawning does not have to disconnect.
func watch(key: StringName, listener: Callable) -> void:
	if not _watchers.has(key):
		_watchers[key] = []
	(_watchers[key] as Array).append(listener)


## First run: every switch at its default.
func write_defaults() -> void:
	for key: StringName in DEFAULTS:
		_config.set_value(SECTION, key, DEFAULTS[key])


func _announce(key: StringName, on: bool) -> void:
	changed.emit(key, on)
	var alive : Array = (_watchers.get(key, []) as Array).filter(func(c: Callable) -> bool: return c.is_valid())
	_watchers[key] = alive
	for listener: Callable in alive:
		listener.call(on)
