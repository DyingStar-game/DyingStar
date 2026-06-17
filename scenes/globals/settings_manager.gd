extends Node

# user:// is writable in an exported build (res:// is packed read-only), so settings actually
# persist between sessions there.
const CONFIG_FILEPATH : String = "user://settings.ini"
var config : ConfigFile = ConfigFile.new()

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

func initialize_settings():
	config.set_value("video", "fullscreen", false)
	config.set_value("video", "v_sync", false)
	config.set_value("video", "screen_shake", true)
	config.set_value("video", "dev_mode", false)

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

## Dev mode: persist the flag. It is read on startup by apply_settings, which then skips forcing
## the monitor / resolution / fullscreen — handy when launching several instances at once.
func set_dev_mode(on: bool) -> void:
	save_video_settings("dev_mode", on)
	save_settings()

func is_dev_mode() -> bool:
	return config.get_value("video", "dev_mode", false)

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
