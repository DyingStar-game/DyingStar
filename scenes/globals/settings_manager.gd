extends Node

## Emitted when the camera field of view changes, so the active player camera updates live.
signal fov_changed(fov: float)
## Emitted when the shadows toggle changes, so the day/night sun enables/disables its shadow live.
signal shadows_changed(on: bool)
## Emitted when the shadow distance changes, so the day/night sun updates its shadow range live.
signal shadow_distance_changed(distance: float)
## Emitted when the local microphone is muted/unmuted, so the voice client actually STOPS SENDING.
## No audio bus is involved: a bus mute is applied after the effect chain, so AudioEffectCapture
## would keep feeding the voice client and the others would still hear us.
signal microphone_muted_changed(muted: bool)

# user:// is writable in an exported build (res:// is packed read-only), so settings actually
# persist between sessions there.
const CONFIG_FILEPATH : String = "user://settings.ini"
## A player's remapped keys, written by the controls page. Loaded HERE, at boot: applying them is a
## STARTUP job, not a menu job. It used to happen in MenuConfig._ready(), which only worked because a
## copy of that page was instanced inside pause_menu.tscn and therefore spawned with the player —
## remove that copy (it was dead UI, never shown) and every remap silently reverted to the project
## defaults until the player opened Settings > Controls once. Same lesson as the window settings just
## above: loaded but never applied reads exactly like "it did not persist".
const INPUT_MAP_FILEPATH : String = "user://inputs.map"
## Audio settings key -> the audio bus it drives. Sliders are 0..100 (linear), applied as dB.
## MenuMusic sends into Music: the menu's music answers to its own slider AND to the Music one.
const AUDIO_BUSES : Dictionary = {
	"general": "Master", "music": "Music", "menu_music": "MenuMusic", "sfx": "SFX", "voip": "VoIP",
	"ui": "UI",
}
var config : ConfigFile = ConfigFile.new()
## The display language. Given our ConfigFile and our save call rather than a file of its own, so
## the settings still have a single home and a single writer. Built in _ready(), before the
## dedicated-server early return, so it is never null even where nothing displays text.
var language : LanguageSettings
## The rendering options (anti-aliasing, upscaling, shadows, effects, distances). Same arrangement
## as `language`: our ConfigFile and our save call, built before the dedicated-server return so it
## is never null. It knows nothing of the engine; `render_applier` does.
var render : RenderSettings
## Hands `render` to the game view. Client only: null on a dedicated server, which draws nothing.
var render_applier : RenderApplier = null
## Settings > General > Interface size. Same arrangement as `language`; applied to the root window.
var ui_scale : UiScaleSettings
## The debug switches (Settings > Debug). Same arrangement as `language`; on a dedicated server, the
## few it reads come from server.ini.
var debug : DebugSettings
## The saved keybindings as action -> {device key: binding text} (InputDevice.KEYS), empty when
## nothing was ever remapped. Kept so the controls page can show and re-save them without parsing the file a second time.
var keybindings : Dictionary = {}

func _ready() -> void:
	language = LanguageSettings.new(config, save_settings)
	render = RenderSettings.new(config, save_settings)
	ui_scale = UiScaleSettings.new(config, save_settings, get_tree().root)
	debug = DebugSettings.new(config, save_settings, _server_ini_flag)
	if OS.has_feature("dedicated_server"):
		return
	render.caps = RenderSettings.current_caps()
	# First run (no file yet): write the defaults so there is something to load — and start the
	# rendering options on the preset guessed for this GPU. An existing file gets nothing new.
	var first_run : bool = config.load(CONFIG_FILEPATH) != OK
	if first_run:
		initialize_settings()
	render.ensure_initialized(first_run)
	if first_run:
		save_settings()
	# The root window, not a page's viewport: the settings pages live in a SubViewport.
	render_applier = RenderApplier.new(render, get_tree().root)
	render.changed.connect(_on_render_changed)
	# Re-apply the saved settings to the window on startup (this is what was missing: they were
	# loaded but never applied, so they appeared not to persist).
	apply_settings()
	ui_scale.apply()
	load_keybindings()

## Apply the saved keybindings over the project defaults. Safe to call again: it rebuilds each action
## from scratch. Returns quietly when the player never remapped anything.
func load_keybindings() -> void:
	keybindings = {}
	if not FileAccess.file_exists(INPUT_MAP_FILEPATH):
		return
	var file := FileAccess.open(INPUT_MAP_FILEPATH, FileAccess.READ)
	if file == null:
		return
	var content := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(content)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[DyingStar] inputs.map is not valid JSON — keeping the default bindings.")
		return
	for action_name in (parsed as Dictionary).keys():
		if not InputMap.has_action(action_name):
			continue  # an action renamed or removed since the file was written
		var by_device: Dictionary = keybindings_of(parsed[action_name])
		keybindings[action_name] = by_device
		# Each device's binding over that device's defaults only: a remapped key keeps the default
		# gamepad button, and the reverse.
		for device_key: String in by_device:
			InputDevice.rebind(action_name, InputEventCodec.decode(str(by_device[device_key])))


## One action's entry of user://inputs.map as {device key: binding text} (InputDevice.KEYS). A file
## written before gamepads held one string per action, a key or a mouse button: it reads as that.
static func keybindings_of(entry: Variant) -> Dictionary:
	if entry is Dictionary:
		var out: Dictionary = {}
		for device_key: String in InputDevice.KEYS.values():
			if (entry as Dictionary).has(device_key):
				out[device_key] = str(entry[device_key])
		return out
	return {InputDevice.KEYS[InputDevice.Kind.KEYBOARD_MOUSE]: str(entry)}

func initialize_settings():
	config.set_value("video", "fullscreen", false)
	config.set_value("video", "v_sync", false)
	config.set_value("video", "max_fps", 144)
	config.set_value("video", "fov", 100.0)
	config.set_value("video", "dev_mode", false)
	# The rendering options (shadows included) are not listed here: GraphicsOptions owns their
	# defaults, and RenderSettings.ensure_initialized() writes the preset guessed for this GPU.
	debug.write_defaults()
	# "auto" follows the OS on first launch, so a French player is not greeted in English.
	config.set_value("general", "language", "auto")
	for key in AUDIO_BUSES:
		config.set_value("audio", key, 100.0)
	# HUD mic toggle, remembered between sessions like every other audio setting.
	config.set_value("audio", "microphone_muted", false)

## Settings > General > Play hints: the keys of the moment on the left of the screen (PlayHintsPanel).
## On by default: they are for the player who does not know the keys yet, and go away once learnt.
func is_play_hints_enabled() -> bool:
	return bool(config.get_value("general", "play_hints", true))


func set_play_hints_enabled(on: bool) -> void:
	config.set_value("general", "play_hints", on)
	save_settings()


func save_settings():
	config.save(CONFIG_FILEPATH)

func reset_settings():
	config.load(CONFIG_FILEPATH)

func load_settings():
	config.load(CONFIG_FILEPATH)
	var settings : Dictionary
	for section in config.get_sections():
		for key in config.get_section_keys(section):
			settings[key] = config.get_value(section, key)
	return settings

## Apply the saved settings to the window. V-Sync always applies; the window's monitor /
## resolution / fullscreen are SKIPPED in dev mode, so running several instances at once doesn't
## force them all to the saved fullscreen/resolution (see the Dev mode checkbox in Video settings).
func apply_settings():
	var vsync: bool = config.get_value("video", "v_sync", false)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	# Cap the framerate (0 = unlimited). Default 144 so an uncapped GPU doesn't render 500+ fps.
	Engine.max_fps = int(config.get_value("video", "max_fps", 144))
	apply_audio_settings()
	language.apply()
	# Before the dev-mode return below: dev mode is about the WINDOW, not about how the game looks.
	if render_applier != null:
		render_applier.apply_all()
	if config.get_value("video", "dev_mode", false):
		return
	if config.has_section_key("video", "monitor"):
		DisplayServer.window_set_current_screen(int(config.get_value("video", "monitor")))
	if config.get_value("video", "fullscreen", false):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		if config.has_section_key("video", "resolution"):
			_apply_window_size(config.get_value("video", "resolution"))

func save_video_settings(key, value):
	config.set_value("video", key, value)

func load_video_settings():
	var video_settings = {}
	for key in config.get_section_keys("video"):
		video_settings[key] = config.get_value("video", key)
	return video_settings

# ── Granular apply + persist (single source of truth for the graphics settings page) ──

func set_fullscreen(on: bool) -> void:
	if on:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		# Leaving fullscreen: go windowed AND restore the chosen size (else it stays full-size).
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_apply_window_size(config.get_value("video", "resolution", DisplayServer.window_get_size()))
	save_video_settings("fullscreen", on)
	save_settings()

func set_vsync(on: bool) -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)
	save_video_settings("v_sync", on)
	save_settings()

## Camera field of view (degrees). Persisted + emitted so the active player camera updates live;
## a freshly spawned camera reads get_fov() on its own.
func set_fov(fov: float) -> void:
	save_video_settings("fov", fov)
	save_settings()
	fov_changed.emit(fov)

func get_fov() -> float:
	return config.get_value("video", "fov", 100.0)

## Cap the framerate at `fps` (0 = unlimited). Applied live via Engine.max_fps + persisted.
func set_max_fps(fps: int) -> void:
	Engine.max_fps = fps
	save_video_settings("max_fps", fps)
	save_settings()

## Real-time shadows on/off (drives the day/night sun's shadow_enabled). Now one of the rendering
## options — written through `render` by the Graphics page and the overlay; kept here, with its
## signal, because the sun and the moons read it from here.
func is_shadows() -> bool:
	return render.effective("shadows")

## Sun shadow draw distance (metres), a rendering option too. See is_shadows().
func get_shadow_distance() -> float:
	return render.effective("shadow_distance")

## The two shadow options predate RenderSettings and have listeners of their own: keep telling them.
func _on_render_changed(keys: PackedStringArray) -> void:
	if "shadows" in keys:
		shadows_changed.emit(is_shadows())
	if "shadow_distance" in keys:
		shadow_distance_changed.emit(get_shadow_distance())

# ── Audio (single source of truth for the audio settings page) ──

## Apply the saved bus volumes + input/output devices on startup.
func apply_audio_settings() -> void:
	for key in AUDIO_BUSES:
		_apply_bus_volume(key, config.get_value("audio", key, 100.0))
	var mic: String = config.get_value("audio", "microphone", "")
	if mic != "" and mic in AudioServer.get_input_device_list():
		AudioServer.input_device = mic
	var speaker: String = config.get_value("audio", "speaker", "")
	if speaker != "" and speaker in AudioServer.get_output_device_list():
		AudioServer.output_device = speaker

## Convert a 0..100 slider value to dB and apply it to the mapped bus (skipped if the bus is
## absent from the layout). 0 -> -80 dB (effectively silent) since linear_to_db(0) is -inf.
func _apply_bus_volume(key: String, value: float) -> void:
	var idx: int = AudioServer.get_bus_index(AUDIO_BUSES.get(key, ""))
	if idx < 0:
		return
	# value 0 -> mute the bus (guaranteed silence); otherwise unmute and set the volume in dB.
	AudioServer.set_bus_mute(idx, value <= 0.0)
	if value > 0.0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(value / 100.0))

## HUD "mute microphone" button. Deliberately touches NO audio bus: muting the capture bus does not
## stop AudioEffectCapture (bus mute applies after the effect chain), so the voice client kept
## sending and the others still heard us. The voice client listens to microphone_muted_changed and
## stops feeding frames instead.
func set_microphone_muted(muted: bool) -> void:
	if is_microphone_muted() == muted:
		return
	config.set_value("audio", "microphone_muted", muted)
	save_settings()
	microphone_muted_changed.emit(muted)

func is_microphone_muted() -> bool:
	return bool(config.get_value("audio", "microphone_muted", false))

func set_audio_volume(key: String, value: float) -> void:
	_apply_bus_volume(key, value)
	config.set_value("audio", key, value)
	save_settings()

func get_audio_volume(key: String) -> float:
	return config.get_value("audio", key, 100.0)

## kind = "microphone" (input) or "speaker" (output).
func set_audio_device(kind: String, device: String) -> void:
	if kind == "microphone":
		AudioServer.input_device = device
	else:
		AudioServer.output_device = device
	config.set_value("audio", kind, device)
	save_settings()

## Dev mode: persist the flag. It is read on startup by apply_settings, which then skips forcing
## the monitor / resolution / fullscreen — handy when launching several instances at once.
func set_dev_mode(on: bool) -> void:
	save_video_settings("dev_mode", on)
	save_settings()

func is_dev_mode() -> bool:
	return config.get_value("video", "dev_mode", false)

## A numeric key of the server's ini, or [param default] when the file or the key is missing. A
## hand-edited value may come back as a String; it is parsed as a float.
static func _server_ini_number(section: String, key: String, default: float) -> float:
	var ini := "server.ini"
	for a: String in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) != OK:
		return default
	var v: Variant = cfg.get_value(section, key, default)
	if v is float or v is int:
		return float(v)
	if v is String and String(v).strip_edges().is_valid_float():
		return String(v).strip_edges().to_float()
	return default

## A boolean key of the server's ini, accepting the bare `true` / `1` / `yes`
## a hand-edited file carries (ConfigFile hands those back as String).
static func _server_ini_flag(section: String, key: String) -> bool:
	var ini := "server.ini"
	for a: String in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) != OK:
		return false
	var v: Variant = cfg.get_value(section, key, false)
	return (v is bool and bool(v)) or (v is int and int(v) != 0) \
			or (v is String and String(v).strip_edges().to_lower() in ["true", "1", "yes"])

func set_monitor(index: int) -> void:
	DisplayServer.window_set_current_screen(index)
	save_video_settings("monitor", index)
	save_settings()

func set_resolution(size: Vector2i) -> void:
	# window_set_size is IGNORED while maximized/fullscreen, so force windowed first.
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_apply_window_size(size)
	save_video_settings("resolution", size)
	save_settings()

## Resize the window and re-center it on its current screen.
func _apply_window_size(size: Vector2i) -> void:
	DisplayServer.window_set_size(size)
	var screen: int = DisplayServer.window_get_current_screen()
	DisplayServer.window_set_position(
		DisplayServer.screen_get_position(screen) + (DisplayServer.screen_get_size(screen) - size) / 2)
