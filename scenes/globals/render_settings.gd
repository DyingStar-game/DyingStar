class_name RenderSettings
extends RefCounted
## The rendering options: what is stored, what actually applies, and which preset that amounts to.
##
## Split out of SettingsManager like LanguageSettings, and for the same two reasons: the manager is
## at the linter's public-method ceiling, and "where settings are stored" and "what an option means"
## are two jobs. Same contract too — the ConfigFile and the save call are handed in, so there is
## still one settings file and one writer.
##
## It never touches the engine. It says what each option's EFFECTIVE value is — the stored one,
## unless the renderer cannot do it or another option rules it out — and emits `changed` with the
## options whose effective value moved. RenderApplier turns that into engine calls; the pages and
## the overlay redraw from it; PlanetTerrain and AtmosphereRenderer read the few they consume.

## Emitted after every write, with the options whose EFFECTIVE value changed (possibly none — a
## write can change only what is stored, e.g. MSAA picked while FSR 2.2 overrides it). Listeners
## that only redraw can ignore the list; listeners that apply must apply exactly these.
signal changed(keys: PackedStringArray)
## The in-game graphics overlay was switched on or off (Settings > General).
signal overlay_changed(on: bool)

const OVERLAY_SECTION : String = "general"
const OVERLAY_KEY : String = "graphics_overlay"

## What the machine can do, measured once by current_caps() — or handed in by a test:
##   method      the rendering method ("forward_plus", "mobile", "gl_compatibility")
##   overridden  option keys a client.ini debug key currently forces
##   tier        GpuTier's guess for this GPU
##   adapter     the GPU's name, for the "Recommended for" line
var caps : Dictionary = {}

var _config : ConfigFile
var _save : Callable
## Last effective value of every option, to report only what really moved.
var _effective : Dictionary = {}


func _init(config: ConfigFile, save: Callable, capabilities: Dictionary = {}) -> void:
	_config = config
	_save = save
	caps = capabilities


## Measure this machine. Kept out of _init so the dedicated server, which constructs us but draws
## nothing, never queries a renderer it does not use.
static func current_caps() -> Dictionary:
	var overridden : PackedStringArray = []
	for option in GraphicsOptions.OPTIONS:
		for ini_key in option.get("client_ini", []):
			if ClientConfig.has_key(ini_key):
				overridden.append(option["key"])
				break
	return {
		"method": RenderingServer.get_current_rendering_method(),
		"overridden": overridden,
		"tier": GpuTier.detect(),
		"adapter": RenderingServer.get_video_adapter_name(),
	}


## Called once the settings file is loaded. On the very first launch, start on the preset guessed
## for this GPU; otherwise write NOTHING — a missing key reads as its default, which is how the game
## looked before these options existed, so an existing player's picture does not change under them.
func ensure_initialized(first_run: bool) -> void:
	if first_run:
		for option in GraphicsOptions.OPTIONS:
			_config.set_value(GraphicsOptions.SECTION, option["key"], _preset_value(option, detected()))
	_effective = _compute_effective()


## The stored value, cleaned: of the option's type, inside its range or among its choices, else the
## default. A hand-edited or outdated file must never reach the engine as garbage.
func get_value(key: String) -> Variant:
	var option : Dictionary = GraphicsOptions.find(key)
	if option.is_empty():
		push_error("RenderSettings: unknown option '%s'" % key)
		return null
	return _clean(option, _config.get_value(GraphicsOptions.SECTION, key, option["default"]))


## What applies: the stored value, unless the renderer cannot do it or another option forces it off.
func effective(key: String) -> Variant:
	var option : Dictionary = GraphicsOptions.find(key)
	if option.is_empty():
		return null
	if _block(option).get("force", false):
		return GraphicsOptions.off_value(option)
	var value : Variant = get_value(key)
	if option["kind"] == GraphicsOptions.CHOICE and not choice_available(key, value):
		return GraphicsOptions.off_value(option)
	return value


## "" when the option can be changed, else the translation key of why not (for the tooltip).
func availability(key: String) -> String:
	var option : Dictionary = GraphicsOptions.find(key)
	return "" if option.is_empty() else str(_block(option).get("why", ""))


## Whether one value of a CHOICE works on this renderer (FSR 2.2 needs Forward+, for instance).
func choice_available(key: String, value: Variant) -> bool:
	var option : Dictionary = GraphicsOptions.find(key)
	for choice in option.get("choices", []):
		if GraphicsOptions.same(choice[0], value):
			return choice.size() < 3 or _method() in choice[2]
	return false


## A client.ini debug key owns this option: it is shown greyed and never applied from here.
func is_overridden(key: String) -> bool:
	return key in caps.get("overridden", PackedStringArray())


## Store one option (cleaned), save, and report what that changed.
func set_value(key: String, value: Variant) -> void:
	var option : Dictionary = GraphicsOptions.find(key)
	if option.is_empty():
		push_error("RenderSettings: unknown option '%s'" % key)
		return
	_config.set_value(GraphicsOptions.SECTION, key, _clean(option, value))
	_save.call()
	_sync()


## Store every option's value for one of GraphicsOptions.PRESETS, with a single save.
func apply_preset(preset_name: String) -> void:
	if not preset_name in GraphicsOptions.PRESETS:
		push_error("RenderSettings: unknown preset '%s'" % preset_name)
		return
	for option in GraphicsOptions.OPTIONS:
		_config.set_value(GraphicsOptions.SECTION, option["key"], _preset_value(option, preset_name))
	_save.call()
	_sync()


## The preset the stored values amount to, or CUSTOM. Derived, never stored: a label that is saved
## can disagree with the values beside it, one that is computed cannot.
func preset() -> String:
	for preset_name in GraphicsOptions.PRESETS:
		var all_match : bool = true
		for option in GraphicsOptions.OPTIONS:
			if not GraphicsOptions.same(get_value(option["key"]), _preset_value(option, preset_name)):
				all_match = false
				break
		if all_match:
			return preset_name
	return GraphicsOptions.CUSTOM


## GpuTier's guess for this machine (MEDIUM when it was never measured).
func detected() -> String:
	return str(caps.get("tier", GpuTier.MEDIUM))


func is_overlay_enabled() -> bool:
	return bool(_config.get_value(OVERLAY_SECTION, OVERLAY_KEY, false))


func set_overlay_enabled(on: bool) -> void:
	_config.set_value(OVERLAY_SECTION, OVERLAY_KEY, on)
	_save.call()
	overlay_changed.emit(on)


## One line for the boot log: the derived preset, the guess, and every effective value.
func describe() -> String:
	var parts : PackedStringArray = ["preset=%s" % preset(), "detected=%s" % detected(),
		"renderer=%s" % _method(), "adapter=\"%s\"" % caps.get("adapter", "")]
	for option in GraphicsOptions.OPTIONS:
		parts.append("%s=%s" % [option["key"], effective(option["key"])])
	return " ".join(parts)


func _sync() -> void:
	var now : Dictionary = _compute_effective()
	var moved : PackedStringArray = []
	for key in now:
		if not _effective.has(key) or not GraphicsOptions.same(_effective[key], now[key]):
			moved.append(key)
	_effective = now
	changed.emit(moved)


func _compute_effective() -> Dictionary:
	var out : Dictionary = {}
	for option in GraphicsOptions.OPTIONS:
		out[option["key"]] = effective(option["key"])
	return out


## Why an option cannot be changed right now, as {why, force}; {} when it can.
func _block(option: Dictionary) -> Dictionary:
	if option.has("renderers") and not _method() in option["renderers"]:
		return {"why": GraphicsOptions.WHY_RENDERER, "force": true}
	if is_overridden(option["key"]):
		return {"why": GraphicsOptions.WHY_CLIENT_INI, "force": false}
	var rule : Dictionary = option.get("blocked_by", {})
	if not rule.is_empty():
		var other : Variant = effective(rule["key"])
		for value in rule["values"]:
			if GraphicsOptions.same(other, value):
				return {"why": rule["why"], "force": rule["force"]}
	return {}


func _clean(option: Dictionary, value: Variant) -> Variant:
	match option["kind"]:
		GraphicsOptions.TOGGLE:
			return value if typeof(value) == TYPE_BOOL else option["default"]
		GraphicsOptions.CHOICE:
			for choice in option["choices"]:
				if GraphicsOptions.same(choice[0], value):
					return choice[0]
			return option["default"]
		GraphicsOptions.SLIDER:
			if not typeof(value) in [TYPE_FLOAT, TYPE_INT]:
				return option["default"]
			return clampf(float(value), option["min"], option["max"])
	return option["default"]


func _preset_value(option: Dictionary, preset_name: String) -> Variant:
	return option["presets"][GraphicsOptions.PRESETS.find(preset_name)]


func _method() -> String:
	return str(caps.get("method", "forward_plus"))
