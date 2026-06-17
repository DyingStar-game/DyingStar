extends Control

## Wires the graphics options to SettingsManager (apply + persist), and on open reflects the real
## current display state — including auto-filling the screen resolution with the monitor's size.

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3840, 2160),
]

@onready var _monitor: OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/Monitor/OptionButton
@onready var _display_mode: OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/DisplayMode/OptionButton
@onready var _resolution: OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/ScreenResolution/OptionButton
@onready var _vsync: Button = $ScrollContainer/MarginContainer/VBoxContainer/VSync/Button
@onready var _dev_mode: Button = $ScrollContainer/MarginContainer/VBoxContainer/DevMode/Button

func _ready() -> void:
	_init_monitor()
	_init_display_mode()
	_init_resolution()
	_init_vsync()
	_init_dev_mode()
	_monitor.item_selected.connect(func(i: int) -> void: SettingsManager.set_monitor(i))
	# DisplayMode item id 0 = Fullscreen, 1 = Windowed (as authored in the scene).
	_display_mode.item_selected.connect(
		func(i: int) -> void: SettingsManager.set_fullscreen(_display_mode.get_item_id(i) == 0))
	_resolution.item_selected.connect(
		func(i: int) -> void: SettingsManager.set_resolution(_resolution.get_item_metadata(i)))
	_vsync.toggled.connect(func(on: bool) -> void: SettingsManager.set_vsync(on))
	_dev_mode.toggled.connect(_on_dev_mode_toggled)

## List the real monitors and pre-select the one the window is on.
func _init_monitor() -> void:
	_monitor.clear()
	for i in DisplayServer.get_screen_count():
		_monitor.add_item("Monitor %d" % (i + 1), i)
	_monitor.select(DisplayServer.window_get_current_screen())

## Pre-select Fullscreen / Windowed from the real window mode.
func _init_display_mode() -> void:
	var fs: bool = DisplayServer.window_get_mode() in [
		DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	_display_mode.select(0 if fs else 1)

## Auto-fill: offer the standard resolutions plus the monitor's current size, selected by default.
func _init_resolution() -> void:
	_resolution.clear()
	var current: Vector2i = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	var sizes: Array[Vector2i] = RESOLUTIONS.duplicate()
	if not sizes.has(current):
		sizes.append(current)
	for idx in sizes.size():
		var s: Vector2i = sizes[idx]
		_resolution.add_item("%d x %d" % [s.x, s.y], idx)
		_resolution.set_item_metadata(idx, s)
		if s == current:
			_resolution.select(idx)

func _init_vsync() -> void:
	_vsync.toggle_mode = true
	_vsync.button_pressed = DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED

## Reflect the saved dev-mode flag (it has no live DisplayServer state — it only gates startup).
func _init_dev_mode() -> void:
	_dev_mode.toggle_mode = true
	_dev_mode.button_pressed = SettingsManager.is_dev_mode()
	_dev_mode.text = "On" if _dev_mode.button_pressed else "Off"

func _on_dev_mode_toggled(on: bool) -> void:
	_dev_mode.text = "On" if on else "Off"
	SettingsManager.set_dev_mode(on)
