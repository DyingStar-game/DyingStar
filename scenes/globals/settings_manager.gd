extends Node

## Emitted when a debug toggle changes, so live systems (e.g. vehicles) react without a restart.
signal cargo_debug_changed(on: bool)
## Emitted when the camera field of view changes, so the active player camera updates live.
signal fov_changed(fov: float)
## Emitted when the "show debug panels" toggle changes, so the in-game HUD reacts live (menu ↔ key).
signal show_debug_changed(on: bool)
signal movement_debug_changed(on: bool)
signal surface_debug_changed(on: bool)
## Emitted when the shadows toggle changes, so the day/night sun enables/disables its shadow live.
signal shadows_changed(on: bool)
## Emitted when the shadow distance changes, so the day/night sun updates its shadow range live.
signal shadow_distance_changed(distance: float)
## Emitted when the celestial-gizmo toggle changes, so the in-world star/planet markers show/hide live.
signal celestial_gizmos_changed(on: bool)
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
const AUDIO_BUSES : Dictionary = {
	"general": "Master", "music": "Music", "sfx": "SFX", "voip": "VoIP",
}
var config : ConfigFile = ConfigFile.new()
## The saved keybindings as action -> key text, empty when nothing was ever remapped. Kept so the
## controls page can show and re-save them without parsing the file a second time.
var keybindings : Dictionary = {}

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		return
	# First run (no file yet): write the defaults so there is something to load.
	if config.load(CONFIG_FILEPATH) != OK:
		initialize_settings()
		save_settings()
	# Re-apply the saved settings to the window on startup (this is what was missing: they were
	# loaded but never applied, so they appeared not to persist).
	apply_settings()
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
		var ev_str: String = str(parsed[action_name])
		keybindings[action_name] = ev_str
		InputMap.action_erase_events(action_name)
		InputMap.action_add_event(action_name, _event_from_text(ev_str))

## Rebuild an InputEvent from the text the controls page saved.
static func _event_from_text(ev_str: String) -> InputEvent:
	if ev_str.begins_with("mouse_"):
		var mouse := InputEventMouseButton.new()
		mouse.button_index = int(ev_str.split("_")[1])
		return mouse
	var key := InputEventKey.new()
	# find_keycode_from_string encodes modifiers in the high bits; split them back out so a saved
	# "Alt + ²" reloads WITH its Alt (else remapped modifier bindings lose the modifier).
	var kc: int = OS.find_keycode_from_string(ev_str)
	key.physical_keycode = kc & KEY_CODE_MASK
	key.alt_pressed = (kc & KEY_MASK_ALT) != 0
	key.ctrl_pressed = (kc & KEY_MASK_CTRL) != 0
	key.shift_pressed = (kc & KEY_MASK_SHIFT) != 0
	key.meta_pressed = (kc & KEY_MASK_META) != 0
	return key

func initialize_settings():
	config.set_value("video", "fullscreen", false)
	config.set_value("video", "v_sync", false)
	config.set_value("video", "max_fps", 144)
	config.set_value("video", "fov", 100.0)
	config.set_value("video", "screen_shake", true)
	config.set_value("video", "dev_mode", false)
	# Real-time shadows on by default; players on weak GPUs can turn them off in Graphics settings.
	config.set_value("video", "shadows", true)
	# Directional (sun) shadow draw distance in metres. Bigger = shadows further out but softer/costlier.
	config.set_value("video", "shadow_distance", 300.0)
	config.set_value("general", "cargo_debug", false)
	# Off by default: labelled markers pointing at the star and every planet/moon (dev/orientation aid).
	config.set_value("general", "celestial_gizmos", false)
	# Shown by default: we are in early alpha, so the in-game debug panels are on out of the box.
	config.set_value("general", "show_debug", true)
	config.set_value("general", "movement_debug", false)
	config.set_value("general", "surface_debug", false)
	for key in AUDIO_BUSES:
		config.set_value("audio", key, 100.0)
	# HUD mic toggle, remembered between sessions like every other audio setting.
	config.set_value("audio", "microphone_muted", false)

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

## Real-time shadows on/off (drives the day/night sun's shadow_enabled). Persisted under [video];
## emits so the sun toggles its shadow live without a restart. Default true.
func set_shadows(on: bool) -> void:
	save_video_settings("shadows", on)
	save_settings()
	shadows_changed.emit(on)

func is_shadows() -> bool:
	return config.get_value("video", "shadows", true)

## Sun shadow draw distance (metres). Persisted under [video]; emits so the sun updates live. Default 300.
func set_shadow_distance(distance: float) -> void:
	save_video_settings("shadow_distance", distance)
	save_settings()
	shadow_distance_changed.emit(distance)

func get_shadow_distance() -> float:
	return config.get_value("video", "shadow_distance", 300.0)

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

## Cargo debug: draw a green envelope around items REALLY locked into a vehicle bed (dev aid). Lives
## under [general]; emits so vehicles toggle their markers live.
func set_cargo_debug(on: bool) -> void:
	config.set_value("general", "cargo_debug", on)
	save_settings()
	cargo_debug_changed.emit(on)

func is_cargo_debug() -> bool:
	return config.get_value("general", "cargo_debug", false)

## Show/hide in-world markers pointing at the star and each planet/moon (orientation aid). Lives under
## [general]; emits so the marker layer toggles live without a restart. Default off.
func set_celestial_gizmos(on: bool) -> void:
	config.set_value("general", "celestial_gizmos", on)
	save_settings()
	celestial_gizmos_changed.emit(on)

func is_celestial_gizmos() -> bool:
	return config.get_value("general", "celestial_gizmos", false)

## Show/hide the in-game debug panels (server/client FPS, coords, counts…). Persisted under [general];
## emits so the HUD toggles live and the settings menu stays in sync with the toggle_debug key.
## Default true (early alpha).
func set_show_debug(on: bool) -> void:
	config.set_value("general", "show_debug", on)
	save_settings()
	show_debug_changed.emit(on)

func is_show_debug() -> bool:
	return config.get_value("general", "show_debug", true)

## Movement debug: a small on-screen readout (speed / mouse-wheel walk tier / current animation clip).
## Lives under [general]; emits so the player HUD toggles live. Default off (dev/calibration aid).
func set_movement_debug(on: bool) -> void:
	config.set_value("general", "movement_debug", on)
	save_settings()
	movement_debug_changed.emit(on)

func is_movement_debug() -> bool:
	# A dedicated server never loads settings.ini (see _ready), so this used
	# to be a constant false there — and the server is the one side whose
	# step-up probe sees terrain (collision is server-only). The server
	# reads `[debug] movement=true` in server.ini instead (same file and
	# `srvini=` override as its `perf` key), resolved once.
	if OS.has_feature("dedicated_server"):
		if _server_movement_debug < 0:
			_server_movement_debug = 1 if _server_ini_flag("debug", "movement") else 0
		return _server_movement_debug == 1
	return config.get_value("general", "movement_debug", false)


## -1 unresolved, else 0/1 — see is_movement_debug.
var _server_movement_debug: int = -1


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

## Surface debug: an on-screen readout of the ground under your feet — the taxonomy family, how it was
## worked out, and whether a footstep sample exists for it. Its own toggle rather than a line added to
## the movement readout: someone chasing a wrong footstep sound has no use for animation clips, and
## someone tuning a walk cycle has none for material ids.
func set_surface_debug(on: bool) -> void:
	config.set_value("general", "surface_debug", on)
	save_settings()
	surface_debug_changed.emit(on)

func is_surface_debug() -> bool:
	return config.get_value("general", "surface_debug", false)

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
