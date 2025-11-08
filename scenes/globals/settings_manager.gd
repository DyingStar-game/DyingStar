extends Node

const CONFIG_FILEPATH : String = "res://settings.ini"
var config : ConfigFile = ConfigFile.new()

func _ready() -> void:
	if !OS.has_feature("dedicated_server"):
		load_settings()

func initialize_settings():
	config.set_value("video", "fullscreen", false)
	config.set_value("video", "v_sync", false)
	config.set_value("video", "screen_shake", true)

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

func apply_settings():
	var settings = load_settings()
	match settings.fullscreen:
		false:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		true:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	match settings.v_sync:
		false:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		true:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)

func save_video_settings(key, value):
	config.set_value("video", key, value)

func load_video_settings():
	var video_settings = {}
	for key in config.get_section_keys("video"):
		video_settings[key] = config.get_value("video", key)
	return video_settings
